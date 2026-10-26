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
