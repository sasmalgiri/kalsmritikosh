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

    /// Total count of canonical (de-duped) entity rows across all
    /// kinds. Used by the Onboarding scope panel and any other UI
    /// that needs a single "X entities indexed" figure.
    public func canonicalCount() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM entities;", [])
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

    /// G3.20 — read the persisted fact_type for a single row. Returns
    /// nil when the row isn't classified or doesn't exist. Used by the
    /// WalkExplainer to type each end of a bond step.
    public func lookupFactType(forEntityID id: Entity.ID) async throws -> String? {
        let rows = try await database.query(
            "SELECT fact_type FROM entities WHERE id = ? LIMIT 1;",
            [.uuid(id)]
        )
        return rows.first?.string(0)
    }

    /// Hydrate a batch of canonical entities by id. Used by the
    /// HybridRetriever.entityLayer when the EntityTrie produced
    /// candidate ids and the layer needs the full Entity objects.
    public func findByIDs(_ ids: [Entity.ID], limit: Int = 200) async throws -> [Entity] {
        guard !ids.isEmpty else { return [] }
        let capped = Array(ids.prefix(limit))
        let placeholders = Array(repeating: "?", count: capped.count).joined(separator: ", ")
        let bindings: [SQLValue] = capped.map { .uuid($0) }
        let rows = try await database.query("""
        SELECT id, kind, value, normalized, source_object_id, confidence, attributes_json
        FROM entities WHERE id IN (\(placeholders));
        """, bindings)
        return rows.compactMap(decodeFullEntity)
    }

    /// EntityTrie warm-up — paged enumeration of every canonical
    /// entity's id + value + normalized. The Trie builds prefix
    /// buckets from both `value` and `normalized` so "Project Delta"
    /// is reachable as "project delta", "project", and "delta" prefix
    /// queries.
    public func allValues(offset: Int = 0, pageSize: Int = 5_000) async throws -> [(UUID, String, String?)] {
        let rows = try await database.query("""
        SELECT id, value, normalized FROM entities
        ORDER BY id ASC
        LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let value = row.string(1) else { return nil }
            return (id, value, row.string(2))
        }
    }

    /// InMemoryBondGraph warm-up — paged enumeration of every entity's
    /// classified fact_type. Skips NULL and the `_unclassified`
    /// sentinel. Returns (canonical_id, fact_type_raw) tuples; caller
    /// maps the raw string to the FactType enum.
    public func allFactTypes(offset: Int = 0, pageSize: Int = 5_000) async throws -> [(UUID, String)] {
        let rows = try await database.query("""
        SELECT id, fact_type FROM entities
        WHERE fact_type IS NOT NULL AND fact_type != '_unclassified'
        ORDER BY id ASC
        LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let raw = row.string(1) else { return nil }
            return (id, raw)
        }
    }

    /// G3 BondBackfill — fetch all canonical entities whose mentions
    /// touch this KO. Used by the BondBackfill engine to rebuild
    /// fact_bonds against an already-ingested corpus (without
    /// re-ingesting every file). Joins through entity_mentions so
    /// entities shared across documents are returned for each KO
    /// they appear in, not just the one they were first seen in.
    public func findByMentionSource(_ id: KnowledgeObject.ID) async throws -> [Entity] {
        let rows = try await database.query("""
        SELECT DISTINCT e.id, e.kind, e.value, e.normalized, e.source_object_id, e.confidence, e.attributes_json
        FROM entities e
        JOIN entity_mentions m ON m.entity_id = e.id
        WHERE m.source_object_id = ?
        LIMIT 500;
        """, [.uuid(id)])
        return rows.compactMap(decodeFullEntity)
    }

    /// Topic-to-entity retrieval: given a set of KO ids (typically
    /// the FTS-matched documents for a query topic like "patents"),
    /// returns the entities co-occurring in those KOs ranked by
    /// within-set mention count. This surfaces topic-relevant entities
    /// that frequency-only retrieval misses ("via patents" pulls IIPRD,
    /// Khurana — not Google, which is high-frequency globally but
    /// noise-frequency within patent-KOs).
    ///
    /// Returns up to `limit` rows of (entity, count). Entities are
    /// only person/organization/vendor/client kinds — name-like
    /// candidates the user would ask about by name.
    public func findInObjects(
        _ koIDs: [KnowledgeObject.ID],
        limit: Int = 30
    ) async throws -> [(Entity, Int)] {
        guard !koIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: koIDs.count).joined(separator: ",")
        var bindings: [SQLValue] = koIDs.map { .uuid($0) }
        bindings.append(.integer(Int64(limit)))
        let sql = """
        SELECT e.id, e.kind, e.value, e.normalized, e.source_object_id,
               e.confidence, e.attributes_json, COUNT(m.id) AS hits
        FROM entities e
        JOIN entity_mentions m ON m.entity_id = e.id
        WHERE m.source_object_id IN (\(placeholders))
          AND e.kind IN ('person','organization','vendor','client')
        GROUP BY e.id
        ORDER BY hits DESC
        LIMIT ?;
        """
        let rows = try await database.query(sql, bindings)
        var out: [(Entity, Int)] = []
        for row in rows {
            guard let entity = decodeFullEntity(row) else { continue }
            let count = Int(row.int(7) ?? 0)
            out.append((entity, count))
        }
        return out
    }

    /// G3.22 — counts of canonical entities grouped by their classified
    /// fact_type. NULL-typed rows aren't returned. Smoke + eval diag
    /// uses this to confirm the classifier actually labeled something.
    public func countsByFactType() async throws -> [String: Int] {
        let rows = try await database.query("""
        SELECT fact_type, COUNT(*) FROM entities
        WHERE fact_type IS NOT NULL AND fact_type != '_unclassified'
        GROUP BY fact_type;
        """)
        var out: [String: Int] = [:]
        for row in rows {
            guard let t = row.string(0) else { continue }
            out[t] = Int(row.int(1) ?? 0)
        }
        return out
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

    /// Every (KO id, source filename, surface form, mention confidence)
    /// for a canonical entity. Joins entity_mentions → knowledge_objects
    /// → files. Used by the dossier export.
    public func mentions(forEntityID id: Entity.ID, limit: Int = 500) async throws -> [EntityMentionRow] {
        let rows = try await database.query("""
        SELECT m.source_object_id, m.surface, m.confidence, f.url, k.source_type, k.created_at
        FROM entity_mentions m
        JOIN knowledge_objects k ON k.id = m.source_object_id
        JOIN files f ON f.id = k.file_id
        WHERE m.entity_id = ?
        ORDER BY k.created_at DESC
        LIMIT ?;
        """, [.uuid(id), .integer(Int64(limit))])
        return rows.compactMap { row in
            guard
                let koID = row.uuid(0),
                let urlString = row.string(3),
                let url = URL(string: urlString),
                let typeRaw = row.string(4),
                let type = SourceType(rawValue: typeRaw)
            else { return nil }
            return EntityMentionRow(
                objectID: koID,
                sourceFile: url,
                sourceType: type,
                surface: row.string(1) ?? "",
                confidence: Confidence(row.double(2) ?? 0.5),
                createdAt: row.date(5) ?? Date()
            )
        }
    }

    public func list(kind: Entity.Kind, limit: Int = 200) async throws -> [EntitySummaryRow] {
        // Human-in-loop: entities a user rejected (review_status = 'rejected')
        // are soft-excluded from the browse surface. They are NOT deleted — see
        // listExcluded / setReviewStatus.
        let rows = try await database.query("""
        SELECT id, value, normalized, confidence
        FROM entities WHERE kind = ? AND review_status IS NULL
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

    /// Canonical rows of a kind with their mention counts — the corpus-wide
    /// corroboration signal the on-device reconciler uses to pick the
    /// authoritative spelling of a name over an OCR/typo variant.
    public func canonicalsWithMentionCounts(kind: Entity.Kind, limit: Int = 2_000) async throws -> [EntityCanonicalRow] {
        let rows = try await database.query("""
        SELECT e.id, e.value, e.normalized, e.confidence, e.quality_tier, COUNT(m.id) AS mentions
        FROM entities e
        LEFT JOIN entity_mentions m ON m.entity_id = e.id
        WHERE e.kind = ? AND e.review_status IS NULL
        GROUP BY e.id
        ORDER BY mentions DESC
        LIMIT ?;
        """, [.text(kind.rawValue), .integer(Int64(limit))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let value = row.string(1) else { return nil }
            return EntityCanonicalRow(
                id: id,
                value: value,
                normalized: row.string(2) ?? value.lowercased(),
                confidence: row.double(3) ?? 0.5,
                qualityTier: row.string(4) ?? "T2",
                mentionCount: Int(row.int(5) ?? 0)
            )
        }
    }

    /// Fold an OCR/typo variant into the authoritative entity WITHOUT
    /// deleting it (data-safety rule: preserve everything, tier by trust).
    /// The variant is registered as an alias of the winner (so lookups by
    /// the mis-spelling resolve correctly) and demoted to T3 / low confidence
    /// so listings + confidence-ordered answers prefer the winner.
    public func markOCRVariant(loserID: Entity.ID, winnerID: Entity.ID, loserNormalized: String) async throws {
        try await database.exec("""
        UPDATE entities
        SET quality_tier = 'T3', confidence = MIN(confidence, 0.35)
        WHERE id = ?;
        """, [.uuid(loserID)])
        try await addAlias(entityID: winnerID, aliasNormalized: loserNormalized, source: "ocr-variant")
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
        // Rejected entities are excluded from search too, so a soft-excluded
        // entity stops surfacing in answers/dossiers, not just the browse list.
        let rows = try await database.query("""
        SELECT DISTINCT e.id, e.value, e.normalized, e.confidence
        FROM entities e
        LEFT JOIN entity_aliases a ON a.entity_id = e.id
        WHERE (e.value LIKE ?
           OR e.normalized LIKE ?
           OR a.alias_normalized LIKE ?)
           AND e.review_status IS NULL
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

    // MARK: - Human-in-loop review status (v49)

    /// Soft-exclude ("reject") or restore a canonical entity. `status` is
    /// "rejected" to exclude, or nil to restore. The row itself is never
    /// deleted — the preserve-everything directive — only marked so the browse
    /// / search / candidate-ranking surfaces hide it. The reversible audit
    /// record lives in fact_reviews (written by the caller).
    public func setReviewStatus(_ id: Entity.ID, _ status: String?) async throws {
        try await database.exec(
            "UPDATE entities SET review_status = ? WHERE id = ?;",
            [status.map { .text($0) } ?? .null, .uuid(id)]
        )
    }

    /// The canonical entities of a kind a user has rejected — powers the
    /// "Show excluded" section in the Knowledge browser (with Restore).
    public func listExcluded(kind: Entity.Kind, limit: Int = 200) async throws -> [EntitySummaryRow] {
        let rows = try await database.query("""
        SELECT id, value, normalized, confidence
        FROM entities WHERE kind = ? AND review_status = 'rejected'
        ORDER BY value COLLATE NOCASE
        LIMIT ?;
        """, [.text(kind.rawValue), .integer(Int64(limit))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let value = row.string(1),
                  let conf = row.double(3) else { return nil }
            return EntitySummaryRow(
                id: id, value: value,
                normalizedValue: row.string(2), confidence: Confidence(conf)
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
        // HISTORY Phase A — quality_tier participates in upsert. On
        // conflict, MIN keeps the best (highest-trust) tier seen so
        // far: 'T1' < 'T2' < 'T3' lexicographically, so MIN selects
        // T1 over T2/T3. Same row, best-known tier.
        let rows = try await database.query("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind, normalized) DO UPDATE SET
            confidence = max(entities.confidence, excluded.confidence),
            value = CASE WHEN excluded.confidence > entities.confidence
                         THEN excluded.value
                         ELSE entities.value
                    END,
            quality_tier = MIN(entities.quality_tier, excluded.quality_tier)
        RETURNING id;
        """, [
            .uuid(e.id),
            .text(e.kind.rawValue),
            .text(e.value),
            .text(normalized),
            .uuid(e.sourceObjectID),
            .real(e.confidence.value),
            .text(attrsStr),
            .text(e.qualityTier.rawValue)
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

public struct EntityCanonicalRow: Sendable, Hashable {
    public let id: Entity.ID
    public let value: String
    public let normalized: String
    public let confidence: Double
    public let qualityTier: String
    public let mentionCount: Int
}

public struct EntitySummaryRow: Identifiable, Sendable, Hashable {
    public let id: Entity.ID
    public let value: String
    public let normalizedValue: String?
    public let confidence: Confidence
}

public struct EntityMentionRow: Sendable, Hashable {
    public let objectID: KnowledgeObject.ID
    public let sourceFile: URL
    public let sourceType: SourceType
    public let surface: String
    public let confidence: Confidence
    public let createdAt: Date
}
