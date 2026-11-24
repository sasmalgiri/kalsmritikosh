//
//  AuditChainTombstones.swift
//  Kalsmritikosh
//
//  ALCOA fix (owner 2026-11-24) — a RECORDED erasure (case or person) does not make the audit chain read "broken".
//  While the erasure runs, the v215 AFTER DELETE triggers copy each removed sealed row's seal (table, row id, chain
//  source, event id, position, payload digest — never content) into `audit_chain_tombstones`. Inside the same savepoint
//  `seal(_:erasureID:)` adds the events derived from a removed row (an AI record's withdrawal) and returns the digest of
//  the erasure's tombstones, which CaseEraser writes on its register row; that row is sealed, so a tombstone added or
//  removed afterwards breaks the chain. `recorded(_:)` gives verify the tombstones of recorded erasures whose digest still
//  matches: a sealed row that is missing AND has one of these is "erased (recorded)"; any other missing row is broken.
//  A full erase empties the chain and the tombstones together.
//

import Foundation
import os

public nonisolated enum AuditChainTombstones {

    /// One tombstone as verify uses it.
    public struct Mark: Sendable, Equatable {
        public let source: String
        public let eventID: UUID
        public let seq: Int
        public let sealDigest: String
    }

    static func available(_ db: isolated Database) throws -> Bool {
        !(try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit_chain_tombstones';", []).isEmpty)
    }

    /// The digest that binds an erasure's tombstones (sorted by position; content-free lines).
    static func digest(_ marks: [Mark]) -> String {
        CaseFileHash.sha256(marks.sorted { $0.seq < $1.seq }
            .map { "\($0.seq)|\($0.source)|\($0.eventID.uuidString)|\($0.sealDigest)" }.joined(separator: "\n"))
    }

    /// Inside the erasure's savepoint, after its deletes: add the derived events of removed rows and return the digest of
    /// this erasure's tombstones (nil when it removed no sealed row, or on a ledger before v215).
    static func seal(_ db: isolated Database, erasureID: UUID, at date: Date) throws -> String? {
        guard try available(db) else { return nil }
        // An AI record's withdrawal is sealed as its own event with an id derived from the record's id.
        for r in try db.query("SELECT row_key FROM audit_chain_tombstones WHERE erasure_id = ? AND tbl = 'case_ai_records' AND source = 'aiRecord';",
                              [.uuid(erasureID)]) {
            guard let key = r.string(0), let id = UUID(uuidString: key) else { continue }
            let derived = AuditChainLedgerSources.derivedID(id, "withdrawn")
            try db.exec("""
                INSERT OR IGNORE INTO audit_chain_tombstones (erasure_id, tbl, row_key, source, event_id, seq, seal_digest, recorded_at)
                SELECT ?, 'case_ai_records', ?, a.source, a.event_id, a.seq, a.payload_hash, ? FROM audit_chain a
                WHERE a.source = 'aiRecord' AND a.event_id = ?;
                """, [.uuid(erasureID), .text(key), .date(date), .uuid(derived)])
        }
        let marks = try db.query("SELECT source, event_id, seq, seal_digest FROM audit_chain_tombstones WHERE erasure_id = ?;", [.uuid(erasureID)])
            .compactMap(mark)
        return marks.isEmpty ? nil : digest(marks)
    }

    static func mark(_ r: SQLRow) -> Mark? {
        guard let s = r.string(0), let id = r.uuid(1), let seq = r.int(2), let d = r.string(3) else { return nil }
        return Mark(source: s, eventID: id, seq: Int(seq), sealDigest: d)
    }

    /// The tombstones of recorded erasures whose kept digest still matches, keyed `source:EVENT-ID` → seal digest.
    /// Tombstones of an erasure that is not recorded, or whose set no longer matches its recorded digest, are not used.
    public static func recorded(_ database: Database) async throws -> [String: String] {
        guard !(try await database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'audit_chain_tombstones';", []).isEmpty) else {
            return [:]
        }
        var byErasure: [String: (expected: String, marks: [Mark])] = [:]
        for r in try await database.query("""
            SELECT t.source, t.event_id, t.seq, t.seal_digest, t.erasure_id, e.seal_tombstones_sha256
            FROM audit_chain_tombstones t JOIN case_erasures e ON e.id = t.erasure_id WHERE e.seal_tombstones_sha256 IS NOT NULL;
            """, []) {
            guard let m = mark(r), let e = r.string(4), let expected = r.string(5) else { continue }
            byErasure[e, default: (expected, [])].marks.append(m)
        }
        var out: [String: String] = [:]
        for (erasure, group) in byErasure {
            guard digest(group.marks) == group.expected else {
                KalsmritikoshLog.app.error("Audit chain: the tombstones of erasure \(erasure, privacy: .private) do not match its record; not used")
                continue
            }
            for m in group.marks { out[m.source + ":" + m.eventID.uuidString] = m.sealDigest }
        }
        return out
    }
}
