//
//  EventVersionsRepository.swift
//  Kalsmritikosh
//
//  HISTORY Phase I.A — versioned audit log over `events`. Implements
//  SCD2 (Slowly Changing Dimension Type 2) over the event table:
//  every change to an event's payload is a NEW row in
//  `event_versions` rather than a destructive UPDATE on `events`.
//
//  Use cases:
//    • A user corrects the date of "Contract signed" from 2025-03-12
//      to 2025-03-14 — the previous version stays auditable.
//    • The LLM-driven NarrativeSlotBackfiller refines a kind from
//      `.other` to `.contractSigned` — agent='ontology.backfill'.
//    • The EventExtractor re-ingests a forensic PDF and the timestamp
//      precision tightens — old row closes, new row opens.
//
//  PROV-O light: every version carries (agent, activity, reason) so
//  the audit log answers WHO / WHAT / WHY without leaning on full
//  W3C PROV-O ontology overhead.
//
//  Reads do NOT replace the canonical `events` row. The `events`
//  table is the "current snapshot" view downstream consumers query;
//  `event_versions` is the history a future "show timeline edits"
//  surface walks when the user wants to see how a record changed.
//

import Foundation

public struct EventVersion: Sendable, Identifiable {
    public typealias ID = UUID

    public let id: ID
    public let eventID: Event.ID
    public let version: Int
    public let validFrom: Date
    public let validTo: Date?
    public let payload: Event
    public let agent: String
    public let activity: String?
    public let reason: String?
    public let recordedAt: Date

