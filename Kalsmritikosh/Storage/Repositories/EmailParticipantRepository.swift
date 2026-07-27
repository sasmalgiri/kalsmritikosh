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
