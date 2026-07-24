//
//  ClaimProjectionProgressRepository.swift
//  Kalsmritikosh
//
//  PA-PROD Commit B2 — durable keyset cursor for the resumable Claim-projection backfill,
//  per (producer_version, source_kind). A new producer version gets an independent progress
//  set; an older version's completed rows are never overwritten or reinterpreted.
//

import Foundation

public actor ClaimProjectionProgressRepository {
    public struct Cursor: Sendable, Equatable {
        public let lastSourceID: UUID?
        public let complete: Bool
        public static let start = Cursor(lastSourceID: nil, complete: false)
    }

    private let database: Database
    public init(database: Database) { self.database = database }

    /// The cursor for a (version, kind), or `.start` when none has been recorded yet.
    public func cursor(version: String, kind: String) async throws -> Cursor {
        let rows = try await database.query("""
        SELECT last_source_id, complete FROM claim_projection_progress
        WHERE producer_version = ? AND source_kind = ?;
        """, [.text(version), .text(kind)])
        guard let r = rows.first else { return .start }
        return Cursor(lastSourceID: r.uuid(0), complete: (r.int(1) ?? 0) != 0)
    }

    /// Advance the cursor to the last successfully-projected source id (not complete).
    public func advance(version: String, kind: String, lastSourceID: UUID, at when: Date) async throws {
        try await database.exec("""
        INSERT INTO claim_projection_progress (producer_version, source_kind, last_source_id, complete, updated_at)
        VALUES (?,?,?,0,?)
        ON CONFLICT(producer_version, source_kind) DO UPDATE SET
            last_source_id = excluded.last_source_id, complete = 0, updated_at = excluded.updated_at;
        """, [.text(version), .text(kind), .uuid(lastSourceID), .real(when.timeIntervalSince1970)])
    }

    /// Mark a (version, kind) pass complete, preserving the last source id.
    public func markComplete(version: String, kind: String, at when: Date) async throws {
        try await database.exec("""
        INSERT INTO claim_projection_progress (producer_version, source_kind, last_source_id, complete, updated_at)
        VALUES (?,?,(SELECT last_source_id FROM claim_projection_progress WHERE producer_version = ? AND source_kind = ?),1,?)
        ON CONFLICT(producer_version, source_kind) DO UPDATE SET complete = 1, updated_at = excluded.updated_at;
        """, [.text(version), .text(kind), .text(version), .text(kind), .real(when.timeIntervalSince1970)])
    }
}
