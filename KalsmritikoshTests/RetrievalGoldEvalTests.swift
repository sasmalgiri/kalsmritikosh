//
//  RetrievalGoldEvalTests.swift
//  KalsmritikoshTests
//
//  Release-gate §19 (macro F) — the CURRENT deterministic retrieval
//  evaluation against current main. Ingests the ProjectDelta fixture corpus
//  through the REAL ingest pipeline, then runs the 60-question gold set
//  through the REAL HybridRetriever (no LLM anywhere — deterministic layers:
//  FTS/metadata/entity/event/graph; the vector layer degrades gracefully with
//  no stored embeddings) and pins per-class source-recall floors. The gold
//  set + RetrievalGoldEval existed but had NO automated consumer; this test
//  is the hosted regression gate. Floors are the measured values on the
//  introduction commit minus a small tolerance — raise them when retrieval
//  improves; never lower them to hide a regression.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("§19 — 60-question deterministic retrieval gold eval", .serialized)
@MainActor
struct RetrievalGoldEvalTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // KalsmritikoshTests/
            .deletingLastPathComponent()          // repo root
    }

    @Test("ProjectDelta 60-question retrieval recall meets the recorded per-class floors")
    func goldRecallFloors() async throws {
        // ── Real ingest rig over a fresh ledger ─────────────────────────────
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("goldeval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db)
        let events = EventsRepository(database: db)
        let entities = EntitiesRepository(database: db)
        let coordinator = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: objects,
            chunks: chunks, evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: intake)

        let fixtures = repoRoot().appendingPathComponent("Kalsmritikosh/Resources/Fixtures/ProjectDelta")
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        print("GOLD-EVAL: fixtures at \(fixtures.path): \(files.map(\.lastPathComponent))")
        #expect(files.count >= 8, "ProjectDelta fixture drifted: \(files.map(\.lastPathComponent))")
        for file in files {
            do { _ = try await coordinator.ingest(fileAt: file) }
            catch {
                Issue.record("ingest \(file.lastPathComponent) failed: \(error)")
                throw error
            }
        }
        let koCount = try await objects.count()
        print("GOLD-EVAL: ingested KOs = \(koCount)")
        #expect(koCount >= 8)

        // ── Real retriever over the ingested ledger (deterministic layers) ──
        let retriever = HybridRetriever(
            memory: MemoryRepository(database: db),
            events: events,
            entities: entities,
            chunks: chunks,
            summaries: SummariesRepository(database: db),
            graph: GraphStore(relationships: RelationshipsRepository(database: db)),
            vectors: SQLiteVectorStore(database: db, modelID: "apple.nl.v1"),
            embedder: NLEmbedder(),
            objects: objects)

        // ── The 60-question gold set, straight from the repo resource ───────
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("Kalsmritikosh/Resources/Eval/questions.json"))
        let questions = try JSONDecoder().decode([EvalKitRunner.Question].self, from: data)
        #expect(questions.count == 60)

        let report = await RetrievalGoldEval().run(
            retriever: retriever, objects: objects, questions: questions)
        print("GOLD-EVAL: \(report.renderLine())")
        // Reliable metric capture regardless of console plumbing.
        try? (report.renderLine() + "\n").write(
            to: FileManager.default.temporaryDirectory.appendingPathComponent("kalsmritikosh-gold-eval.txt"),
            atomically: true, encoding: .utf8)

        // ── Floors ──────────────────────────────────────────────────────────
        // MEASURED 2026-08-07 on current main with this rig (fresh Tier-0/1
        // ingest, NO Tier-2 enrichment — no vectors/synthetic-questions/
        // QA-pairs/bond-graph/caches): lookup 0.667, aggregation 0.133,
        // temporal 0.233, multihop 0.322, overall 0.339 (n=60). These are the
        // DETERMINISTIC-LAYER floor of a just-ingested corpus — the in-app
        // pipeline with full enrichment scores far higher (eval-report-*.md).
        // Floors sit below measured to absorb OS-version drift in the Apple
        // NL entity extractor on hosted runners. Raise them when deterministic
        // retrieval improves; NEVER lower them to hide a regression.
        let floors: [String: Double] = [
            "lookup": 0.55,
            "aggregation": 0.08,
            "temporal": 0.15,
            "multihop": 0.22,
        ]
        #expect(report.total == 60)
        #expect(report.overall >= 0.28,
                "overall deterministic recall \(report.overall) fell below floor 0.28")
        for classRecall in report.byClass {
            let floor = floors[classRecall.className] ?? 0
            #expect(classRecall.recall >= floor,
                    "\(classRecall.className) recall \(classRecall.recall) fell below floor \(floor)")
        }
    }
}
