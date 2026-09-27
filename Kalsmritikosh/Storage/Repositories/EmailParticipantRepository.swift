//
//  EmailParticipantRepository.swift
//  Kalsmritikosh
//
//  OPS-005 — persistence layer for email_participant_occurrences (v73).
//
//  Guarantees:
//  • insertBatch is SAVEPOINT-atomic: all rows write or none do.
//  • INSERT OR IGNORE on the primary key: re-ingest of the same KO
//    (which carries the same UUID seeds) is a no-op.
//  • deleteForSourceObject removes all occurrence rows for a KO;
//    the SQL CASCADE on source_ko_id also fires on KO hard-delete.
//  • Canonical entity rows are never touched.
//

import Foundation
import OSLog

public actor EmailParticipantRepository {
    private let database: Database

    public init(database: Database) { self.database = database }

    // MARK: - Write

    /// Persist a batch of occurrence rows atomically.
    /// Rows whose id already exists are silently skipped (idempotent).
    @discardableResult
    public func insertBatch(_ occurrences: [EmailParticipantOccurrence]) async throws -> Int {
        guard !occurrences.isEmpty else { return 0 }
        let sp = "epo_insert_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var written = 0
        do {
            try await database.exec("SAVEPOINT \(sp);")
            for occ in occurrences {
                try await database.exec("""
                INSERT OR IGNORE INTO email_participant_occurrences
                    (id, source_ko_id, entity_id, role, raw_address, display_name, created_at)
                VALUES (?,?,?,?,?,?,?);
                """, [
                    .text(occ.id.uuidString),
                    .text(occ.sourceObjectID.uuidString),
                    .text(occ.entityID.uuidString),
                    .text(occ.role.rawValue),
                    .text(occ.rawAddress),
                    occ.displayName.map { .text($0) } ?? .null,
                    .real(occ.createdAt.timeIntervalSince1970)
                ])
                let changed = try await database.query("SELECT changes();", [])
                written += Int(changed.first?.int(0) ?? 0)
            }
            try await database.exec("RELEASE \(sp);")
            KalsmritikoshLog.storage.debug("EmailParticipantRepository: inserted \(written, privacy: .public) occurrences")
        } catch {
            try? await database.exec("ROLLBACK TO \(sp);")
            try? await database.exec("RELEASE \(sp);")
            KalsmritikoshLog.storage.error("EmailParticipantRepository insertBatch failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        return written
    }

    /// Delete all occurrence rows for the given source KO.
    /// Called before re-inserting on a forced re-ingest.
    public func deleteForSourceObject(_ objectID: KnowledgeObject.ID) async throws {
        try await database.exec(
            "DELETE FROM email_participant_occurrences WHERE source_ko_id = ?;",
            [.text(objectID.uuidString)]
        )
    }

    // MARK: - Read

    /// All occurrences for one source KO.
    public func occurrences(
        forSourceObject objectID: KnowledgeObject.ID
    ) async throws -> [EmailParticipantOccurrence] {
        let rows = try await database.query("""
        SELECT id, source_ko_id, entity_id, role, raw_address, display_name, created_at
          FROM email_participant_occurrences
         WHERE source_ko_id = ?
         ORDER BY rowid;
        """, [.text(objectID.uuidString)])
        return rows.compactMap { decodeRow($0) }
    }

    /// All occurrences for one canonical entity (any role).
    public func occurrences(
        forEntity entityID: Entity.ID
    ) async throws -> [EmailParticipantOccurrence] {
        let rows = try await database.query("""
        SELECT id, source_ko_id, entity_id, role, raw_address, display_name, created_at
          FROM email_participant_occurrences
         WHERE entity_id = ?
         ORDER BY created_at DESC;
        """, [.text(entityID.uuidString)])
        return rows.compactMap { decodeRow($0) }
    }

    /// All occurrences for one canonical entity in a specific role.
    public func occurrences(
        forEntity entityID: Entity.ID,
        role: EmailParticipantRole
    ) async throws -> [EmailParticipantOccurrence] {
        let rows = try await database.query("""
        SELECT id, source_ko_id, entity_id, role, raw_address, display_name, created_at
          FROM email_participant_occurrences
         WHERE entity_id = ? AND role = ?
         ORDER BY created_at DESC;
        """, [.text(entityID.uuidString), .text(role.rawValue)])
        return rows.compactMap { decodeRow($0) }
    }

    /// Count of occurrences for a source KO (used by backfill to skip already-processed KOs).
    /// L5 — the archive owner's addresses: the recipients mail is most often
    /// addressed TO (a mailbox is delivered to its owner). Most frequent first.
    public func likelyOwnerAddresses(limit: Int = 2) async throws -> [String] {
        let rows = try await database.query("""
        SELECT lower(raw_address), COUNT(DISTINCT source_ko_id) FROM email_participant_occurrences
        WHERE role = 'to' GROUP BY 1 ORDER BY 2 DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap { $0.string(0) }
    }

    /// L5 — every correspondence row of a person named `nameToken` (display
    /// name or address local part contains it, whole-word-ish, case-insensitive).
    public func correspondence(nameToken: String, limit: Int = 2_000)
        async throws -> [(address: String, displayName: String?, sourceObjectID: UUID, role: String)] {
        let token = nameToken.lowercased()
        let rows = try await database.query("""
        SELECT lower(raw_address), display_name, source_ko_id, role FROM email_participant_occurrences
        WHERE (' ' || lower(COALESCE(display_name, '')) || ' ') LIKE ?
           OR lower(raw_address) LIKE ?
        LIMIT ?;
        """, [.text("% \(token) %"), .text("\(token)%@%"), .integer(Int64(limit))])
        return rows.compactMap { r in
            guard let a = r.string(0), let ko = r.uuid(2), let role = r.string(3) else { return nil }
            return (a, r.string(1), ko, role)
        }
    }

    /// L5 — the display names an address SENDS under ("Shirshendu Sasmal"),
    /// most frequent first.
    public func displayNames(sentBy address: String, limit: Int = 3) async throws -> [String] {
        let rows = try await database.query("""
        SELECT display_name, COUNT(*) FROM email_participant_occurrences
        WHERE lower(raw_address) = lower(?) AND role IN ('from', 'sender')
          AND TRIM(COALESCE(display_name, '')) != ''
        GROUP BY lower(display_name) ORDER BY 2 DESC LIMIT ?;
        """, [.text(address), .integer(Int64(limit))])
        return rows.compactMap { $0.string(0) }
    }

    public func occurrenceCount(forSourceObject objectID: KnowledgeObject.ID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM email_participant_occurrences WHERE source_ko_id = ?;",
            [.text(objectID.uuidString)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Row decoder

    private func decodeRow(_ row: SQLRow) -> EmailParticipantOccurrence? {
        guard let id         = row.uuid(0),
              let koID       = row.uuid(1),
              let entID      = row.uuid(2),
              let roleStr    = row.string(3),
              let role       = EmailParticipantRole(rawValue: roleStr),
              let rawAddress = row.string(4) else { return nil }
        let displayName = row.string(5)
        let createdAt   = row.date(6) ?? Date()
        return EmailParticipantOccurrence(
            id:             id,
            sourceObjectID: koID,
            entityID:       entID,
            role:           role,
            rawAddress:     rawAddress,
            displayName:    displayName,
            createdAt:      createdAt
        )
    }
}
