//
//  CaseHistoryReview.swift
//  Kalsmritikosh
//
//  Smart-map S7 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §16 HISTORY; plan §9; schema v183). Prior cases
//  and the investigation of an investigation, inside explicit, governed boundaries. Nothing here calls a model or the network.
//
//  • Overlap (HISTORY-01): CaseDeconfliction stays the entity-overlap signal (counts and case names only) and now says its
//    basis — a phone or email is an exact identifier; a person or organisation is a same-NAME match and stays a candidate.
//    The investigator can choose exact identifiers (account numbers, references, phones, emails) or a pattern to look for in
//    other cases; a pattern match is a candidate too. Restricted (privileged or above confidential) documents are neither
//    searched nor counted, and the result never says how many were left out.
//  • History set (HISTORY-02): a case's own selection of other cases, imported collections or configured external sources,
//    each with a purpose and a permitted scope — separate from global search. There is no kind for AI memory: it is not a
//    documentary source; an external source is "configured, not read" until its material is imported.
//  • Cross-case references (HISTORY-03): origin case, record, live or pinned recorded state, scope and purpose. A reference
//    holds no copy of the record: reading it re-reads the origin under TODAY's access (history source, scope, privilege,
//    erasure). The same-case write checks (CaseMapRepository.belongs, CaseFileRepository.requireInCase) are unchanged: a map
//    link to another case's record is still refused; a reference is its own record type.
//  • Comparison (HISTORY-04): times, identifiers, circumstances and limits side by side; it records nothing and decides
//    nothing — similarity is not a common cause and a same name is not the same person.
//  • Review case (HISTORY-05): a separate mother case that references another case's records, actions and decisions and owns
//    its own findings. Nothing in the review writes to the original case.
//  • Known at the time (HISTORY-06): the origin's nearest recorded state at or before a moment and the record's recorded
//    revisions up to then; absent history is said, never reconstructed.
//  • Later restrictions (HISTORY-07): every read, comparison and export re-checks; a withdrawn source, an erased case or a
//    privileged document leaves an "unavailable" reference, not a retained copy.
//  • Return paths (HISTORY-08): a finding traces to the original record, its decision, sources and work, and the original
//    record lists the reviews that reference it; the review's chronology, authorship and conclusions export on their own.
//

import Foundation
import os

// MARK: - Cross-case access (HISTORY-07)

public nonisolated enum CaseCrossCaseAccess {
    /// What may be read across cases: nothing privileged, nothing above confidential.
    public static let scopeNote = "Documents labelled privileged or restricted are not read, searched or counted across cases."

    /// The versions among `versions` that may be read or counted across cases (unresolvable lineage is not).
    public static func permitted(_ versions: Set<UUID>, database: Database) async throws -> Set<UUID> {
        guard !versions.isEmpty else { return [] }
        let repo = SensitiveScopeRepository(database: database)
        let scope = SensitiveScope(workspaceID: UUID(), maximumSensitivity: .confidential, permitsPrivilegedMaterial: false, purpose: .retrieval)
        var out = Set<UUID>()
        for v in versions {
            if case .resolved(let label) = try await repo.effectiveLabel(for: SensitiveScopeTarget(kind: .sourceVersion, id: v)), scope.permits(label) { out.insert(v) }
        }
        return out
    }
}

// MARK: - HISTORY-01 chosen identifiers

public nonisolated enum CaseOverlapBasis: String, Sendable, CaseIterable {
    case exactIdentifier, sameName, pattern
    public var label: String {
        switch self {
        case .exactIdentifier: return "Exact identifier"
        case .sameName: return "Same name only — a candidate, not the same person or organisation"
        case .pattern: return "Matches a pattern — a candidate, not the same thing"
        }
    }
    public var isCandidate: Bool { self != .exactIdentifier }
}

extension CaseOverlapEntity {
    /// HISTORY-01 — a phone number or email address is an exact identifier; a person or organisation is matched by name.
    public var basis: CaseOverlapBasis { ["phoneNumber", "emailAddress"].contains(kind) ? .exactIdentifier : .sameName }
    public var isCandidate: Bool { basis.isCandidate }
}

public nonisolated enum CaseOverlapIdentifierKind: String, Sendable, CaseIterable, Codable {
    case accountNumber, reference, phone, email, identifier, pattern
    public var label: String {
        switch self {
        case .accountNumber: return "Account number"
        case .reference: return "Payment or document reference"
        case .phone: return "Phone number"
        case .email: return "Email address"
        case .identifier: return "Other identifier"
        case .pattern: return "Pattern (# is any digit)"
        }
    }
}

public nonisolated struct CaseOverlapIdentifier: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let kind: CaseOverlapIdentifierKind
    public let value: String
    public let chosenBy: String
    public let chosenAt: Date
    public var basis: CaseOverlapBasis { kind == .pattern ? .pattern : .exactIdentifier }
    /// The regular expression it is looked for with (whole token, case-insensitive; a phone by its digits).
    public var regex: String {
        let edge = "(?<![A-Za-z0-9])", end = "(?![A-Za-z0-9])"
        switch kind {
        case .pattern:
            return edge + value.map { $0 == "#" ? "[0-9]" : NSRegularExpression.escapedPattern(for: String($0)) }.joined() + end
        case .phone:
            let digits = value.filter(\.isNumber)
            return edge + digits.map { String($0) }.joined(separator: "[\\s().-]*") + end
        default:
            return edge + NSRegularExpression.escapedPattern(for: value) + end
        }
    }
}

