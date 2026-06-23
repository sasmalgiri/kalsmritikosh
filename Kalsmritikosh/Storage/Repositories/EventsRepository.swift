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
            INSERT INTO events (id, kind, date, end_date, title, summary, source_object_id, confidence, attributes_json, date_confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                .real(e.dateConfidence)
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
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence
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
            SELECT id, kind, date, end_date, title, summary, source_object_id, confidence
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
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence
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
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence
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
        return Event(
            id: id,
            kind: kind,
            date: date,
            endDate: row.date(3),
            title: title,
            summary: row.string(5),
            sourceObjectID: sourceID,
            confidence: Confidence(conf),
            dateConfidence: dateConf
        )
    }
}
