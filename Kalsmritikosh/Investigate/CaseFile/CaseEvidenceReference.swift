//
//  CaseEvidenceReference.swift
//  Kalsmritikosh
//
//  Implementation brief §4 (P0): case-file evidence references were free strings, while the
//  analytical services already cite an exact source version. A reference now has an explicit kind:
//    • a source version — must exist and be inside THIS case's scope (an exact version, or the
//      current version of a source the case includes; scope is never widened to find a match),
//    • an exhibit in this case's register ("exhibit:EX-001") — a physical item, not a document,
//    • an investigator note ("note:…") — the investigator's own assertion, labelled as such.
//  Anything else is an unresolved legacy reference: refused for new work, kept as written for old
//  rows, and listed in the case's repair queue. A label is never proof of a source's identity.
//

import Foundation

public nonisolated enum CaseEvidenceReference: Equatable, Sendable {
    case sourceVersion(UUID)
    case exhibit(String)
    case investigatorNote(String)
    case unresolved(String)

    public static func parse(_ raw: String) -> CaseEvidenceReference {
        let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: ref) { return .sourceVersion(id) }
        if ref.lowercased().hasPrefix("exhibit:") {
            let number = ref.dropFirst("exhibit:".count).trimmingCharacters(in: .whitespaces)
            return number.isEmpty ? .unresolved(ref) : .exhibit(number)
        }
        if ref.lowercased().hasPrefix("note:") {
            let text = ref.dropFirst("note:".count).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? .unresolved(ref) : .investigatorNote(text)
        }
        return .unresolved(ref)
    }

    /// Why a reference does not resolve in a case, or nil when it does.
    static func problem(_ raw: String, caseID: UUID, in db: isolated Database) throws -> String? {
        switch parse(raw) {
        case .sourceVersion(let id):
            guard try !db.query("SELECT 1 FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(id)]).isEmpty else {
                return "the source version is no longer in the archive"
            }
            let inScope = try !db.query("""
                SELECT 1 FROM investigation_case_sources s
                 WHERE s.case_id = ? AND s.in_scope = 1 AND (
                       (s.source_kind = 'sourceVersion' AND upper(s.source_ref) = upper(?))
                    OR (s.source_kind IN ('logicalSource','workspaceSource') AND EXISTS (
                           SELECT 1 FROM source_versions v WHERE v.id = ? AND v.is_current = 1
                              AND upper(v.logical_source_id) = upper(s.source_ref))))
                 LIMIT 1;
                """, [.uuid(caseID), .text(id.uuidString), .uuid(id)]).isEmpty
            return inScope ? nil : "the source is not in this case's scope"
        case .exhibit(let number):
            let live = try !db.query("SELECT 1 FROM case_exhibits WHERE case_id = ? AND number = ? AND withdrawn_at IS NULL LIMIT 1;",
                                     [.uuid(caseID), .text(number)]).isEmpty
            return live ? nil : "no exhibit \(number) is on this case's register"
        case .investigatorNote:
            return nil
        case .unresolved:
            return "it names no source version, exhibit or investigator note"
        }
    }
}

/// One stored reference that no longer resolves — shown in the case's repair queue, never silently
/// fixed or dropped.
public nonisolated struct UnresolvedCaseReference: Identifiable, Sendable, Equatable {
    public var id: String { "\(record)|\(recordID.uuidString)|\(ref)" }
    public let record: String
    public let recordID: UUID
    public let ref: String
    public let problem: String
}

// MARK: - S15 (ARCH-05) — one typed reference