/// One chosen identifier and the other cases it is found in (case names and counts only).
public nonisolated struct CaseIdentifierOverlap: Sendable, Equatable, Identifiable {
    public var id: UUID { identifier.id }
    public let identifier: CaseOverlapIdentifier
    public let basis: CaseOverlapBasis
    public let otherCases: [CaseOverlapCase]
    /// Other cases that record an account with this identifier (structured, exact).
    public let accountInCases: [UUID]
    public var summary: String {
        let where_ = otherCases.map(\.phrase).joined(separator: " · ")
        return "\(identifier.kind.label) “\(identifier.value)” — \(basis.label). " + (where_.isEmpty ? "Not found in another case." : where_)
            + " " + CaseCrossCaseAccess.scopeNote
    }
}

// MARK: - HISTORY-02 history sources

public nonisolated enum CaseHistorySourceKind: String, Sendable, CaseIterable, Codable {
    case `case`, collection, external
    public var label: String {
        switch self {
        case .case: return "Another case on this Mac"
        case .collection: return "An imported collection"
        case .external: return "A configured external source (not read by the app)"
        }
    }
    /// Whether its own records are documentary sources. An external source is a pointer until its material is imported.
    public var isDocumentary: Bool { self != .external }
}

public nonisolated enum CaseHistoryScope: String, Sendable, CaseIterable, Codable {
    case identifiersOnly, records, recordsAndSources
    public var label: String {
        switch self {
        case .identifiersOnly: return "Identifiers and dates only"
        case .records: return "Records (no source passages)"
        case .recordsAndSources: return "Records and their source passages"
        }
    }
}

public nonisolated struct CaseHistorySource: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let kind: CaseHistorySourceKind
    public let originCaseID: UUID?
    public let collectionRef: String?
    public let externalName: String?
    public let purpose: String
    public let scope: CaseHistoryScope
    public let selectedBy: String
    public let selectedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
}

// MARK: - HISTORY-03 references

public nonisolated enum CaseCrossReferenceMode: String, Sendable, CaseIterable, Codable {
    case snapshot, live
    public var label: String {
        switch self {
        case .snapshot: return "Pinned to a recorded state (it does not change)"
        case .live: return "Follows the record (it can change)"
        }
    }
}

public nonisolated struct CaseCrossReference: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let historySourceID: UUID
    public let originCaseID: UUID
    public let origin: CaseMapNodeID
    public let mode: CaseCrossReferenceMode
    public let pinnedCheckpointID: UUID?
    public let purpose: String
    public let createdBy: String
    public let createdAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
}

/// A reference as it reads TODAY (re-checked).
public nonisolated struct CaseCrossReferenceView: Sendable, Equatable {
    public enum State: Equatable, Sendable { case available, unavailable(String) }
    public let reference: CaseCrossReference
    public let state: State
    public let title: String?
    public let wording: String?
    public let review: CaseMapReviewState?
    public let statusText: String?
    /// Sources shown (only those cleared for cross-case reading, and only when the scope includes source passages).
    public let sources: [CaseMapSourceRef]
    /// The origin's links of this record to its work (tasks) and what it rests on, by title.
    public let work: [String]
    public let asOf: String
    public let note: String?
    public var isAvailable: Bool { state == .available }
}

// MARK: - HISTORY-04 comparison

public nonisolated struct CaseHistoryComparisonCrossCase: Sendable, Equatable {
    public struct Line: Sendable, Equatable { public let aspect: String; public let thisCase: String; public let otherCase: String; public let note: String }
    public let similarities: [Line]
    public let differences: [Line]
    public let limitations: [String]
    public static let caution = "Similarity is not a finding of a common cause, and a same name is not the same person. This comparison records nothing and decides nothing."
}

// MARK: - HISTORY-05 / 08 review

public nonisolated enum CaseReviewAssessment: String, Sendable, CaseIterable, Codable {
    case agrees, disagrees, incomplete, notAssessable, observation
    public var label: String {
        switch self {
        case .agrees: return "The review agrees with it"
        case .disagrees: return "The review disagrees with it"
        case .incomplete: return "The review finds it incomplete"
        case .notAssessable: return "The review could not assess it"
        case .observation: return "An observation of the review"
        }
    }
}

public nonisolated struct CaseReviewFinding: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let caseID: UUID
    public let referenceID: UUID
    public let assessment: CaseReviewAssessment
    public let text: String
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
}

public nonisolated struct CaseReviewTrace: Sendable, Equatable {
    public let finding: CaseReviewFinding
    public let reference: CaseCrossReferenceView
    /// The original decision as recorded (its review state and status), or why it cannot be read.
    public let originalDecision: String
}

public nonisolated struct CaseOriginKnownAt: Sendable, Equatable {
    public let knownAt: CaseKnownAt
    /// The record's recorded revisions at or before the moment ("change by actor at time").
    public let revisions: [String]
    /// What history is absent (the baseline), said.
    public let absentHistory: String
}

