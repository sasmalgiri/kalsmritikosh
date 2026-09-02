//
//  PatentSlotGoldTests.swift
//  KalsmritikoshTests
//
//  D-16 (P0 answer-quality pack) — the patent gold pack, end to end through
//  the REAL ingest pipeline, REAL retriever, and REAL verifier (no LLM):
//  the 28 Aug screenshot's two questions, replayed against a SYNTHETIC
//  IPO-style grant letter (never the owner's real certificate — fixture
//  content ships in test code only). The letter is phrased so the
//  PatentLegalEventExtractor triggers fire and PatentDomainPack extracts
//  all three number fields plus the grant/filing dates.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("D-16 — patent slot gold pack (real ingest, deterministic)", .serialized)
@MainActor
struct PatentSlotGoldTests {

    /// Synthetic IPO-style grant letter. All numbers invented.
    static let grantLetter = """
    # Intellectual Property Office — Letter of Grant

    In the matter of the application for patent filed by Nila Instruments Pvt Ltd,
    the patent is hereby granted and recorded in the Register of Patents.

    Application No. 202499055555
    Patent No. 900123
    Date of Filing : 11 March 2023
    Date of Grant : 17 June 2025

    The first examination report was answered in full. This letter accompanies
    the letters patent certificate issued to the applicant.
    """

    /// Variant WITHOUT a grant date — drives the D-15 honest not-found.
    static let grantLetterNoDate = """
    # Intellectual Property Office — Letter of Grant

    In the matter of the application for patent filed by Nila Instruments Pvt Ltd,
    the patent is hereby granted and recorded in the Register of Patents.

    Application No. 202499055555
    Patent No. 900123
    Date of Filing : 11 March 2023
    """

    // MARK: - Rig (RetrievalGoldEvalTests pattern: real ingest + real retriever)

    private struct Rig {
        let db: Database
        let retriever: HybridRetriever
        let verifier: EvidenceVerifier
        let dir: URL
    }

    private func makeRig(document: String, name: String) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("patentgold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try document.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)

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
            genericFacts: GenericFactRepository(database: db),
            readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: intake)
        _ = try await coordinator.ingest(fileAt: dir.appendingPathComponent(name))

        let retriever = HybridRetriever(
            memory: MemoryRepository(database: db),
            events: events,
            entities: entities,
            chunks: chunks,
            summaries: SummariesRepository(database: db),
            graph: GraphStore(relationships: RelationshipsRepository(database: db)),
            vectors: SQLiteVectorStore(database: db, modelID: "apple.nl.v1"),
            embedder: NLEmbedder(),
            objects: objects,
            genericFacts: GenericFactRepository(database: db))
        // The answerability floor is tuned for the full pipeline's hybrid
        // scores; this deterministic rig has no vector layer, so its FTS-only
        // scores sit below the production floor. The gold pins the SLOT-path
        // behavior, not the answerability tuning — open the gate.
        return Rig(db: db, retriever: retriever,
                   verifier: EvidenceVerifier(answerabilityMinRetrievalScore: 0.0), dir: dir)
    }

    /// One question through retrieval → deterministic fact findings → verifier.
    private func answer(_ rig: Rig, _ question: String) async throws -> VerifiedAnswer {
        // The REAL rule-based detector, so entity hints/keywords feed the
        // deterministic retrieval layers exactly as in production.
        let intent = (try? await RuleIntentDetector().detect(question: question))
            ?? UserIntent(kind: .factualLookup, scope: .global, rawQuestion: question)
        let retrieval = try await rig.retriever.retrieve(for: intent, layers: [])
        let claims = ReasoningExpert.factClaims(from: retrieval)
        let findings = ExpertFindings(
            expertID: "expert.reasoning", claims: claims,
            confidence: claims.isEmpty ? .zero : .medium, droppedUnverifiable: 0)
        return try await rig.verifier.verify(intent: intent, findings: [findings], retrieval: retrieval)
    }

    // MARK: - Gold questions

    @Test("The screenshot's question: granted patent number → one cited sentence, no dump, no note")
    func grantedPatentNumber() async throws {
        let rig = try await makeRig(document: Self.grantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await answer(rig, "what is the granted patent number")
        print("GOLD patent-number: refused=\(a.refused) conf=\(a.confidence.value) text=\(a.answerText ?? "nil")")
        #expect(!a.refused)
        // The value keeps its full matched text; the label is suppressed
        // because the value already carries it.
        #expect(a.answerText == "Patent No. 900123.")
        #expect(a.answerText?.contains("202499055555") == false, "application number leaked into the primary answer")
        #expect(a.body.contains("Reported:") == false, "assertion dump leaked into the body")
        #expect(a.body.contains("experts disagreed") == false)
        #expect(!a.citations.isEmpty)
        #expect(a.confidence.value >= 0.6, "slot answer confidence \(a.confidence.value)")
    }

    @Test("Application number resolves to its own field")
    func applicationNumber() async throws {
        let rig = try await makeRig(document: Self.grantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await answer(rig, "what is the application number")
        #expect(!a.refused)
        #expect(a.answerText == "Application No. 202499055555.")
        #expect(!a.citations.isEmpty)
    }

    @Test("Grant date answers from the certificate")
    func grantDate() async throws {
        let rig = try await makeRig(document: Self.grantLetter, name: "grant-letter.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await answer(rig, "on which date was the patent granted")
        #expect(!a.refused)
        // V2 date canon (enumerated gold change, owner binding 2026-09-01): a
        // v1 grant date stores precision-aware ISO and renders the seal-anchored
        // day form DD/MM/YYYY — "17 June 2025" → "17/06/2025". Surface-gold-
        // unchanged is scoped to IDENTIFIER fields; date surfaces move to canon.
        #expect(a.answerText?.contains("17/06/2025") == true, "got: \(a.answerText ?? "nil")")
        #expect(a.answerText?.hasPrefix("Grant date:") == true)
    }

    @Test("The screenshot's second question: missing grant date → the honest, field-named refusal")
    func missingGrantDateHonest() async throws {
        let rig = try await makeRig(document: Self.grantLetterNoDate, name: "grant-letter-nodate.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let a = try await answer(rig, "on which date was the patent granted")
        print("GOLD not-found: refused=\(a.refused) text=\(a.answerText ?? "nil")")
        #expect(a.answerText?.contains("carries a grant date") == true, "got: \(a.answerText ?? "nil")")
        #expect(a.answerText?.contains("900123") == true, "the related evidence is not named")
        #expect(a.body.contains("Reported:") == false, "assertion dump leaked into the not-found body")
        #expect(a.body.contains("definition") == false, "the old definition label survived")
    }

    @Test("Story spine: the milestones come out filed → granted, dated and ordered")
    func storySpineOrdered() {
        let events = PatentLegalEventExtractor.extract(text: Self.grantLetter, sourceObjectID: UUID())
        let filed = events.first { ($0.attributes["milestone"]?.value).flatMap { if case .string(let s) = $0 { return s } else { return nil } } == "filed" }
        let granted = events.first { ($0.attributes["milestone"]?.value).flatMap { if case .string(let s) = $0 { return s } else { return nil } } == "granted" }
        #expect(filed != nil, "filed milestone missing: \(events.map(\.title))")
        #expect(granted != nil, "granted milestone missing: \(events.map(\.title))")
        if let filed, let granted {
            #expect(filed.date < granted.date, "milestones out of order")
        }
    }
}
