//
//  StudioRecordRepository.swift
//  Kalsmritikosh
//
//  Final brief §3.1 — professional studio work in the encrypted ledger (schema v158). Each draft
//  (privilege log, workplace investigation, SIU referral, forensic engagement, fact-check memo,
//  reasoning analysis, research review, proof argument, dispute file, …) is one studio_records row:
//  the studio's own Codable model as its payload, plus the case or workspace it belongs to, the
//  persona and job, model version, revision, who and when, and its review state.
//
//  • A draft belongs to ONE case. Binding an unbound draft records it; a draft already bound to
//    another case is refused, never silently re-pointed.
//  • Every saved revision is kept (studio_record_revisions, append-only): a revision is cut when the
//    content changes and the last one is older than `revisionInterval`, or for an explicit reason
//    (export, case binding, import). Every export is a frozen snapshot with its SHA-256.
//  • Removing a draft retracts it (retracted_at/by); the row and its history stay.
//  • The old preference store is imported ONCE per key: its exact text is kept first (with its
//    SHA-256), then every element gets one recorded outcome — imported, identical duplicate, already
//    migrated, or quarantined (undecodable or a same-id conflict). The marker is written in the same
//    savepoint, so a failed import leaves nothing and is retried. The caller clears the preference
//    copy only when every element is accounted for and every imported record reads back intact.
//

import Foundation
import CryptoKit
import os

public nonisolated enum StudioRecordError: Error, Equatable, LocalizedError {
    case blankActor
    case retracted(UUID)
    case boundToAnotherCase(UUID)
    case notFound(UUID)
    case caseNotFound(UUID)
    case caseInAnotherWorkspace(UUID)
    case caseClosed(UUID)
    case changedSinceValidation(UUID)
    case unknownRevision(UUID, Int)
    case onLegalHold(UUID)
    case reasonRequired

    public var errorDescription: String? {
        switch self {
        case .changedSinceValidation: return "The draft changed while it was being checked. Nothing was exported — export again."
        case .unknownRevision: return "That version of the draft is not in the ledger."
        case .onLegalHold: return "This draft (or its case) is under a legal hold, so it cannot be erased. Release the hold first, with its reason."
        case .reasonRequired: return "An erasure needs a reason (for example the person's request and its date)."
        case .notFound: return "This draft is not in the ledger."
        case .caseNotFound: return "The case this draft belongs to is not in the ledger."
        case .caseInAnotherWorkspace: return "That case belongs to another workspace."
        case .caseClosed: return "The case is closed, so its drafts can be read and exported but not changed. Reopen the case to edit."
        case .blankActor: return "A name is needed to record who made the change."
        case .retracted: return "This draft was removed; it is kept in the record but can no longer be edited."
        case .boundToAnotherCase: return "This draft belongs to another case. Start a new draft for this case instead."
        }
    }
}

public nonisolated enum StudioReviewState: String, Sendable, Codable, CaseIterable {
    case draft, inReview, approved, superseded
}

/// One draft as the ledger holds it.
public nonisolated struct StudioRecord: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let studio: String
    public let caseID: UUID?
    public let workspaceID: UUID?
    public let title: String
    public let modelVersion: Int
    public let revision: Int
    public let payload: Data
    public let payloadSHA256: String
    public let reviewState: StudioReviewState
    public let importedFromDevice: Bool
    public let createdBy: String
    public let createdAt: Date
    public let updatedBy: String
    public let updatedAt: Date
    /// The persona and catalog job this draft belongs to (K7).
    public var persona: String? = nil
    public var jobID: String? = nil
}

public nonisolated struct StudioRecordRevision: Sendable, Hashable {
    public let revision: Int
    public let payloadSHA256: String
    public let reason: String
    public let savedBy: String
    public let savedAt: Date
}

public nonisolated struct StudioRecordExport: Sendable, Hashable {
    public let id: UUID
    public let revision: Int
    public let format: String
    public let artifactSHA256: String
    public let snapshot: String
    public let exportedBy: String
    public let exportedAt: Date
    /// K5 — digest of the case's accessible source versions when the export was authorised.
    public var scopeFingerprint: String? = nil
}

/// What one legacy element decodes to (the caller's model knows how).
public nonisolated struct StudioLegacyElement: Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public init(id: UUID, title: String, updatedAt: Date) { self.id = id; self.title = title; self.updatedAt = updatedAt }
}

public nonisolated struct StudioLegacyImportResult: Sendable, Equatable {
    public let importedIDs: [UUID]
    public let quarantined: Int
    public let alreadyImported: Bool
    /// Elements found in the stored list, and outcomes recorded for them (review R4: equal, or the
    /// preference copy must not be cleared).
    public var elementCount: Int = 0
    public var outcomeCount: Int = 0
    public var everyElementAccounted: Bool { outcomeCount == elementCount }
}

