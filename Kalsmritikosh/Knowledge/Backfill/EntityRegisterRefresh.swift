//
//  EntityRegisterRefresh.swift
//  Kalsmritikosh
//
//  GO2R U0-b (part 2) — the targeted register refresh. The v1 entity producer
//  could emit person values carrying email address-list punctuation
//  (", Akhilesh Sharma", "'Arindam Das'" — witnessed live); the v2 producer
//  (EmailAddressListParser + edge strip at construction) cannot. This pass
//  brings the STORED register up to the v2 era without re-ingesting anything:
//
//    scan   — entities below producer_version 2, not already merged away
//    clean  — person/organization values get stripEdgePunctuation +
//             collapseWhitespace (identical to the write-time law)
//    merge  — when the cleaned value collides with an existing canonical
//             (UNIQUE kind+normalized), the dirty row soft-merges into it —
//             reversible, alias-preserving, NOTHING deleted (the drain law)
//    stamp  — every scanned row advances to producer_version 2
//
//  SAVEPOINT-wrapped; idempotent by construction (a second run scans zero).
//  The live run snapshots first (harness), exactly like the drain.
//

import Foundation
import os

public struct EntityRegisterRefreshReceipt: Sendable {
    public var scanned = 0
    public var cleanedInPlace = 0
    public var mergedIntoExisting = 0
    public var stampedOnly = 0

    public func renderLines() -> String {
        """
        REGISTER REFRESH RECEIPT
          scanned (below v2):     \(scanned)
          cleaned in place:       \(cleanedInPlace)
          merged into existing:   \(mergedIntoExisting) (soft-merge, reversible, nothing deleted)
          stamped only (clean):   \(stampedOnly)
        """
    }
}

public struct EntityRegisterRefresh {
    private let database: Database
    private let entities: EntitiesRepository
    private static let log = Logger(subsystem: "ecosanskritiinnovation.Kalsmritikosh", category: "knowledge")

    public init(database: Database, entities: EntitiesRepository) {
        self.database = database
        self.entities = entities
    }

    /// Kinds whose stored VALUES the v1→v2 change can have corrupted.
    private static let rewritableKinds: Set<String> = ["person", "organization"]

    public func run() async throws -> EntityRegisterRefreshReceipt {
        var receipt = EntityRegisterRefreshReceipt()
        try await database.exec("SAVEPOINT register_refresh;", [])
        do {
            let rows = try await database.query("""
            SELECT id, kind, value, normalized FROM entities
            WHERE COALESCE(producer_version, 0) != ? AND merged_into IS NULL;
            """, [.integer(Int64(DerivedProducerVersions.entities))])
            receipt.scanned = rows.count

            for row in rows {
                guard let id = row.uuid(0), let kind = row.string(1), let value = row.string(2) else { continue }

                guard Self.rewritableKinds.contains(kind) else {
                    try await stamp(id); receipt.stampedOnly += 1; continue
                }
                let cleaned = EntitiesRepository.stripEdgePunctuation(
                    EntitiesRepository.collapseWhitespace(value))
                guard !cleaned.isEmpty, cleaned != value else {
                    try await stamp(id); receipt.stampedOnly += 1; continue
                }
                let cleanedNorm = cleaned.lowercased()

                // Collision with an existing canonical? Soft-merge, never delete.
                let existing = try await database.query("""
                SELECT id FROM entities
                WHERE kind = ? AND normalized = ? AND id != ? AND merged_into IS NULL
                LIMIT 1;
                """, [.text(kind), .text(cleanedNorm), .uuid(id)])
                if let winnerID = existing.first?.uuid(0) {
                    try await entities.merge(loserID: id, winnerID: winnerID)
                    try await stamp(id)
                    try await stamp(winnerID)
                    receipt.mergedIntoExisting += 1
                } else {
                    try await database.exec("""
                    UPDATE entities SET value = ?, normalized = ?, producer_version = ?
                    WHERE id = ?;
                    """, [.text(cleaned), .text(cleanedNorm),
                          .integer(Int64(DerivedProducerVersions.entities)), .uuid(id)])
                    receipt.cleanedInPlace += 1
                }
            }
            try await database.exec("RELEASE register_refresh;", [])
        } catch {
            Self.log.error("EntityRegisterRefresh failed, rolling back: \(String(describing: error))")
            try? await database.exec("ROLLBACK TO register_refresh;", [])
            try? await database.exec("RELEASE register_refresh;", [])
            throw error
        }
        Self.log.info("REGISTER REFRESH: \(receipt.scanned) scanned, \(receipt.cleanedInPlace) cleaned, \(receipt.mergedIntoExisting) merged, \(receipt.stampedOnly) stamped")
        return receipt
    }

    /// The re-witness the unit's acceptance demands: zero rewritable-kind
    /// values still carrying edge punctuation.
    public func dirtyRemainder() async throws -> Int {
        let rows = try await database.query("""
        SELECT COUNT(*) FROM entities
        WHERE kind IN ('person','organization') AND merged_into IS NULL
          AND (value LIKE ',%' OR value LIKE ' %' OR value LIKE '''%' OR value LIKE '"%'
               OR value LIKE '%,' OR value LIKE '%''' OR value LIKE '%"');
        """, [])
        return Int(rows.first?.int(0) ?? 0)
    }

    private func stamp(_ id: Entity.ID) async throws {
        try await database.exec(
            "UPDATE entities SET producer_version = ? WHERE id = ?;",
            [.integer(Int64(DerivedProducerVersions.entities)), .uuid(id)])
    }
}