public nonisolated enum CaseHistoryReviewError: Error, Equatable, LocalizedError {
    case sameCase
    case originNotFound
    case collectionNotFound
    case sourceNotActive
    case scopeTooNarrow
    case recordNotInOrigin
    case checkpointNotInOrigin
    case referenceNotFound
    case notAReview
    case noRecordedState(String)
    case badPattern
    public var errorDescription: String? {
        switch self {
        case .sameCase: return "A case's history set holds other cases, not itself."
        case .originNotFound: return "That case is not on this Mac (it may have been erased)."
        case .collectionNotFound: return "That collection was not found."
        case .sourceNotActive: return "That case is not (or no longer) in this case's history set. Add it with a purpose first."
        case .scopeTooNarrow: return "The history set allows identifiers and dates only from that case; a reference to its records needs a wider scope."
        case .recordNotInOrigin: return "That record is not part of the other case."
        case .checkpointNotInOrigin: return "That recorded state is not one of the other case's (or its content was erased)."
        case .referenceNotFound: return "That reference is not in this case."
        case .notAReview: return "This case is not recorded as a review of that case."
        case .noRecordedState(let baseline): return "No recorded state of that case exists for that time. \(baseline)"
        case .badPattern: return "A pattern needs at least one letter or digit besides #."
        }
    }
}

// MARK: - Writes (the ONE case file repository; every write is in the case that owns it)

extension CaseFileRepository {

    @discardableResult
    public func chooseOverlapIdentifier(caseID: UUID, kind: CaseOverlapIdentifierKind, value: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), v = try Self.clean(value, "The identifier")
        if kind == .pattern, !v.contains(where: { $0 != "#" && ($0.isLetter || $0.isNumber) }) { throw CaseHistoryReviewError.badPattern }
        let id = UUID()
        try await write("cf_hid", caseID: caseID, actor: who, action: "overlapIdentifierChosen", detail: "\(kind.rawValue): \(v)", at: date, allowedWhenClosed: true) { db in
            try db.exec("INSERT INTO case_overlap_identifiers (id, case_id, kind, value, chosen_by, chosen_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(v), .text(who), .date(date)])
        }
        return id
    }

    public func overlapIdentifiers(caseID: UUID) async throws -> [CaseOverlapIdentifier] {
        try await database.query("SELECT id, kind, value, chosen_by, chosen_at FROM case_overlap_identifiers WHERE case_id = ? AND withdrawn_at IS NULL ORDER BY chosen_at, rowid;",
                                 [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1).flatMap(CaseOverlapIdentifierKind.init(rawValue:)), let v = r.string(2), let by = r.string(3), let at = r.date(4) else { return nil }
            return CaseOverlapIdentifier(id: id, kind: k, value: v, chosenBy: by, chosenAt: at)
        }
    }

