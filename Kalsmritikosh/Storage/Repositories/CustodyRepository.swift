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

    /// Global custody feed across ALL files, newest first — the chain-of-
    /// custody half of the unified Audit view.
    public func recent(limit: Int = 300) async throws -> [CustodyEvent] {
        let rows = try await database.query("""
        SELECT id, file_id, kind, actor, at, detail, hash
        FROM custody_events ORDER BY at DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
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

    /// AUD-CHAIN — every custody event as a canonical seal input, oldest first.
    /// The payload is a stable sorted `key=value;` string over the immutable
    /// fields so re-hashing during verification is deterministic across runs.
    public func auditChainEvents() async throws -> [AuditChainEvent] {
        let rows = try await database.query("""
        SELECT id, file_id, kind, actor, at, detail, hash
        FROM custody_events ORDER BY at ASC, id ASC;
        """, [])
        return rows.compactMap { r in
            guard let id = r.uuid(0), let fileID = r.uuid(1), let kind = r.string(2),
                  let actor = r.string(3), let at = r.date(4) else { return nil }
            let detail = r.string(5) ?? ""
            let hash = r.string(6) ?? ""
            let payload = "actor=\(actor);at=\(at.timeIntervalSince1970);detail=\(detail);"
                + "fileID=\(fileID.uuidString);hash=\(hash);kind=\(kind)"
            return AuditChainEvent(source: .custody, eventID: id, occurredAt: at, canonicalPayload: payload)
        }
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
