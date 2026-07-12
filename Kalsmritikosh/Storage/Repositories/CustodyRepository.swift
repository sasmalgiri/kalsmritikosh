//
//  CustodyRepository.swift
//  Kalsmritikosh
//
//  T18 — append-only chain-of-custody ledger (schema v34). Records are only
//  ever INSERTed; the custody history of a source survives intact (§21).
//

import Foundation

public actor CustodyRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    @discardableResult
    public func record(_ event: CustodyEvent) async throws -> UUID {
        try await database.exec("""
        INSERT INTO custody_events
            (id, file_id, kind, actor, at, detail, hash)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(event.id),
            .uuid(event.fileID),
            .text(event.kind.rawValue),
            .text(event.actor),
            .real(event.at.timeIntervalSince1970),
            event.detail.map { .text($0) } ?? .null,
            event.hash.map { .text($0) } ?? .null
        ])
        return event.id
    }

    /// Full custody history for one file, newest first.
    public func history(forFile id: UUID) async throws -> [CustodyEvent] {
        let rows = try await database.query("""
        SELECT id, file_id, kind, actor, at, detail, hash
        FROM custody_events WHERE file_id = ? ORDER BY at DESC;
        """, [.uuid(id)])
        return rows.compactMap(decode)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM custody_events;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Count of recorded hash mismatches — a tamper signal the UI can surface.
    public func mismatchCount() async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM custody_events WHERE kind = 'hash_mismatch';", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// A5.7 — the recorded hash-mismatch custody events (a file's bytes changed
    /// since first ingest), newest first, for the custody-break gap detector.
    public func recentMismatches(limit: Int = 200) async throws -> [CustodyEvent] {
        let rows = try await database.query("""
        SELECT id, file_id, kind, actor, at, detail, hash
        FROM custody_events WHERE kind = 'hash_mismatch'
        ORDER BY at DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    // MARK: - Internals

    private func decode(_ row: SQLRow) -> CustodyEvent? {
        guard
            let id = row.uuid(0),
            let fileID = row.uuid(1),
            let kindRaw = row.string(2),
            let kind = CustodyEvent.Kind(rawValue: kindRaw),
            let actor = row.string(3),
            let at = row.double(4)
        else { return nil }
        return CustodyEvent(
            id: id,
            fileID: fileID,
            kind: kind,
            actor: actor,
            at: Date(timeIntervalSince1970: at),
            detail: row.string(5),
            hash: row.string(6)
        )
    }
}
