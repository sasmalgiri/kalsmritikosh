//
//  LedgerDrainCoordinatorTests.swift
//  KalsmritikoshTests
//
//  V5 (F7) commit A — the drain's fixture proofs: a REAL ingested ledger is
//  aged into the legacy shape (v0 facts, unbound subjects, no anchors, stale
//  events, NULL document_class, a junk register entry), then drained.
//  Proofs: everything reaches the current eras; the junk retires; anchors are
//  born and facts bind to them; a SECOND run is a no-op (resume marker =
//  producer_version); chunks / FTS index / embeddings are provably untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V5 — LedgerDrainCoordinator (the drain)", .serialized)
struct LedgerDrainCoordinatorTests {

    private struct Rig {
        let db: Database
        let objects: KnowledgeObjectRepository
        let entities: EntitiesRepository
        let events: EventsRepository
        let facts: GenericFactRepository
        let evidence: EvidenceStore
        let dir: URL
        var drain: LedgerDrainCoordinator {
            LedgerDrainCoordinator(database: db, objects: objects, entities: entities,
                                   events: events, facts: facts, evidence: evidence)
        }
    }

    /// Real ingest of the grant letter + an invoice email, then AGED to legacy.
    @MainActor
    private func makeAgedRig() async throws -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        let objects = KnowledgeObjectRepository(database: db)
        let entities = EntitiesRepository(database: db)
        let events = EventsRepository(database: db)
        let facts = GenericFactRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(),
            entityQualityGate: EntityQualityGate(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects, chunks: ChunksRepository(database: db),
            entities: entities, events: events, evidenceStore: evidence, genericFacts: facts,
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db)))

        let gen = NoiseFixtureGenerator()
        for (name, text) in [("grant.md", gen.noisyGrantLetter),
                             ("invoice.txt", "Invoice number INV-42, invoice dated 5 May 2024. Amount due ₹20,000. Bill to: Orchid Ltd.")] {
            let url = dir.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            _ = try await coordinator.ingest(fileAt: url)
        }

        // ── AGE to legacy: v0 facts (unbound, fused-era), no anchors, stale
        //    events, NULL document_class, plus a junk register ghost. ─────────
        try await db.exec("UPDATE generic_facts SET producer_version = NULL, subject_id = NULL;", [])
        try await db.exec("UPDATE events SET producer_version = NULL;", [])
        try await db.exec("UPDATE knowledge_objects SET document_class = NULL;", [])
        try await db.exec("DELETE FROM entities WHERE kind = 'identifierAnchor';", [])
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///ghost"), .text("txt")])
        let ghostKO = UUID()
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, document_class)
        VALUES (?, ?, 'txt', 'ghost body', 0, 0, 'other');
        """, [.uuid(ghostKO), .uuid(fileID)])
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
        VALUES (?, 'person', 'Nil Nil', 'nil nil', ?, 0.4);
        """, [.uuid(UUID()), .uuid(ghostKO)])
        return Rig(db: db, objects: objects, entities: entities, events: events,
                   facts: facts, evidence: evidence, dir: dir)
    }

    @Test("The drain lifts an aged ledger to the current eras — and proves what it never touched")
    @MainActor
    func drainLiftsAgedLedger() async throws {
        let rig = try await makeAgedRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        let receipt = try await rig.drain.drain()
        print(receipt.renderLines())

        // Junk retired (the owner-blessed purge).
        #expect(receipt.entitiesRetired >= 1, "the Nil Nil ghost must retire")
        let ghosts = try await rig.db.query("SELECT COUNT(*) FROM entities WHERE value = 'Nil Nil';", [])
        #expect(Int(ghosts.first?.int(0) ?? -1) == 0)

        // Facts rewritten to the current era, identifier facts BOUND to anchors.
        #expect(receipt.factsSourcesRewritten >= 2, "both aged sources must rewrite")
        let staleFacts = try await rig.db.query(
            "SELECT COUNT(*) FROM generic_facts WHERE COALESCE(producer_version,0) != ?;",
            [.integer(Int64(DerivedProducerVersions.facts))])
        #expect(Int(staleFacts.first?.int(0) ?? -1) == 0, "no fact may remain stale")
        let unboundIdentifiers = try await rig.facts.all(pageSize: 5_000)
            .filter { FactSchemaRegistry.expectedShape(of: $0.field) == .identifier && $0.subjectID == nil }
        #expect(unboundIdentifiers.isEmpty, "identifier facts must bind to anchors: \(unboundIdentifiers.map(\.field))")
        #expect(receipt.anchorsAfter >= 1, "anchors must be born for the legacy sources")

        // Events at the current era; the patent letter carries NO commercial boilerplate.
        let staleEvents = try await rig.db.query(
            "SELECT COUNT(*) FROM events WHERE COALESCE(producer_version,0) != ?;",
            [.integer(Int64(DerivedProducerVersions.events))])
        #expect(Int(staleEvents.first?.int(0) ?? -1) == 0, "no event may remain stale")

        // document_class stamped everywhere.
        let unclassed = try await rig.db.query(
            "SELECT COUNT(*) FROM knowledge_objects WHERE document_class IS NULL;", [])
        #expect(Int(unclassed.first?.int(0) ?? -1) == 0, "every KO must carry its class after the drain")

        // The untouched proof — the drain's own receipt attests it.
        #expect(receipt.untouchedProven, "chunks/FTS/embeddings must be untouched:\n\(receipt.renderLines())")
    }

    @Test("A second drain run is a no-op — producer_version IS the resume marker")
    @MainActor
    func secondRunIsNoOp() async throws {
        let rig = try await makeAgedRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        _ = try await rig.drain.drain()
        let second = try await rig.drain.drain()
        print("SECOND RUN:\n" + second.renderLines())
        #expect(second.entitiesRetired == 0)
        #expect(second.factsSourcesRewritten == 0, "current-era facts must be skipped")
        #expect(second.factsDeleted == 0)
        #expect(second.eventKOsRewritten == 0, "current-era events must be skipped")
        #expect(second.documentClassStamped == 0)
        #expect(second.entitiesStampedV1 == 0)
        #expect(second.untouchedProven)
    }

    @Test("W-4b: an anchor whose minting facts died is swept; a bound anchor survives")
    func orphanAnchorSweep() async throws {
        let rig = try await makeAgedRig()
        defer { try? FileManager.default.removeItem(at: rig.dir) }

        // A ghost: an identifier anchor NO generic_facts row binds — the live
        // register's "ed202331019665" class after its junk fact was refreshed
        // away. The drain must sweep it, and must keep every bound anchor.
        let ghost = UUID()
        let realKO = try #require((try await rig.db.query(
            "SELECT id FROM knowledge_objects LIMIT 1;", [])).first?.uuid(0))
        try await rig.db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, ?, 'applicationnumber|ed202331019665', 'applicationnumber|ed202331019665', ?, 0.9, '{}', 'T1');
        """, [.uuid(ghost), .text(Entity.Kind.identifierAnchor.rawValue), .uuid(realKO)])

        let receipt = try await rig.drain.drain()
        #expect(receipt.orphanAnchorsSwept >= 1, "the ghost must be swept")
        let ghostLeft = Int((try await rig.db.query(
            "SELECT COUNT(*) FROM entities WHERE id = ?;", [.uuid(ghost)])).first?.int(0) ?? -1)
        #expect(ghostLeft == 0)
        // Every surviving anchor is bound to at least one fact.
        let unbound = Int((try await rig.db.query("""
        SELECT COUNT(*) FROM entities
        WHERE kind = ? AND merged_into IS NULL
          AND id NOT IN (SELECT DISTINCT subject_id FROM generic_facts WHERE subject_id IS NOT NULL);
        """, [.text(Entity.Kind.identifierAnchor.rawValue)])).first?.int(0) ?? -1)
        #expect(unbound == 0, "after the drain, no anchor floats free of its facts")
    }
}
