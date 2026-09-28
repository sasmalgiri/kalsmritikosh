//
//  EntityRetirementNotDeletionTests.swift
//  KalsmritikoshTests
//
//  OWNER RULING 2026-09-25 — "so it better not to delete anything?"
//
//  `EntityQualityGate.purgeGarbage` (drain pass 1) was the ONE site in the app
//  that destroyed extracted knowledge. Of 47 `DELETE FROM` sites the other 46
//  either replace a derived projection (drain, topic/milestone rebuild) or roll
//  back a failed document commit — both structurally necessary. This one deleted
//  canonical entities outright, cascading away their mentions and aliases, plus
//  any memory_objects that shared the subject name. Nothing came back.
//
//  It is now a SOFT RETIREMENT, and this file is the proof. It had NO test
//  coverage before — a shipped, destructive, drain-invoked path with nothing
//  asserting what it did.
//
//  What is asserted, in the order that matters:
//
//   1. THE ROWS SURVIVE. Not "the count changed" — the specific entity row is
//      still SELECTable afterwards, with review_status='rejected', and its
//      mentions and aliases are still there. This is the assertion the old
//      behaviour could never have passed.
//   2. ANSWERS ARE UNCHANGED. A retired entity must not reach a reader. Proven
//      through the live read surfaces (`list`, `search`) rather than by
//      re-asserting the column we just wrote.
//   3. MEMORY IS RETIRED, NOT DELETED — and actually hidden, because memory is
//      keyed by subject NAME, so retiring the entity alone would not have hidden
//      it. Both halves are checked: row present, reader blind to it.
//   4. IT IS AUDITED. A fact_reviews row per retirement, reviewer='quality-gate'
//      so machine action is distinguishable from the user's own rejections.
//   5. IT IS IDEMPOTENT. A second run retires nothing and writes no new audit
//      rows — the Fixed-Point Law, which a re-run of a soft flag could easily
//      violate by re-logging 4,343 reviews every drain.
//   6. THE USER OUTRANKS THE HEURISTIC. An entity the user restored by hand is
//      NOT re-retired. The old delete had no way to express this: once deleted,
//      a restored ghost could not exist to be re-deleted, and re-extraction
//      would silently resurrect and re-delete it forever.
//
//  A GOOD ENTITY IS ALSO SEEDED throughout, so a gate that retired everything
//  would fail these tests rather than pass them trivially.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Entity quality gate RETIRES, never deletes")
struct EntityRetirementNotDeletionTests {

