//
//  EventsRepository.swift
//  Kalsmritikosh
//

import Foundation

public actor EventsRepository {
    private let database: Database
    private let encoder = JSONEncoder()

    public init(database: Database) {
        self.database = database
    }

    public func insertBatch(_ events: [Event]) async throws {
        for e in events {
            let attrs = try encoder.encode(e.attributes)
            try await database.exec("""
            INSERT INTO events (id, kind, date, end_date, title, summary, source_object_id, confidence, attributes_json, date_confidence, quality_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .uuid(e.id),
                .text(e.kind.rawValue),
                .date(e.date),
                .optionalDate(e.endDate),
                .text(e.title),
                .optionalText(e.summary),
                .uuid(e.sourceObjectID),
                .real(e.confidence.value),
                .text(String(data: attrs, encoding: .utf8) ?? "{}"),
                .real(e.dateConfidence),
                .text(e.qualityTier.rawValue)
            ])
            for entityID in e.entityIDs {
                try await database.exec("""
                INSERT OR IGNORE INTO event_entities (event_id, entity_id) VALUES (?, ?);
                """, [.uuid(e.id), .uuid(entityID)])
            }
        }
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM events;")
        return Int(rows.first?.int(0) ?? 0)
    }

    public func between(start: Date, end: Date, limit: Int = 500) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier
        FROM events
        WHERE date BETWEEN ? AND ?
        ORDER BY date ASC
        LIMIT ?;
        """, [.date(start), .date(end), .integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    public func findByIDs(_ ids: [Event.ID]) async throws -> [Event] {
        guard !ids.isEmpty else { return [] }
        var results: [Event] = []
        for id in ids {
            let rows = try await database.query("""
            SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier
            FROM events WHERE id = ? LIMIT 1;
            """, [.uuid(id)])
            if let row = rows.first, let event = decode(row) {
                results.append(event)
            }
        }
        return results
    }

    public func recent(limit: Int = 200) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier
        FROM events
        ORDER BY date DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    // MARK: - G3 Phase 2

    /// G3.8 — return events whose `fact_type` is NULL so the
    /// OntologyBackfill can label them.
    public func listUnlabeledFactTypes(limit: Int = 500) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier
        FROM events WHERE fact_type IS NULL ORDER BY date DESC LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    /// G3.8 — write the classifier's label back to a single row.
    public func setFactType(_ factType: String, forEventID id: Event.ID) async throws {
        try await database.exec(
            "UPDATE events SET fact_type = ? WHERE id = ?;",
            [.text(factType), .uuid(id)]
        )
    }

    /// G3.13 — write a JSON-encoded slot-values map back to a single row.
    /// Caller is responsible for shape (OntologyValidator-gated).
    public func setSlotValues(_ json: String, forEventID id: Event.ID) async throws {
        try await database.exec(
            "UPDATE events SET slot_values_json = ? WHERE id = ?;",
            [.text(json), .uuid(id)]
        )
    }

    /// G3.20 — read the persisted fact_type for a single row. Returns
    /// nil when the row isn't classified or doesn't exist. Used by the
    /// WalkExplainer to type each end of a bond step.
    public func lookupFactType(forEventID id: Event.ID) async throws -> String? {
        let rows = try await database.query(
            "SELECT fact_type FROM events WHERE id = ? LIMIT 1;",
            [.uuid(id)]
        )
        return rows.first?.string(0)
    }

    /// EntityTimeline warm-up — paged enumeration of every event paired
    /// with its participating entity ids. Returns (event, participants)
    /// tuples; the cache shards them by entity into sorted per-entity
    /// timelines.
    public func allWithParticipants(offset: Int = 0, pageSize: Int = 2_000) async throws -> [(Event, [Entity.ID])] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier
        FROM events
        ORDER BY date ASC
        LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        var out: [(Event, [Entity.ID])] = []
        for row in rows {
            guard let event = decode(row) else { continue }
            let participants = try await database.query("""
            SELECT entity_id FROM event_entities WHERE event_id = ?;
            """, [.uuid(event.id)])
            let entityIDs = participants.compactMap { $0.uuid(0) }
            out.append((event, entityIDs))
        }
        return out
    }

    /// InMemoryBondGraph warm-up — paged enumeration of every event's
    /// classified fact_type. Skips NULL and the `_unclassified`
    /// sentinel. Returns (event_id, fact_type_raw) tuples.
    public func allFactTypes(offset: Int = 0, pageSize: Int = 5_000) async throws -> [(UUID, String)] {
        let rows = try await database.query("""
        SELECT id, fact_type FROM events
        WHERE fact_type IS NOT NULL AND fact_type != '_unclassified'
        ORDER BY id ASC
        LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
        return rows.compactMap { row in
            guard let id = row.uuid(0), let raw = row.string(1) else { return nil }
            return (id, raw)
        }
    }

    /// G3 BondBackfill — fetch all events whose source KO is `id`,
    /// hydrating their entityIDs from event_entities. Returns the
    /// fact-grade Event objects BondConstructor expects (kind, title,
    /// summary, date, entityIDs, …). Used to rebuild fact_bonds for
    /// an already-ingested corpus without re-running ingest.
    public func findBySourceObject(_ id: KnowledgeObject.ID) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier
        FROM events WHERE source_object_id = ? ORDER BY date ASC LIMIT 200;
        """, [.uuid(id)])
        var out: [Event] = []
        for row in rows {
            guard var event = decode(row) else { continue }
            let participants = try await database.query("""
            SELECT entity_id FROM event_entities WHERE event_id = ?;
            """, [.uuid(event.id)])
            let entityIDs = participants.compactMap { $0.uuid(0) }
            event = Event(
                id: event.id,
                kind: event.kind,
                date: event.date,
                endDate: event.endDate,
                title: event.title,
                summary: event.summary,
                entityIDs: entityIDs,
                sourceObjectID: event.sourceObjectID,
                sourceRange: event.sourceRange,
                confidence: event.confidence,
                dateConfidence: event.dateConfidence,
                attributes: event.attributes
            )
            out.append(event)
        }
        return out
    }

    /// G3.22 — counts of events grouped by their classified fact_type.
    /// NULL-typed rows aren't returned. Smoke + eval diag uses this to
    /// confirm the classifier actually labeled something.
    public func countsByFactType() async throws -> [String: Int] {
        let rows = try await database.query("""
        SELECT fact_type, COUNT(*) FROM events
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

    private func decode(_ row: SQLRow) -> Event? {
        guard
            let id = row.uuid(0),
            let kindRaw = row.string(1),
            let kind = Event.Kind(rawValue: kindRaw),
            let date = row.date(2),
            let title = row.string(4),
            let sourceID = row.uuid(6),
            let conf = row.double(7)
        else { return nil }
        let dateConf = row.double(8) ?? 0.5
        let tier = row.string(9).flatMap(QualityTier.init(rawValue:)) ?? .t2
        return Event(
            id: id,
            kind: kind,
            date: date,
            endDate: row.date(3),
            title: title,
            summary: row.string(5),
            sourceObjectID: sourceID,
            confidence: Confidence(conf),
            dateConfidence: dateConf,
            qualityTier: tier
        )
    }
}
