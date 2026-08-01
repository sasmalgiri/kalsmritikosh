//
//  SourceUpgradeJobRepository.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009 §14/§15/§16) — the ONE authority over exact-SourceVersion upgrade jobs on the v88
//  ledger. Claiming is LEASE-based inside one savepoint (find eligible → lease token + expiry → running
//  → attempts+1). Every transition appends an append-only enrichment_job_events row (operational
//  provenance, not evidence). Idempotent: at most one ACTIVE job per (source_version_id, kind,
//  producer_id, producer_version); re-requesting reuses it. Boot recovery requeues only EXPIRED leases.
//

import Foundation

public struct SourceUpgradeJobRepository: Sendable {

    private let database: Database
    public init(database: Database) { self.database = database }

    private static let columns = """
        id, scope_kind, subject_id, source_version_id, kind, target_dimension, requested_goal, priority,
        origin, state, attempts, max_attempts, last_error, producer_id, producer_version, not_before,
        lease_token, lease_expires_at
        """

    // MARK: - Enqueue (idempotent reuse)

    @discardableResult
    public func enqueue(sourceVersionID: UUID, kind: SourceUpgradeKind, goal: SourceUpgradeGoal? = nil,
                        priority: SourceUpgradePriority = .background, origin: SourceUpgradeOrigin = .backgroundPolicy,
                        producerID: String = "usf-m3", producerVersion: String = "1",
                        notBefore: Date? = nil, maxAttempts: Int = 3, at now: Date) async throws -> SourceUpgradeJob {
        let nb = notBefore ?? now
        let sp = "usf_upgrade_enq_\(sourceVersionID.uuidString.prefix(8))_\(UUID().uuidString.prefix(4))"
        return try await database.withSavepoint(sp) { db -> SourceUpgradeJob in
            guard try db.query("SELECT 1 FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(sourceVersionID)]).first != nil else {
                throw SourceUpgradeError.sourceVersionMissing(sourceVersionID)
            }
            // Reuse an active (pending/running) job for the same exact work identity.
            if let existing = try Self.activeRow(db, sourceVersionID: sourceVersionID, kind: kind,
                                                 producerID: producerID, producerVersion: producerVersion) {
                return existing
            }
            let job = SourceUpgradeJob(
                id: UUID(), scope: .sourceVersion, subjectID: nil, sourceVersionID: sourceVersionID, kind: kind,
                targetDimension: kind.targetDimension, requestedGoal: goal, priority: priority, origin: origin,
                state: .pending, attempts: 0, maxAttempts: max(1, maxAttempts), lastError: nil,
                producerID: producerID, producerVersion: producerVersion, notBefore: nb, leaseToken: nil, leaseExpiresAt: nil)
            try Self.insert(db, job, now: now)
            try Self.event(db, jobID: job.id, action: "enqueue", from: nil, to: "pending", detail: goal?.rawValue, now: now)
            return job
        }
    }

    // MARK: - Lease-based claim

    public func claimNext(leaseSeconds: TimeInterval = 300, at now: Date) async throws -> SourceUpgradeJob? {
        let sp = "usf_upgrade_claim_\(UUID().uuidString.prefix(6))"
        return try await database.withSavepoint(sp) { db -> SourceUpgradeJob? in
            guard let row = try db.query("""
                SELECT \(Self.columns) FROM enrichment_jobs
                 WHERE scope_kind = 'sourceVersion' AND state = 'pending' AND not_before <= ?
                 ORDER BY priority DESC, not_before ASC, created_at ASC, id ASC LIMIT 1;
                """, [.real(now.timeIntervalSince1970)]).first, let job = Self.decode(row) else { return nil }
            let token = UUID().uuidString
            try db.exec("""
                UPDATE enrichment_jobs SET state = 'running', lease_token = ?, lease_expires_at = ?,
                    attempts = attempts + 1, updated_at = ? WHERE id = ?;
                """, [.text(token), .real(now.addingTimeInterval(leaseSeconds).timeIntervalSince1970),
                      .real(now.timeIntervalSince1970), .uuid(job.id)])
            try Self.event(db, jobID: job.id, action: "claim", from: "pending", to: "running", detail: nil, now: now)
            return try Self.row(db, id: job.id)
        }
    }