/// What one erasure cleared, and what it could not reach (review L4).
public nonisolated struct StudioErasureResult: Sendable, Equatable {
    public let erasureID: UUID
    public let revisionsCleared: Int
    public let exportsCleared: Int
    public let quarantineCleared: Int
    /// Captured legacy preference stores that held a copy of this draft and were cleared (K3). Their
    /// other elements live on in the ledger (imported) or in quarantine.
    public let legacyOriginalsCleared: Int
    /// Copies outside the ledger the app cannot erase — the person removes them.
    public static let outsideTheLedger = "Files you exported, backups and snapshots you made, and sync folders keep their own copies; remove those yourself."
}

public nonisolated struct StudioErasure: Sendable, Equatable {
    public let id: UUID
    public let recordID: UUID
    public let reason: String
    public let legalBasis: String?
    public let erasedBy: String
    public let erasedAt: Date
}

public actor StudioRecordRepository {
    /// A new revision is cut at most this often while editing (every keystroke updates the head row).
    public static let revisionInterval: TimeInterval = 300

    private let database: Database
    public init(database: Database) { self.database = database }

    // MARK: - Read

    /// Live drafts of one studio, newest first; `caseID` narrows to one case.
    public func records(studio: String, caseID: UUID? = nil) async throws -> [StudioRecord] {
        var sql = "\(Self.columns) WHERE studio = ? AND retracted_at IS NULL"
        var params: [SQLValue] = [.text(studio)]
        if let caseID { sql += " AND case_id = ?"; params.append(.uuid(caseID)) }
        sql += " ORDER BY updated_at DESC, id;"
        return try await database.query(sql, params).compactMap(Self.decode)
    }

    /// One draft, including a retracted one.
    public func record(id: UUID) async throws -> StudioRecord? {
        try await database.query("\(Self.columns) WHERE id = ? LIMIT 1;", [.uuid(id)]).compactMap(Self.decode).first
    }

    public func revisions(recordID: UUID) async throws -> [StudioRecordRevision] {
        try await database.query("SELECT revision, payload_sha256, reason, saved_by, saved_at FROM studio_record_revisions WHERE record_id = ? ORDER BY revision;",
                                 [.uuid(recordID)]).compactMap { r in
            guard let rev = r.int(0), let sha = r.string(1), let reason = r.string(2), let by = r.string(3), let at = r.date(4) else { return nil }
            return StudioRecordRevision(revision: Int(rev), payloadSHA256: sha, reason: reason, savedBy: by, savedAt: at)
        }
    }

    /// The payload as it stood at one revision (a frozen snapshot never changes).
    public func payload(recordID: UUID, revision: Int) async throws -> Data? {
        try await database.query("SELECT payload_json FROM studio_record_revisions WHERE record_id = ? AND revision = ? LIMIT 1;",
                                 [.uuid(recordID), .integer(Int64(revision))]).first?.string(0).map { Data($0.utf8) }
    }

    public func exports(recordID: UUID) async throws -> [StudioRecordExport] {
        try await database.query("SELECT id, revision, format, artifact_sha256, snapshot_text, exported_by, exported_at, scope_fingerprint FROM studio_record_exports WHERE record_id = ? ORDER BY exported_at, id;",
                                 [.uuid(recordID)]).compactMap { r in
            guard let id = r.uuid(0), let rev = r.int(1), let f = r.string(2), let sha = r.string(3), let snap = r.string(4),
                  let by = r.string(5), let at = r.date(6) else { return nil }
            return StudioRecordExport(id: id, revision: Int(rev), format: f, artifactSHA256: sha, snapshot: snap, exportedBy: by, exportedAt: at, scopeFingerprint: r.string(7))
        }
    }

    /// Elements the import could not take (undecodable, or a same-id conflict), as parsed JSON with the
    /// reason; the exact original text of the whole store is in `legacyBlob(sourceKey:)`.
    public func quarantined(sourceKey: String) async throws -> [(index: Int, raw: String, error: String)] {
        try await database.query("SELECT element_index, raw_json, error FROM studio_legacy_quarantine WHERE source_key = ? ORDER BY element_index;",
                                 [.text(sourceKey)]).compactMap { r in
            guard let i = r.int(0), let raw = r.string(1), let e = r.string(2) else { return nil }
            return (Int(i), raw, e)
        }
    }

    /// True when the draft is approved AND its current content is exactly the content approved.
    public func approvalIsCurrent(recordID: UUID) async throws -> Bool {
        guard let r = try await database.query("SELECT review_state, payload_sha256, approved_payload_sha256 FROM studio_records WHERE id = ? LIMIT 1;",
                                               [.uuid(recordID)]).first else { throw StudioRecordError.notFound(recordID) }
        return r.string(0) == StudioReviewState.approved.rawValue && r.string(2) != nil && r.string(1) == r.string(2)
    }

    // MARK: - Write

    /// Save a draft's current content. Creates the row on first save (revision 1); later saves update
    /// the head and cut a revision when the content changed and the last revision is older than
    /// `revisionInterval`, or when `reason` is given. Returns the head revision.
    @discardableResult
    public func save(studio: String, id: UUID, title: String, payload: Data, modelVersion: Int = 1,
                     persona: String? = nil, jobID: String? = nil, caseID: UUID? = nil, workspaceID: UUID? = nil,
                     actor: String, at date: Date = Date(), reason: String? = nil) async throws -> Int {
        let who = try Self.clean(actor)
        let json = String(decoding: payload, as: UTF8.self)
        let sha = Self.sha256(payload)
        return try await database.withSavepoint("studio_save_\(Self.token(id))") { db -> Int in
            let existing = try db.query("SELECT revision, payload_sha256, retracted_at, case_id, workspace_id, review_state, approved_payload_sha256 FROM studio_records WHERE id = ? LIMIT 1;", [.uuid(id)]).first
            if let caseID { try Self.checkCase(db, caseID, workspaceID: workspaceID, forEdit: true) }
            guard let existing else {
                try db.exec("""
                    INSERT INTO studio_records (id, studio, persona, job_id, case_id, workspace_id, title, model_version, revision,
                        payload_json, payload_sha256, review_state, origin, created_by, created_at, updated_by, updated_at)
                    VALUES (?,?,?,?,?,?,?,?,1,?,?,'draft','ledger',?,?,?,?);
                    """, [.uuid(id), .text(studio), .optionalText(persona), .optionalText(jobID), Self.opt(caseID), Self.opt(workspaceID),
                          .text(title), .integer(Int64(modelVersion)), .text(json), .text(sha), .text(who), .date(date), .text(who), .date(date)])
                try Self.cut(db, id, 1, json, sha, reason ?? "created", who, date)
                return 1
            }
            if existing.date(2) != nil { throw StudioRecordError.retracted(id) }
            if let bound = existing.uuid(3), let caseID, bound != caseID { throw StudioRecordError.boundToAnotherCase(bound) }
            // An edit to a draft of a closed case is refused (its history and exports stay readable).
            if let bound = existing.uuid(3), existing.string(1) != sha { try Self.checkCase(db, bound, workspaceID: nil, forEdit: true) }
            var rev = Int(existing.int(0) ?? 1)
            let changed = existing.string(1) != sha
            // Approval covers the exact content approved: any change returns the draft to draft.
            if changed, existing.string(5) == StudioReviewState.approved.rawValue, existing.string(6) != sha {
                rev += 1
                try Self.cut(db, id, rev, json, sha, "approval no longer applies: the content changed after it was approved", who, date)
                try db.exec("UPDATE studio_records SET review_state = 'draft', approved_payload_sha256 = NULL WHERE id = ?;", [.uuid(id)])
            }
            if changed || reason != nil {
                let last = try db.query("SELECT saved_at, payload_sha256 FROM studio_record_revisions WHERE record_id = ? ORDER BY revision DESC LIMIT 1;", [.uuid(id)]).first
                let lastAt = last?.date(0) ?? .distantPast
                if reason != nil || date.timeIntervalSince(lastAt) >= Self.revisionInterval {
                    if last?.string(1) != sha || reason != nil {
                        rev += 1
                        try Self.cut(db, id, rev, json, sha, reason ?? "edited", who, date)
                    }
                }
            }
            try db.exec("""
                UPDATE studio_records SET title = ?, payload_json = ?, payload_sha256 = ?, revision = ?, model_version = ?,
                    case_id = COALESCE(case_id, ?), workspace_id = COALESCE(workspace_id, ?),
                    persona = COALESCE(persona, ?), job_id = COALESCE(job_id, ?), updated_by = ?, updated_at = ?
                WHERE id = ?;
                """, [.text(title), .text(json), .text(sha), .integer(Int64(rev)), .integer(Int64(modelVersion)),
                      Self.opt(caseID), Self.opt(workspaceID), .optionalText(persona), .optionalText(jobID), .text(who), .date(date), .uuid(id)])
            return rev
        }
    }

    /// Bind a draft to its case. An unbound draft is bound (and a revision records it); the same case
    /// again is a no-op; another case is refused.
    public func bind(recordID: UUID, caseID: UUID, workspaceID: UUID?, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor)
        try await database.withSavepoint("studio_bind_\(Self.token(recordID))") { db in
            guard let row = try db.query("SELECT case_id, revision, payload_json, payload_sha256, retracted_at FROM studio_records WHERE id = ? LIMIT 1;", [.uuid(recordID)]).first else {
                throw StudioRecordError.notFound(recordID)
            }
            if row.date(4) != nil { throw StudioRecordError.retracted(recordID) }
            try Self.checkCase(db, caseID, workspaceID: workspaceID, forEdit: true)
            if let bound = row.uuid(0) {
                if bound != caseID { throw StudioRecordError.boundToAnotherCase(bound) }
                return
            }
            let rev = Int(row.int(1) ?? 1) + 1
            try Self.cut(db, recordID, rev, row.string(2) ?? "{}", row.string(3) ?? "", "bound to case \(caseID.uuidString)", who, date)
            try db.exec("UPDATE studio_records SET case_id = ?, workspace_id = COALESCE(workspace_id, ?), revision = ?, updated_by = ?, updated_at = MAX(updated_at, ?) WHERE id = ?;",
                        [.uuid(caseID), Self.opt(workspaceID), .integer(Int64(rev)), .text(who), .date(date), .uuid(recordID)])
        }
    }

    /// Retract a draft: it leaves the list; the row, its revisions and exports stay.
    public func retract(recordID: UUID, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor)
        try await database.withSavepoint("studio_retract_\(Self.token(recordID))") { db in
            try db.exec("UPDATE studio_records SET retracted_at = ?, retracted_by = ? WHERE id = ? AND retracted_at IS NULL;",
                        [.date(date), .text(who), .uuid(recordID)])
        }
    }

    // MARK: - Erasure (review L4)

    /// Erase a draft's content: its current payload, every revision's payload, every export snapshot
    /// and any quarantined legacy copy are cleared; the rows stay (dates and SHA-256s), with a
    /// recorded erasure saying who, when, why and on what basis. Refused while a legal hold on the
    /// draft or its case is active. Retraction is not erasure: `retract` keeps everything.
    public func erase(recordID: UUID, reason: String, legalBasis: String?, actor: String, at date: Date = Date()) async throws -> StudioErasureResult {
        let who = try Self.clean(actor)
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { throw StudioRecordError.reasonRequired }
        let basis = legalBasis?.trimmingCharacters(in: .whitespacesAndNewlines)
        let erasureID = UUID()
        return try await database.withSavepoint("studio_erase_\(Self.token(recordID))") { db in
            guard let row = try db.query("SELECT case_id, payload_sha256, erased_at FROM studio_records WHERE id = ? LIMIT 1;", [.uuid(recordID)]).first else {
                throw StudioRecordError.notFound(recordID)
            }
            let caseID = row.uuid(0)
            var held: [SQLValue] = [.uuid(recordID)]
            if let caseID { held.append(.uuid(caseID)) }
            let marks = held.map { _ in "?" }.joined(separator: ", ")
            if let hold = try db.query("""
                SELECT h.id FROM legal_hold_items i JOIN legal_holds h ON h.id = i.hold_id AND h.released_at IS NULL
                WHERE i.removed_at IS NULL AND i.object_id IN (\(marks)) LIMIT 1;
                """, held).first?.uuid(0) {
                throw StudioRecordError.onLegalHold(hold)
            }
            let id: [SQLValue] = [.uuid(recordID)]
            let revisions = Int(try db.query("SELECT COUNT(*) FROM studio_record_revisions WHERE record_id = ? AND payload_json <> '';", id).first?.int(0) ?? 0)
            let exports = Int(try db.query("SELECT COUNT(*) FROM studio_record_exports WHERE record_id = ? AND snapshot_text <> '';", id).first?.int(0) ?? 0)
            let quarantine = Int(try db.query("""
                SELECT COUNT(*) FROM studio_legacy_quarantine q JOIN studio_legacy_outcomes o
                  ON o.source_key = q.source_key AND o.element_index = q.element_index
                WHERE o.record_id = ? AND q.raw_json <> '';
                """, id).first?.int(0) ?? 0)
            let legacy = Int(try db.query("""
                SELECT COUNT(*) FROM studio_legacy_blobs WHERE raw_blob <> ''
                  AND source_key IN (SELECT DISTINCT source_key FROM studio_legacy_outcomes WHERE record_id = ?);
                """, id).first?.int(0) ?? 0)
            // The erasure is recorded first: the append-only triggers allow clearing content only then.
            try db.exec("""
                INSERT INTO studio_erasures (id, record_id, case_id, reason, legal_basis, payload_sha256, revisions_cleared,
                    exports_cleared, quarantine_cleared, legacy_originals, erased_by, erased_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [.uuid(erasureID), .uuid(recordID), caseID.map { .uuid($0) } ?? .null, .text(why),
                      basis.flatMap { $0.isEmpty ? nil : SQLValue.text($0) } ?? .null, .text(row.string(1) ?? ""),
                      .integer(Int64(revisions)), .integer(Int64(exports)), .integer(Int64(quarantine)), .integer(Int64(legacy)),
                      .text(who), .date(date)])
            try db.exec("UPDATE studio_record_revisions SET payload_json = '' WHERE record_id = ?;", [.uuid(recordID)])
            try db.exec("UPDATE studio_record_exports SET snapshot_text = '' WHERE record_id = ?;", [.uuid(recordID)])
            try db.exec("""
                UPDATE studio_legacy_quarantine SET raw_json = '' WHERE EXISTS (
                  SELECT 1 FROM studio_legacy_outcomes o WHERE o.record_id = ?
                    AND o.source_key = studio_legacy_quarantine.source_key AND o.element_index = studio_legacy_quarantine.element_index);
                """, [.uuid(recordID)])
            try db.exec("""
                UPDATE studio_legacy_blobs SET raw_blob = '', cleared_reason = ?, cleared_at = ?
                WHERE raw_blob <> '' AND source_key IN (SELECT DISTINCT source_key FROM studio_legacy_outcomes WHERE record_id = ?);
                """, [.text("erasure \(erasureID.uuidString) of draft \(recordID.uuidString): \(why)"), .date(date), .uuid(recordID)])
            try db.exec("""
                UPDATE studio_records SET payload_json = '', title = '', review_state = 'draft', approved_payload_sha256 = NULL,
                    erased_at = ?, retracted_at = COALESCE(retracted_at, ?), retracted_by = COALESCE(retracted_by, ?),
                    updated_by = ?, updated_at = MAX(updated_at, ?) WHERE id = ?;
                """, [.date(date), .date(date), .text(who), .text(who), .date(date), .uuid(recordID)])
            return StudioErasureResult(erasureID: erasureID, revisionsCleared: revisions, exportsCleared: exports,
                                       quarantineCleared: quarantine, legacyOriginalsCleared: legacy)
        }
    }

    public func erasures(recordID: UUID) async throws -> [StudioErasure] {
        try await database.query("SELECT id, reason, legal_basis, erased_by, erased_at FROM studio_erasures WHERE record_id = ? ORDER BY erased_at;",
                                 [.uuid(recordID)]).compactMap { r in
            guard let id = r.uuid(0), let why = r.string(1), let by = r.string(3), let at = r.date(4) else { return nil }
            return StudioErasure(id: id, recordID: recordID, reason: why, legalBasis: r.string(2), erasedBy: by, erasedAt: at)
        }
    }

    public func setReviewState(recordID: UUID, _ state: StudioReviewState, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor)
        try await database.withSavepoint("studio_review_\(Self.token(recordID))") { db in
            guard let row = try db.query("SELECT revision, payload_json, payload_sha256, retracted_at, case_id FROM studio_records WHERE id = ? LIMIT 1;", [.uuid(recordID)]).first else {
                throw StudioRecordError.notFound(recordID)
            }
            if row.date(3) != nil { throw StudioRecordError.retracted(recordID) }
            if let bound = row.uuid(4) { try Self.checkCase(db, bound, workspaceID: nil, forEdit: true) }
            let rev = Int(row.int(0) ?? 1) + 1
            let sha = row.string(2) ?? ""
            try Self.cut(db, recordID, rev, row.string(1) ?? "{}", sha, "review state: \(state.rawValue)", who, date)
            let approved = state == .approved
            try db.exec("UPDATE studio_records SET review_state = ?, revision = ?, updated_by = ?, updated_at = MAX(updated_at, ?), approved_payload_sha256 = ?, approved_by = ?, approved_at = ? WHERE id = ?;",
                        [.text(state.rawValue), .integer(Int64(rev)), .text(who), .date(date),
                         approved ? .text(sha) : .null, approved ? .text(who) : .null, approved ? .date(date) : .null, .uuid(recordID)])
        }
    }

    /// Record a completed export: the exact text written, its SHA-256 and the revision it was made
    /// from (a revision is cut first if the content changed since the last one). Call only after the
    /// file was written successfully.
    @discardableResult
    /// Review R2: freeze the draft's current content for an export. The content must be exactly what
    /// was validated (`expectedPayloadSHA256`); a revision is cut if the last one is not this content.
    /// Returns that revision and whether a current approval covers exactly this content.
    public func freezeForExport(recordID: UUID, expectedPayloadSHA256: String, actor: String, at date: Date = Date()) async throws -> (revision: Int, approved: Bool) {
        let who = try Self.clean(actor)
        return try await database.withSavepoint("studio_freeze_\(Self.token(recordID))") { db -> (Int, Bool) in
            guard let row = try db.query("SELECT revision, payload_json, payload_sha256, review_state, approved_payload_sha256 FROM studio_records WHERE id = ? LIMIT 1;",
                                         [.uuid(recordID)]).first else { throw StudioRecordError.notFound(recordID) }
            let sha = row.string(2) ?? ""
            guard sha == expectedPayloadSHA256 else { throw StudioRecordError.changedSinceValidation(recordID) }
            var rev = Int(row.int(0) ?? 1)
            let last = try db.query("SELECT payload_sha256 FROM studio_record_revisions WHERE record_id = ? ORDER BY revision DESC LIMIT 1;", [.uuid(recordID)]).first?.string(0)
            if last != sha {
                rev += 1
                try Self.cut(db, recordID, rev, row.string(1) ?? "{}", sha, "frozen for export", who, date)
                try db.exec("UPDATE studio_records SET revision = ? WHERE id = ?;", [.integer(Int64(rev)), .uuid(recordID)])
            }
            let approved = row.string(3) == StudioReviewState.approved.rawValue && row.string(4) == sha
            return (rev, approved)
        }
    }

    public func recordExport(recordID: UUID, format: String, text: String, revision frozen: Int? = nil,
                             scopeFingerprint: String? = nil, actor: String, at date: Date = Date()) async throws -> StudioRecordExport {
        let who = try Self.clean(actor)
        let sha = Self.sha256(Data(text.utf8))
        let exportID = UUID()
        return try await database.withSavepoint("studio_export_\(Self.token(exportID))") { db -> StudioRecordExport in
            guard let row = try db.query("SELECT revision, payload_json, payload_sha256 FROM studio_records WHERE id = ? LIMIT 1;", [.uuid(recordID)]).first else {
                throw StudioRecordError.notFound(recordID)
            }
            // The export records the revision it was made from (frozen before rendering), not
            // whatever the draft holds by the time the file was written.
            if let frozen {
                guard !(try db.query("SELECT 1 FROM studio_record_revisions WHERE record_id = ? AND revision = ? LIMIT 1;",
                                     [.uuid(recordID), .integer(Int64(frozen))])).isEmpty else { throw StudioRecordError.unknownRevision(recordID, frozen) }
                try db.exec("INSERT INTO studio_record_exports (id, record_id, revision, format, artifact_sha256, snapshot_text, exported_by, exported_at, scope_fingerprint) VALUES (?,?,?,?,?,?,?,?,?);",
                            [.uuid(exportID), .uuid(recordID), .integer(Int64(frozen)), .text(format), .text(sha), .text(text), .text(who), .date(date), .optionalText(scopeFingerprint)])
                return StudioRecordExport(id: exportID, revision: frozen, format: format, artifactSHA256: sha, snapshot: text, exportedBy: who, exportedAt: date, scopeFingerprint: scopeFingerprint)
            }
            var rev = Int(row.int(0) ?? 1)
            let last = try db.query("SELECT payload_sha256 FROM studio_record_revisions WHERE record_id = ? ORDER BY revision DESC LIMIT 1;", [.uuid(recordID)]).first?.string(0)
            if last != row.string(2) {
                rev += 1
                try Self.cut(db, recordID, rev, row.string(1) ?? "{}", row.string(2) ?? "", "exported", who, date)
                try db.exec("UPDATE studio_records SET revision = ? WHERE id = ?;", [.integer(Int64(rev)), .uuid(recordID)])
            }
            try db.exec("INSERT INTO studio_record_exports (id, record_id, revision, format, artifact_sha256, snapshot_text, exported_by, exported_at, scope_fingerprint) VALUES (?,?,?,?,?,?,?,?,?);",
                        [.uuid(exportID), .uuid(recordID), .integer(Int64(rev)), .text(format), .text(sha), .text(text), .text(who), .date(date), .optionalText(scopeFingerprint)])
            return StudioRecordExport(id: exportID, revision: rev, format: format, artifactSHA256: sha, snapshot: text, exportedBy: who, exportedAt: date, scopeFingerprint: scopeFingerprint)
        }
    }

    // MARK: - One-time import of the old preference store

    public func hasImportedLegacy(sourceKey: String) async throws -> Bool {
        !(try await database.query("SELECT 1 FROM studio_legacy_imports WHERE source_key = ? LIMIT 1;", [.text(sourceKey)])).isEmpty
    }

    /// Import the JSON array the old view stored under `sourceKey`, once (review R4):
    ///  1. the whole stored text is kept byte for byte with its SHA-256 before anything is converted;
    ///  2. each element gets exactly one recorded outcome — imported; an identical duplicate of an
    ///     earlier element; already migrated (the ledger holds the same id with the same content);
    ///     or quarantined (undecodable, or the same id with DIFFERENT content, inside the list or
    ///     against the ledger — a conflict is kept, never skipped);
    ///  3. the import marker is written in the same savepoint, so a failed import leaves nothing and
    ///     is retried. Imported drafts are unbound: the person assigns each to its case.
    public func importLegacy(studio: String, sourceKey: String, blob: String, actor: String, at date: Date = Date(),
                             decode: @Sendable (Data) -> StudioLegacyElement?) async throws -> StudioLegacyImportResult {
        let who = try Self.clean(actor)
        // Parse outside the savepoint (pure work). The canonical form compares content; the raw blob
        // (kept below) is the exact original.
        var elements: [(index: Int, canonical: Data?, error: String?)] = []
        if !blob.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let array = (try? JSONSerialization.jsonObject(with: Data(blob.utf8))) as? [Any] {
                for (i, e) in array.enumerated() {
                    if let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) { elements.append((i, d, nil)) }
                    else { elements.append((i, nil, "not a JSON object")) }
                }
            } else {
                elements.append((-1, nil, "the stored list is not valid JSON (the exact text is kept in studio_legacy_blobs)"))
            }
        }
        let decoded: [(index: Int, canonical: Data?, element: StudioLegacyElement?, error: String?)] = elements.map { e in
            guard let d = e.canonical else { return (e.index, nil, nil, e.error) }
            guard let el = decode(d) else { return (e.index, d, nil, "the record does not match this studio's format") }
            return (e.index, d, el, nil)
        }
        let rawSHA = Self.sha256(Data(blob.utf8))
        return try await database.withSavepoint("studio_import_\(Self.token(UUID()))") { db -> StudioLegacyImportResult in
            guard try db.query("SELECT 1 FROM studio_legacy_imports WHERE source_key = ? LIMIT 1;", [.text(sourceKey)]).isEmpty else {
                return StudioLegacyImportResult(importedIDs: [], quarantined: 0, alreadyImported: true)
            }
            // 1. The exact original, first.
            try db.exec("INSERT OR IGNORE INTO studio_legacy_blobs (source_key, raw_blob, sha256, byte_count, captured_at) VALUES (?,?,?,?,?);",
                        [.text(sourceKey), .text(blob), .text(rawSHA), .integer(Int64(blob.utf8.count)), .date(date)])
            var imported: [UUID] = [], quarantined = 0, outcomes = 0
            var seen: [UUID: Data] = [:]
            for r in decoded {
                let raw = r.canonical.map { String(decoding: $0, as: UTF8.self) } ?? (r.index == -1 ? blob : "")
                guard let el = r.element, let data = r.canonical else {
                    try Self.recordQuarantine(db, sourceKey, r.index, raw, r.error ?? "unknown", date); quarantined += 1; try Self.recordOutcome(db, sourceKey, r.index, nil, "quarantined", r.error ?? "unknown", date); outcomes += 1
                    continue
                }
                if let earlier = seen[el.id] {
                    if earlier == data { try Self.recordOutcome(db, sourceKey, r.index, el.id, "identicalDuplicate", "the same record appears earlier in the list", date); outcomes += 1 }
                    else { try Self.recordQuarantine(db, sourceKey, r.index, raw, "conflict: the same id appears earlier in the list with different content", date); quarantined += 1; try Self.recordOutcome(db, sourceKey, r.index, el.id, "quarantined", "conflict: the same id appears earlier in the list with different content", date); outcomes += 1 }
                    continue
                }
                seen[el.id] = data
                if let existing = try db.query("SELECT studio, payload_json FROM studio_records WHERE id = ? LIMIT 1;", [.uuid(el.id)]).first {
                    let same = existing.string(0) == studio && Self.canonical(existing.string(1)) == data
                    if same { try Self.recordOutcome(db, sourceKey, r.index, el.id, "alreadyMigrated", "the ledger already holds this record with the same content", date); outcomes += 1 }
                    else { try Self.recordQuarantine(db, sourceKey, r.index, raw, "conflict: the ledger holds a different record under this id", date); quarantined += 1; try Self.recordOutcome(db, sourceKey, r.index, el.id, "quarantined", "conflict: the ledger holds a different record under this id", date); outcomes += 1 }
                    continue
                }
                let json = String(decoding: data, as: UTF8.self), sha = Self.sha256(data)
                try db.exec("""
                    INSERT INTO studio_records (id, studio, title, model_version, revision, payload_json, payload_sha256, review_state, origin,
                        created_by, created_at, updated_by, updated_at)
                    VALUES (?,?,?,1,1,?,?,'draft','appStorageImport',?,?,?,?);
                    """, [.uuid(el.id), .text(studio), .text(el.title), .text(json), .text(sha), .text(who), .date(date), .text(who), .date(el.updatedAt)])
                try Self.cut(db, el.id, 1, json, sha, "imported from the on-device store", who, date)
                imported.append(el.id)
                try Self.recordOutcome(db, sourceKey, r.index, el.id, "imported", "imported", date); outcomes += 1
            }
            try db.exec("INSERT INTO studio_legacy_imports (source_key, imported_count, quarantined_count, imported_by, imported_at) VALUES (?,?,?,?,?);",
                        [.text(sourceKey), .integer(Int64(imported.count)), .integer(Int64(quarantined)), .text(who), .date(date)])
            return StudioLegacyImportResult(importedIDs: imported, quarantined: quarantined, alreadyImported: false,
                                            elementCount: decoded.count, outcomeCount: outcomes)
        }
    }

    /// The exact stored text of an old preference store, and whether it still matches its digest.
    public func legacyBlob(sourceKey: String) async throws -> (raw: String, intact: Bool)? {
        try await legacyBlobState(sourceKey: sourceKey).map { ($0.raw, $0.intact) }
    }

    /// The captured store with its state: `clearedReason` is set when an erasure cleared it (K3).
    public func legacyBlobState(sourceKey: String) async throws -> (raw: String, intact: Bool, clearedReason: String?)? {
        guard let r = try await database.query("SELECT raw_blob, sha256, cleared_reason FROM studio_legacy_blobs WHERE source_key = ? LIMIT 1;", [.text(sourceKey)]).first,
              let raw = r.string(0), let sha = r.string(1) else { return nil }
        return (raw, Self.sha256(Data(raw.utf8)) == sha, r.string(2))
    }

    /// Every element's recorded outcome, in order.
    public func legacyOutcomes(sourceKey: String) async throws -> [(index: Int, id: UUID?, outcome: String, detail: String)] {
        try await database.query("SELECT element_index, record_id, outcome, detail FROM studio_legacy_outcomes WHERE source_key = ? ORDER BY element_index;",
                                 [.text(sourceKey)]).compactMap { r in
            guard let i = r.int(0), let o = r.string(2), let d = r.string(3) else { return nil }
            return (Int(i), r.uuid(1), o, d)
        }
    }

    private static func recordOutcome(_ db: isolated Database, _ key: String, _ index: Int, _ id: UUID?, _ kind: String,
                                      _ detail: String, _ date: Date) throws {
        try db.exec("INSERT INTO studio_legacy_outcomes (source_key, element_index, record_id, outcome, detail, recorded_at) VALUES (?,?,?,?,?,?);",
                    [.text(key), .integer(Int64(index)), id.map { .uuid($0) } ?? .null, .text(kind), .text(detail), .date(date)])
    }

    private static func recordQuarantine(_ db: isolated Database, _ key: String, _ index: Int, _ raw: String, _ why: String, _ date: Date) throws {
        try db.exec("INSERT INTO studio_legacy_quarantine (id, source_key, element_index, raw_json, error, captured_at) VALUES (?,?,?,?,?,?);",
                    [.uuid(UUID()), .text(key), .integer(Int64(index)), .text(raw), .text(why), .date(date)])
    }

    static func canonical(_ json: String?) -> Data? {
        guard let json, let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// True when every id reads back from the ledger with a payload that decodes (`check`). The caller
    /// clears the old preference copy only then.
    public func verifyImported(_ ids: [UUID], check: @Sendable (Data) -> Bool) async throws -> Bool {
        for id in ids {
            guard let r = try await record(id: id), Self.sha256(r.payload) == r.payloadSHA256, check(r.payload) else { return false }
        }
        return true
    }

    // MARK: - Internals

    private static let columns = """
        SELECT id, studio, case_id, workspace_id, title, model_version, revision, payload_json, payload_sha256, review_state, origin,
               created_by, created_at, updated_by, updated_at, persona, job_id FROM studio_records
        """

    private static func decode(_ r: SQLRow) -> StudioRecord? {
        guard let id = r.uuid(0), let studio = r.string(1), let json = r.string(7), let sha = r.string(8),
              let createdBy = r.string(11), let createdAt = r.date(12), let updatedBy = r.string(13), let updatedAt = r.date(14) else { return nil }
        return StudioRecord(id: id, studio: studio, caseID: r.uuid(2), workspaceID: r.uuid(3), title: r.string(4) ?? "",
                            modelVersion: Int(r.int(5) ?? 1), revision: Int(r.int(6) ?? 1), payload: Data(json.utf8), payloadSHA256: sha,
                            reviewState: StudioReviewState(rawValue: r.string(9) ?? "") ?? .draft, importedFromDevice: r.string(10) == "appStorageImport",
                            createdBy: createdBy, createdAt: createdAt, updatedBy: updatedBy, updatedAt: updatedAt,
                            persona: r.string(15), jobID: r.string(16))
    }

    /// Review R3: the parent case exists, belongs to `workspaceID` when one is given, and — for an
    /// edit — is not closed. Checked inside the same savepoint as the write.
    private static func checkCase(_ db: isolated Database, _ caseID: UUID, workspaceID: UUID?, forEdit: Bool) throws {
        guard let row = try db.query("SELECT workspace_id, status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first else {
            throw StudioRecordError.caseNotFound(caseID)
        }
        if let workspaceID, let ws = row.uuid(0), ws != workspaceID { throw StudioRecordError.caseInAnotherWorkspace(caseID) }
        if forEdit, row.string(1) == "closed" { throw StudioRecordError.caseClosed(caseID) }
    }

    private static func cut(_ db: isolated Database, _ id: UUID, _ rev: Int, _ json: String, _ sha: String, _ reason: String,
                            _ who: String, _ date: Date) throws {
        try db.exec("INSERT INTO studio_record_revisions (record_id, revision, payload_json, payload_sha256, reason, saved_by, saved_at) VALUES (?,?,?,?,?,?,?);",
                    [.uuid(id), .integer(Int64(rev)), .text(json), .text(sha), .text(reason), .text(who), .date(date)])
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private static func opt(_ id: UUID?) -> SQLValue { id.map { .uuid($0) } ?? .null }
    private static func token(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "") }

    private static func clean(_ actor: String) throws -> String {
        let a = actor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { throw StudioRecordError.blankActor }
        return a
    }
}
