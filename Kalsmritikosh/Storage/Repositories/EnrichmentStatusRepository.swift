//
//  EnrichmentStatusRepository.swift
//  Kalsmritikosh
//
//  System 2 — Hot/Warm/Cold importance tiering.
//
//  Every KnowledgeObject carries an enrichment_status row that records
//  how "hot" it is: how often it's cited in answers, how often it's hit
//  by retrieval, whether the user pinned it, and a rolled-up importance
//  score. The enrichment ladder (Tier 2/3 deepen) walks HOT objects
//  first — spend the expensive vector + LLM extraction budget where the
//  archive is actually being used, and let cold clutter stay parsed-only.
//
//  This repo is the persistence face of that tiering. The scoring math
//  lives (pure, DB-free) in Knowledge/Ledger/ImportanceScorer.swift.
//

import Foundation

public enum EnrichmentTier: String, Codable, Sendable, CaseIterable {
    case cold
    case warm
    case hot

    public var displayName: String {
        switch self {
        case .cold: return "Cold"
        case .warm: return "Warm"
        case .hot:  return "Hot"
        }
    }

    /// Ascending heat. Handy for sorting or stepping a tier up/down.
    public var sortOrder: Int {
        switch self {
        case .cold: return 0
        case .warm: return 1
        case .hot:  return 2
        }
    }
}

public struct EnrichmentRecord: Sendable, Identifiable {
    public let objectID: UUID
    public var tier: EnrichmentTier
    public var importance: Double
    public var queryHits: Int
    public var citationCount: Int
    public var pinned: Bool
    public var enriched: Bool
    public var updatedAt: Date

    public var id: UUID { objectID }

    public nonisolated init(
        objectID: UUID,
        tier: EnrichmentTier,
        importance: Double,
        queryHits: Int,
        citationCount: Int,
        pinned: Bool,
        enriched: Bool,
        updatedAt: Date
    ) {
        self.objectID = objectID
        self.tier = tier
        self.importance = importance
        self.queryHits = queryHits
        self.citationCount = citationCount
        self.pinned = pinned
        self.enriched = enriched
        self.updatedAt = updatedAt
    }
}

public actor EnrichmentStatusRepository {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Row lifecycle

    /// INSERT OR IGNORE a default (cold, un-enriched) row.
    public func ensure(_ objectID: UUID) async {
        try? await database.exec("""
        INSERT OR IGNORE INTO enrichment_status
            (object_id, tier, importance, query_hits, citation_count, pinned, enriched, updated_at)
        VALUES (?, 'cold', 0, 0, 0, 0, 0, ?);
        """, [.uuid(objectID), .real(now())])
    }

    // MARK: - Counters

    public func bumpCitation(_ objectID: UUID) async {
        await ensure(objectID)
        try? await database.exec("""
        UPDATE enrichment_status
        SET citation_count = citation_count + 1, updated_at = ?
        WHERE object_id = ?;
        """, [.real(now()), .uuid(objectID)])
    }

    public func bumpQueryHit(_ objectID: UUID) async {
        await ensure(objectID)
        try? await database.exec("""
        UPDATE enrichment_status
        SET query_hits = query_hits + 1, updated_at = ?
        WHERE object_id = ?;
        """, [.real(now()), .uuid(objectID)])
    }

    // MARK: - Setters

    public func setPinned(_ objectID: UUID, _ pinned: Bool) async {
        await ensure(objectID)
        try? await database.exec("""
        UPDATE enrichment_status
        SET pinned = ?, updated_at = ?
        WHERE object_id = ?;
        """, [.integer(pinned ? 1 : 0), .real(now()), .uuid(objectID)])
    }

    public func setTier(_ objectID: UUID, _ tier: EnrichmentTier) async {
        await ensure(objectID)
        try? await database.exec("""
        UPDATE enrichment_status
        SET tier = ?, updated_at = ?
        WHERE object_id = ?;
        """, [.text(tier.rawValue), .real(now()), .uuid(objectID)])
    }

    public func setImportance(_ objectID: UUID, _ value: Double) async {
        await ensure(objectID)
        try? await database.exec("""
        UPDATE enrichment_status
        SET importance = ?, updated_at = ?
        WHERE object_id = ?;
        """, [.real(value), .real(now()), .uuid(objectID)])
    }

    public func markEnriched(_ objectID: UUID) async {
        await ensure(objectID)
        try? await database.exec("""
        UPDATE enrichment_status
        SET enriched = 1, updated_at = ?
        WHERE object_id = ?;
        """, [.real(now()), .uuid(objectID)])
    }

    // MARK: - Reads

    public func status(_ objectID: UUID) async -> EnrichmentRecord? {
        let rows = (try? await database.query("""
        SELECT object_id, tier, importance, query_hits, citation_count, pinned, enriched, updated_at
        FROM enrichment_status
        WHERE object_id = ?;
        """, [.uuid(objectID)])) ?? []
        return rows.first.flatMap(decode)
    }

    public func topByImportance(tier: EnrichmentTier? = nil, limit: Int = 50) async -> [EnrichmentRecord] {
        let rows: [SQLRow]
        if let tier {
            rows = (try? await database.query("""
            SELECT object_id, tier, importance, query_hits, citation_count, pinned, enriched, updated_at
            FROM enrichment_status
            WHERE tier = ?
            ORDER BY importance DESC
            LIMIT ?;
            """, [.text(tier.rawValue), .integer(Int64(limit))])) ?? []
        } else {
            rows = (try? await database.query("""
            SELECT object_id, tier, importance, query_hits, citation_count, pinned, enriched, updated_at
            FROM enrichment_status
            ORDER BY importance DESC
            LIMIT ?;
            """, [.integer(Int64(limit))])) ?? []
        }
        return rows.compactMap(decode)
    }

    public func needingEnrichment(tier: EnrichmentTier = .hot, limit: Int = 20) async -> [EnrichmentRecord] {
        let rows = (try? await database.query("""
        SELECT object_id, tier, importance, query_hits, citation_count, pinned, enriched, updated_at
        FROM enrichment_status
        WHERE tier = ? AND enriched = 0
        ORDER BY importance DESC
        LIMIT ?;
        """, [.text(tier.rawValue), .integer(Int64(limit))])) ?? []
        return rows.compactMap(decode)
    }

    public func countsByTier() async -> [EnrichmentTier: Int] {
        let rows = (try? await database.query("""
        SELECT tier, COUNT(*)
        FROM enrichment_status
        GROUP BY tier;
        """, [])) ?? []
        var out: [EnrichmentTier: Int] = [:]
        for row in rows {
            guard
                let raw = row.string(0),
                let tier = EnrichmentTier(rawValue: raw)
            else { continue }
            out[tier] = Int(row.int(1) ?? 0)
        }
        return out
    }

    public func count() async -> Int {
        let rows = (try? await database.query("SELECT COUNT(*) FROM enrichment_status;", [])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func decode(_ row: SQLRow) -> EnrichmentRecord? {
        guard
            let objectID = row.uuid(0),
            let tierRaw = row.string(1),
            let tier = EnrichmentTier(rawValue: tierRaw),
            let updatedAtRaw = row.double(7)
        else { return nil }
        return EnrichmentRecord(
            objectID: objectID,
            tier: tier,
            importance: row.double(2) ?? 0,
            queryHits: Int(row.int(3) ?? 0),
            citationCount: Int(row.int(4) ?? 0),
            pinned: (row.int(5) ?? 0) != 0,
            enriched: (row.int(6) ?? 0) != 0,
            updatedAt: Date(timeIntervalSince1970: updatedAtRaw)
        )
    }
}
