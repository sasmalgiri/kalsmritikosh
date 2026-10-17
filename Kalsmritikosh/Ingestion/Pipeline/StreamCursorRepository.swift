//
//  StreamCursorRepository.swift
//  Kalsmritikosh
//
//  F04 — the durable continuation state of a resumable stream (v140): per scope (e.g. SQLite table)
//  of an exact source version, the serialized cursor reached, the units processed and the units
//  discovered. `advance` runs inside the savepoint that commits the record, so the cursor never
//  runs ahead of committed evidence.
//

import Foundation

public nonisolated struct StreamScopeState: Sendable, Equatable {
    public let scope: String
    public let scopeIndex: Int
    public let cursor: String?
    public let processed: Int
    public let discovered: Int?

    /// Units not yet processed (0 when the scope has not been counted yet).
    public var deferred: Int { max(0, (discovered ?? processed) - processed) }
}

public nonisolated struct StreamCoverage: Sendable, Equatable {
    public let discovered: Int
    public let processed: Int
    public var deferred: Int { max(0, discovered - processed) }
}

public struct StreamCursorRepository: Sendable {
    private let database: Database
    public init(database: Database) { self.database = database }

    public func states(sourceVersionID svid: UUID) async throws -> [StreamScopeState] {
        try await database.query("""
            SELECT scope, scope_index, cursor, processed, discovered FROM stream_cursors
             WHERE source_version_id = ? ORDER BY scope_index;
            """, [.uuid(svid)]).compactMap { r in
            guard let scope = r.string(0) else { return nil }
            return StreamScopeState(scope: scope, scopeIndex: Int(r.int(1) ?? 0), cursor: r.string(2),
                                    processed: Int(r.int(3) ?? 0), discovered: r.int(4).map(Int.init))
        }
    }

    /// Discovered / processed units across every scope; nil when the version was never walked resumably.
    public func coverage(sourceVersionID svid: UUID) async throws -> StreamCoverage? {
        guard let r = try await database.query("""
            SELECT COUNT(*), COALESCE(SUM(COALESCE(discovered, processed)), 0), COALESCE(SUM(processed), 0)
              FROM stream_cursors WHERE source_version_id = ?;
            """, [.uuid(svid)]).first, (r.int(0) ?? 0) > 0 else { return nil }
        return StreamCoverage(discovered: Int(r.int(1) ?? 0), processed: Int(r.int(2) ?? 0))
    }

    /// Record every scope's discovered size (a scope the run never reached gets a row with no cursor).
    public func recordDiscovered(sourceVersionID svid: UUID, _ totals: [ResumableScopeTotal], at now: Date) async throws {
        try await database.withSavepoint("scur_disc") { db in
            for t in totals {
                try db.exec("""
                    INSERT INTO stream_cursors (source_version_id, scope, scope_index, processed, discovered, updated_at)
                    VALUES (?, ?, ?, 0, ?, ?)
                    ON CONFLICT (source_version_id, scope) DO UPDATE SET
                        scope_index = excluded.scope_index, discovered = excluded.discovered, updated_at = excluded.updated_at;
                    """, [.uuid(svid), .text(t.scope), .integer(Int64(t.scopeIndex)), .integer(Int64(t.discovered)), .date(now)])
            }
        }
    }

    /// Advance a scope's cursor — call INSIDE the savepoint that commits the record it follows.
    static func advance(_ db: isolated Database, sourceVersionID svid: UUID, scope: String, scopeIndex: Int,
                        cursor: String, processed: Int, at now: Date) throws {
        try db.exec("""
            INSERT INTO stream_cursors (source_version_id, scope, scope_index, cursor, processed, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (source_version_id, scope) DO UPDATE SET
                cursor = excluded.cursor, processed = excluded.processed, updated_at = excluded.updated_at;
            """, [.uuid(svid), .text(scope), .integer(Int64(scopeIndex)), .text(cursor), .integer(Int64(processed)), .date(now)])
    }
}