    // MARK: - Terminal / retry transitions

    public func succeed(_ id: UUID, at now: Date) async throws {
        try await transition(id, to: .done, action: "succeed", detail: nil, clearLease: true, setCompleted: true, now: now)
    }

    /// Handler failure. Bounded auto-retry: requeue to pending while attempts < max_attempts (with a
    /// backoff), else mark failed. `failed → pending` also available explicitly via `retry`.
    public func fail(_ id: UUID, error: String, backoff: TimeInterval = 30, at now: Date) async throws {
        let sp = "usf_upgrade_fail_\(id.uuidString.prefix(8))"
        try await database.withSavepoint(sp) { db in
            guard let job = try Self.row(db, id: id) else { throw SourceUpgradeError.jobNotFound(id) }
            let err = String(error.prefix(500))
            if job.attempts < job.maxAttempts {
                try db.exec("""
                    UPDATE enrichment_jobs SET state = 'pending', last_error = ?, lease_token = NULL,
                        lease_expires_at = NULL, not_before = ?, updated_at = ? WHERE id = ?;
                    """, [.text(err), .real(now.addingTimeInterval(backoff).timeIntervalSince1970),
                          .real(now.timeIntervalSince1970), .uuid(id)])
                try Self.event(db, jobID: id, action: "retry", from: job.state.rawValue, to: "pending", detail: err, now: now)
            } else {
                try db.exec("""
                    UPDATE enrichment_jobs SET state = 'failed', last_error = ?, lease_token = NULL,
                        lease_expires_at = NULL, updated_at = ? WHERE id = ?;
                    """, [.text(err), .real(now.timeIntervalSince1970), .uuid(id)])
                try Self.event(db, jobID: id, action: "fail", from: job.state.rawValue, to: "failed", detail: err, now: now)
            }
        }
    }

    public func block(_ id: UUID, reason: String, at now: Date) async throws {
        try await transition(id, to: .blocked, action: "block", detail: String(reason.prefix(500)), clearLease: true, setCompleted: false, now: now)
    }

    public func cancel(_ id: UUID, at now: Date) async throws {
        try await transition(id, to: .cancelled, action: "cancel", detail: nil, clearLease: true, setCompleted: false, now: now)
    }

    public func supersede(_ id: UUID, at now: Date) async throws {
        try await transition(id, to: .superseded, action: "supersede", detail: nil, clearLease: true, setCompleted: false, now: now)
    }

    /// Explicit failed/blocked → pending retry (dependency resolved / manual re-request).
    public func retry(_ id: UUID, at now: Date) async throws {
        try await transition(id, to: .pending, action: "retry", detail: nil, clearLease: true, setCompleted: false, now: now)
    }

