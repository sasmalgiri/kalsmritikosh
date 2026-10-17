//
//  EventMutator.swift
//  Kalsmritikosh
//
//  Phase J.11 — Vol 17 §A6 / Vol 25 ¶10. Merge and split operations
//  over the events table with full SCD2 audit:
//
//      merge(sourceIDs: into:)
//          • Records a final version on every source event closing
//            its valid_to.
//          • Inserts (or upserts) the target event.
//          • Re-targets event_entities + event_links rows from
//            sources → target.
//          • Records the target's "v1" version stamped agent=
//            "user.merge".
//          • Deletes the source rows (the FK cascade clears their
//            event_entities — but we re-target FIRST so the links
//            don't go through the cascade).
//
//      split(eventID: into:)
//          • Records a final version on the original.
//          • Inserts each new event; the FIRST new event inherits
//            the original's event_links touch (best-effort default;
//            the user can re-author).
//          • Records each new event with agent="user.split" stamped
//            with a `reason` pointing back at the original's id.
//          • Deletes the original.
//
//  All operations run inside a SAVEPOINT so a mid-flight failure
//  leaves the ledger at the pre-mutation state. The audit log in
//  event_versions remains intact across rollback because writes to
//  it land inside the same SAVEPOINT.
//

import Foundation
import OSLog

