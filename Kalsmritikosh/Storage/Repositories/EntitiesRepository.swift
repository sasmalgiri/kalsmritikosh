//
//  EntitiesRepository.swift
//  Kalsmritikosh
//
//  v3 layout: `entities` is the canonical noun-table (one row per
//  (kind, normalized)). Each per-document occurrence lives in
//  `entity_mentions` with span info; `entity_aliases` carries normalized
//  synonyms (e.g. email-domain → org). Lookups resolve through aliases.
//

import Foundation

public actor EntitiesRepository {
    private let database: Database
    private let encoder = JSONEncoder()

    public init(database: Database) {
        self.database = database
    }

    /// Upsert each entity as a canonical row (keyed by kind+normalized)
    /// and record one mention per input row pointing at the resolved
    /// canonical id. The incoming `Entity.id` is used only when a new
    /// canonical row is created; on conflict the existing canonical's id
    /// wins and the mention is attached to it.
    ///
    /// Returns `[input.id : canonical.id]` so callers (the ingest
    /// coordinator) can remap event entity references and graph edges to
    /// the canonical ids before any downstream insert.
    @discardableResult
    public func insertBatch(_ entities: [Entity]) async throws -> [Entity.ID: Entity.ID] {
        var mapping: [Entity.ID: Entity.ID] = [:]
        for e in entities {
            let rawNormalized = rawNormalize(e)
            guard !rawNormalized.isEmpty else { continue }
            let normalized = applyCanonicalAlias(rawNormalized, kind: e.kind)
            let canonID = try await upsertCanonical(e, normalized: normalized)
            try await insertMention(e, canonicalID: canonID, normalized: normalized)
            // T13.5 — when the alias map collapsed two surface forms onto
            // one canonical (e.g. "Gmail" / "Googlemail" → google), seed
            // an entity_aliases row for the pre-alias form so a future
            // find(byValue: "Gmail") still resolves to the canonical via
            // the LEFT JOIN even when the canonical's value column says
            // "Google".
            if normalized != rawNormalized {
                try await addAlias(
                    entityID: canonID,
                    aliasNormalized: rawNormalized,
                    source: "canonical-alias"
                )
            }
            mapping[e.id] = canonID
        }
        return mapping
    }

    /// Add (or no-op) an alias for an existing canonical entity.
    public func addAlias(
        entityID: Entity.ID,
        aliasNormalized: String,
        source: String
    ) async throws {
        let normalized = aliasNormalized.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try await database.exec("""
        INSERT INTO entity_aliases (entity_id, alias_normalized, source)
        VALUES (?, ?, ?)
        ON CONFLICT(entity_id, alias_normalized) DO NOTHING;
        """, [
            .uuid(entityID),
            .text(normalized),
            .text(source)
        ])
    }

    /// Upsert a canonical organization keyed by its normalized label and
    /// return its id. Used by ingest-time domain mining.
    public func upsertCanonicalOrganization(
        label: String,
        sourceObjectID: KnowledgeObject.ID
    ) async throws -> Entity.ID {
        let normalized = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw NSError(domain: "EntitiesRepository", code: 1) }
        let rows = try await database.query("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?, ?, ?, ?, ?, ?, '{}')
        ON CONFLICT(kind, normalized) DO UPDATE SET
            confidence = max(entities.confidence, excluded.confidence)
        RETURNING id;
        """, [
            .uuid(UUID()),
            .text(Entity.Kind.organization.rawValue),
            .text(label),
            .text(normalized),
            .uuid(sourceObjectID),
            .real(Confidence.medium.value)
        ])
        guard let id = rows.first?.uuid(0) else {
            throw NSError(domain: "EntitiesRepository", code: 2)
        }
        return id
    }

    // MARK: - Reads

    public func count(of kind: Entity.Kind) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM entities WHERE kind = ?;",
            [.text(kind.rawValue)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - G3 Phase 2

    /// G3.8 — return entities whose `fact_type` column is NULL so the
    /// OntologyBackfill classifier can label them in one pass. Bounded
    /// by `limit` so a large archive can backfill in batches.
    public func listUnlabeledFactTypes(limit: Int = 500) async throws -> [Entity] {
        let rows = try await database.query("""
        SELECT id, kind, value, normalized, source_object_id, confidence, attributes_json
        FROM entities WHERE fact_type IS NULL ORDER BY id LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decodeFullEntity)
    }

    /// G3.8 — write the classifier's label back to a single row.
    public func setFactType(_ factType: String, forEntityID id: Entity.ID) async throws {
        try await database.exec(
            "UPDATE entities SET fact_type = ? WHERE id = ?;",
            [.text(factType), .uuid(id)]
        )
    }

    /// G3.13 — write a JSON-encoded slot-values map back to a single row.
    /// Caller is responsible for shape (OntologyValidator-gated).
    public func setSlotValues(_ json: String, forEntityID id: Entity.ID) async throws {
        try await database.exec(
            "UPDATE entities SET slot_values_json = ? WHERE id = ?;",
            [.text(json), .uuid(id)]
        )
    }

    /// Count rows in the per-document mentions table — used by acceptance
    /// checks ("ingest twice: canonical count unchanged, mention count
    /// doubles only if rows were actually re-ingested").
    public func mentionCount() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM entity_mentions;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Returns the number of (kind, normalized) groups that have more
    /// than one canonical row. Must be 0 — the UNIQUE constraint enforces
    /// it. Surfaced for the T3 acceptance assertion.
    public func duplicateCanonicalGroups() async throws -> Int {
        let rows = try await database.query("""
        SELECT COUNT(*) FROM (
            SELECT kind, normalized FROM entities
            GROUP BY kind, normalized
            HAVING COUNT(*) > 1
        );
        """, [])
        return Int(rows.first?.int(0) ?? 0)
    }

    public func list(kind: Entity.Kind, limit: Int = 200) async throws -> [EntitySummaryRow] {
        let rows = try await database.query("""
        SELECT id, value, normalized, confidence
        FROM entities WHERE kind = ?
        ORDER BY value COLLATE NOCASE
        LIMIT ?;
        """, [.text(kind.rawValue), .integer(Int64(limit))])

        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let value = row.string(1),
                let conf = row.double(3)
            else { return nil }
            return EntitySummaryRow(
                id: id,
                value: value,
                normalizedValue: row.string(2),
                confidence: Confidence(conf)
            )
        }
    }

    public func find(byID id: Entity.ID) async throws -> Entity? {
        let rows = try await database.query("""
        SELECT id, kind, value, normalized, source_object_id, confidence
        FROM entities WHERE id = ? LIMIT 1;
        """, [.uuid(id)])
        return rows.first.flatMap(decodeFullEntity)
    }

    /// Resolves a query through the canonical `value` / `normalized`
    /// columns AND any alias rows.
    public func find(byValue value: String, limit: Int = 25) async throws -> [Entity] {
        let pattern = "%\(value)%"
        let aliasPattern = "%\(value.lowercased())%"
        let rows = try await database.query("""
        SELECT DISTINCT e.id, e.kind, e.value, e.normalized, e.source_object_id, e.confidence
        FROM entities e
        LEFT JOIN entity_aliases a ON a.entity_id = e.id
        WHERE e.value LIKE ?
           OR e.normalized LIKE ?
           OR a.alias_normalized LIKE ?
        ORDER BY e.confidence DESC
        LIMIT ?;
        """, [.text(pattern), .text(pattern), .text(aliasPattern), .integer(Int64(limit))])
        return rows.compactMap(decodeFullEntity)
    }

    public func search(value query: String, limit: Int = 50) async throws -> [EntitySummaryRow] {
        let pattern = "%\(query)%"
        let aliasPattern = "%\(query.lowercased())%"
        let rows = try await database.query("""
        SELECT DISTINCT e.id, e.value, e.normalized, e.confidence
        FROM entities e
        LEFT JOIN entity_aliases a ON a.entity_id = e.id
        WHERE e.value LIKE ?
           OR e.normalized LIKE ?
           OR a.alias_normalized LIKE ?
        ORDER BY e.confidence DESC
        LIMIT ?;
        """, [.text(pattern), .text(pattern), .text(aliasPattern), .integer(Int64(limit))])

        return rows.compactMap { row in
            guard
                let id = row.uuid(0),
                let value = row.string(1),
                let conf = row.double(3)
            else { return nil }
            return EntitySummaryRow(
                id: id,
                value: value,
                normalizedValue: row.string(2),
                confidence: Confidence(conf)
            )
        }
    }

    // MARK: - Internals

    /// Known organization aliases collapsed onto one canonical at
    /// normalize time. T13.5 — verified Gmail / Googlemail were
    /// previously stored as separate canonicals from Google; this map
    /// folds them. Extend with conservative, well-known aliases only:
    /// stock tickers, parent-company collisions, and trademark/Wikipedia
    /// redirects. Single-word abbreviations that are also English
    /// courtesy titles (Ms., Mr., Mrs.) are deliberately excluded.
    public static let canonicalOrganizationAliases: [String: String] = [
        // Alphabet / Google family
        "gmail": "google",
        "googlemail": "google",
        "alphabet": "google",
        "alphabet inc": "google",
        // Microsoft
        "msft": "microsoft",
        "microsoft corporation": "microsoft",
        "microsoft corp": "microsoft",
        // Amazon
        "amzn": "amazon",
        "aws": "amazon",
        "amazon web services": "amazon",
        "amazon.com": "amazon",
        // Apple
        "aapl": "apple",
        "apple inc": "apple",
        "apple computer": "apple",
        // Meta / Facebook
        "facebook": "meta",
        "fb": "meta",
        "meta platforms": "meta",
        // IBM
        "international business machines": "ibm",
        // Oracle
        "orcl": "oracle",
        // Salesforce
        "crm": "salesforce",
        "salesforce.com": "salesforce",
        // X / Twitter (controversial but well-known)
        "twitter": "x"
    ]

    private func rawNormalize(_ entity: Entity) -> String {
        let candidate = entity.normalizedValue ?? entity.value
        return candidate.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apply the canonical-alias map only to organization-shaped kinds
    /// (person / org / vendor / client). Dates, money, email addresses
    /// and phones are never aliased — they're already structured.
    private func applyCanonicalAlias(_ normalized: String, kind: Entity.Kind) -> String {
        switch kind {
        case .person, .organization, .vendor, .client:
            return Self.canonicalOrganizationAliases[normalized] ?? normalized
        default:
            return normalized
        }
    }

    /// Legacy single-step normalize kept around for any non-batch caller
    /// that might appear later. Identical semantics to the two-step
    /// rawNormalize + applyCanonicalAlias used by `insertBatch`.
    private func normalize(_ entity: Entity) -> String {
        applyCanonicalAlias(rawNormalize(entity), kind: entity.kind)
    }

    private func upsertCanonical(_ e: Entity, normalized: String) async throws -> Entity.ID {
        let attrs = try encoder.encode(e.attributes)
        let attrsStr = String(data: attrs, encoding: .utf8) ?? "{}"
        let rows = try await database.query("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind, normalized) DO UPDATE SET
            confidence = max(entities.confidence, excluded.confidence),
            value = CASE WHEN excluded.confidence > entities.confidence
                         THEN excluded.value
                         ELSE entities.value
                    END
        RETURNING id;
        """, [
            .uuid(e.id),
            .text(e.kind.rawValue),
            .text(e.value),
            .text(normalized),
            .uuid(e.sourceObjectID),
            .real(e.confidence.value),
            .text(attrsStr)
        ])
        guard let id = rows.first?.uuid(0) else {
            throw NSError(domain: "EntitiesRepository", code: 3)
        }
        return id
    }

    private func insertMention(
        _ e: Entity,
        canonicalID: Entity.ID,
        normalized: String
    ) async throws {
        let spanStart: SQLValue = e.sourceRange?.characterRange.map { .integer(Int64($0.lowerBound)) } ?? .null
        let spanEnd: SQLValue = e.sourceRange?.characterRange.map { .integer(Int64($0.upperBound)) } ?? .null
        try await database.exec("""
        INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, span_start, span_end, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, [
            .uuid(UUID()),
            .uuid(canonicalID),
            .text(e.kind.rawValue),
            .text(e.value),
            .text(normalized),
            .uuid(e.sourceObjectID),
            spanStart,
            spanEnd,
            .real(e.confidence.value)
        ])
    }

    private func decodeFullEntity(_ row: SQLRow) -> Entity? {
        guard
            let id = row.uuid(0),
            let kindRaw = row.string(1),
            let kind = Entity.Kind(rawValue: kindRaw),
            let value = row.string(2),
            let sourceID = row.uuid(4),
            let conf = row.double(5)
        else { return nil }
        return Entity(
            id: id,
            kind: kind,
            value: value,
            normalizedValue: row.string(3),
            sourceObjectID: sourceID,
            confidence: Confidence(conf)
        )
    }
}

public struct EntitySummaryRow: Identifiable, Sendable, Hashable {
    public let id: Entity.ID
    public let value: String
    public let normalizedValue: String?
    public let confidence: Confidence
}