    public nonisolated init(
        id: ID = UUID(),
        eventID: Event.ID,
        version: Int,
        validFrom: Date,
        validTo: Date? = nil,
        payload: Event,
        agent: String,
        activity: String? = nil,
        reason: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.eventID = eventID
        self.version = version
        self.validFrom = validFrom
        self.validTo = validTo
        self.payload = payload
        self.agent = agent
        self.activity = activity
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

public actor EventVersionsRepository {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Optional sink invoked after every successful `recordVersion`.
    /// AppState wires this to ConfidencePropagator.propagate(forEvent:)
    /// so a user correction / re-derivation automatically refreshes
    /// the confidence of every causal link touching the changed
    /// event. Nil = no auto-trigger; callers must call the
    /// propagator manually.
    private var onVersionRecorded: (@Sendable (Event.ID) async -> Void)?

    public init(database: Database) {
        self.database = database
    }

    /// Install the auto-trigger. Wired once at boot; callers don't
    /// need to remember to invoke ConfidencePropagator manually
    /// after every version write.
    public func setOnVersionRecorded(_ handler: @escaping @Sendable (Event.ID) async -> Void) {
        self.onVersionRecorded = handler
    }

    // MARK: - Writes

    /// Record a new version for `event`. Closes the previous current
    /// row's `valid_to` (if any) and inserts a fresh row with the
    /// passed payload. Caller controls `agent` / `activity` / `reason`
    /// so the audit log says who and why.
    ///
    /// Agent vocabulary (suggested; not enforced):
    ///   - "system.eventExtractor"       (RuleEventExtractor first emission)
    ///   - "system.narrativeSlotBackfill" (NarrativeSlotBackfiller)
    ///   - "system.ontologyBackfill"     (OntologyBackfill)
    ///   - "system.llmRefiner"           (future LLM enrichment)
    ///   - "user.correction"             (manual edit UI)
    ///
    /// Returns the version number assigned (1-based, monotonically
    /// increasing per event_id).
    @discardableResult
    public func recordVersion(
        event: Event,
        agent: String,
        activity: String? = nil,
        reason: String? = nil,
        at recordedAt: Date = Date()
    ) async throws -> Int {
        try await database.exec("SAVEPOINT kalsmritikosh_event_version;")
        do {
            // 1. Close any current row's valid_to.
            try await database.exec("""
            UPDATE event_versions SET valid_to = ?
            WHERE event_id = ? AND valid_to IS NULL;
            """, [
                .real(recordedAt.timeIntervalSince1970),
                .uuid(event.id)
            ])
            // 2. Compute the next version number.
            let nextVersion: Int
            let rows = try await database.query("""
            SELECT COALESCE(MAX(version), 0) FROM event_versions WHERE event_id = ?;
            """, [.uuid(event.id)])
            nextVersion = Int(rows.first?.int(0) ?? 0) + 1
            // 3. Encode payload.
            let payloadData = try encoder.encode(event)
            let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
            // 4. Insert new row.
            try await database.exec("""
            INSERT INTO event_versions
                (id, event_id, version, valid_from, valid_to, payload_json,
                 agent, activity, reason, recorded_at)
            VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?);
            """, [
                .uuid(UUID()),
                .uuid(event.id),
                .integer(Int64(nextVersion)),
                .real(recordedAt.timeIntervalSince1970),
                .text(payloadJSON),
                .text(agent),
                activity.map { .text($0) } ?? .null,
                reason.map { .text($0) } ?? .null,
                .real(recordedAt.timeIntervalSince1970)
            ])
            try await database.exec("RELEASE SAVEPOINT kalsmritikosh_event_version;")
            // Phase J.15 — Vol 25 ¶10 event-versioning regen trigger.
            // Fire-and-forget so the caller doesn't block on
            // downstream link recomputation; failures are logged in
            // ConfidencePropagator itself.
            if let handler = onVersionRecorded {
                let eventID = event.id
                Task.detached(priority: .utility) {
                    await handler(eventID)
                }
            }
            return nextVersion
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT kalsmritikosh_event_version;")
            try? await database.exec("RELEASE SAVEPOINT kalsmritikosh_event_version;")
            throw error
        }
    }

    // MARK: - Reads

    /// All versions for `eventID`, oldest first. The last entry whose
    /// `validTo` is nil is the current snapshot.
    public func versions(of eventID: Event.ID) async throws -> [EventVersion] {
        let rows = try await database.query("""
        SELECT id, event_id, version, valid_from, valid_to, payload_json,
               agent, activity, reason, recorded_at
        FROM event_versions
        WHERE event_id = ?
        ORDER BY version ASC;
        """, [.uuid(eventID)])
        return rows.compactMap(decodeRow)
    }

    /// The current version row (valid_to IS NULL). Returns nil when
    /// no audit row exists for the event — common for events that
    /// pre-date Phase I.A's wiring.
    public func currentVersion(of eventID: Event.ID) async throws -> EventVersion? {
        let rows = try await database.query("""
        SELECT id, event_id, version, valid_from, valid_to, payload_json,
               agent, activity, reason, recorded_at
        FROM event_versions
        WHERE event_id = ? AND valid_to IS NULL
        ORDER BY version DESC LIMIT 1;
        """, [.uuid(eventID)])
        return rows.first.flatMap(decodeRow)
    }

    public func count() async throws -> Int {
        let rows = try await database.query("SELECT COUNT(*) FROM event_versions;", [])
        return Int(rows.first?.int(0) ?? 0)
    }

    // MARK: - Internals

    private func decodeRow(_ row: SQLRow) -> EventVersion? {
        guard
            let id = row.uuid(0),
            let eventID = row.uuid(1),
            let version = row.int(2),
            let validFromRaw = row.double(3),
            let payloadJSON = row.string(5),
            let agent = row.string(6),
            let recordedAtRaw = row.double(9)
        else { return nil }
        guard let payloadData = payloadJSON.data(using: .utf8),
              let payload = try? decoder.decode(Event.self, from: payloadData)
        else { return nil }
        let validTo = row.double(4).map { Date(timeIntervalSince1970: $0) }
        return EventVersion(
            id: id,
            eventID: eventID,
            version: Int(version),
            validFrom: Date(timeIntervalSince1970: validFromRaw),
            validTo: validTo,
            payload: payload,
            agent: agent,
            activity: row.string(7),
            reason: row.string(8),
            recordedAt: Date(timeIntervalSince1970: recordedAtRaw)
        )
    }
}