/// A reference as it travels into an output or a hand-over: the record that cites it, the canonical object and exact
/// version, the locator, whether the cited place is available NOW (checked against the ledger and the case's scope —
/// a missing, superseded, erased or out-of-scope source is said so, never shown as if present), the authorised scope it
/// was checked against, and who asserted it. Built from the map's source references; the quoted words stay in the
/// protected source column of the export, not here.
public nonisolated struct CaseTypedReference: Codable, Hashable, Sendable {
    public enum Availability: String, Codable, Sendable, CaseIterable {
        case available, superseded, erased, outsideScope, positionUnavailable, missingOriginal, changedOnDisk, accessDenied, notRecorded
        public var label: String {
            switch self {
            case .available: return "available"
            case .superseded: return "superseded: a newer version exists; this reference is to the cited version"
            case .erased: return "unavailable: the cited version was erased"
            case .outsideScope: return "unavailable: the cited version is not in this case's scope"
            case .positionUnavailable: return "the document is available; the cited position is not recorded"
            case .missingOriginal: return "unavailable: the original file is missing and no copy was kept"
            case .changedOnDisk: return "unavailable: the file changed since it was cited"
            case .accessDenied: return "unavailable: this Mac does not let the app read the file"
            case .notRecorded: return "no source version recorded"
            }
        }
        /// The file-level outcome of opening the cited version (CitedSourceResolver), as an availability.
        public init(_ u: CitedSourceResolver.Unavailable) {
            switch u {
            case .erased: self = .erased
            case .superseded: self = .superseded
            case .changedOnDisk: self = .changedOnDisk
            case .missingOriginal: self = .missingOriginal
            case .accessDenied: self = .accessDenied
            }
        }
    }
    public struct Locator: Codable, Hashable, Sendable {
        public var blockID: UUID?
        public var note: String?
    }
    /// The citing record's stable key ("kind:id").
    public var holder: String
    public var objectID: UUID?
    public var sourceVersionID: UUID?
    public var locator: Locator
    public var availability: Availability
    /// The scope fingerprint it was checked against (nil: not checked against a recorded scope).
    public var scopeFingerprint: String?
    /// Who asserted it (investigator, rule or model, with the name), as the map labels it.
    public var provenance: String

    /// One exported row: holder, object, version, locator, availability, scope, provenance.
    public var fields: [String] {
        [holder, objectID?.uuidString.lowercased() ?? "", sourceVersionID?.uuidString.lowercased() ?? "",
         locator.blockID.map { "block \($0.uuidString.lowercased())" } ?? (locator.note ?? ""), availability.label, scopeFingerprint ?? "not recorded", provenance]
    }
}

public nonisolated enum CaseTypedReferences {
    /// The reference with its availability read from the ledger inside the caller's savepoint (no file is opened here; a
    /// caller that opened the file passes CitedSourceResolver's outcome through `Availability.init`).
    static func resolve(_ db: isolated Database, caseID: UUID, holder: String, source s: CaseMapSourceRef, provenance: String,
                        scopeFingerprint: String?) throws -> CaseTypedReference {
        var r = CaseTypedReference(holder: holder, objectID: s.objectID, sourceVersionID: s.sourceVersionID,
                                   locator: .init(blockID: s.blockID, note: s.positionAvailable ? nil : "position not recorded"),
                                   availability: .notRecorded, scopeFingerprint: scopeFingerprint, provenance: provenance)
        guard let v = s.sourceVersionID else { return r }
        guard let row = try db.query("SELECT is_current FROM source_versions WHERE id IN (?, ?, ?) LIMIT 1;",
                                     [.text(v.uuidString), .text(v.uuidString.lowercased()), .uuid(v)]).first else {
            r.availability = .erased; return r
        }
        if try CaseEvidenceReference.problem(v.uuidString, caseID: caseID, in: db) != nil, !(try CaseFileRepository.versionInCase(db, v, caseID: caseID)) {
            r.availability = .outsideScope; return r
        }
        if (row.int(0) ?? 1) != 1 { r.availability = .superseded; return r }
        if let b = s.blockID {
            let present = try !db.query("SELECT 1 FROM evidence_blocks WHERE id IN (?, ?, ?) LIMIT 1;",
                                        [.text(b.uuidString), .text(b.uuidString.lowercased()), .uuid(b)]).isEmpty
            r.availability = present ? .available : .positionUnavailable
            return r
        }
        r.availability = s.positionAvailable ? .available : .positionUnavailable
        return r
    }
}
