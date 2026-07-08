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
        try await database.exec("SAVEPOINT kalsmritikosh_event_merge;")
        do {
            // 1. Close versions on every source.
            let sourceEvents = try await events.findByIDs(nontargetSources)
            for src in sourceEvents {
                _ = try await versions.recordVersion(
                    event: src,
                    agent: "user.merge.source",
                    activity: "supersededByMerge",
                    reason: "Merged into \(target.id.uuidString.prefix(8))"
                )
            }
            // 2. Upsert the target row. We INSERT OR REPLACE so the
            //    same target.id can land whether it existed before
            //    or not.
            let targetPayload = try encoder.encode(target)
            let attrJSON = String(data: targetPayload, encoding: .utf8) ?? "{}"
            _ = attrJSON  // payload re-encoded for version; the row
                          // itself goes through writeEventRow.
            try await writeEventRow(target)

            // 3. Re-target event_entities + event_links from sources
            //    to target. event_entities has a composite PK so
            //    a straight UPDATE would clash if both source and
            //    target already touched the same entity — INSERT OR
            //    IGNORE then DELETE handles the dedup.
            for src in nontargetSources {
                try await database.exec("""
                INSERT OR IGNORE INTO event_entities (event_id, entity_id)
                SELECT ?, entity_id FROM event_entities WHERE event_id = ?;
                """, [.uuid(target.id), .uuid(src)])
            }
            for src in nontargetSources {
                try await database.exec("""
                UPDATE event_links SET source_event_id = ?
                WHERE source_event_id = ?;
                """, [.uuid(target.id), .uuid(src)])
                try await database.exec("""
                UPDATE event_links SET target_event_id = ?
                WHERE target_event_id = ?;
                """, [.uuid(target.id), .uuid(src)])
            }

            // 4. Stamp the target's new version row.
            _ = try await versions.recordVersion(
                event: target,
                agent: "user.merge",
                activity: "mergedFrom",
                reason: reason
                    ?? "Merged from \(nontargetSources.map { $0.uuidString.prefix(8) }.joined(separator: ", "))"
            )

            // 5. Drop the source events — the cascade on event_entities
            //    is harmless because we already moved the rows above.
            for src in nontargetSources {
                try await database.exec(
                    "DELETE FROM events WHERE id = ?;",
                    [.uuid(src)]
                )
            }
            try await database.exec("RELEASE SAVEPOINT kalsmritikosh_event_merge;")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT kalsmritikosh_event_merge;")
            try? await database.exec("RELEASE SAVEPOINT kalsmritikosh_event_merge;")
            KalsmritikoshLog.knowledge.error("EventMutator.merge: \(String(describing: error), privacy: .public)")
            throw error
        }
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
        try await database.exec("SAVEPOINT kalsmritikosh_event_split;")
        do {
            // 1. Record the original's final version.
            _ = try await versions.recordVersion(
                event: original,
                agent: "user.split.source",
                activity: "supersededBySplit",
                reason: "Split into \(parts.count) parts"
            )

            // 2. Insert each part.
            for part in parts {
                try await writeEventRow(part)
                for entityID in part.entityIDs {
                    try await database.exec("""
                    INSERT OR IGNORE INTO event_entities (event_id, entity_id)
                    VALUES (?, ?);
                    """, [.uuid(part.id), .uuid(entityID)])
                }
                _ = try await versions.recordVersion(
                    event: part,
                    agent: "user.split",
                    activity: "splitFrom",
                    reason: reason
                        ?? "Split from \(eventID.uuidString.prefix(8))"
                )
            }

            // 3. Redirect any links touching the original to the
            //    FIRST part. The user can re-author after if some
            //    of those links should attach to a different part.
            if let heir = parts.first {
                try await database.exec("""
                UPDATE event_links SET source_event_id = ?
                WHERE source_event_id = ?;
                """, [.uuid(heir.id), .uuid(eventID)])
                try await database.exec("""
                UPDATE event_links SET target_event_id = ?
                WHERE target_event_id = ?;
                """, [.uuid(heir.id), .uuid(eventID)])
            }

            // 4. Drop the original.
            try await database.exec(
                "DELETE FROM events WHERE id = ?;",
                [.uuid(eventID)]
            )

            try await database.exec("RELEASE SAVEPOINT kalsmritikosh_event_split;")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT kalsmritikosh_event_split;")
            try? await database.exec("RELEASE SAVEPOINT kalsmritikosh_event_split;")
            KalsmritikoshLog.knowledge.error("EventMutator.split: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Internals

    /// Lightweight write of an event row. EventsRepository's
    /// insertBatch does a multi-row INSERT OR REPLACE under the
    /// hood, but exposes only the batch shape — for single-row
    /// writes we go through the same canonical INSERT to keep
    /// the column list consistent.
    private func writeEventRow(_ event: Event) async throws {
        try await events.insertBatch([event])
    }
}
