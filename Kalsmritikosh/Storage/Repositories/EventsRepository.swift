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
            // T16 — persist an evidentiary status. If the event still carries
            // the default (.inferred), derive it from its signals so the
            // stored spread is meaningful; an explicitly-set status is kept.
            let status: EventStatus = e.status == .inferred
                ? EventStatus.derive(
                    qualityTier: e.qualityTier,
                    dateConfidence: e.dateConfidence,
                    contentConfidence: e.confidence.value,
                    kind: e.kind)
                : e.status
            try await database.exec("""
            INSERT INTO events (id, kind, date, end_date, title, summary, source_object_id, confidence, attributes_json, date_confidence, quality_tier, date_precision, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                .text(e.qualityTier.rawValue),
                .integer(Int64(e.datePrecision.rawValue)),
                .text(status.rawValue)
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

    /// Count events carrying a `milestone` attribute (the legal/patent spine).
    public func milestoneCount() async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM events WHERE attributes_json LIKE '%\"milestone\"%';")
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Delete previously-generated milestone events so a re-run is idempotent.
    /// These are derived (re-generatable from documents), so deleting is safe;
    /// their event_entities rows cascade.
    public func deleteMilestoneEvents() async throws {
        try await database.exec(
            "DELETE FROM events WHERE attributes_json LIKE '%\"milestone\"%';")
    }

    public func between(start: Date, end: Date, limit: Int = 500) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
        FROM events
        WHERE date BETWEEN ? AND ? AND review_status IS NULL
        ORDER BY date ASC
        LIMIT ?;
        """, [.date(start), .date(end), .integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    public func findByIDs(_ ids: [Event.ID]) async throws -> [Event] {
        guard !ids.isEmpty else { return [] }
        var results: [Event] = []
        for id in ids {
            // Rejected events are excluded here too, so an event a user
            // soft-excluded stops surfacing in retrieval / answers that hydrate
            // events by id. Restore/detail read the row directly (reviewStatus).
            let rows = try await database.query("""
            SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision
            FROM events WHERE id = ? AND review_status IS NULL LIMIT 1;
            """, [.uuid(id)])
            if let row = rows.first, let event = decode(row) {
                results.append(event)
            }
        }
        return results
    }

    public func recent(limit: Int = 200) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
        FROM events
        WHERE review_status IS NULL
        ORDER BY date DESC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
    }

    // MARK: - Human-in-loop review status (v50)

    /// Soft-exclude ("reject") or restore an event. `status` is "rejected" to
    /// exclude, nil to restore. The row and its trust `status` column are never
    /// touched — only the separate `review_status` marker — so a rejected event
    /// drops out of the timeline / retrieval / answers but is fully restorable.
    public func setReviewStatus(_ id: Event.ID, _ status: String?) async throws {
        try await database.exec(
            "UPDATE events SET review_status = ? WHERE id = ?;",
            [status.map { .text($0) } ?? .null, .uuid(id)]
        )
    }

    /// The current review_status for one event (nil = normal, "rejected" =
    /// excluded). Unfiltered direct read so the detail sheet can show Reject vs
    /// Restore even for an already-excluded event.
    public func reviewStatus(forID id: Event.ID) async throws -> String? {
        let rows = try await database.query(
            "SELECT review_status FROM events WHERE id = ? LIMIT 1;", [.uuid(id)])
        return rows.first?.string(0)
    }

    /// Events a user has rejected, newest first — powers the "Show excluded"
    /// section in the Timeline (with Restore).
    public func listRejected(limit: Int = 200) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
        FROM events
        WHERE review_status = 'rejected'
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
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
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

    // MARK: - HISTORY Phase C — 5W+H narrative slots (v21)

    /// Persist the 5W+H bundle to `events.narrative_slots_json`. Empty
    /// bundles encode as "{}" so a "clear all slots" pass round-trips
    /// to the column default.
    public func setNarrativeSlots(_ slots: EventNarrativeSlots, forEventID id: Event.ID) async throws {
        try await database.exec(
            "UPDATE events SET narrative_slots_json = ? WHERE id = ?;",
            [.text(slots.encodedJSON()), .uuid(id)]
        )
    }

    /// Read the 5W+H bundle for a single event. Missing or malformed
    /// JSON decodes as `.empty` — column default is "{}", so missing
    /// only happens for deleted rows.
    public func narrativeSlots(forEventID id: Event.ID) async throws -> EventNarrativeSlots {
        let rows = try await database.query(
            "SELECT narrative_slots_json FROM events WHERE id = ? LIMIT 1;",
            [.uuid(id)]
        )
        guard let row = rows.first, let json = row.string(0) else {
            return .empty
        }
        return EventNarrativeSlots.decoded(from: json)
    }

    /// Batch read for the narrative composer (Phase D) — single
    /// `WHERE id IN (...)` query so the retrieval boost (which calls
    /// this on every reconstructive query over ~200 events) stays
    /// O(1) round-trips instead of O(N).
    public func narrativeSlots(forEventIDs ids: [Event.ID]) async throws -> [Event.ID: EventNarrativeSlots] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT id, narrative_slots_json FROM events WHERE id IN (\(placeholders));
        """, ids.map { .uuid($0) })
        var out: [Event.ID: EventNarrativeSlots] = [:]
        for row in rows {
            guard let id = row.uuid(0), let json = row.string(1) else { continue }
            out[id] = EventNarrativeSlots.decoded(from: json)
        }
        return out
    }

    /// HISTORY F follow-on — resolve a batch of event IDs to the
    /// last-path component of their source file's URL. Lets the
    /// NarrativeEvalKit measure chapter_coverage against stable
    /// filenames (in questions.json) instead of per-machine UUIDs.
    public func sourceFilenames(forEventIDs ids: [Event.ID]) async throws -> [Event.ID: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try await database.query("""
        SELECT e.id, f.url FROM events e
        JOIN knowledge_objects k ON k.id = e.source_object_id
        JOIN files f ON f.id = k.file_id
        WHERE e.id IN (\(placeholders));
        """, ids.map { .uuid($0) })
        var out: [Event.ID: String] = [:]
        for row in rows {
            guard let id = row.uuid(0), let urlString = row.string(1) else { continue }
            let filename = URL(fileURLWithPath: urlString).lastPathComponent
            out[id] = filename.isEmpty
                ? (URL(string: urlString)?.lastPathComponent ?? urlString)
                : filename
        }
        return out
    }

    /// Phase C.2 backfill helper — list events whose narrative slots
    /// need (re-)extraction. Covers three real-data shapes the
    /// 2026-06-28 production audit surfaced:
    ///   1. Default '{}' — column never written (pre-v21 ingest).
    ///   2. Empty WHO — bundle exists but WHO is `[]` (the
    ///      forensic-PDF / mbox case where the older extractor
    ///      didn't pull from .emailAddress entities; now fixed).
    ///   3. Empty WHAT or WHEN — defensive; should never happen
    ///      but if it does the extractor will refill it.
    /// Sorted oldest-first so a multi-pass backfill drains the
    /// archive's earliest events first (the ones most likely to
    /// anchor topic narratives).
    public func listEventsMissingNarrativeSlots(limit: Int = 200) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
        FROM events
        WHERE narrative_slots_json IS NULL
           OR narrative_slots_json = '{}'
           OR narrative_slots_json LIKE '%"who":[]%'
           OR narrative_slots_json LIKE '%"what":[]%'
           OR narrative_slots_json LIKE '%"when":[]%'
        ORDER BY date ASC
        LIMIT ?;
        """, [.integer(Int64(limit))])
        return rows.compactMap(decode)
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
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
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
        SELECT id, kind, date, end_date, title, summary, source_object_id, confidence, date_confidence, quality_tier, date_precision, status
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
                attributes: event.attributes,
                status: event.status
            )
            out.append(event)
        }
        return out
    }

    /// HIST-031 — the COMPLETE ID-linked timeline for one entity: every event the
    /// entity participates in, chronologically. This is the history-scoped read
    /// that replaces the "recent global events" anti-pattern — results are bounded
    /// to the subject by the event_entities join, never the whole archive.
    /// Deterministic order: date, then id for stable ties. Paged.
    public func allForEntity(_ entityID: Entity.ID, offset: Int = 0, pageSize: Int = 1_000) async throws -> [Event] {
        let rows = try await database.query("""
        SELECT e.id, e.kind, e.date, e.end_date, e.title, e.summary, e.source_object_id,
               e.confidence, e.date_confidence, e.quality_tier, e.date_precision, e.status
        FROM events e
        JOIN event_entities ee ON ee.event_id = e.id
        WHERE ee.entity_id = ?
        ORDER BY e.date ASC, e.id ASC
        LIMIT ? OFFSET ?;
        """, [.uuid(entityID), .integer(Int64(pageSize)), .integer(Int64(offset))])
        var out: [Event] = []
        for row in rows {
            guard let base = decode(row) else { continue }
            let participants = try await database.query("""
            SELECT entity_id FROM event_entities WHERE event_id = ?;
            """, [.uuid(base.id)])
            let entityIDs = participants.compactMap { $0.uuid(0) }
            out.append(Event(
                id: base.id, kind: base.kind, date: base.date, endDate: base.endDate,
                title: base.title, summary: base.summary, entityIDs: entityIDs,
                sourceObjectID: base.sourceObjectID, sourceRange: base.sourceRange,
                confidence: base.confidence, dateConfidence: base.dateConfidence,
                attributes: base.attributes, status: base.status))
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
        // HISTORY Phase G.1 — precision read at index 10. Legacy rows
        // from before v22 default to .day (column NOT NULL DEFAULT 5).
        // Inference fallback runs when the column genuinely missing
        // (e.g. SELECT shapes that didn't include it).
        let precisionRaw = row.int(10).map { Int($0) }
        let precision: DatePrecision = {
            if let raw = precisionRaw, let p = DatePrecision(rawValue: raw) { return p }
            return DatePrecision.inferFromConfidence(dateConf)
        }()
        // T16 — status at index 11. Legacy rows (pre-v32 SELECT shapes that
        // omit it) default to .inferred.
        let status = row.string(11).flatMap(EventStatus.init(rawValue:)) ?? .inferred
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
            qualityTier: tier,
            datePrecision: precision,
            status: status
        )
    }
}
