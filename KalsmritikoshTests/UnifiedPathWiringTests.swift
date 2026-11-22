//
//  UnifiedPathWiringTests.swift
//  KalsmritikoshTests
//
//  Test phase T2 (2026-11-22) — the "built, not called" rows of the unified-path program (docs/UNIFIED_PATH_PROGRAM_2026-11-22.md
//  §3) that can be proven headlessly: AI-26 ComposeTwin acts, AI-28 study deeper, AI-29 the mission assessor acts on the answer,
//  AI-31 missing evidence in the briefing, AI-32 the capability catalogue in routing, AI-33 citations open at the quoted block,
//  AI-34 the AI-on release levers, AUTO-13 jobs as workflow runs, REASON-17 the scope ledger, QA-20 local measurements.
//  Scripted providers only (an on-device spy for the twin reading); no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — built pieces now wired", .serialized)
struct UnifiedPathWiringTests {

    nonisolated final class SpyProvider: ModelProvider, @unchecked Sendable {
        let id = "provider.test.t2.\(UUID().uuidString)"
        let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning]
        let manifest: ModelManifest
        private let lock = NSLock()
        private var calls = 0
        private let reply: String
        init(reply: String) {
            self.reply = reply
            manifest = ModelManifest(id: id, displayName: "Spy", capabilities: [.textGeneration, .reasoning], privacyLevel: .onDevice)
        }
        var generations: Int { lock.withLock { calls } }
        func isAvailable() async -> Bool { true }
        func generate(prompt: String, options: GenerationOptions) async throws -> String { lock.withLock { calls += 1 }; return reply }
        func embed(text: String) async throws -> [Float] { throw ModelProviderError.unavailable(providerID: id) }
    }

    nonisolated final class Count: @unchecked Sendable {
        private let l = NSLock(); private var n = 0
        func tick() { l.withLock { n += 1 } }
        var value: Int { l.withLock { n } }
    }

    static func registry(_ provider: SpyProvider) async -> CapabilityRegistry {
        let hw = HardwareProfile(totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824,
                                 processorCount: 8, isAppleSilicon: true, chipName: "T2Chip-\(UUID().uuidString)", hasNeuralEngine: true)
        let registry = CapabilityRegistry(hardware: hw, benchmark: PerformanceBenchmark(hardwareProfile: hw))
        await registry.register(provider)
        return registry
    }

    static func scratch(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: - AI-26 ComposeTwin acts

    @Test("AI-26: a second AI reading that disagrees marks the committed answer 'Needs review'; agreement and skips record nothing")
    func composeTwinFlags() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ledger = AnswerLedgerRepository(database: db)
        let answerID = UUID()
        try await db.exec("INSERT INTO answers (id, question, answer_state, body, created_at) VALUES (?, 'How much was paid?', 'verified', 'Paid 5,000 on 3 May.', 1);",
                          [.uuid(answerID)])
        let spy = SpyProvider(reply: "Invoice 7741 shows an amount of Rs 41,000.")
        let caps = await Self.registry(spy)
        let verdict = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) {
            await OneAI.TestOverride.$allowLocalModels.withValue(true) {
                await ComposeTwinRunner.run(question: "How much is due?", shippedAnswer: "The amount due is Rs 48,500 on invoice 7741.",
                                            snippets: ["Invoice 7741: amount Rs 41,000."], capabilities: caps)
            }
        }
        guard case .disagreed = verdict else { Issue.record("expected a disagreement, got \(verdict)"); return }
        #expect(spy.generations == 1)
        await ComposeTwinRunner.recordVerdict(verdict, answerID: answerID, ledger: ledger)
        let flags = try await ledger.reviewFlags(answerID: answerID)
        #expect(flags.count == 1 && flags[0].origin == "composeTwin" && flags[0].detail.contains("48"), "\(flags)")
        await ComposeTwinRunner.recordVerdict(.agreed, answerID: answerID, ledger: ledger)
        await ComposeTwinRunner.recordVerdict(.skipped(reason: "x"), answerID: answerID, ledger: ledger)
        await ComposeTwinRunner.recordVerdict(verdict, answerID: nil, ledger: ledger)
        #expect(try await ledger.reviewFlags(answerID: answerID).count == 1, "only a disagreement on a committed answer marks it")
        let body = try await db.query("SELECT body FROM answers WHERE id = ?;", [.uuid(answerID)]).first?.string(0)
        #expect(body == "Paid 5,000 on 3 May.", "the answer itself is never rewritten")
        #expect(await ComposeTwinRunner.run(question: "q", shippedAnswer: "a", snippets: [], capabilities: caps) == .skipped(reason: "no evidence excerpts to re-read"))
    }

    // MARK: - AI-28 study deeper

    @Test("AI-28: 'Study deeper' distils the named subject now (no ingest-time escalator trigger) and writes its memory")
    @MainActor
    func studyDeeper() async throws {
        let dir = try Self.scratch("study")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest), db = try #require(state.database)
        let file = dir.appendingPathComponent("s.txt")
        try Data("On 3 March 2026 Asha Rao approved invoice INV-2041. On 9 March 2026 Asha Rao signed the delivery note for Dalmia Traders.".utf8).write(to: file)
        let r = try await ingest.ingest(fileAt: file)
        // The distiller needs a dated event about the subject (the test host's ingest may not extract one from plain text).
        if (try await db.query("SELECT COUNT(*) FROM events WHERE source_object_id = ?;", [.uuid(r.object.id)]).first?.int(0) ?? 0) == 0 {
            try await db.exec("INSERT INTO events (id, kind, date, title, source_object_id, confidence) VALUES (?, 'invoiceIssued', ?, 'Asha Rao approved invoice INV-2041', ?, 0.9);",
                              [.uuid(UUID()), .real(1_772_496_000), .uuid(r.object.id)])
        }
        #expect(await state.studyDeeper(subjects: [], triggeringObjectID: nil) == 0)
        let done = await state.studyDeeper(subjects: [(kind: .person, identifier: "Asha Rao")], triggeringObjectID: nil)
        let events = try await db.query("SELECT title FROM events;").compactMap { $0.string(0) }
        let people = try await db.query("SELECT value FROM entities WHERE kind = 'person';").compactMap { $0.string(0) }
        #expect(done == 1, "the subject was distilled (events \(events), people \(people))")
        let memories = try await db.query("SELECT COUNT(*) FROM memory_objects WHERE subject_identifier LIKE '%Asha Rao%';").first?.int(0) ?? 0
        #expect(memories >= 1)
        await state.shutdown()
    }

    // MARK: - AI-29 mission assessor acts

    @Test("AI-29: the mission assessment acts on the answer — partial lowers confidence and names what is missing; blocked with no citation refuses; satisfied leaves it")
    func missionVerdictActs() {
        let cited = VerifiedAnswer(body: "Paid 5,000.", answerText: "Paid 5,000.", citations: [.init(objectID: UUID(), snippet: "Paid 5,000")],
                                   confidence: Confidence(0.9))
        let bare = VerifiedAnswer(body: "Paid 5,000.", answerText: "Paid 5,000.", citations: [], confidence: Confidence(0.9))
        let same = MasterBrain.actOnMission(cited, .none)
        #expect(same.confidence.value == 0.9 && same.body == cited.body)
        let partial = MasterBrain.actOnMission(cited, .init(disposition: .partial, unmet: ["the payer was not found"]))
        #expect(partial.confidence.value <= 0.5 && partial.body.contains("the payer was not found"), "\(partial.body)")
        let blocked = MasterBrain.actOnMission(bare, .init(disposition: .blocked, unmet: ["no deciding document was found"]))
        #expect(blocked.refused, "blocked with nothing cited is refused")
        let blockedCited = MasterBrain.actOnMission(cited, .init(disposition: .blocked, unmet: []))
        #expect(!blockedCited.refused && blockedCited.confidence.value <= 0.33)
        let refused = VerifiedAnswer(body: "", citations: [], confidence: .zero, refused: true)
        #expect(MasterBrain.actOnMission(refused, .init(disposition: .partial, unmet: [])).refused)
    }

    // MARK: - AI-31 missing evidence

    @Test("AI-31: the briefing names what KIND of evidence is missing for each coverage gap, in neutral words")
    func missingEvidenceKinds() {
        #expect(CaseLedgerBriefing.missingKind(forReason: "not read: password protected") == .encrypted)
        #expect(CaseLedgerBriefing.missingKind(forReason: "partly read: text recognition pending") == .deferredProcessing)
        #expect(CaseLedgerBriefing.missingKind(forReason: "not read: unsupported format") == .preservedOnly)
        #expect(CaseLedgerBriefing.missingKind(forReason: "not read: file damaged") == .corrupt)
        #expect(CaseLedgerBriefing.missingKind(forReason: "withheld: privileged") == .redactedOut)
        #expect(CaseLedgerBriefing.missingKind(forReason: "unknown") == .searchedNotFound)
        var m = CaseLedgerBriefing.Material()
        m.coverageGaps = [(name: "ledger.pdf", reason: "not read: password protected")]
        let b = CaseLedgerBriefing.build(m, number: [UUID(): 1])
        let expected = MissingEvidence(requestedField: "ledger.pdf", kind: .encrypted, documentsSearched: 1).disclosure()
        #expect(b.text.contains("## Kind of evidence missing\n- " + expected), "\(b.text)")
    }

    // MARK: - AI-32 capability catalogue

    @Test("AI-32: routing prefers the capabilities the catalogue lists for the question's kind (never as a hard requirement)")
    func catalogueInRouting() async throws {
        let router = DeterministicRouter(expertRegistry: ExpertRegistry())
        for kind in [UserIntent.Kind.riskDetection, .reconstructTimeline, .factualLookup] {
            let d = try await router.route(intent: UserIntent(kind: kind, scope: .global, rawQuestion: "What happened with the shipment?"))
            let wanted = ModelCapabilityCatalog.requiredCapabilities(for: kind)
            #expect(wanted.isSubset(of: d.answerSpec.prefers.union(d.answerSpec.requires)), "\(kind): \(d.answerSpec)")
            #expect(wanted.subtracting(d.answerSpec.requires).isSubset(of: d.answerSpec.prefers))
        }
    }

    // MARK: - AI-33 citations open at the quote

    @Test("AI-33: a citation that carries only a document and a quote opens at the block holding the quote; no quote → the whole document")
    @MainActor
    func citationOpensAtQuote() async throws {
        let dir = try Self.scratch("loc")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest), evidence = try #require(state.evidenceStore)
        let file = dir.appendingPathComponent("loc.txt")
        try Data("The first paragraph is about the warehouse lease.\n\nThe second paragraph says the shipment of forty cartons left Mumbai on 4 May.\n\nThe third paragraph is the signature block.".utf8).write(to: file)
        let r = try await ingest.ingest(fileAt: file)
        let blocks = try await evidence.blocks(forObject: r.object.id)
        let block = try #require(await state.quotedBlockID(objectID: r.object.id, quote: "shipment of forty cartons left Mumbai"))
        #expect(blocks.first { $0.id == block }?.rawText.contains("forty cartons") == true, "the block that holds the quote")
        #expect(await state.quotedBlockID(objectID: r.object.id, quote: "a sentence that is not in the document") == nil)
        #expect(await state.quotedBlockID(objectID: r.object.id, quote: "short") == nil, "too short to place")
        let none = await state.sourceLocationResolver(quote: nil).locate(citation: .init(objectID: r.object.id, snippet: "x"))
        #expect(none == .wholeDocument)
        _ = await state.sourceLocationResolver(quote: "shipment of forty cartons left Mumbai").locate(citation: .init(objectID: r.object.id, snippet: "x"))
        await state.shutdown()
    }

    // MARK: - AI-34 AI levers

    @Test("AI-34: with AI on the release profile turns the generative levers on (privacy levers unchanged); with AI off the locked profile")
    func aiOnLevers() {
        let on = ReleaseCapabilityProfile.v1AIOn, off = ReleaseCapabilityProfile.v1
        #expect(on.ingestGenerativeLLMEnabled && on.memoryDistillationOnIngestEnabled && on.contextPrefixBackfillEnabled && on.firstChunkCardEnabled)
        #expect(!on.cloudRoutingEnabled && !on.ollamaUserSetupVisible && !on.byoModelUIVisible, "privacy levers unchanged")
        #expect(!off.ingestGenerativeLLMEnabled && !off.memoryDistillationOnIngestEnabled)
        let base = SystemMode.EnrichmentPolicy(eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: false)
        let pOn = ReleaseCapabilityProfile.effectiveIngestPolicy(base, profile: on)
        #expect(pOn.eagerMemoryDistillation && pOn.contextPrefixBackfill && pOn.firstChunkCard)
        let pOff = ReleaseCapabilityProfile.effectiveIngestPolicy(base, profile: off)
        #expect(!pOff.eagerMemoryDistillation && !pOff.contextPrefixBackfill && !pOff.firstChunkCard, "AI off: exactly the engine's policy")
        OneAI.TestOverride.$setUp.withValue(true) { #expect(ReleaseCapabilityProfile.current().ingestGenerativeLLMEnabled) }
        OneAI.TestOverride.$setUp.withValue(false) { #expect(!ReleaseCapabilityProfile.current().ingestGenerativeLLMEnabled) }
    }

    // MARK: - AUTO-13 jobs as workflow runs

    @Test("AUTO-13: a job with a workspace runs as a workflow run — the old job path is the step, run once, and the run is recorded")
    func jobAsWorkflowRun() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let runner = PersonaJobWorkflowRunner(database: db)
        let job = PersonaJob(persona: "investigator", id: "t2.job", title: "Chronology", detail: "d", kind: .ask)
        let calls = Count()
        let launch = try await runner.run(job: job, context: PersonaJobLaunchContext(workspaceID: ws, actor: "tester", at: Date()), workspaceID: ws) {
            calls.tick()
            return PersonaJobLaunch(job: job, summary: "Chronology made")
        }
        #expect(calls.value == 1, "the job ran once, as the step")
        #expect(launch.summary.hasPrefix("Chronology made") && launch.summary.contains("Recorded as workflow run"), "\(launch.summary)")
        let runs = try await db.query("SELECT COUNT(*) FROM workflow_runs WHERE workspace_id = ?;", [.uuid(ws)]).first?.int(0) ?? 0
        #expect(runs == 1)
    }

    // MARK: - REASON-17 scope ledger

    @Test("REASON-17: a case's work product is recorded under the scope it was made in, and shows stale after the case's sources change")
    func scopeLedgerStale() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db), evidence = EvidenceStore(database: db)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = try await cases.createCase(workspaceID: ws, title: "Smith", actor: "u", at: t0)
        c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: UUID().uuidString, sourceKind: .sourceVersion, actor: "u", at: t0)
        let service = InvestigationAnswerService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence),
                                                 baseRetriever: CaseWholeReadingTests.EmptyRetriever(), evidence: evidence,
                                                 makeBrain: { MasterBrain(retriever: $0) }, scopeLedger: InvestigationScopeLedger(database: db))
        let output = UUID()
        try await db.exec("""
            INSERT INTO case_document_outputs (id, case_id, kind, route, snapshot_sha256, status, released_by, released_at)
            VALUES (?, ?, 'report', 'file', 'abc', 'released', 'u', 1);
            """, [.uuid(output), .uuid(c.id)])
        let first = try await service.scopeArtifactStatus(caseID: c.id)
        let item = try #require(first.first { $0.artifactID.uppercased() == output.uuidString.uppercased() })
        #expect(item.kind == .workProduct && !item.stale)
        #expect(try await service.scopeArtifactStatus(caseID: c.id).count == first.count, "recorded once")
        _ = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: UUID().uuidString, sourceKind: .sourceVersion, actor: "u", at: t0)
        let after = try await service.scopeArtifactStatus(caseID: c.id)
        #expect(after.first { $0.id == item.id }?.stale == true, "the scope changed since it was made")
    }

    // MARK: - QA-20 local measurements

    @Test("QA-20: the measurement tools run on this ledger and report counts and scores only — never document content")
    @MainActor
    func localMeasurements() async throws {
        let dir = try Self.scratch("qa20")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest)
        let file = dir.appendingPathComponent("secret.txt")
        try Data("The Zebrafinch account of Quillmoor Holdings received 4,000 on 2 June 2026.".utf8).write(to: file)
        _ = try await ingest.ingest(fileAt: file)
        let lines = [await state.measureRetrievalEval(), await state.measureRetrievalGold(), await state.measureErrorAnalysis(), await state.measureANN()]
        for l in lines {
            #expect(!l.isEmpty && !l.contains("Zebrafinch") && !l.contains("Quillmoor"), "\(l)")
        }
        #expect(lines[0].hasPrefix("keyword layer — recall@10") || lines[0].hasPrefix("Not run"), "\(lines[0])")
        #expect(lines[3].contains("vectors — query p50"), "\(lines[3])")
        await state.shutdown()
    }
}