    /// A migrated ledger with one KO (entities carry a source_object_id FK),
    /// one junk entity + its mention and alias, and one good entity.
    private func seed() async throws -> (db: Database, junk: UUID, good: UUID, ko: UUID) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("retire-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///retire-test"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, ?, ?, 0, 0);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("retirement test body")])

        // "Nil Nil" is the canonical junk shape the gate exists to catch.
        let junkID = UUID(), goodID = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?, 'person', 'Nil Nil', 'nil nil', ?, 0.5, '{}');
        """, [.uuid(junkID), .uuid(koID)])
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
        VALUES (?, 'person', 'Shirshendu Sasmal', 'shirshendu sasmal', ?, 0.9, '{}');
        """, [.uuid(goodID), .uuid(koID)])

        // Derived rows that the OLD delete cascaded away.
        try await db.exec("""
        INSERT INTO entity_mentions
            (id, entity_id, kind, surface, normalized, source_object_id, confidence)
        VALUES (?, ?, 'person', 'Nil Nil', 'nil nil', ?, 0.5);
        """, [.uuid(UUID()), .uuid(junkID), .uuid(koID)])
        try await db.exec("""
        INSERT OR IGNORE INTO entity_aliases (entity_id, alias_normalized, source)
        VALUES (?, 'nil  nil', 'test');
        """, [.uuid(junkID)])

        // Memory for BOTH subjects — memory is keyed by name, not entity id.
        for (subject, narrative) in [("Nil Nil", "junk subject memory"),
                                     ("Shirshendu Sasmal", "real subject memory")] {
            try await db.exec("""
            INSERT INTO memory_objects
                (id, subject_kind, subject_identifier, key_decisions_json, key_event_ids_json,
                 important_relationship_ids_json, risks_json, status, narrative,
                 source_object_ids_json, confidence, version, created_at, updated_at, quality_tier)
            VALUES (?, 'person', ?, '[]', '[]', '[]', '[]', 'active', ?, '[]', 0.5, 1, 0, 0, 'T2');
            """, [.uuid(UUID()), .text(subject), .text(narrative)])
        }
        return (db, junkID, goodID, koID)
    }

    private func count(_ db: Database, _ sql: String, _ binds: [SQLValue] = []) async throws -> Int {
        Int(try await db.query(sql, binds).first?.int(0) ?? 0)
    }

    @Test("The junk entity row SURVIVES, flagged — and its mentions and aliases survive with it")
    func retiresWithoutDeleting() async throws {
        let (db, junk, good, _) = try await seed()
        let gate = EntityQualityGate()

        let report = try await gate.purgeGarbage(in: db)
        #expect(report.entitiesRetired == 1, "the one junk entity should be retired")
        #expect(report.memoryObjectsRetired == 1, "its memory should be retired too")

        // THE ASSERTION THE OLD BEHAVIOUR COULD NOT PASS: the row is still here.
        let survives = try await count(db, "SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(junk)])
        #expect(survives == 1, "RETIRED MUST NOT MEAN DELETED — the entity row is gone")

        let status = try await db.query("SELECT review_status FROM entities WHERE id = ?;", [.uuid(junk)])
            .first?.string(0)
        #expect(status == "rejected", "should carry the SAME soft-exclude value the Reject button writes")

        // The old delete cascaded these away; they must be intact.
        let mentions = try await count(db, "SELECT COUNT(*) FROM entity_mentions WHERE entity_id = ?;", [.uuid(junk)])
        let aliases = try await count(db, "SELECT COUNT(*) FROM entity_aliases WHERE entity_id = ?;", [.uuid(junk)])
        #expect(mentions == 1, "mentions were cascaded away by the old delete; they must survive retirement")
        #expect(aliases == 1, "aliases were cascaded away by the old delete; they must survive retirement")

        // And the gate must not be retiring indiscriminately.
        let goodStatus = try await db.query("SELECT review_status FROM entities WHERE id = ?;", [.uuid(good)])
            .first?.string(0)
        #expect(goodStatus == nil, "a real person must be left untouched")
    }

    @Test("A retired entity does not reach a reader — answers are unchanged")
    func retiredEntityIsHiddenFromReadSurfaces() async throws {
        let (db, _, _, _) = try await seed()
        let entities = EntitiesRepository(database: db)

        // Before: the junk entity is visible to the live read surface.
        let before = try await entities.list(kind: .person, limit: 100)
        #expect(before.contains { $0.value == "Nil Nil" }, "precondition: the junk entity starts visible")

        _ = try await EntityQualityGate().purgeGarbage(in: db)

        // After: gone from the reader, though the row is still in the table.
        let after = try await entities.list(kind: .person, limit: 100)
        #expect(!after.contains { $0.value == "Nil Nil" },
                "a retired entity must not surface — this is what keeps answers unchanged")
        #expect(after.contains { $0.value == "Shirshendu Sasmal" }, "the real person must still surface")

        // And it is reachable for RESTORE, which is the whole point of retiring.
        let excluded = try await entities.listExcluded(kind: .person)
        #expect(excluded.contains { $0.value == "Nil Nil" },
                "retired entities must be listed as excluded so the user can restore them")
    }

    @Test("Memory is retired and hidden, not deleted")
    func memoryIsRetiredNotDeleted() async throws {
        let (db, _, _, _) = try await seed()
        let memory = MemoryRepository(database: db)

        #expect(try await memory.current(forSubject: .person, identifier: "Nil Nil") != nil,
                "precondition: junk memory starts readable")

        _ = try await EntityQualityGate().purgeGarbage(in: db)

        // The row survives …
        let rows = try await count(db,
            "SELECT COUNT(*) FROM memory_objects WHERE subject_identifier = 'Nil Nil';")
        #expect(rows == 1, "memory must be RETIRED, not deleted")
        #expect(try await memory.retiredCount() == 1)

        // … but no reader sees it. Memory is keyed by NAME, so this could not
        // have been achieved by flagging the entity alone.
        #expect(try await memory.current(forSubject: .person, identifier: "Nil Nil") == nil,
                "retired memory must not be readable, or the junk would still reach answers")
        #expect(try await memory.search("junk subject").isEmpty,
                "retired memory must not be searchable")
        let all = try await memory.listAll()
        #expect(!all.contains { $0.subjectIdentifier == "Nil Nil" })

        // The real subject's memory is untouched.
        #expect(try await memory.current(forSubject: .person, identifier: "Shirshendu Sasmal") != nil,
                "a real subject's memory must survive and stay readable")

        // Explicit opt-in can still see it — nothing is hidden irretrievably.
        #expect(try await memory.current(forSubject: .person, identifier: "Nil Nil",
                                         includeRetired: true) != nil,
                "includeRetired must expose it for audit and restore")
    }

    @Test("Every retirement is audited, and attributable to the machine")
    func retirementIsAudited() async throws {
        let (db, junk, _, _) = try await seed()
        _ = try await EntityQualityGate().purgeGarbage(in: db)

        let rows = try await db.query("""
        SELECT action, reviewer, reason FROM fact_reviews
        WHERE subject_kind = 'entity' AND subject_id = ?;
        """, [.uuid(junk)])
        #expect(rows.count == 1, "the retirement must appear in the audit trail")
        #expect(rows.first?.string(0) == "reject")
        #expect(rows.first?.string(1) == "quality-gate",
                "machine action must be distinguishable from the user's own rejections")
        #expect(rows.first?.string(2)?.contains("not deleted") == true,
                "the audit reason should say what actually happened")
    }

    @Test("A second run changes nothing — no re-retirement, no duplicate audit rows")
    func isIdempotent() async throws {
        let (db, _, _, _) = try await seed()
        let gate = EntityQualityGate()

        let first = try await gate.purgeGarbage(in: db)
        #expect(first.entitiesRetired == 1)

        let second = try await gate.purgeGarbage(in: db)
        #expect(second.entitiesRetired == 0, "already-retired entities must not be rescanned")
        #expect(second.memoryObjectsRetired == 0)

        // The Fixed-Point Law: a soft flag re-applied every drain would re-log
        // an audit row per entity per run, growing the review ledger forever.
        let reviews = try await count(db,
            "SELECT COUNT(*) FROM fact_reviews WHERE reviewer = 'quality-gate';")
        #expect(reviews == 1, "a second run must not write a second audit row")
    }

    @Test("A user's restore outranks the heuristic — it is not re-retired")
    func userRestoreWins() async throws {
        let (db, junk, _, _) = try await seed()
        let gate = EntityQualityGate()
        let entities = EntitiesRepository(database: db)
        let reviews = FactReviewsRepository(database: db)

        _ = try await gate.purgeGarbage(in: db)

        // The user disagrees and restores it — exactly what KnowledgeView does.
        try await entities.setReviewStatus(junk, nil)
        _ = try await reviews.record(FactReview(
            subjectKind: .entity, subjectID: junk, action: .accept,
            priorValue: "Nil Nil", reviewer: "user", reason: "Restored"))

        // The next drain must respect that decision.
        let after = try await gate.purgeGarbage(in: db)
        #expect(after.entitiesRetired == 0, "the gate must not overrule a human restore")
        #expect(after.skippedUserRestored == 1, "and it must SAY that it skipped one")

        let status = try await db.query("SELECT review_status FROM entities WHERE id = ?;", [.uuid(junk)])
            .first?.string(0)
        #expect(status == nil, "the entity must still be live after the user restored it")
    }
}
