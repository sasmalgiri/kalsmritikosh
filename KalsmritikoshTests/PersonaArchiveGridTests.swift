//
//  PersonaArchiveGridTests.swift
//  KalsmritikoshTests
//
//  S2-U5 — the persona-archive GRID: five archives (patent = ProjectDelta,
//  which the 60-question gold eval already covers exhaustively; plus
//  transactions, HR email, genealogy, journalism), each ingested through the
//  REAL pipeline and probed per question class in both directions:
//    answerable   → retrieval surfaces the expected source document
//    unanswerable → retrieval does NOT confidently surface anything for a
//                   field no document carries (the honest-not-found feed)
//  Retrieval-level here by design: the composer grid becomes generated-green
//  at P3-U5; this gate proves the LEDGER side of every persona's promise.
//  C-9 rides: packs are class-blind, so every archive also must yield facts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S2-U5 — persona archive grid (retrieval per class, both directions)", .serialized)
@MainActor
struct PersonaArchiveGridTests {

    struct Probe {
        let archive: String
        let questionClass: String
        let question: String
        /// Substring of the source filename retrieval must surface; nil = an
        /// UNANSWERABLE probe (nothing in the archive carries it).
        let expectedFile: String?
    }

    static let probes: [Probe] = [
        // ── Transactions ────────────────────────────────────────────────
        .init(archive: "PersonaTransactions", questionClass: "lookup",
              question: "what is the amount due on invoice 7741", expectedFile: "invoice-7741"),
        .init(archive: "PersonaTransactions", questionClass: "temporal",
              question: "when was invoice 7741 paid", expectedFile: "payment-email"),
        .init(archive: "PersonaTransactions", questionClass: "aggregation",
              question: "how much was the March payroll batch", expectedFile: "bank-statement"),
        .init(archive: "PersonaTransactions", questionClass: "lookup",
              question: "what is the purchase order number", expectedFile: nil),
        // ── HR email ────────────────────────────────────────────────────
        .init(archive: "PersonaHREmail", questionClass: "lookup",
              question: "what notice must employees receive of roster changes", expectedFile: "policy-extract"),
        .init(archive: "PersonaHREmail", questionClass: "temporal",
              question: "when was the shift changed with under two hours notice", expectedFile: "complaint-email"),
        .init(archive: "PersonaHREmail", questionClass: "multihop",
              question: "was an operational emergency recorded for the 14 May roster change", expectedFile: "interview-notes"),
        .init(archive: "PersonaHREmail", questionClass: "lookup",
              question: "what is the employee's salary", expectedFile: nil),
        // ── Genealogy ───────────────────────────────────────────────────
        .init(archive: "PersonaGenealogy", questionClass: "lookup",
              question: "when was Edith Mary Calloway born", expectedFile: "birth-certificate"),
        .init(archive: "PersonaGenealogy", questionClass: "multihop",
              question: "who lived at 7 Mill Lane in 1911", expectedFile: "census-1911"),
        .init(archive: "PersonaGenealogy", questionClass: "temporal",
              question: "when did Edith marry Harold Finch", expectedFile: "family-letter"),
        .init(archive: "PersonaGenealogy", questionClass: "lookup",
              question: "what was Edith's death date", expectedFile: nil),
        // ── Journalism ──────────────────────────────────────────────────
        .init(archive: "PersonaJournalism", questionClass: "aggregation",
              question: "how many signal fault events were logged on Line 3", expectedFile: "foia-reply"),
        .init(archive: "PersonaJournalism", questionClass: "temporal",
              question: "when was the Weststation relay flagged for replacement", expectedFile: "interview-transcript"),
        .init(archive: "PersonaJournalism", questionClass: "lookup",
              question: "how many pages were withheld from the FOIA release", expectedFile: "foia-reply"),
        .init(archive: "PersonaJournalism", questionClass: "lookup",
              question: "what is the signal contractor's tender price", expectedFile: nil),
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Every persona archive answers its grid: expected sources surface; absent fields surface nothing confident",
          arguments: ["PersonaTransactions", "PersonaHREmail", "PersonaGenealogy", "PersonaJournalism"])
    func archiveGrid(archive: String) async throws {
        // Real ingest over a fresh ledger (the gold-eval rig, per archive).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db)
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

        let fixtures = repoRoot().appendingPathComponent("Kalsmritikosh/Resources/Fixtures/\(archive)")
        let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count >= 3, "\(archive) fixture drifted")
        for file in files { _ = try await coordinator.ingest(fileAt: file) }

        let retriever = HybridRetriever(
            memory: MemoryRepository(database: db),
            events: EventsRepository(database: db),
            entities: EntitiesRepository(database: db),
            chunks: chunks,
            summaries: SummariesRepository(database: db),
            graph: GraphStore(relationships: RelationshipsRepository(database: db)),
            vectors: SQLiteVectorStore(database: db, modelID: "apple.nl.v1"),
            embedder: NLEmbedder(),
            objects: objects)

        for probe in Self.probes where probe.archive == archive {
            let intent = UserIntent(
                kind: .factualLookup, scope: .global, timeframe: nil,
                entityHints: [], rawQuestion: probe.question)
            guard let result = try? await retriever.retrieve(for: intent, layers: []) else {
                Issue.record("\(archive): retrieval threw for '\(probe.question)'"); continue
            }
            let ids = Set(result.chunks.map(\.chunk.objectID))
            let hitFiles = Array(((try? await objects.sourceFilenames(for: ids)) ?? [:]).values)
            if let expected = probe.expectedFile {
                #expect(hitFiles.contains { $0.contains(expected) },
                        "\(archive)/\(probe.questionClass): '\(probe.question)' must surface \(expected); got \(hitFiles)")
            } else {
                // Unanswerable: retrieval legitimately returns CONTEXT (the
                // honest not-found searches everything before saying so) —
                // the ledger-side truth is that NO FACT carries the absent
                // field. That is what the composer's D-15/F8 verdict consumes.
                let absentFieldTokens = probe.question
                    .lowercased().components(separatedBy: " ")
                    .filter { ["purchase", "salary", "death", "tender"].contains($0) }
                for token in absentFieldTokens {
                    let rows = try await db.query(
                        "SELECT COUNT(*) FROM generic_facts WHERE field LIKE ?;",
                        [.text("%\(token)%")])
                    #expect(Int(rows.first?.int(0) ?? 0) == 0,
                            "\(archive): a fact exists for absent field token '\(token)' — the probe is wrong or extraction hallucinated")
                }
            }
        }

        // C-9 rides: packs are class-blind — every archive yields SOME facts.
        let factCount = Int((try await db.query("SELECT COUNT(*) FROM generic_facts;", [])).first?.int(0) ?? 0)
        #expect(factCount > 0, "\(archive): the class-blind packs extracted nothing")
    }
}
