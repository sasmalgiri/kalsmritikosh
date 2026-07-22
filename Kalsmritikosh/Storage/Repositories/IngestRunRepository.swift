//
//  IngestRunRepository.swift
//  Kalsmritikosh
//
//  ING-001 / ING-004 — durable ingest run-state. Persists each ingest run and every file's
//  transition so an interrupted ingest (crash, quit, power loss) can be RESUMED rather than
//  silently left half-done or restarted from scratch. Nothing is deleted — a run's history
//  is the recovery record.
//
//  Raw sqlite3 C-API repository style. Deterministic; the caller supplies timestamps.
//

import Foundation
import CryptoKit

public enum IngestRunStatus: String, Sendable, Codable { case pending, running, paused, completed, failed }
public enum IngestFileState: String, Sendable, Codable { case pending, running, done, failed }

public struct IngestRunHeader: Sendable, Hashable {
    public let id: UUID
    public let status: IngestRunStatus
    public let totalFiles: Int
    public let completedFiles: Int
    public let failedFiles: Int
}

public actor IngestRunRepository {
    private let database: Database
    public init(database: Database) { self.database = database }

    /// Stable hash of a file path (so the same file resumes at the same slot).
    public nonisolated static func pathHash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func startRun(id: UUID = UUID(), totalFiles: Int, atMillis: Double) async throws -> UUID {
        try await database.exec("""
        INSERT OR REPLACE INTO ingest_runs (id, status, total_files, completed_files, failed_files, started_at, updated_at)
        VALUES (?, 'running', ?, 0, 0, ?, ?);
        """, [.uuid(id), .integer(Int64(totalFiles)), .real(atMillis), .real(atMillis)])
        return id
    }

    public func setFileState(run: UUID, path: String, state: IngestFileState, error: String? = nil, atMillis: Double) async throws {
        try await database.exec("""
        INSERT OR REPLACE INTO ingest_run_files (run_id, path_hash, path, state, error, updated_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [.uuid(run), .text(Self.pathHash(path)), .text(path), .text(state.rawValue),
              error.map { SQLValue.text($0) } ?? .null, .real(atMillis)])
        try await recomputeCounts(run: run, atMillis: atMillis)
    }

    public func finish(run: UUID, status: IngestRunStatus, atMillis: Double) async throws {
        try await database.exec("UPDATE ingest_runs SET status = ?, updated_at = ? WHERE id = ?;",
                                [.text(status.rawValue), .real(atMillis), .uuid(run)])
    }

    /// Runs left mid-flight (running/paused) — candidates to resume at boot.
    public func resumableRuns() async throws -> [IngestRunHeader] {
        let rows = try await database.query("""
        SELECT id, status, total_files, completed_files, failed_files
        FROM ingest_runs WHERE status IN ('running','paused') ORDER BY started_at DESC;
        """, [])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let st = r.string(1).flatMap(IngestRunStatus.init) else { return nil }
            return IngestRunHeader(id: id, status: st, totalFiles: Int(r.int(2) ?? 0),
                                   completedFiles: Int(r.int(3) ?? 0), failedFiles: Int(r.int(4) ?? 0))
        }
    }

    /// Files not yet done for a run — the exact remaining work to resume.
    public func pendingFiles(run: UUID) async throws -> [String] {
        let rows = try await database.query("""
        SELECT path FROM ingest_run_files WHERE run_id = ? AND state IN ('pending','running','failed');
        """, [.uuid(run)])
        return rows.compactMap { $0.string(0) }
    }

    // MARK: - Internals

    private func recomputeCounts(run: UUID, atMillis: Double) async throws {
        let done = try await scalar("SELECT COUNT(*) FROM ingest_run_files WHERE run_id = ? AND state = 'done';", run)
        let failed = try await scalar("SELECT COUNT(*) FROM ingest_run_files WHERE run_id = ? AND state = 'failed';", run)
        try await database.exec("UPDATE ingest_runs SET completed_files = ?, failed_files = ?, updated_at = ? WHERE id = ?;",
                                [.integer(Int64(done)), .integer(Int64(failed)), .real(atMillis), .uuid(run)])
    }

    private func scalar(_ sql: String, _ run: UUID) async throws -> Int {
        Int((try await database.query(sql, [.uuid(run)])).first?.int(0) ?? 0)
    }
}