public actor EventMutator {
    private let database: Database
    private let events: EventsRepository
    private let versions: EventVersionsRepository
    private let encoder = JSONEncoder()

    public init(
        database: Database,
        events: EventsRepository,
        versions: EventVersionsRepository
    ) {
        self.database = database
        self.events = events
        self.versions = versions
    }

    // MARK: - Merge

    /// Merge two or more events into a single target. The target
    /// can be a brand-new Event (any id not already in `events`) or
    /// one of the source events (in which case the others fold into
    /// it). The caller's `target` carries the final canonical
    /// payload — title, date, kind, entity ids, etc.
    public func merge(
        sourceIDs: [Event.ID],
        into target: Event,
        reason: String? = nil
    ) async throws {
        let nontargetSources = sourceIDs.filter { $0 != target.id }
        // Everything read or encoded up front; the savepoint body only writes (F28 — the whole merge
        // is ONE isolated unit, so a concurrent writer can never see or wedge a half-merged event).
        let sourceEvents = try await events.findByIDs(nontargetSources)
        let sourcePayloads = try sourceEvents.map { ($0.id, try EventVersionsRepository.payloadJSON($0)) }
        let targetPayload = try EventVersionsRepository.payloadJSON(target)
        let targetRow = try EventsRepository.insertStatements(for: [target])
        let targetID = target.id
        let mergeReason = reason
            ?? "Merged from \(nontargetSources.map { $0.uuidString.prefix(8) }.joined(separator: ", "))"
        let now = Date()
        do {
            try await database.withSavepoint("kalsmritikosh_event_merge") { db in
                // 1. Close versions on every source.
                for (id, json) in sourcePayloads {
                    _ = try EventVersionsRepository.recordVersion(
                        db, eventID: id, payloadJSON: json, agent: "user.merge.source",
                        activity: "supersededByMerge", reason: "Merged into \(targetID.uuidString.prefix(8))", at: now)
                }
                // 2. Write the target row.
                for st in targetRow { try db.exec(st.sql, st.binds) }

                // 3. Re-target event_entities + event_links from sources
                //    to target. event_entities has a composite PK so
                //    a straight UPDATE would clash if both source and
                //    target already touched the same entity — INSERT OR
                //    IGNORE then DELETE handles the dedup.
                for src in nontargetSources {
                    try db.exec("""
                    INSERT OR IGNORE INTO event_entities (event_id, entity_id)
                    SELECT ?, entity_id FROM event_entities WHERE event_id = ?;
                    """, [.uuid(targetID), .uuid(src)])
                }
                for src in nontargetSources {
                    try db.exec("UPDATE event_links SET source_event_id = ? WHERE source_event_id = ?;",
                                [.uuid(targetID), .uuid(src)])
                    try db.exec("UPDATE event_links SET target_event_id = ? WHERE target_event_id = ?;",
                                [.uuid(targetID), .uuid(src)])
                }

                // 4. Stamp the target's new version row.
                _ = try EventVersionsRepository.recordVersion(
                    db, eventID: targetID, payloadJSON: targetPayload, agent: "user.merge",
                    activity: "mergedFrom", reason: mergeReason, at: now)

                // 5. Drop the source events — the cascade on event_entities
                //    is harmless because we already moved the rows above.
                for src in nontargetSources {
                    try db.exec("DELETE FROM events WHERE id = ?;", [.uuid(src)])
                }
            }
        } catch {
            KalsmritikoshLog.knowledge.error("EventMutator.merge: \(String(describing: error), privacy: .public)")
            throw error
        }
        await versions.notifyRecorded(sourcePayloads.map(\.0) + [targetID])
    }

    // MARK: - Split

    /// Split one event into two or more. The first element of
    /// `parts` inherits the original's event_links touches; the
    /// rest are inserted clean (no links). entityIDs of the parts
    /// override the original's event_entities rows wholesale.
    public func split(
        eventID: Event.ID,
        into parts: [Event],
        reason: String? = nil
    ) async throws {
        precondition(parts.count >= 2, "Split requires at least two parts.")
        guard let original = try await events.findByIDs([eventID]).first else {
            KalsmritikoshLog.knowledge.info("EventMutator.split: event \(eventID.uuidString.prefix(8), privacy: .public) not found")
            return
        }
        let originalPayload = try EventVersionsRepository.payloadJSON(original)
        let partRows = try parts.map { part in
            (id: part.id, rows: try EventsRepository.insertStatements(for: [part]),
             entityIDs: part.entityIDs, payload: try EventVersionsRepository.payloadJSON(part))
        }
        let splitReason = reason ?? "Split from \(eventID.uuidString.prefix(8))"
        let partCount = parts.count
        let heirID = parts.first?.id
        let now = Date()
        do {
            // F28 — the whole split is ONE isolated savepoint.
            try await database.withSavepoint("kalsmritikosh_event_split") { db in
                // 1. Record the original's final version.
                _ = try EventVersionsRepository.recordVersion(
                    db, eventID: eventID, payloadJSON: originalPayload, agent: "user.split.source",
                    activity: "supersededBySplit", reason: "Split into \(partCount) parts", at: now)

                // 2. Insert each part.
                for part in partRows {
                    for st in part.rows { try db.exec(st.sql, st.binds) }
                    for entityID in part.entityIDs {
                        try db.exec("INSERT OR IGNORE INTO event_entities (event_id, entity_id) VALUES (?, ?);",
                                    [.uuid(part.id), .uuid(entityID)])
                    }
                    _ = try EventVersionsRepository.recordVersion(
                        db, eventID: part.id, payloadJSON: part.payload, agent: "user.split",
                        activity: "splitFrom", reason: splitReason, at: now)
                }

                // 3. Redirect any links touching the original to the
                //    FIRST part. The user can re-author after if some
                //    of those links should attach to a different part.
                if let heirID {
                    try db.exec("UPDATE event_links SET source_event_id = ? WHERE source_event_id = ?;",
                                [.uuid(heirID), .uuid(eventID)])
                    try db.exec("UPDATE event_links SET target_event_id = ? WHERE target_event_id = ?;",
                                [.uuid(heirID), .uuid(eventID)])
                }

                // 4. Drop the original.
                try db.exec("DELETE FROM events WHERE id = ?;", [.uuid(eventID)])
            }
        } catch {
            KalsmritikoshLog.knowledge.error("EventMutator.split: \(String(describing: error), privacy: .public)")
            throw error
        }
        await versions.notifyRecorded([eventID] + partRows.map(\.id))
    }

    // MARK: - Internals

}
