//
//  SensitiveScopeRepository.swift
//  Kalsmritikosh
//
//  OPS-003A — the single authority for reading and writing protection assignments.
//  All six enforcement surfaces (screen, retrieval, prompt, report, receipt, export)
//  read from this repository — there is no per-surface or per-persona override.
//
//  Effective ProtectionLabel for a target = SensitivityInheritance.inherit applied to
//  all ACTIVE assignments. A target with NO active assignments returns
//  ProtectionLabel(sensitivity: .internalLevel, privileged: false) — fail-closed;
//  unknown provenance is never assumed public.
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
    /// Privilege assignments must originate from a recorded human action; deterministic
    /// rules may propose sensitivity but must not set privileged=true (enforced in
    /// OPS-003B callers — this layer stores whatever the caller passes).
    @discardableResult
    public func assign(
        targetKind: SensitiveScopeTargetKind,
        targetID: UUID,
        sensitivity: SensitivityLevel,
        privileged: Bool,
        origin: String,
        reason: String?,
        assignedBy: String,
        at: Date = Date()
    ) async throws -> SensitiveScopeAssignment {
        let assignmentID = UUID()
        let reviewID = UUID()
        let assignment = SensitiveScopeAssignment(
            id: assignmentID, targetKind: targetKind, targetID: targetID,
            sensitivity: sensitivity, privileged: privileged,
            origin: origin, reason: reason, assignedBy: assignedBy,
            createdAt: at, revokedAt: nil, revokedBy: nil, revokedReason: nil
        )
        try await database.withSavepoint("ssa_assign") { db in
            try Self.insertAssignment(db, assignment: assignment)
            try Self.insertReview(db, id: reviewID, assignmentID: assignmentID,
                                  action: .assigned, actorNote: nil, at: at)
        }
        return assignment
    }

    // MARK: - Revoke

    /// Revoke one active assignment. Records a review entry. Throws if the assignment
    /// is not found or already revoked. Does NOT remove other active assignments on
    /// the same target — effective label only fully clears when all are revoked.
    public func revoke(
        assignmentID: UUID,
        revokedBy: String,
        reason: String?,
        at: Date = Date()
    ) async throws {
        let reviewID = UUID()
        try await database.withSavepoint("ssa_revoke") { db in
            let existing = try db.query(
                "SELECT revoked_at FROM sensitive_scope_assignments WHERE id = ? LIMIT 1;",
                [.uuid(assignmentID)])
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
        }
    }

    // MARK: - Effective label

    /// The effective ProtectionLabel for a target, derived from all its ACTIVE assignments.
    /// Returns (.internalLevel, privileged: false) when no active assignment exists —
    /// fail-closed: a target with unknown protection is never assumed public.
    public func effectiveLabel(
        forTargetKind kind: SensitiveScopeTargetKind,
        id targetID: UUID
    ) async throws -> ProtectionLabel {
        let rows = try await database.query("""
        SELECT sensitivity, privileged
          FROM sensitive_scope_assignments
         WHERE target_kind = ? AND target_id = ? AND revoked_at IS NULL;
        """, [.text(kind.rawValue), .uuid(targetID)])
        guard !rows.isEmpty else {
            return ProtectionLabel(sensitivity: .internalLevel, privileged: false)
        }
        let labels: [ProtectionLabel] = rows.compactMap { row in
            guard let sv = row.int(0), let pv = row.int(1),
                  let s = SensitivityLevel(rawValue: Int(sv)) else { return nil }
            return ProtectionLabel(sensitivity: s, privileged: pv != 0)
        }
        return SensitivityInheritance.inherit(from: labels)
    }

    /// Batch effective-label resolution. Keys are target UUIDs. Missing targets resolve
    /// to the fail-closed default (.internalLevel, privileged: false).
    public func batchEffectiveLabels(
        _ targets: [(SensitiveScopeTargetKind, UUID)]
    ) async throws -> [UUID: ProtectionLabel] {
        var result: [UUID: ProtectionLabel] = [:]
        for (kind, id) in targets {
            result[id] = try await effectiveLabel(forTargetKind: kind, id: id)
        }
        return result
    }

    // MARK: - Assignment history

    /// All assignments (active + revoked) for a target, ordered oldest-first.
    public func assignments(
        forTargetKind kind: SensitiveScopeTargetKind,
        id targetID: UUID
    ) async throws -> [SensitiveScopeAssignment] {
        let rows = try await database.query("""
        SELECT id, target_kind, target_id, sensitivity, privileged, origin, reason, assigned_by,
               created_at, revoked_at, revoked_by, revoked_reason
          FROM sensitive_scope_assignments
         WHERE target_kind = ? AND target_id = ?
         ORDER BY created_at ASC;
        """, [.text(kind.rawValue), .uuid(targetID)])
        return rows.compactMap(Self.decodeAssignment)
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

    // MARK: - Row decoding

    private nonisolated static func decodeAssignment(_ row: SQLRow) -> SensitiveScopeAssignment? {
        guard let id        = row.uuid(0),
              let kindStr   = row.string(1),
              let kind      = SensitiveScopeTargetKind(rawValue: kindStr),
              let targetID  = row.uuid(2),
              let sv        = row.int(3),
              let sensitivity = SensitivityLevel(rawValue: Int(sv)),
              let pv        = row.int(4),
              let origin    = row.string(5),
              let assignedBy = row.string(7),
              let createdAt = row.date(8)
        else { return nil }
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
