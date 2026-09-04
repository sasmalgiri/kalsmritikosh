//
//  StorySecondDoorTests.swift
//  Kalsmritikosh Tests
//
//  P4-U1 (GO 2 REVISED) — the story's second door. The laws:
//    · Ask-door artifacts land `unreviewed`; the Dossier's door keeps `verified`
//    · dedup by (anchor, request-shape, ledger stamp) — an unchanged ledger
//      returns the existing artifact, never a duplicate row
//    · version-stamped → stale-flagged against the CURRENT stamp, never
//      silently wrong; unstamped (pre-P4) artifacts read as stale (honesty)
//    · story subjects resolve via identifier anchors ONLY — ambiguity is
//      listed, no-anchor fails closed with the honest message
//    · a cancelled stream yields no result, so nothing persists
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P4-U1 — the story's second door (durable, honest persistence)")
struct StorySecondDoorTests {

    private let subjectID = UUID()
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func freshDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        return db
    }

    private func result() -> HistoryReconstructionResult {
        let subject = ResolvedHistorySubject(subject: .person(subjectID), displayName: "Patent 555489",
                                             canonicalEntityID: subjectID, resolutionConfidence: 1.0)
        let item = HistoryItem(subject: .person(subjectID), kind: .legalMilestone, title: "Patent granted",
                               start: TemporalValue(start: Date(timeIntervalSince1970: 1_732_752_000), precision: .day, confidence: 0.9),
                               evidenceStatus: .sourceAsserted, confidence: 0.9,
                               evidence: [EvidenceReference(objectID: UUID())])
        let outline = HistoryOutline(
            subject: subject, corpusSnapshotID: nil, items: [item],
            chapters: [HistoryChapterPlan(ordinal: 0, title: "2024", itemIDs: [item.id])],
            actors: [subjectID], relationships: [],
            coverage: HistoryCoverage(totalItems: 1, datedItems: 1, undatedItems: 0,
                                      earliest: Date(timeIntervalSince1970: 1_732_752_000), latest: nil,
                                      evidenceObjectCount: 1, assertionCount: 0, genericFactCount: 0, eventCount: 1),
            gaps: [])
        return HistoryReconstructionResult(subject: subject, outline: outline, claims: [],
                                           engineVersion: "history-engine-1", generatedAt: clock)
    }

    @discardableResult
    private func seedAnchor(_ db: Database, field: String, canon: String, source: UUID) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, ?, ?, ?, ?, 0.95, '{}', 'T1');
        """, [.uuid(id), .text(Entity.Kind.identifierAnchor.rawValue),
              .text("\(field)|\(canon)"), .text("\(field)|\(canon)"), .uuid(source)])
        return id
    }

    // MARK: - the two doors

    @Test("Ask door lands unreviewed + stamped; same triple dedups; Dossier door keeps verified")
    func twoDoors() async throws {
        let db = try await freshDB()
        let repo = HistoryArtifactRepository(database: db)
        let stamp = try await repo.currentLedgerStamp()

        // Ask door.
        let askID = try await repo.save(result(), at: clock, reviewState: "unreviewed",
                                        anchorKey: "patentnumber|555489",
                                        requestShape: "story", ledgerStamp: stamp)
        let ask = try #require(try await repo.header(id: askID))
        #expect(ask.reviewState == "unreviewed")
        #expect(ask.anchorKey == "patentnumber|555489")
        #expect(ask.requestShape == "story")
        #expect(ask.ledgerStamp == stamp)
        #expect(!ask.isStale(currentLedgerStamp: stamp), "built on this ledger — fresh")

        // Dedup: the same story on the same ledger returns the SAME artifact.
        let hit = try await repo.existingCurrent(anchorKey: "patentnumber|555489",
                                                 requestShape: "story", ledgerStamp: stamp)
        #expect(hit == askID)

        // Dossier door: historical default untouched — verified, no triple.
        let dossierID = try await repo.save(result(), at: clock)
        let dossier = try #require(try await repo.header(id: dossierID))
        #expect(dossier.reviewState == "verified")
        #expect(dossier.anchorKey == nil)
        #expect(dossier.isStale(currentLedgerStamp: stamp), "unstamped reads as stale — honesty over flattery")
    }

    @Test("A ledger change flips staleness and reopens the dedup window")
    func stalenessFollowsTheLedger() async throws {
        let db = try await freshDB()
        let repo = HistoryArtifactRepository(database: db)
        let stamp1 = try await repo.currentLedgerStamp()
        let id = try await repo.save(result(), at: clock, reviewState: "unreviewed",
                                     anchorKey: "patentnumber|555489",
                                     requestShape: "story", ledgerStamp: stamp1)

        // The ledger changes: a new document arrives.
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/new.pdf', 'pdf');", [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'pdf', 'fresh evidence', 100, 100);
        """, [.uuid(UUID()), .uuid(fileID)])

        let stamp2 = try await repo.currentLedgerStamp()
        #expect(stamp1 != stamp2, "the stamp moves with the ledger")
        let artifact = try #require(try await repo.header(id: id))
        #expect(artifact.isStale(currentLedgerStamp: stamp2), "shown as possibly out of date — never silently wrong")
        // Dedup no longer matches — a rebuild on the new ledger is allowed;
        // the old artifact stays loadable (preserve-not-delete).
        let hit = try await repo.existingCurrent(anchorKey: "patentnumber|555489",
                                                 requestShape: "story", ledgerStamp: stamp2)
        #expect(hit == nil)
        #expect(try await repo.header(id: id) != nil)
    }

    // MARK: - the widened resolver (identifier anchors only)

    @Test("Story subjects resolve via anchors; ambiguity is listed; no anchor fails closed")
    func storyResolverLaws() async throws {
        let db = try await freshDB()
        let entities = EntitiesRepository(database: db)
        let resolver = HistorySubjectResolver(entities: entities)
        let grantLetter = UUID()
        try await seedAnchor(db, field: "patentnumber", canon: "555489", source: grantLetter)

        // One patent on file → "the patent" resolves to its anchor, and the
        // anchor's source document rides as evidence.
        let anchors1 = try await entities.allAnchors()
        let one = try await resolver.resolveStory(question: "tell me the story of the patent", anchors: anchors1)
        guard case .resolved(let subject, let key) = one else {
            Issue.record("expected resolved, got \(one)"); return
        }
        #expect(key == "patentnumber|555489")
        #expect(subject.matchedEvidenceObjectIDs.contains(grantLetter))

        // Two patents → listed, never guessed.
        try await seedAnchor(db, field: "patentnumber", canon: "888001", source: UUID())
        let anchors2 = try await entities.allAnchors()
        let two = try await resolver.resolveStory(question: "tell me the story of the patent", anchors: anchors2)
        guard case .ambiguous(let message) = two else {
            Issue.record("expected ambiguous, got \(two)"); return
        }
        #expect(message.contains("2"))

        // No anchor referent → fail-closed, honest message.
        let none = try await resolver.resolveStory(question: "tell me the story of my life", anchors: anchors2)
        guard case .notResolvable(let honest) = none else {
            Issue.record("expected notResolvable, got \(none)"); return
        }
        #expect(honest.contains("anchor"))
    }

    // MARK: - cancelled streams persist nothing

    @Test("A stream abandoned before its verified result persists no artifact")
    func cancelledStreamPersistsNothing() async throws {
        let db = try await freshDB()
        let subject = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, 'person', 'Subject A', 'subject a', ?, 0.9, '{}', 'T2');
        """, [.uuid(subject), .uuid(UUID())])
        let engine = HistoryReconstructionEngine(
            entities: EntitiesRepository(database: db), events: EventsRepository(database: db),
            assertions: AssertionsRepository(database: db), genericFacts: GenericFactRepository(database: db),
            relationships: RelationshipsRepository(database: db), clock: { self.clock })

        // Walk away before .verified — the door needs a RESULT, and an
        // abandoned stream never yields one, so there is nothing to persist.
        for await update in engine.reconstruct(subject: .person(subject), request: HistoryRequest()) {
            if case .reconciling = update { break }
        }
        let count = (try await db.query("SELECT COUNT(*) FROM history_artifacts;", [])).first?.int(0) ?? -1
        #expect(count == 0)

        // Positive control: the completed path persists exactly one.
        let repo = HistoryArtifactRepository(database: db)
        let stamp = try await repo.currentLedgerStamp()
        _ = try await repo.save(result(), at: clock, reviewState: "unreviewed",
                                anchorKey: "patentnumber|555489", requestShape: "story", ledgerStamp: stamp)
        let after = (try await db.query("SELECT COUNT(*) FROM history_artifacts;", [])).first?.int(0) ?? -1
        #expect(after == 1)
    }
}
