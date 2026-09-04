//
//  StoryGoldTests.swift
//  Kalsmritikosh Tests
//
//  P4-U4 — the STORY GOLD: a seeded archive with a known chain (filed →
//  hearing → granted), a known gap (a years-long silence), and a known
//  contradiction (two grant dates) tells its story with ALL THREE surfaced —
//  chaptered, every sentence standing on a named item, persisted through the
//  unreviewed door, byte-identical on a rerun. Plus the route: story-shaped
//  questions reach the story door; the live seven keep their shapes.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P4-U4 — story gold (chain + gap + contradiction, all surfaced)", .serialized)
@MainActor
struct StoryGoldTests {

    private let clock = Date(timeIntervalSince1970: 1_788_220_800)   // the pinned witness clock

    private func rig() async throws -> (db: Database, anchors: [Entity], engine: HistoryReconstructionEngine) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])

        // The anchor: the one patent on file.
        let grantLetter = UUID()
        let anchorID = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, ?, 'patentnumber|555489', 'patentnumber|555489', ?, 0.95, '{}', 'T1');
        """, [.uuid(anchorID), .text(Entity.Kind.identifierAnchor.rawValue), .uuid(grantLetter)])

        // The known chain + the contradiction (same title, dates 17 days apart,
        // from TWO INDEPENDENT documents — the detector's independence law) +
        // a years-long silence between filing and hearing (the gap).
        let feeReceipt = UUID()
        func event(_ title: String, _ epoch: TimeInterval, source: UUID) async throws {
            let id = UUID()
            try await db.exec("""
            INSERT INTO events (id, kind, date, title, source_object_id, confidence)
            VALUES (?, 'contractSigned', ?, ?, ?, 0.9);
            """, [.uuid(id), .real(epoch), .text(title), .uuid(source)])
            try await db.exec("INSERT INTO event_entities (event_id, entity_id) VALUES (?, ?);",
                              [.uuid(id), .uuid(anchorID)])
        }
        try await event("Patent filed", 1_553_126_400, source: grantLetter)   // 2019-03-21
        try await event("Hearing held", 1_722_816_000, source: grantLetter)   // 2024-08-05 (5-year silence)
        try await event("Patent granted", 1_732_752_000, source: grantLetter) // 2024-11-28
        try await event("Patent granted", 1_734_220_800, source: feeReceipt)  // 2024-12-15 — the second account

        let entities = EntitiesRepository(database: db)
        let engine = HistoryReconstructionEngine(
            entities: entities, events: EventsRepository(database: db),
            assertions: AssertionsRepository(database: db), genericFacts: GenericFactRepository(database: db),
            relationships: RelationshipsRepository(database: db), clock: { self.clock })
        return (db, try await entities.allAnchors(), engine)
    }

    @Test("The seeded archive tells its story: chain chaptered, silence gapped, grant dates in conflict — and a rerun is byte-identical")
    func storyGold() async throws {
        let (db, anchors, engine) = try await rig()
        let entities = EntitiesRepository(database: db)
        let resolution = try await HistorySubjectResolver(entities: entities)
            .resolveStory(question: "tell me the story of the patent", anchors: anchors)
        guard case .resolved(let subject, let anchorKey) = resolution else {
            Issue.record("expected resolved, got \(resolution)"); return
        }
        #expect(anchorKey == "patentnumber|555489")

        var result: HistoryReconstructionResult?
        for await update in engine.reconstruct(subject: subject.subject, request: HistoryRequest()) {
            if case .verified(let r) = update { result = r }
        }
        let story = try #require(result)

        // The chain is chaptered and chronological.
        #expect(story.outline.items.count == 4)
        #expect(story.outline.everyItemChaptered)
        let titles = story.outline.items.compactMap { $0.title }
        #expect(titles.first?.contains("filed") == true)

        // The gap: the 5-year silence surfaces, typed.
        #expect(story.outline.gaps.contains { $0.kind == .silentPeriod },
                "the silence between filing and hearing is SHOWN")

        // The contradiction: both grant dates preserved, never averaged.
        #expect(!story.outline.contradictions.isEmpty,
                "two grant dates = a conflict shown to the user")

        // Rendering: every span stands on a named item (cited-or-marked).
        let narrative = HistoryNarrativeRenderer().render(outline: story.outline)
        for chapter in narrative.chapters {
            let spans = try #require(chapter.spans)
            #expect(spans.allSatisfy { !$0.itemIDs.isEmpty })
        }
        // The story's number is the ledger's number (rung-1 agreement law).
        #expect(subject.displayName.contains("555489"))

        // Persistence through the unreviewed door, dedup'd on the rerun.
        let repo = HistoryArtifactRepository(database: db)
        let stamp = try await repo.currentLedgerStamp()
        let first = try await repo.save(story, narrative: narrative, at: clock,
                                        reviewState: "unreviewed", anchorKey: anchorKey,
                                        requestShape: "story", ledgerStamp: stamp)
        #expect(try await repo.existingCurrent(anchorKey: anchorKey, requestShape: "story",
                                               ledgerStamp: stamp) == first)

        // Rerun: the whole story is byte-identical.
        var rerun: HistoryReconstructionResult?
        for await update in engine.reconstruct(subject: subject.subject, request: HistoryRequest()) {
            if case .verified(let r) = update { rerun = r }
        }
        let narrative2 = HistoryNarrativeRenderer().render(outline: try #require(rerun).outline)
        #expect(narrative2 == narrative, "same ledger → same story, byte for byte")
    }

    @Test("Routing: story questions reach the story shape; the live seven keep theirs")
    func storyRouting() {
        #expect(QuestionShapeRouter.route("tell me the story of the patent").shape == .story)
        #expect(QuestionShapeRouter.route("what is the story of invoice 7741").shape == .story)
        // The live seven are untouched (reseal #7 predicted-diff: NONE).
        #expect(QuestionShapeRouter.route("what is the granted patent number").shape == .unresolved)
        #expect(QuestionShapeRouter.route("what is the application number").shape == .unresolved)
        #expect(QuestionShapeRouter.route("on which date was the patent granted").shape == .unresolved)
        #expect(QuestionShapeRouter.route("who is Shirshendu Sasmal").shape == .unresolved)
        #expect(QuestionShapeRouter.route("how many hearings were there").shape == .count)
        #expect(QuestionShapeRouter.route("is there any invoice from Khurana and Khurana").shape == .existence)
        #expect(QuestionShapeRouter.route("what is the capital of France").shape == .outOfScope)
    }
}
