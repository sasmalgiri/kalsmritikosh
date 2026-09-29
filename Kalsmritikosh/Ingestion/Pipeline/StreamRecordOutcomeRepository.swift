//
//  StreamRecordOutcomeRepository.swift
//  Kalsmritikosh
//
//  F01/F15 — the durable per-record ledger of a streamed ingest (v139). A record is identified by its
//  position in the version's immutable acquired stream, so a retry over the same bytes meets the same
//  record at the same position. States: `attempting` (written before the record's writes begin),
//  `committed` (after they all succeed), `failed` (with the reason). A retry skips committed records
//  and rolls back the object of an interrupted/failed attempt before redoing it.
//

import Foundation

public nonisolated enum StreamRecordState: String, Sendable, Codable, Hashable {
    case attempting, committed, failed
}

public nonisolated struct StreamRecordOutcome: Sendable {
    public let position: Int
    public let state: StreamRecordState
    public let objectID: UUID?
    public let ownershipKeys: [String: AnyCodable]
    public let reason: String?
    public let attempts: Int
}

public struct StreamRecordOutcomeRepository: Sendable {
    private let database: Database
    public init(database: Database) { self.database = database }

    public func outcome(sourceVersionID: UUID, position: Int) async throws -> StreamRecordOutcome? {
        try await database.query("""
            SELECT position, state, object_id, ownership_keys, reason, attempts FROM stream_record_outcomes
             WHERE source_version_id = ? AND position = ?;
            """, [.uuid(sourceVersionID), .integer(Int64(position))]).first.flatMap(Self.decode)
    }

    /// A page of outcomes in stream order, strictly after `afterPosition` (keyset; bounded memory).
    public func page(sourceVersionID: UUID, afterPosition: Int, limit: Int,
                     state: StreamRecordState? = nil) async throws -> [StreamRecordOutcome] {
        try await database.query("""
            SELECT position, state, object_id, ownership_keys, reason, attempts FROM stream_record_outcomes
             WHERE source_version_id = ? AND position > ? AND (? IS NULL OR state = ?)
             ORDER BY position LIMIT ?;
            """, [.uuid(sourceVersionID), .integer(Int64(afterPosition)),
                  state.map { .text($0.rawValue) } ?? .null, state.map { .text($0.rawValue) } ?? .null,
                  .integer(Int64(limit))]).compactMap(Self.decode)
    }

    public func counts(sourceVersionID: UUID) async throws -> [StreamRecordState: Int] {
        var out: [StreamRecordState: Int] = [:]
        for r in try await database.query(
            "SELECT state, COUNT(*) FROM stream_record_outcomes WHERE source_version_id = ? GROUP BY state;",
            [.uuid(sourceVersionID)]) {
            if let s = r.string(0).flatMap(StreamRecordState.init(rawValue:)) { out[s] = Int(r.int(1) ?? 0) }
        }
        return out
    }

    /// The first failure's reason (for an actionable readiness detail).
    public func firstFailureReason(sourceVersionID: UUID) async throws -> String? {
        try await database.query("""
            SELECT reason FROM stream_record_outcomes WHERE source_version_id = ? AND state = 'failed'
             ORDER BY position LIMIT 1;
            """, [.uuid(sourceVersionID)]).first?.string(0)
    }

    /// Begin an attempt: roll back the object of a previous unfinished/failed attempt (its partial
    /// writes cascade away with it), then record `attempting` for the new object — in ONE unit.
    public func beginAttempt(sourceVersionID svid: UUID, position: Int, objectID: UUID, at now: Date) async throws {
        try await database.withSavepoint("sro_begin") { db in
            if let prior = try db.query("""
                SELECT object_id, state FROM stream_record_outcomes WHERE source_version_id = ? AND position = ?;
                """, [.uuid(svid), .integer(Int64(position))]).first,
               prior.string(1) != StreamRecordState.committed.rawValue, let stale = prior.uuid(0), stale != objectID {
                try db.exec("DELETE FROM knowledge_objects WHERE id = ?;", [.uuid(stale)])
            }
            try db.exec("""
                INSERT INTO stream_record_outcomes (source_version_id, position, state, object_id, attempts, updated_at)
                VALUES (?, ?, 'attempting', ?, 1, ?)
                ON CONFLICT (source_version_id, position) DO UPDATE SET
                    state = 'attempting', object_id = excluded.object_id, reason = NULL,
                    attempts = attempts + 1, updated_at = excluded.updated_at;
                """, [.uuid(svid), .integer(Int64(position)), .uuid(objectID), .date(now)])
        }
    }

    public func commit(sourceVersionID svid: UUID, position: Int, objectID: UUID,
                       ownershipKeys: [String: AnyCodable], at now: Date) async throws {
        let keys = (try? JSONEncoder().encode(ownershipKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try await database.exec("""
            UPDATE stream_record_outcomes SET state = 'committed', object_id = ?, ownership_keys = ?, reason = NULL, updated_at = ?
             WHERE source_version_id = ? AND position = ?;
            """, [.uuid(objectID), .text(keys), .date(now), .uuid(svid), .integer(Int64(position))])
    }

    public func fail(sourceVersionID svid: UUID, position: Int, reason: String, at now: Date) async throws {
        try await database.exec("""
            UPDATE stream_record_outcomes SET state = 'failed', reason = ?, updated_at = ?
             WHERE source_version_id = ? AND position = ?;
            """, [.text(String(reason.prefix(500))), .date(now), .uuid(svid), .integer(Int64(position))])
    }

    private static func decode(_ r: SQLRow) -> StreamRecordOutcome? {
        guard let p = r.int(0), let s = r.string(1).flatMap(StreamRecordState.init(rawValue:)) else { return nil }
        let keys = r.string(3).flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: AnyCodable].self, from: $0) } ?? [:]
        return StreamRecordOutcome(position: Int(p), state: s, objectID: r.uuid(2), ownershipKeys: keys,
                                   reason: r.string(4), attempts: Int(r.int(5) ?? 0))
    }
}