    /// HISTORY-02 — add another case, a collection or a configured external source to this case's history set.
    @discardableResult
    public func addHistorySource(caseID: UUID, kind: CaseHistorySourceKind, originCaseID: UUID? = nil, collectionRef: String? = nil, externalName: String? = nil,
                                 purpose: String, scope: CaseHistoryScope, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(purpose, "The purpose")
        if kind == .case { guard let o = originCaseID else { throw CaseHistoryReviewError.originNotFound }; if o == caseID { throw CaseHistoryReviewError.sameCase } }
        if kind == .external, Self.blankToNil(externalName) == nil { throw CaseFileError.blank("The external source's name") }
        if kind == .collection, Self.blankToNil(collectionRef) == nil { throw CaseHistoryReviewError.collectionNotFound }
        let id = UUID()
        try await write("cf_hsrc", caseID: caseID, actor: who, action: "historySourceAdded", detail: "\(kind.rawValue) (\(scope.rawValue)): \(why)", at: date, allowedWhenClosed: true) { db in
            if kind == .case, let o = originCaseID {
                guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(o)]).isEmpty else { throw CaseHistoryReviewError.originNotFound }
            }
            if kind == .collection, let c = Self.blankToNil(collectionRef) {
                guard try !db.query("SELECT 1 FROM workspaces WHERE id IN (?, ?, ?);", [.text(c), .text(c.uppercased()), .text(c.lowercased())]).isEmpty else {
                    throw CaseHistoryReviewError.collectionNotFound
                }
            }
            try db.exec("""
                INSERT INTO case_history_sources (id, case_id, source_kind, origin_case_id, collection_ref, external_name, purpose, permitted_scope, selected_by, selected_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), originCaseID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(collectionRef)),
                      .optionalText(Self.blankToNil(externalName)), .text(why), .text(scope.rawValue), .text(who), .date(date)])
        }
        return id
    }

    public func withdrawHistorySource(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_hsrcw", caseID: caseID, actor: who, action: "historySourceWithdrawn", detail: why, at: date, allowedWhenClosed: true) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM case_history_sources WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseHistoryReviewError.sourceNotActive
            }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_history_sources SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func historySources(caseID: UUID) async throws -> [CaseHistorySource] {
        try await database.query("""
            SELECT id, source_kind, origin_case_id, collection_ref, external_name, purpose, permitted_scope, selected_by, selected_at, withdrawn_at
            FROM case_history_sources WHERE case_id = ? ORDER BY selected_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1).flatMap(CaseHistorySourceKind.init(rawValue:)), let p = r.string(5),
                  let sc = r.string(6).flatMap(CaseHistoryScope.init(rawValue:)), let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseHistorySource(id: id, caseID: caseID, kind: k, originCaseID: r.uuid(2), collectionRef: r.string(3), externalName: r.string(4), purpose: p,
                                     scope: sc, selectedBy: by, selectedAt: at, withdrawnAt: r.date(9))
        }
    }

    /// HISTORY-03 — a reference from this case to one record of a case in its history set (live, or pinned to one of that
    /// case's recorded states). Checked inside the write: the history source is active and allows records, the record is in
    /// the origin case (the origin's own write check), and a pinned state is one of the origin's, not erased.
    @discardableResult
    public func addCrossReference(caseID: UUID, historySourceID: UUID, origin: CaseMapNodeID, mode: CaseCrossReferenceMode, pinnedCheckpointID: UUID? = nil,
                                  purpose: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(purpose, "The purpose")
        guard origin.caseID != caseID else { throw CaseHistoryReviewError.sameCase }
        if mode == .snapshot, pinnedCheckpointID == nil { throw CaseHistoryReviewError.checkpointNotInOrigin }
        let id = UUID()
        try await write("cf_xref", caseID: caseID, actor: who, action: "crossReferenceAdded", detail: "\(origin.key) (\(mode.rawValue)): \(why)", at: date, allowedWhenClosed: false) { db in
            guard let src = try db.query("SELECT source_kind, origin_case_id, permitted_scope FROM case_history_sources WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;",
                                         [.uuid(historySourceID), .uuid(caseID)]).first,
                  src.string(0) == CaseHistorySourceKind.case.rawValue, src.uuid(1) == origin.caseID else { throw CaseHistoryReviewError.sourceNotActive }
            guard src.string(2) != CaseHistoryScope.identifiersOnly.rawValue else { throw CaseHistoryReviewError.scopeTooNarrow }
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(origin.caseID)]).isEmpty else { throw CaseHistoryReviewError.originNotFound }
            guard CaseMapRecordKind.linkable.contains(origin.kind), try CaseMapRepository.belongs(db, origin, caseID: origin.caseID) else {
                throw CaseHistoryReviewError.recordNotInOrigin
            }
            if let cp = pinnedCheckpointID {
                guard try !db.query("SELECT 1 FROM case_checkpoints WHERE id = ? AND case_id = ? AND erased_at IS NULL;", [.uuid(cp), .uuid(origin.caseID)]).isEmpty else {
                    throw CaseHistoryReviewError.checkpointNotInOrigin
                }
            }
            try db.exec("""
                INSERT INTO case_cross_references (id, case_id, history_source_id, origin_case_id, origin_kind, origin_record_id, mode, pinned_checkpoint_id, purpose,
                    created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(historySourceID), .uuid(origin.caseID), .text(origin.kind.rawValue), .text(origin.recordID), .text(mode.rawValue),
                      pinnedCheckpointID.map { .uuid($0) } ?? .null, .text(why), .text(who), .date(date)])
        }
        return id
    }

    public func withdrawCrossReference(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_xrefw", caseID: caseID, actor: who, action: "crossReferenceWithdrawn", detail: why, at: date) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM case_cross_references WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseHistoryReviewError.referenceNotFound
            }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE case_cross_references SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    public func crossReferences(caseID: UUID) async throws -> [CaseCrossReference] {
        try await database.query("""
            SELECT id, history_source_id, origin_case_id, origin_kind, origin_record_id, mode, pinned_checkpoint_id, purpose, created_by, created_at, withdrawn_at
            FROM case_cross_references WHERE case_id = ? ORDER BY created_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let hs = r.uuid(1), let oc = r.uuid(2), let k = r.string(3).flatMap(CaseMapRecordKind.init(rawValue:)), let rid = r.string(4),
                  let m = r.string(5).flatMap(CaseCrossReferenceMode.init(rawValue:)), let p = r.string(7), let by = r.string(8), let at = r.date(9) else { return nil }
            return CaseCrossReference(id: id, caseID: caseID, historySourceID: hs, originCaseID: oc, origin: CaseMapNodeID(caseID: oc, kind: k, recordID: rid), mode: m,
                                      pinnedCheckpointID: r.uuid(6), purpose: p, createdBy: by, createdAt: at, withdrawnAt: r.date(10))
        }
    }

    /// HISTORY-05 — record that this case reviews another investigation; the origin joins its history set (records and
    /// their source passages, re-checked on every read). The origin case is not written.
    @discardableResult
    public func startReview(caseID: UUID, of originCaseID: UUID, purpose: String, actor: String, at date: Date = Date()) async throws -> (review: UUID, historySource: UUID) {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(purpose, "The purpose")
        guard originCaseID != caseID else { throw CaseHistoryReviewError.sameCase }
        let id = UUID()
        try await write("cf_rev", caseID: caseID, actor: who, action: "reviewStarted", detail: why, at: date) { db in
            guard try !db.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(originCaseID)]).isEmpty else { throw CaseHistoryReviewError.originNotFound }
            try db.exec("INSERT INTO case_review_of (id, case_id, origin_case_id, purpose, created_by, created_at) VALUES (?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .uuid(originCaseID), .text(why), .text(who), .date(date)])
        }
        let src = try await addHistorySource(caseID: caseID, kind: .case, originCaseID: originCaseID, purpose: "Review: \(why)", scope: .recordsAndSources, actor: who, at: date)
        return (id, src)
    }

    /// The cases this case reviews.
    public func reviewedCases(caseID: UUID) async throws -> [UUID] {
        try await database.query("SELECT origin_case_id FROM case_review_of WHERE case_id = ? AND ended_at IS NULL ORDER BY created_at;", [.uuid(caseID)]).compactMap { $0.uuid(0) }
    }

    /// HISTORY-05 — the review's own finding about a referenced record. Written in the review case only.
    @discardableResult
    public func recordReviewFinding(caseID: UUID, referenceID: UUID, assessment: CaseReviewAssessment, text: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), t = try Self.clean(text, "The finding")
        let id = UUID()
        try await write("cf_revf", caseID: caseID, actor: who, action: "reviewFindingRecorded", detail: assessment.rawValue, at: date) { db in
            guard let ref = try db.query("SELECT origin_case_id FROM case_cross_references WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;",
                                         [.uuid(referenceID), .uuid(caseID)]).first?.uuid(0) else { throw CaseHistoryReviewError.referenceNotFound }
            guard try !db.query("SELECT 1 FROM case_review_of WHERE case_id = ? AND origin_case_id = ? AND ended_at IS NULL;", [.uuid(caseID), .uuid(ref)]).isEmpty else {
                throw CaseHistoryReviewError.notAReview
            }
            try db.exec("INSERT INTO case_review_findings (id, case_id, reference_id, assessment, finding_text, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?);",
                        [.uuid(id), .uuid(caseID), .uuid(referenceID), .text(assessment.rawValue), .text(t), .text(who), .date(date)])
        }
        return id
    }

    public func reviewFindings(caseID: UUID) async throws -> [CaseReviewFinding] {
        try await database.query("""
            SELECT id, reference_id, assessment, finding_text, recorded_by, recorded_at, withdrawn_at FROM case_review_findings WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let ref = r.uuid(1), let a = r.string(2).flatMap(CaseReviewAssessment.init(rawValue:)), let t = r.string(3), let by = r.string(4),
                  let at = r.date(5) else { return nil }
            return CaseReviewFinding(id: id, caseID: caseID, referenceID: ref, assessment: a, text: t, recordedBy: by, recordedAt: at, withdrawnAt: r.date(6))
        }
    }
}

// MARK: - Reads (re-checked every time)

public actor CaseHistoryReviewService {
    private let database: Database
    private let file: CaseFileRepository
    private let map: CaseMapService
    private let history: CaseHistoryService

    public init(database: Database, file: CaseFileRepository, map: CaseMapService) {
        self.database = database; self.file = file; self.map = map
        self.history = CaseHistoryService(database: database, map: map)
    }

    // MARK: HISTORY-01

    /// Each chosen identifier and the other cases whose in-scope, cross-case-readable documents contain it as a whole token,
    /// or that record an account with it (exact). Case names and counts only — never a passage, a file name or a count of
    /// what was not readable.
    public func identifierOverlaps(caseID: UUID) async throws -> [CaseIdentifierOverlap] {
        let chosen = try await file.overlapIdentifiers(caseID: caseID)
        guard !chosen.isEmpty else { return [] }
        let ctx = try await CaseDeconfliction(database: database).prepare(caseID: caseID)
        var versionsByCase: [UUID: Set<UUID>] = [:]
        for (v, owners) in ctx.versionCases { for o in owners where o != caseID && ctx.cases[o] != nil { versionsByCase[o, default: []].insert(v) } }
        let readable = try await CaseCrossCaseAccess.permitted(Set(versionsByCase.values.flatMap { $0 }), database: database)
        var out: [CaseIdentifierOverlap] = []
        for ident in chosen {
            let probe: String
            switch ident.kind {
            case .pattern:
                let pieces: [String] = ident.value.split(separator: "#").map { String($0) }
                probe = pieces.max { $0.count < $1.count } ?? ""
            case .phone:
                probe = String(ident.value.filter { $0.isNumber }.suffix(4))
            default:
                probe = ident.value
            }
            let pattern = ident.regex
            var perCase: [UUID: Int] = [:]
            for (other, versions) in versionsByCase {
                let ok = Array(versions.intersection(readable))
                guard !ok.isEmpty else { continue }
                var docs = Set<UUID>()
                for chunk in CaseDeconfliction.chunks(ok) {
                    let rows = try await database.query("""
                        SELECT source_version_id, raw_text FROM evidence_blocks
                        WHERE source_version_id IN (\(chunk.map { _ in "?" }.joined(separator: ","))) AND instr(lower(raw_text), lower(?)) > 0;
                        """, chunk.map { SQLValue.uuid($0) } + [.text(probe)])
                    for r in rows {
                        guard let v = r.uuid(0), let t = r.string(1) else { continue }
                        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
                        guard t.range(of: pattern, options: opts) != nil else { continue }
                        docs.insert(v)
                    }
                }
                if !docs.isEmpty { perCase[other] = docs.count }
            }
            var accountCases: [UUID] = []
            if ident.kind == .accountNumber {
                let key = CaseMoneyAccount.key(ident.value, institution: nil)
                accountCases = try await database.query("""
                    SELECT DISTINCT case_id FROM case_money_accounts WHERE withdrawn_at IS NULL AND case_id <> ? AND (identifier_key = ? OR identifier_key LIKE ?);
                    """, [.uuid(caseID), .text(key), .text(key + "@%")]).compactMap { $0.uuid(0) }.filter { ctx.cases[$0] != nil }
                for c in accountCases where perCase[c] == nil { perCase[c] = 0 }
            }
            let cases = perCase.compactMap { id, n -> CaseOverlapCase? in
                guard let info = ctx.cases[id] else { return nil }
                return CaseOverlapCase(caseID: id, workspaceID: info.workspaceID, title: info.title, status: info.status, closed: info.closed, archived: info.archived, documents: n)
            }.sorted { ($0.documents, $1.title) > ($1.documents, $0.title) }
            out.append(CaseIdentifierOverlap(identifier: ident, basis: ident.basis, otherCases: cases, accountInCases: accountCases.sorted { $0.uuidString < $1.uuidString }))
        }
        return out
    }

    // MARK: HISTORY-03 / 06 / 07 resolve

    func source(_ id: UUID, caseID: UUID) async throws -> CaseHistorySource? {
        try await file.historySources(caseID: caseID).first { $0.id == id }
    }

    /// Read one reference as it is today: the history source must still be active, the origin case must exist, the record
    /// must still be in it (live) or in the pinned recorded state (snapshot, itself re-checked for scope and privilege), and
    /// only cross-case-readable sources are shown — and only when the scope includes source passages.
    public func resolve(caseID: UUID, referenceID: UUID) async throws -> CaseCrossReferenceView {
        guard let ref = try await file.crossReferences(caseID: caseID).first(where: { $0.id == referenceID }) else { throw CaseHistoryReviewError.referenceNotFound }
        func unavailable(_ why: String) -> CaseCrossReferenceView {
            CaseCrossReferenceView(reference: ref, state: .unavailable(why), title: nil, wording: nil, review: nil, statusText: nil, sources: [], work: [], asOf: "—", note: nil)
        }
        guard ref.isActive else { return unavailable("The reference was withdrawn.") }
        guard let src = try await source(ref.historySourceID, caseID: caseID), src.isActive else {
            return unavailable("The other case is no longer in this case's history set (access withdrawn).")
        }
        guard try await !database.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(ref.originCaseID)]).isEmpty else {
            return unavailable("The case it refers to is no longer on this Mac (erased). Nothing of it was kept here.")
        }
        let projection: CaseMapProjection
        let asOf: String
        switch ref.mode {
        case .live:
            let load = await map.load(caseID: ref.originCaseID, generation: 1)
            guard let p = load.projection else { return unavailable("The other case could not be read now.") }
            projection = p; asOf = "as the other case is now"
        case .snapshot:
            guard let cp = ref.pinnedCheckpointID else { return unavailable("No recorded state is pinned.") }
            do {
                let view = try await history.open(id: cp, caseID: ref.originCaseID)
                projection = view.projection; asOf = view.summary.stateLabel
            } catch {
                KalsmritikoshLog.app.notice("Cross-case reference: pinned state unreadable: \(error.localizedDescription, privacy: .public)")
                return unavailable("The pinned recorded state cannot be read: \(error.localizedDescription)")
            }
        }
        guard let node = projection.node(ref.origin) else {
            return unavailable(ref.mode == .live ? "The record is no longer in the other case (removed, withdrawn or out of its scope)." : "The record is not in the pinned recorded state.")
        }
        let cited = Set(node.sources.compactMap(\.sourceVersionID))
        let readable = try await CaseCrossCaseAccess.permitted(cited, database: database)
        let withheld = !cited.subtracting(readable).isEmpty
        let showSources = src.scope == .recordsAndSources
        let sources = showSources ? node.sources.filter { $0.sourceVersionID.map(readable.contains) ?? false } : []
        let quotesDocument = [.evidence, .contradiction, .statement].contains(node.kind)
        let wording: String? = (withheld && quotesDocument) || (!showSources && quotesDocument)
            ? "Not shown: this record quotes material that is not cleared for reading from this case." : node.wording
        let work = projection.links(of: ref.origin).compactMap { l -> String? in
            let other = l.from == ref.origin ? l.to : l.from
            guard [.task, .request, .reportPoint, .reportItem, .report].contains(other.kind), let n = projection.node(other) else { return nil }
            return "\(l.type.label): \(n.title)"
        }.sorted()
        var note: [String] = []
        if withheld { note.append(CaseCrossCaseAccess.scopeNote) }
        if !showSources { note.append("The history set allows records without their source passages.") }
        if ref.mode == .live { note.append("A live reference follows the record and can change.") }
        return CaseCrossReferenceView(reference: ref, state: .available, title: node.title, wording: wording, review: node.review, statusText: node.status.text,
                                      sources: sources, work: work, asOf: asOf, note: note.isEmpty ? nil : note.joined(separator: " "))
    }

    /// HISTORY-06 — what the origin case had recorded about the referenced record at `moment`: its nearest recorded state and
    /// the record's recorded revisions up to then. Absent history is said, never filled in.
    public func originKnownAt(caseID: UUID, referenceID: UUID, at moment: Date) async throws -> CaseOriginKnownAt {
        guard let ref = try await file.crossReferences(caseID: caseID).first(where: { $0.id == referenceID && $0.isActive }) else { throw CaseHistoryReviewError.referenceNotFound }
        guard let src = try await source(ref.historySourceID, caseID: caseID), src.isActive else { throw CaseHistoryReviewError.sourceNotActive }
        let known = try await history.knownAt(caseID: ref.originCaseID, moment)
        let baseline = try await history.baseline(caseID: ref.originCaseID)
        let revisions = try await database.query("""
            SELECT change, actor, recorded_at FROM case_record_revisions
            WHERE case_id = ? AND record_kind = ? AND lower(record_id) = ? AND recorded_at <= ? ORDER BY recorded_at, rowid;
            """, [.uuid(ref.originCaseID), .text(ref.origin.kind.rawValue), .text(ref.origin.recordID), .date(moment.addingTimeInterval(0.001))]).compactMap { r -> String? in
            guard let c = r.string(0), let a = r.string(1), let at = r.date(2) else { return nil }
            return "\(c) by \(a) at \(at.formatted(date: .abbreviated, time: .shortened))"
        }
        return CaseOriginKnownAt(knownAt: known, revisions: revisions, absentHistory: baseline.label)
    }

    /// Pin a snapshot reference to what the origin case had recorded at `moment` (its nearest recorded state then).
    public func pinAsKnownAt(caseID: UUID, historySourceID: UUID, origin: CaseMapNodeID, at moment: Date, purpose: String, actor: String) async throws -> UUID {
        switch try await history.knownAt(caseID: origin.caseID, moment) {
        case .recorded(let cp, _):
            return try await file.addCrossReference(caseID: caseID, historySourceID: historySourceID, origin: origin, mode: .snapshot, pinnedCheckpointID: cp.id,
                                                    purpose: purpose, actor: actor)
        case .notRecorded(let b), .noRecordedStateYet(let b):
            throw CaseHistoryReviewError.noRecordedState("Map states of that case are recorded from \(b.formatted(date: .long, time: .shortened)); nothing earlier is reconstructed.")
        }
    }

    // MARK: HISTORY-04

    /// This case and a case in its history set, side by side: shared exact identifiers (accounts, payment references), names
    /// that appear in both (candidates only), the periods their money records cover, the kinds of money records, and the
    /// limits of the comparison. Reads only; records nothing.
    public func compare(caseID: UUID, historySourceID: UUID) async throws -> CaseHistoryComparisonCrossCase {
        guard let src = try await source(historySourceID, caseID: caseID), src.isActive, src.kind == .case, let other = src.originCaseID else {
            throw CaseHistoryReviewError.sourceNotActive
        }
        guard try await !database.query("SELECT 1 FROM investigation_cases WHERE id = ?;", [.uuid(other)]).isEmpty else { throw CaseHistoryReviewError.originNotFound }
        let a = try await file.moneyLedger(caseID: caseID), b = try await file.moneyLedger(caseID: other)
        // Only records whose source (if any) may be read across cases count on the other side.
        let readable = try await CaseCrossCaseAccess.permitted(Set(b.records.compactMap(\.sourceVersionID) + b.accounts.compactMap(\.sourceVersionID)), database: database)
        let bRecords = b.current.filter { $0.sourceVersionID.map(readable.contains) ?? true }
        let bAccounts = b.accounts.filter { $0.isActive && ($0.sourceVersionID.map(readable.contains) ?? true) }
        var same: [CaseHistoryComparisonCrossCase.Line] = [], diff: [CaseHistoryComparisonCrossCase.Line] = []
        let aKeys = Dictionary(a.accounts.filter(\.isActive).map { ($0.identifierKey, $0) }, uniquingKeysWith: { x, _ in x })
        for acct in bAccounts {
            if let mine = aKeys[acct.identifierKey] {
                same.append(.init(aspect: "Account identifier", thisCase: mine.title, otherCase: acct.title, note: "The same identifier is recorded in both (exact). It is the same account number, not a finding about who used it."))
            }
        }
        let aRefs = Set(a.current.compactMap { CaseMoneyLedger.normRef($0.reference) }), bRefs = Set(bRecords.compactMap { CaseMoneyLedger.normRef($0.reference) })
        for r in aRefs.intersection(bRefs).sorted() {
            same.append(.init(aspect: "Payment reference", thisCase: r, otherCase: r, note: "The same reference appears in both (exact)."))
        }
        func span(_ rs: [CaseMoneyRecord]) -> String {
            let ds = rs.compactMap(\.date).sorted()
            guard let f = ds.first, let l = ds.last else { return "no dated money record" }
            return f == l ? f : "\(f) – \(l)"
        }
        diff.append(.init(aspect: "When the money records fall", thisCase: span(a.current), otherCase: span(bRecords), note: "Dates as recorded in each case."))
        let kindsA = Set(a.current.map(\.kind)), kindsB = Set(bRecords.map(\.kind))
        for k in kindsA.intersection(kindsB).sorted(by: { $0.rawValue < $1.rawValue }) where k != .unclassified {
            same.append(.init(aspect: "Kind of money record", thisCase: k.label, otherCase: k.label, note: "Both cases record this kind of amount."))
        }
        for k in kindsA.symmetricDifference(kindsB).sorted(by: { $0.rawValue < $1.rawValue }) where k != .unclassified {
            diff.append(.init(aspect: "Kind of money record", thisCase: kindsA.contains(k) ? k.label : "—", otherCase: kindsB.contains(k) ? k.label : "—", note: "Recorded in one case only."))
        }
        if src.scope != .identifiersOnly {
            let pa = try await file.people(caseID: caseID), pb = try await file.people(caseID: other)
            let namesB = Dictionary(pb.map { (CaseMoneyLedger.norm($0.name), $0.name) }, uniquingKeysWith: { x, _ in x })
            for p in pa { if let n = namesB[CaseMoneyLedger.norm(p.name)] {
                same.append(.init(aspect: "Name", thisCase: p.name, otherCase: n, note: "The same name appears in both. A same name is a candidate only — not the same person, and not a decision."))
            } }
        }
        var limits = [CaseCrossCaseAccess.scopeNote, "Only what each case recorded is compared; what was never recorded cannot be compared."]
        if src.scope == .identifiersOnly { limits.append("The history set allows identifiers and dates only from the other case: names and records are not compared.") }
        if let info = try await database.query("SELECT status FROM investigation_cases WHERE id = ?;", [.uuid(other)]).first?.string(0), info == "closed" {
            limits.append("The other case is closed; its records are as they were when it closed.")
        }
        return CaseHistoryComparisonCrossCase(similarities: same, differences: diff, limitations: limits)
    }

    // MARK: HISTORY-08

    /// A review finding traced to the original record, its recorded decision, its sources and its work.
    public func trace(caseID: UUID, findingID: UUID) async throws -> CaseReviewTrace {
        guard let f = try await file.reviewFindings(caseID: caseID).first(where: { $0.id == findingID }) else { throw CaseHistoryReviewError.referenceNotFound }
        let view = try await resolve(caseID: caseID, referenceID: f.referenceID)
        let decision: String
        if case .unavailable(let why) = view.state { decision = why }
        else { decision = "\(view.review?.label ?? "No decision recorded") — \(view.statusText ?? "")" }
        return CaseReviewTrace(finding: f, reference: view, originalDecision: decision)
    }

    /// The way back: the reviews (other cases) that reference a record of `originCaseID`, with how many findings each holds.
    /// Titles and counts only — a review's findings are its own.
    public func reviewsReferencing(originCaseID: UUID, record: CaseMapNodeID) async throws -> [(reviewCaseID: UUID, title: String, findings: Int)] {
        let rows = try await database.query("""
            SELECT r.case_id, c.title, (SELECT COUNT(*) FROM case_review_findings f WHERE f.case_id = r.case_id AND f.reference_id = r.id AND f.withdrawn_at IS NULL)
            FROM case_cross_references r JOIN investigation_cases c ON c.id = r.case_id
            WHERE r.origin_case_id = ? AND r.origin_kind = ? AND r.origin_record_id = ? AND r.withdrawn_at IS NULL ORDER BY r.created_at;
            """, [.uuid(originCaseID), .text(record.kind.rawValue), .text(record.recordID)])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let t = r.string(1) else { return nil }
            return (id, t, Int(r.int(2) ?? 0))
        }
    }

    /// The review's own export: its purpose, its chronology (its own case log), each finding with its author and time and the
    /// trace to the original as it reads today (re-checked). The original case's records are referenced, never copied in
    /// beyond what the reference shows now.
    public func reviewExport(caseID: UUID) async throws -> String {
        let title = try await database.query("SELECT title FROM investigation_cases WHERE id = ?;", [.uuid(caseID)]).first?.string(0) ?? "Review"
        var out = "# \(title) — review record\n\n"
        let origins = try await file.reviewedCases(caseID: caseID)
        for o in origins {
            let t = try await database.query("SELECT title FROM investigation_cases WHERE id = ?;", [.uuid(o)]).first?.string(0)
            out += "Reviews: \(t ?? "a case no longer on this Mac (erased)")\n"
        }
        out += "\n_This review's findings, chronology and authorship are its own. Recording them changed nothing in the original case._\n\n## Findings\n\n"
        let findings = try await file.reviewFindings(caseID: caseID).filter(\.isActive)
        if findings.isEmpty { out += "_No finding recorded._\n" }
        for f in findings {
            let tr = try await trace(caseID: caseID, findingID: f.id)
            out += "- **\(f.assessment.label)** — \(f.text) _(recorded by \(f.recordedBy), \(CaseMoneyLedger.day(f.recordedAt)))_\n"
            switch tr.reference.state {
            case .available:
                out += "  - Original record: \(tr.reference.title ?? "") (\(tr.reference.reference.mode.label); \(tr.reference.asOf))\n"
                out += "  - Original decision: \(tr.originalDecision)\n"
                for w in tr.reference.work { out += "  - Original work: \(w)\n" }
                for s in tr.reference.sources { out += "  - Source: \(s.documentName ?? "a source")\(s.quote.map { " — “\($0)”" } ?? "")\n" }
                if let n = tr.reference.note { out += "  - _\(n)_\n" }
            case .unavailable(let why):
                out += "  - Original record: unavailable — \(why)\n"
            }
        }
        out += "\n## The review's own chronology\n\n"
        let log = try await database.query("SELECT sequence, actor, action, detail, at FROM case_actions WHERE case_id = ? ORDER BY sequence;", [.uuid(caseID)])
        for r in log {
            out += "\(r.int(0) ?? 0). \(r.date(4).map(CaseMoneyLedger.day) ?? "") — \(r.string(1) ?? "") — \(r.string(2) ?? "")\(r.string(3).map { ": \($0)" } ?? "")\n"
        }
        return out
    }
}
