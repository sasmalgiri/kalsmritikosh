//
//  CustodyRepository.swift
//  Kalsmritikosh
//
//  T18 — append-only chain-of-custody ledger (schema v34). Records are only
//  ever INSERTed; the custody history of a source survives intact (§21).
//

import Foundation
import os

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

    /// ALCOA ALC-04 — the actor written on an automatic custody event: the person when known, else "system".
    public nonisolated static func actor(_ person: String?) -> String {
        let p = person?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? "system" : p
    }

    /// ALCOA ALC-04 — a custody event for source versions (by version id, or by the content hash / vault address the
    /// bytes were opened under), keyed by the logical source as the case custody manifest reads it. Written for every
    /// vault open and reprocessing re-read (hash_verified / hash_mismatch), every export of an original or a copy derived
    /// from it (exported) and every legal production or send that carries documents (disclosed). `detail` names the
    /// action, never document text. Returns how many events were written (one per logical source).
    @discardableResult
    public nonisolated static func recordForVersions(_ database: Database, versions: [UUID] = [], objects: [UUID] = [], hash: String? = nil,
                                                     kind: CustodyEvent.Kind, actor person: String?, detail: String,
                                                     at now: Date = Date()) async -> Int {
        var sources: [(UUID, String?)] = []
        do {
            for v in Set(versions) {
                if let r = try await database.query("SELECT logical_source_id, lower(content_hash) FROM source_versions WHERE upper(id) = upper(?) LIMIT 1;",
                                                    [.uuid(v)]).first, let id = r.uuid(0) { sources.append((id, r.string(1))) }
            }
            // A knowledge object's custody file is its file (= the logical source of its versions), at the current version's hash.
            for o in Set(objects) {
                if let r = try await database.query("""
                    SELECT ko.file_id, (SELECT lower(sv.content_hash) FROM source_versions sv WHERE sv.logical_source_id = ko.file_id AND sv.is_current = 1 LIMIT 1)
                    FROM knowledge_objects ko WHERE upper(ko.id) = upper(?) LIMIT 1;
                    """, [.uuid(o)]).first, let id = r.uuid(0) { sources.append((id, r.string(1))) }
            }
            if let h = hash?.lowercased(), !h.isEmpty {
                for r in try await database.query("""
                    SELECT DISTINCT logical_source_id FROM source_versions WHERE lower(content_hash) = ? OR lower(vault_address) = ?;
                    """, [.text(h), .text(h)]) {
                    if let id = r.uuid(0) { sources.append((id, h)) }
                }
            }
        } catch {
            KalsmritikoshLog.storage.error("Custody: source of a \(kind.rawValue, privacy: .public) event not found: \(error.localizedDescription, privacy: .private)")
            return 0
        }
        var seen: Set<UUID> = [], written = 0
        let repo = CustodyRepository(database: database)
        for (id, h) in sources where seen.insert(id).inserted {
            do {
                try await repo.record(CustodyEvent(fileID: id, kind: kind, actor: actor(person), at: now, detail: detail, hash: hash?.lowercased() ?? h))
                written += 1
            } catch {
                KalsmritikoshLog.storage.error("Custody: \(kind.rawValue, privacy: .public) event not written: \(error.localizedDescription, privacy: .private)")
            }
        }
        return written
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