    /// Boot recovery: requeue ONLY running jobs whose lease has expired (never every running job).
    @discardableResult
    public func recoverExpiredLeases(at now: Date) async throws -> Int {
        let sp = "usf_upgrade_recover_\(UUID().uuidString.prefix(6))"
        return try await database.withSavepoint(sp) { db -> Int in
            let rows = try db.query("""
                SELECT id FROM enrichment_jobs WHERE state = 'running' AND lease_expires_at IS NOT NULL AND lease_expires_at < ?;
                """, [.real(now.timeIntervalSince1970)])
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                try db.exec("""
                    UPDATE enrichment_jobs SET state = 'pending', lease_token = NULL, lease_expires_at = NULL, updated_at = ? WHERE id = ?;
                    """, [.real(now.timeIntervalSince1970), .uuid(id)])
                try Self.event(db, jobID: id, action: "recover", from: "running", to: "pending", detail: "expired lease", now: now)
            }
            return rows.count
        }
    }

    /// Supersede every ACTIVE job for a source version (e.g. when it is superseded by a new version).
    @discardableResult
    public func supersedeActive(sourceVersionID: UUID, at now: Date) async throws -> Int {
        let sp = "usf_upgrade_sup_\(sourceVersionID.uuidString.prefix(8))"
        return try await database.withSavepoint(sp) { db -> Int in
            let rows = try db.query("""
                SELECT id, state FROM enrichment_jobs
                 WHERE source_version_id = ? AND scope_kind = 'sourceVersion' AND state IN ('pending','running');
                """, [.uuid(sourceVersionID)])
            for r in rows {
                guard let id = r.uuid(0) else { continue }
                try db.exec("UPDATE enrichment_jobs SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL, updated_at = ? WHERE id = ?;",
                            [.real(now.timeIntervalSince1970), .uuid(id)])
                try Self.event(db, jobID: id, action: "supersede", from: r.string(1) ?? "", to: "superseded", detail: "source version superseded", now: now)
            }
            return rows.count
        }
    }

    // MARK: - Reads

    public func job(_ id: UUID) async throws -> SourceUpgradeJob? {
        try await database.query("SELECT \(Self.columns) FROM enrichment_jobs WHERE id = ? LIMIT 1;", [.uuid(id)]).first.flatMap(Self.decode)
    }

    public func activeJob(sourceVersionID: UUID, kind: SourceUpgradeKind, producerID: String = "usf-m3", producerVersion: String = "1") async throws -> SourceUpgradeJob? {
        try await database.query("""
            SELECT \(Self.columns) FROM enrichment_jobs
             WHERE source_version_id = ? AND kind = ? AND producer_id = ? AND producer_version = ?
               AND scope_kind = 'sourceVersion' AND state IN ('pending','running') LIMIT 1;
            """, [.uuid(sourceVersionID), .text(kind.rawValue), .text(producerID), .text(producerVersion)]).first.flatMap(Self.decode)
    }

    /// The upgrade kinds by state for the completion overlay.
    public func kindsByState(sourceVersionID: UUID) async -> (pending: Set<SourceUpgradeKind>, running: Set<SourceUpgradeKind>, failed: Set<SourceUpgradeKind>) {
        let rows = (try? await database.query("""
            SELECT kind, state FROM enrichment_jobs WHERE source_version_id = ? AND scope_kind = 'sourceVersion';
            """, [.uuid(sourceVersionID)])) ?? []
        var pending: Set<SourceUpgradeKind> = [], running: Set<SourceUpgradeKind> = [], failed: Set<SourceUpgradeKind> = []
        for r in rows {
            guard let k = r.string(0).flatMap({ SourceUpgradeKind(rawValue: $0) }) else { continue }
            switch r.string(1) {
            case "pending": pending.insert(k)
            case "running": running.insert(k)
            case "failed": failed.insert(k)
            default: break
            }
        }
        return (pending, running, failed)
    }

    public func events(jobID: UUID) async throws -> [(sequence: Int, action: String, from: String?, to: String?)] {
        try await database.query("SELECT sequence, action, from_state, to_state FROM enrichment_job_events WHERE job_id = ? ORDER BY sequence ASC;", [.uuid(jobID)])
            .map { (Int($0.int(0) ?? 0), $0.string(1) ?? "", $0.string(2), $0.string(3)) }
    }

    // MARK: - Internals

    private func transition(_ id: UUID, to state: SourceUpgradeJobState, action: String, detail: String?,
                            clearLease: Bool, setCompleted: Bool, now: Date) async throws {
        let sp = "usf_upgrade_tx_\(id.uuidString.prefix(8))_\(UUID().uuidString.prefix(4))"
        try await database.withSavepoint(sp) { db in
            guard let job = try Self.row(db, id: id) else { throw SourceUpgradeError.jobNotFound(id) }
            try db.exec("""
                UPDATE enrichment_jobs SET state = ?, updated_at = ?,
                    lease_token = CASE WHEN ? THEN NULL ELSE lease_token END,
                    lease_expires_at = CASE WHEN ? THEN NULL ELSE lease_expires_at END,
                    completed_at = CASE WHEN ? THEN ? ELSE completed_at END WHERE id = ?;
                """, [.text(state.rawValue), .real(now.timeIntervalSince1970),
                      .integer(clearLease ? 1 : 0), .integer(clearLease ? 1 : 0),
                      .integer(setCompleted ? 1 : 0), .real(now.timeIntervalSince1970), .uuid(id)])
            try Self.event(db, jobID: id, action: action, from: job.state.rawValue, to: state.rawValue, detail: detail, now: now)
        }
    }

    private static func insert(_ db: isolated Database, _ j: SourceUpgradeJob, now: Date) throws {
        try db.exec("""
            INSERT INTO enrichment_jobs (id, scope_kind, subject_id, source_version_id, kind, target_dimension,
                requested_goal, priority, origin, state, attempts, max_attempts, last_error, producer_id,
                producer_version, not_before, lease_token, lease_expires_at, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(j.id), .text(j.scope.rawValue), j.subjectID.map { SQLValue.uuid($0) } ?? .null,
                  j.sourceVersionID.map { SQLValue.uuid($0) } ?? .null, .text(j.kind.rawValue),
                  j.targetDimension.map { SQLValue.text($0.rawValue) } ?? .null,
                  j.requestedGoal.map { SQLValue.text($0.rawValue) } ?? .null, .integer(Int64(j.priority.rawValue)),
                  .text(j.origin.rawValue), .text(j.state.rawValue), .integer(Int64(j.attempts)),
                  .integer(Int64(j.maxAttempts)), j.lastError.map { SQLValue.text($0) } ?? .null,
                  .text(j.producerID), .text(j.producerVersion), .real(j.notBefore.timeIntervalSince1970),
                  j.leaseToken.map { SQLValue.text($0) } ?? .null,
                  j.leaseExpiresAt.map { SQLValue.real($0.timeIntervalSince1970) } ?? .null,
                  .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
    }

    private static func event(_ db: isolated Database, jobID: UUID, action: String, from: String?, to: String?, detail: String?, now: Date) throws {
        let seq = Int(try db.query("SELECT COALESCE(MAX(sequence),0)+1 FROM enrichment_job_events WHERE job_id = ?;", [.uuid(jobID)]).first?.int(0) ?? 1)
        try db.exec("""
            INSERT INTO enrichment_job_events (id, job_id, sequence, action, from_state, to_state, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(jobID), .integer(Int64(seq)), .text(action),
                  from.map { SQLValue.text($0) } ?? .null, to.map { SQLValue.text($0) } ?? .null,
                  detail.map { SQLValue.text($0) } ?? .null, .real(now.timeIntervalSince1970)])
    }

    private static func activeRow(_ db: isolated Database, sourceVersionID: UUID, kind: SourceUpgradeKind,
                                  producerID: String, producerVersion: String) throws -> SourceUpgradeJob? {
        try db.query("""
            SELECT \(columns) FROM enrichment_jobs
             WHERE source_version_id = ? AND kind = ? AND producer_id = ? AND producer_version = ?
               AND scope_kind = 'sourceVersion' AND state IN ('pending','running') LIMIT 1;
            """, [.uuid(sourceVersionID), .text(kind.rawValue), .text(producerID), .text(producerVersion)]).first.flatMap(decode)
    }

    private static func row(_ db: isolated Database, id: UUID) throws -> SourceUpgradeJob? {
        try db.query("SELECT \(columns) FROM enrichment_jobs WHERE id = ? LIMIT 1;", [.uuid(id)]).first.flatMap(decode)
    }

    private static func decode(_ r: SQLRow) -> SourceUpgradeJob? {
        guard let id = r.uuid(0), let scope = SourceUpgradeScope(rawValue: r.string(1) ?? ""),
              let kind = SourceUpgradeKind(rawValue: r.string(4) ?? ""),
              let priority = SourceUpgradePriority(rawValue: Int(r.int(7) ?? 40)),
              let origin = SourceUpgradeOrigin(rawValue: r.string(8) ?? ""),
              let state = SourceUpgradeJobState(rawValue: r.string(9) ?? "") else { return nil }
        return SourceUpgradeJob(
            id: id, scope: scope, subjectID: r.uuid(2), sourceVersionID: r.uuid(3), kind: kind,
            targetDimension: r.string(5).flatMap { SourceReadinessDimension(rawValue: $0) },
            requestedGoal: r.string(6).flatMap { SourceUpgradeGoal(rawValue: $0) }, priority: priority, origin: origin,
            state: state, attempts: Int(r.int(10) ?? 0), maxAttempts: Int(r.int(11) ?? 3), lastError: r.string(12),
            producerID: r.string(13) ?? "", producerVersion: r.string(14) ?? "",
            notBefore: Date(timeIntervalSince1970: r.double(15) ?? 0),
            leaseToken: r.string(16), leaseExpiresAt: r.double(17).map { Date(timeIntervalSince1970: $0) })
    }
}
