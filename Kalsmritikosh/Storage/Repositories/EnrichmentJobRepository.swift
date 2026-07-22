//
//  EnrichmentJobRepository.swift
//  Kalsmritikosh
//
//  PERF.2 — durable store for the deferred deep-enrichment job ledger. Enqueue is
//  idempotent per (subject, kind) so a re-ingest never duplicates work; claim/complete/
//  fail move a job through its lifecycle; boot recovery re-queues jobs stranded in
//  `running` by a crash (06_INGESTION §4 "resume safe idempotent stages"). Counts by
//  kind feed the per-dimension readiness display (§6).
//
//  Raw sqlite3 C-API repository style (exec/query + SQLValue/SQLRow).
//

import Foundation

public actor EnrichmentJobRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// Enqueue a job for (subject, kind). Idempotent: if one already exists it is left
    /// as-is (INSERT OR IGNORE on the UNIQUE constraint), so re-ingest doesn't re-queue
    /// completed or in-flight work. Returns true if a new row was created.
    @discardableResult
    public func enqueue(subjectID: UUID, kind: EnrichmentJobKind) async throws -> Bool {
        let before = try await count()
        let now = Date().timeIntervalSince1970
        try await database.exec("""
        INSERT OR IGNORE INTO enrichment_jobs
            (id, subject_id, kind, state, attempts, last_error, created_at, updated_at)
        VALUES (?, ?, ?, 'pending', 0, NULL, ?, ?);
        """, [.uuid(UUID()), .uuid(subjectID), .text(kind.rawValue), .real(now), .real(now)])
        return (try await count()) > before
    }

    /// Claim the oldest pending job of `kind`, marking it `running`. Returns nil if none.
    /// Atomic enough for the single-drainer model (one processor per kind).
    public func claimNext(kind: EnrichmentJobKind) async throws -> EnrichmentJob? {
        let rows = try await database.query("""
        SELECT id, subject_id, kind, state, attempts, last_error, created_at, updated_at
        FROM enrichment_jobs WHERE state = 'pending' AND kind = ?
        ORDER BY created_at ASC LIMIT 1;
        """, [.text(kind.rawValue)])
        guard let job = rows.first.flatMap(Self.decode) else { return nil }
        try await setState(job.id, .running, incrementAttempt: true)
        return job
    }

    public func markDone(_ id: UUID) async throws { try await setState(id, .done) }

    public func markFailed(_ id: UUID, error: String) async throws {
        try await database.exec("""
        UPDATE enrichment_jobs SET state = 'failed', last_error = ?, updated_at = ? WHERE id = ?;
        """, [.text(String(error.prefix(500))), .real(Date().timeIntervalSince1970), .uuid(id)])
    }

    /// Boot recovery: any job left `running` by a crash is returned to `pending` so a
    /// fresh drainer picks it up. Idempotent stages make re-running safe. Returns the count.
    @discardableResult
    public func requeueStuckRunning() async throws -> Int {
        let stuck = Int((try await database.query(
            "SELECT COUNT(*) FROM enrichment_jobs WHERE state = 'running';", [])).first?.int(0) ?? 0)
        try await database.exec("""
        UPDATE enrichment_jobs SET state = 'pending', updated_at = ? WHERE state = 'running';
        """, [.real(Date().timeIntervalSince1970)])
        return stuck
    }

    /// Pending-job count for a kind (feeds the readiness display).
    public func pendingCount(kind: EnrichmentJobKind) async throws -> Int {
        Int((try await database.query(
            "SELECT COUNT(*) FROM enrichment_jobs WHERE state = 'pending' AND kind = ?;",
            [.text(kind.rawValue)])).first?.int(0) ?? 0)
    }

    public func count() async throws -> Int {
        Int((try await database.query("SELECT COUNT(*) FROM enrichment_jobs;", [])).first?.int(0) ?? 0)
    }

    private func setState(_ id: UUID, _ state: EnrichmentJobState, incrementAttempt: Bool = false) async throws {
        let attemptClause = incrementAttempt ? ", attempts = attempts + 1" : ""
        try await database.exec("""
        UPDATE enrichment_jobs SET state = ?\(attemptClause), updated_at = ? WHERE id = ?;
        """, [.text(state.rawValue), .real(Date().timeIntervalSince1970), .uuid(id)])
    }

    private nonisolated static func decode(_ r: SQLRow) -> EnrichmentJob? {
        guard let id = r.uuid(0), let subject = r.uuid(1),
              let kindRaw = r.string(2), let kind = EnrichmentJobKind(rawValue: kindRaw),
              let stateRaw = r.string(3), let state = EnrichmentJobState(rawValue: stateRaw)
        else { return nil }
        return EnrichmentJob(
            id: id, subjectID: subject, kind: kind, state: state,
            attempts: Int(r.int(4) ?? 0), lastError: r.string(5),
            createdAt: Date(timeIntervalSince1970: r.double(6) ?? 0),
            updatedAt: Date(timeIntervalSince1970: r.double(7) ?? 0))
    }
}
