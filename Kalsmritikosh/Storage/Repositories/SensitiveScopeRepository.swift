//
//  SensitiveScopeRepository.swift
//  Kalsmritikosh
//
//  OPS-003A — the single authority for reading and writing protection assignments.
//  All six enforcement surfaces (screen, retrieval, prompt, report, receipt, export)
//  read from this repository — there is no per-surface or per-persona override.
//
//  OPS-003A.1 hardening:
//  • assign() now requires a SensitiveScopeTarget + AssignmentAuthority; it validates
//    target existence inside the savepoint and syncs knowledge_objects.privileged.
//  • revoke() validates a non-blank actor and syncs knowledge_objects.privileged.
//  • effectiveLabel() is lineage-aware and returns ProtectionResolution (not bare label);
//    a UUID not found in any canonical table returns .brokenLineage.
//  • batchResolution() is keyed by SensitiveScopeTarget (kind+id), preventing UUID
//    collision across different target tables.
//  • decodeAssignment() throws on malformed rows instead of silently dropping them.
//  • reviews(forAssignmentID:) exposes the audit ledger.
//

import Foundation
import OSLog

public actor SensitiveScopeRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Assign

    /// Record a new protection assignment and its opening audit-review entry atomically.
    ///
    /// - Validates that the actor string is non-blank before touching the database.
    /// - Validates that the target exists inside the savepoint — throws
    ///   `SensitiveScopeError.targetNotFound` if not found, rolling back atomically.
    /// - Syncs `knowledge_objects.privileged = 1` when the target is a knowledgeObject
    ///   and the authority carries `privileged: true`, inside the same savepoint.
    @discardableResult
    public func assign(
        target: SensitiveScopeTarget,
        sensitivity: SensitivityLevel,
        authority: AssignmentAuthority,
        reason: String?,
        at: Date = Date()
    ) async throws -> SensitiveScopeAssignment {
        guard !authority.actorString.isEmpty else {
            throw SensitiveScopeError.nonblankActorRequired
        }
        let assignmentID = UUID()
        let reviewID = UUID()
        let assignment = SensitiveScopeAssignment(
            id: assignmentID,
            targetKind: target.kind,
            targetID: target.id,
            sensitivity: sensitivity,
            privileged: authority.isPrivileged,
            origin: authority.originString,
            reason: reason,
            assignedBy: authority.actorString,
            createdAt: at,
            revokedAt: nil,
            revokedBy: nil,
            revokedReason: nil
        )
        try await database.withSavepoint("ssa_assign") { db in
            guard try Self.targetExists(db, target: target) else {
                throw SensitiveScopeError.targetNotFound(target)
            }
            try Self.insertAssignment(db, assignment: assignment)
            try Self.insertReview(db, id: reviewID, assignmentID: assignmentID,
                                  action: .assigned, actorNote: nil, at: at)
            if target.kind == .knowledgeObject && authority.isPrivileged {
                try db.exec(
                    "UPDATE knowledge_objects SET privileged = 1 WHERE id = ?;",
                    [.uuid(target.id)])
            }
        }
        return assignment
    }

    // MARK: - Revoke

    /// Revoke one active assignment. Records a review entry. Throws if the assignment is
    /// not found or already revoked. Syncs `knowledge_objects.privileged = 0` when this
    /// was the last privileged active assignment on a knowledgeObject target.
    public func revoke(
        assignmentID: UUID,
        revokedBy: String,
        reason: String?,
        at: Date = Date()
    ) async throws {
        guard !revokedBy.isEmpty else {
            throw SensitiveScopeError.nonblankActorRequired
        }
        let reviewID = UUID()
        try await database.withSavepoint("ssa_revoke") { db in
            let existing = try db.query("""
            SELECT revoked_at, target_kind, target_id, privileged
              FROM sensitive_scope_assignments
             WHERE id = ? LIMIT 1;
            """, [.uuid(assignmentID)])
            guard let first = existing.first else {
                throw SensitiveScopeError.assignmentNotFound(assignmentID)
            }
            guard first.isNull(0) else {
                throw SensitiveScopeError.assignmentAlreadyRevoked(assignmentID)
            }
            try db.exec("""
            UPDATE sensitive_scope_assignments
               SET revoked_at = ?, revoked_by = ?, revoked_reason = ?
             WHERE id = ?;
            """, [.date(at), .text(revokedBy), .optionalText(reason), .uuid(assignmentID)])
            try Self.insertReview(db, id: reviewID, assignmentID: assignmentID,
                                  action: .revoked, actorNote: reason, at: at)
            // Legacy sync: clear knowledge_objects.privileged when the last active
            // privileged assignment on a knowledgeObject target has been revoked.
            let wasPrivileged = (first.int(3) ?? 0) != 0
            let targetKindStr = first.string(1) ?? ""
            if wasPrivileged,
               targetKindStr == SensitiveScopeTargetKind.knowledgeObject.rawValue,
               let targetIDStr = first.string(2) {
                let remaining = try db.query("""
                SELECT COUNT(*) FROM sensitive_scope_assignments
                 WHERE target_kind = ? AND target_id = ?
                   AND revoked_at IS NULL AND privileged = 1;
                """, [.text(targetKindStr), .text(targetIDStr)])
                if (remaining.first?.int(0) ?? 0) == 0 {
                    try db.exec(
                        "UPDATE knowledge_objects SET privileged = 0 WHERE id = ?;",
                        [.text(targetIDStr)])
                }
            }
        }
    }

    // MARK: - Effective label (lineage-aware)

    /// The effective ProtectionLabel for a target, taking lineage into account.
    ///
    /// Returns `.brokenLineage` when the target UUID is not found in its canonical table —
    /// callers must treat this as a denial, not a fallback to any default.
    ///
    /// Returns `.resolved(.internalLevel, privileged: false)` when the target exists but
    /// carries no active assignment anywhere in its lineage — fail-closed default.
    public func effectiveLabel(for target: SensitiveScopeTarget) async throws -> ProtectionResolution {
        let table = Self.targetTableName(for: target.kind)
        let existRows = try await database.query(
            "SELECT 1 FROM \(table) WHERE id = ? LIMIT 1;",
            [.uuid(target.id)])
        guard !existRows.isEmpty else { return .brokenLineage }

        let (sql, bindings) = Self.lineageQuery(for: target)
        let rows = try await database.query(sql, bindings)

        guard !rows.isEmpty else {
            return .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false))
        }
        let labels = try rows.map { row -> ProtectionLabel in
            guard let sv = row.int(0),
                  let pv = row.int(1),
                  let s = SensitivityLevel(rawValue: Int(sv)) else {
                throw SensitiveScopeError.malformedAssignmentRow(UUID())
            }
            return ProtectionLabel(sensitivity: s, privileged: pv != 0)
        }
        return .resolved(SensitivityInheritance.inherit(from: labels))
    }

    /// Batch effective-label resolution. Keys are full `SensitiveScopeTarget` values —
    /// kind+id — preventing UUID collision across different target tables.
    public func batchResolution(
        _ targets: [SensitiveScopeTarget]
    ) async throws -> [SensitiveScopeTarget: ProtectionResolution] {
        var result: [SensitiveScopeTarget: ProtectionResolution] = [:]
        for target in targets {
            result[target] = try await effectiveLabel(for: target)
        }
        return result
    }

    // MARK: - Assignment history

    /// All assignments (active + revoked) for a target, ordered oldest-first.
    /// Throws `SensitiveScopeError.malformedAssignmentRow` if any row cannot be decoded.
    public func assignments(for target: SensitiveScopeTarget) async throws -> [SensitiveScopeAssignment] {
        let rows = try await database.query("""
        SELECT id, target_kind, target_id, sensitivity, privileged, origin, reason, assigned_by,
               created_at, revoked_at, revoked_by, revoked_reason
          FROM sensitive_scope_assignments
         WHERE target_kind = ? AND target_id = ?
         ORDER BY created_at ASC;
        """, [.text(target.kind.rawValue), .uuid(target.id)])
        return try rows.map(Self.decodeAssignment)
    }

    // MARK: - Review history

    /// All audit-review entries for one assignment, ordered oldest-first.
    public func reviews(forAssignmentID assignmentID: UUID) async throws -> [SensitiveScopeReview] {
        let rows = try await database.query("""
        SELECT id, assignment_id, action, actor_note, created_at
          FROM sensitive_scope_reviews
         WHERE assignment_id = ?
         ORDER BY created_at ASC;
        """, [.uuid(assignmentID)])
        return try rows.map { row in
            guard let id         = row.uuid(0),
                  let assignID   = row.uuid(1),
                  let actionStr  = row.string(2),
                  let action     = SensitiveScopeAction(rawValue: actionStr),
                  let createdAt  = row.date(4)
            else {
                throw SensitiveScopeError.malformedAssignmentRow(row.uuid(0) ?? UUID())
            }
            return SensitiveScopeReview(id: id, assignmentID: assignID, action: action,
                                        actorNote: row.string(3), createdAt: createdAt)
        }
    }

    // MARK: - Policy decision (nonisolated — pure computation over value types)

    /// Whether `label` is accessible in `scope`. Nonisolated: callers at any isolation
    /// level may call this without an actor hop.
    public nonisolated static func scopePermits(
        _ label: ProtectionLabel,
        scope: SensitiveScope
    ) -> Bool {
        scope.permits(label)
    }

    // MARK: - Static helpers (synchronous, for withSavepoint closures)

    private static func insertAssignment(
        _ db: isolated Database,
        assignment: SensitiveScopeAssignment
    ) throws {
        try db.exec("""
        INSERT INTO sensitive_scope_assignments
            (id, target_kind, target_id, sensitivity, privileged,
             origin, reason, assigned_by, created_at)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(assignment.id),
              .text(assignment.targetKind.rawValue),
              .uuid(assignment.targetID),
              .integer(Int64(assignment.sensitivity.rawValue)),
              .bool(assignment.privileged),
              .text(assignment.origin),
              .optionalText(assignment.reason),
              .text(assignment.assignedBy),
              .date(assignment.createdAt)])
    }

    private static func insertReview(
        _ db: isolated Database,
        id: UUID,
        assignmentID: UUID,
        action: SensitiveScopeAction,
        actorNote: String?,
        at: Date
    ) throws {
        try db.exec("""
        INSERT INTO sensitive_scope_reviews (id, assignment_id, action, actor_note, created_at)
        VALUES (?,?,?,?,?);
        """, [.uuid(id), .uuid(assignmentID), .text(action.rawValue),
              .optionalText(actorNote), .date(at)])
    }

    // MARK: - Target validation

    /// The canonical SQLite table name for each target kind. Return values are hardcoded
    /// literals — no user input is interpolated into SQL.
    private nonisolated static func targetTableName(for kind: SensitiveScopeTargetKind) -> String {
        switch kind {
        case .file:            return "files"
        case .sourceVersion:   return "source_versions"
        case .knowledgeObject: return "knowledge_objects"
        case .chunk:           return "chunks"
        case .evidenceBlock:   return "evidence_blocks"
        case .entity:          return "entities"
        case .event:           return "events"
        case .claim:           return "claims"
        }
    }

    private static func targetExists(
        _ db: isolated Database,
        target: SensitiveScopeTarget
    ) throws -> Bool {
        let table = targetTableName(for: target.kind)
        let rows = try db.query(
            "SELECT 1 FROM \(table) WHERE id = ? LIMIT 1;",
            [.uuid(target.id)])
        return !rows.isEmpty
    }

    // MARK: - Lineage queries

    /// Returns the SQL and ordered bindings for a lineage-aware active-assignment query.
    /// All bindings are `.uuid(target.id)`, repeated once per JOIN branch.
    ///
    /// Lineage topology:
    ///   file (root)
    ///   sourceVersion (root — no file FK in schema)
    ///   knowledgeObject → file
    ///   chunk → knowledgeObject → file
    ///   entity → knowledgeObject → file  (via entities.source_object_id)
    ///   event → knowledgeObject → file   (via events.source_object_id)
    ///   evidenceBlock → sourceVersion + KOs (via EBO) + files (via KOs)
    ///   claim → cited KOs + cited EBs + cited SVs + KOs-via-EB + files-via-KO
    private nonisolated static func lineageQuery(
        for target: SensitiveScopeTarget
    ) -> (sql: String, bindings: [SQLValue]) {
        let id = target.id
        switch target.kind {

        case .file:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'file' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id)])

        case .sourceVersion:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'sourceVersion' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id)])

        case .knowledgeObject:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'knowledgeObject' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN knowledge_objects ko ON ko.file_id = ssa.target_id
             WHERE ssa.target_kind = 'file' AND ko.id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id), .uuid(id)])

        case .chunk:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'chunk' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN chunks c ON c.object_id = ssa.target_id
             WHERE ssa.target_kind = 'knowledgeObject' AND c.id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN knowledge_objects ko ON ko.file_id = ssa.target_id
              JOIN chunks c ON c.object_id = ko.id
             WHERE ssa.target_kind = 'file' AND c.id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id), .uuid(id), .uuid(id)])

        case .entity:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'entity' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN entities e ON e.source_object_id = ssa.target_id
             WHERE ssa.target_kind = 'knowledgeObject' AND e.id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN knowledge_objects ko ON ko.file_id = ssa.target_id
              JOIN entities e ON e.source_object_id = ko.id
             WHERE ssa.target_kind = 'file' AND e.id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id), .uuid(id), .uuid(id)])

        case .event:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'event' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN events ev ON ev.source_object_id = ssa.target_id
             WHERE ssa.target_kind = 'knowledgeObject' AND ev.id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN knowledge_objects ko ON ko.file_id = ssa.target_id
              JOIN events ev ON ev.source_object_id = ko.id
             WHERE ssa.target_kind = 'file' AND ev.id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id), .uuid(id), .uuid(id)])

        case .evidenceBlock:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'evidenceBlock' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN evidence_blocks eb ON eb.source_version_id = ssa.target_id
             WHERE ssa.target_kind = 'sourceVersion'
               AND eb.id = ? AND eb.source_version_id IS NOT NULL AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN evidence_block_objects ebo ON ebo.knowledge_object_id = ssa.target_id
             WHERE ssa.target_kind = 'knowledgeObject'
               AND ebo.evidence_block_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN knowledge_objects ko ON ko.file_id = ssa.target_id
              JOIN evidence_block_objects ebo ON ebo.knowledge_object_id = ko.id
             WHERE ssa.target_kind = 'file'
               AND ebo.evidence_block_id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id), .uuid(id), .uuid(id), .uuid(id)])

        case .claim:
            return ("""
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
             WHERE ssa.target_kind = 'claim' AND ssa.target_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN claim_evidence_ref cer ON cer.knowledge_object_id = ssa.target_id
             WHERE ssa.target_kind = 'knowledgeObject'
               AND cer.claim_id = ? AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN claim_evidence_ref cer ON cer.evidence_block_id = ssa.target_id
             WHERE ssa.target_kind = 'evidenceBlock'
               AND cer.claim_id = ? AND cer.evidence_block_id IS NOT NULL AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN claim_evidence_ref cer ON cer.source_version_id = ssa.target_id
             WHERE ssa.target_kind = 'sourceVersion'
               AND cer.claim_id = ? AND cer.source_version_id IS NOT NULL AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN evidence_block_objects ebo ON ebo.knowledge_object_id = ssa.target_id
              JOIN claim_evidence_ref cer ON cer.evidence_block_id = ebo.evidence_block_id
             WHERE ssa.target_kind = 'knowledgeObject'
               AND cer.claim_id = ? AND cer.evidence_block_id IS NOT NULL AND ssa.revoked_at IS NULL
            UNION ALL
            SELECT ssa.sensitivity, ssa.privileged
              FROM sensitive_scope_assignments ssa
              JOIN knowledge_objects ko ON ko.file_id = ssa.target_id
              JOIN claim_evidence_ref cer ON cer.knowledge_object_id = ko.id
             WHERE ssa.target_kind = 'file'
               AND cer.claim_id = ? AND ssa.revoked_at IS NULL
            """, [.uuid(id), .uuid(id), .uuid(id), .uuid(id), .uuid(id), .uuid(id)])
        }
    }

    // MARK: - Row decoding

    /// Decode a full assignment row. Throws `malformedAssignmentRow` instead of returning
    /// nil — silent drops masked data-quality bugs in production.
    private nonisolated static func decodeAssignment(_ row: SQLRow) throws -> SensitiveScopeAssignment {
        guard let id         = row.uuid(0),
              let kindStr    = row.string(1),
              let kind       = SensitiveScopeTargetKind(rawValue: kindStr),
              let targetID   = row.uuid(2),
              let sv         = row.int(3),
              let sensitivity = SensitivityLevel(rawValue: Int(sv)),
              let pv         = row.int(4),
              let origin     = row.string(5),
              let assignedBy = row.string(7),
              let createdAt  = row.date(8)
        else {
            throw SensitiveScopeError.malformedAssignmentRow(row.uuid(0) ?? UUID())
        }
        return SensitiveScopeAssignment(
            id: id, targetKind: kind, targetID: targetID,
            sensitivity: sensitivity, privileged: pv != 0,
            origin: origin, reason: row.string(6),
            assignedBy: assignedBy, createdAt: createdAt,
            revokedAt: row.date(9),
            revokedBy: row.string(10),
            revokedReason: row.string(11)
        )
    }
}
