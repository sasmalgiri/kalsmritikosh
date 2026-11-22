//
//  UnifiedPathRound2Tests.swift
//  KalsmritikoshTests
//
//  Test phase T3 (2026-11-22) — the round-2 rows of the unified-path program (docs/UNIFIED_PATH_PROGRAM_2026-11-22.md §4,
//  spec §6.x): AI-36 one AI, AI-37 AI suggestions, AI-38 briefing from every source, AI-39 batch reads that survive a quit,
//  PERF-19 stage workers, PERF-20 shard merge limits, IN-27 extraction backlog, and the QA-21 erasure item (reference
//  shelf, suggestions and batch jobs cleared by a person erasure). Scripted providers and transports only; ephemeral
//  ledgers; no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — round 2", .serialized)
struct UnifiedPathRound2Tests {

    static func scratch(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @MainActor
    static func booted(_ dir: URL) async -> AppState {
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: dir.appendingPathComponent("ledger.sqlite"))
        return state
    }

    static func json(_ object: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    nonisolated final class SpyProvider: ModelProvider, @unchecked Sendable {
        let id: String
        let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning]
        let manifest: ModelManifest
        private let lock = NSLock(); private var calls = 0
        init(id: String, privacy: PrivacyLevel = .onDevice) {
            self.id = id
            manifest = ModelManifest(id: id, displayName: "Spy", capabilities: [.textGeneration, .reasoning], privacyLevel: privacy)
        }
        var generations: Int { lock.withLock { calls } }
        func isAvailable() async -> Bool { true }
        func generate(prompt: String, options: GenerationOptions) async throws -> String { lock.withLock { calls += 1 }; return "ok" }
        func embed(text: String) async throws -> [Float] { throw ModelProviderError.unavailable(providerID: id) }
    }

    static func registry(_ providers: [SpyProvider]) async -> CapabilityRegistry {
        let hw = HardwareProfile(totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824,
                                 processorCount: 8, isAppleSilicon: true, chipName: "T3Chip-\(UUID().uuidString)", hasNeuralEngine: true)
        let registry = CapabilityRegistry(hardware: hw, benchmark: PerformanceBenchmark(hardwareProfile: hw))
        for p in providers { await registry.register(p) }
        return registry
    }

    // MARK: - AI-36 one AI

    @Test("AI-36: the on-device / local / stub generative providers are never resolved as an AI; a declined import resolves no generative capability; an allowed import is the permission for undeclared cloud work")
    func oneAI() async throws {
        #expect(OneAI.isRetiredGenerative(id: "provider.system.languageModel", capabilities: [.textGeneration]))
        #expect(OneAI.isRetiredGenerative(id: "provider.local.ollama", capabilities: [.textGeneration, .reasoning]))
        #expect(OneAI.isRetiredGenerative(id: "provider.cloud", capabilities: [.textGeneration]))
        #expect(!OneAI.isRetiredGenerative(id: "provider.local.embedder", capabilities: [.embedding]), "embedders are not an AI")
        #expect(!OneAI.isRetiredGenerative(id: "provider.online.anthropic", capabilities: [.textGeneration]))

        let retired = SpyProvider(id: "provider.local.t3-\(UUID().uuidString)")
        let onlyRetired = await Self.registry([retired])
        await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) {
            await #expect(throws: (any Error).self, "a retired local model is not the AI") { _ = try await onlyRetired.resolve(.textGeneration(purpose: "t3")) }
            await OneAI.TestOverride.$allowLocalModels.withValue(true) {
                let p = try? await onlyRetired.resolve(.textGeneration(purpose: "t3"))
                #expect(p?.id == retired.id, "the test-only switch still reaches it")
            }
        }
        let other = SpyProvider(id: "provider.test.t3-\(UUID().uuidString)")
        let registry = await Self.registry([other])
        await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) {
            #expect((try? await registry.resolve(.textGeneration(purpose: "t3")))?.id == other.id)
            await ImportAIPermission.$scope.withValue(.init(allowed: false)) {
                await #expect(throws: (any Error).self, "inside a declined import no generative capability resolves") {
                    _ = try await registry.resolve(.textGeneration(purpose: "t3"))
                }
                #expect(!ImportAIPermission.allowsAIHere)
            }
            await ImportAIPermission.$scope.withValue(.init(allowed: true)) { #expect(ImportAIPermission.allowsAIHere) }
        }
        // Undeclared (on-device) generative work reaches a cloud provider only inside an allowed import; embeddings never.
        let undeclared = CapabilitySpec.textGeneration(purpose: "ingest")
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: undeclared, cloudAllowed: true, importGranted: false))
        #expect(CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: undeclared, cloudAllowed: true, importGranted: true))
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: undeclared, cloudAllowed: false, importGranted: true), "Online off: never")
        #expect(!CapabilityRegistry.cloudEligible(providerPrivacy: .cloud, spec: .embedding(purpose: "x"), cloudAllowed: true, importGranted: true))
    }

    @Test("AI-36: the import permission is asked once, not asked when AI is not set up, kept across launches; the cost estimate counts the text the files hold")
    @MainActor
    func importPermission() async throws {
        let saved = UserDefaults.standard.dictionary(forKey: ImportAIPermission.defaultsKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: ImportAIPermission.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: ImportAIPermission.defaultsKey) }
        }
        let dir = try Self.scratch("importai")
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = await OneAI.TestOverride.$setUp.withValue(false) { await ImportAIConsent.decide(for: [dir]) }
        #expect(!g.allowed && ImportAIConsent.shared.pending == nil, "not set up: nothing asked, the import runs without AI")
        let d = UserDefaults.standard.dictionary(forKey: ImportAIPermission.defaultsKey)
        #expect(d?["allowed"] as? Bool == false, "the decision is kept for the background work after a relaunch")
        ImportAIPermission.record(.init(allowed: true))
        #expect(ImportAIPermission.lastDecision?.allowed == true)
        let lastAllowed = await ImportAIPermission.underLastDecision { ImportAIPermission.allowsAIHere }
        #expect(lastAllowed, "background levers run under the last decision")
        let inside = await ImportAIPermission.$scope.withValue(.init(allowed: false)) {
            await ImportAIPermission.underLastDecision { ImportAIPermission.allowsAIHere }
        }
        #expect(!inside, "an import's own decision wins over the last one")

        // Estimate by kind: text whole, markup half, packaged office a quarter, an image a fixed amount, audio nothing.
        try Data(repeating: 0x61, count: 10_000).write(to: dir.appendingPathComponent("a.txt"))
        try Data(repeating: 0x61, count: 10_000).write(to: dir.appendingPathComponent("b.html"))
        try Data(repeating: 0x61, count: 10_000).write(to: dir.appendingPathComponent("c.docx"))
        try Data(repeating: 0x61, count: 10_000).write(to: dir.appendingPathComponent("d.png"))
        try Data(repeating: 0x61, count: 10_000).write(to: dir.appendingPathComponent("e.m4a"))
        let bytes = ImportAIConsent.estimatedTextBytes(of: [dir])
        #expect(bytes == 10_000 + 5_000 + 2_500 + ImportAIConsent.charactersPerImage, "\(bytes)")
        let req = ImportAIConsent.makeRequest(files: 5, bytes: bytes, capped: false)
        #expect(req.files == 5 && req.estimatedTokens > 0 && !req.estimate.isEmpty, "\(req.estimate)")
    }

    // MARK: - AI-37 AI suggestions

    @Test("AI-37: AI suggestions keep only items that cite real case documents (and quote them verbatim); at most 8 per kind; labelled AI, never evidence; inserted before the briefing's end")
    func aiSuggestionsVerify() {
        let texts = ["Invoice INV-2041 was approved by Asha Rao on 3 March 2026.", "Delivery note signed by Vikram Shah."]
        var leads: [[String: Any]] = [["text": "Check who approved INV-2041", "documents": [1], "quote": "approved by Asha Rao"],
                                      ["text": "Cites a document the case does not have", "documents": [9]],
                                      ["text": "Quote not in the cited document", "documents": [2], "quote": "approved by Asha Rao"],
                                      ["text": "No document cited", "documents": []]]
        leads += (0..<10).map { ["text": "Lead \($0)", "documents": [2]] }
        let reply = "Here you go:\n" + Self.json(["leads": leads, "questions": [["text": "Ask Vikram Shah when he signed", "documents": [2]]],
                                                 "gaps": [["text": "No payment record", "documents": [1, 2]]]])
        let out = CaseAISuggestions.verify(reply: reply, texts: texts)
        #expect(out.items.filter { $0.kind == "leads" }.count == CaseAISuggestions.perKind)
        #expect(out.items.first?.text == "Check who approved INV-2041")
        #expect(!out.items.contains { $0.text.contains("does not have") || $0.text.contains("Quote not") || $0.text == "No document cited" })
        #expect(out.dropped == 3 + 3, "three bad items, three over the cap: \(out.dropped)")
        #expect(out.section.hasPrefix("## AI suggestions (written by the AI") && out.section.contains("NOT evidence"))
        #expect(out.section.contains("- AI suggestion (gap): No payment record [D1] [D2]"))
        #expect(CaseAISuggestions.verify(reply: "not json", texts: texts).items.isEmpty)
        let briefing = "=== Case briefing ===\n- x [D1]\n=== End of the case briefing ==="
        let inserted = CaseAISuggestions.insert(out.section, into: briefing)
        #expect(inserted.hasSuffix("=== End of the case briefing ===") && inserted.contains("## AI suggestions"))
        #expect(CaseAISuggestions.insert("", into: briefing) == briefing)
    }

    @Test("AI-37: after an AI-read case answer, the suggestions read runs once per document set, is verified and kept; the kept set is not asked again; the wording says 'Set up AI'")
    func aiSuggestionsOnThePath() async throws {
        nonisolated final class Store: @unchecked Sendable {
            private let l = NSLock(); private var s: [String: String] = [:]
            func put(_ k: String, _ v: String) { l.withLock { s[k] = v } }
            func get(_ k: String) -> String? { l.withLock { s[k] } }
            var count: Int { l.withLock { s.count } }
        }
        let store = Store()
        let docs = UnifiedPathCaseTests.docs()
        let quote = String(UnifiedPathCaseTests.sentencing.prefix(40))
        let suggestions = Self.json(["leads": [["text": "Check the sentencing date against the docket", "documents": [1], "quote": quote]],
                                     "questions": [["text": "Ask about a document 7", "documents": [7]]], "gaps": []])
        let f = try await UnifiedPathCaseTests.fixture(docs, configure: { plan, _ in
            plan.briefing = { _, d in
                var m = CaseLedgerBriefing.Material()
                m.entities = [.init(id: UUID(), kind: "person", value: "John Smith", tier: "T1", source: d[0].objectID, confidence: 0.9, aliases: [])]
                return CaseLedgerBriefing.build(m, number: Dictionary(uniqueKeysWithValues: d.enumerated().map { ($1.objectID, $0 + 1) }))
            }
            plan.cachedSuggestions = { c, fp in store.get(c.uuidString + fp) }
            plan.storeSuggestions = { c, fp, _, outcome in store.put(c.uuidString + fp, outcome.section) }
        }, reply: { send in send.purpose == "case.suggestions" ? suggestions : CaseWholeReadingTests.answered() })
        _ = try await f.service.answer(caseID: f.caseID, question: "When was John Smith sentenced?", access: .testUnrestricted())
        for _ in 0..<100 where store.count == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(store.count == 1, "the suggestions were kept for the document set")
        let reads = f.recorder.requests.filter { $0.purpose == "case.suggestions" }
        #expect(reads.count == 1 && reads[0].suffix == CaseAISuggestions.task)
        _ = try await f.service.answer(caseID: f.caseID, question: "When was John Smith sentenced?", access: .testUnrestricted())
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(f.recorder.requests.filter { $0.purpose == "case.suggestions" }.count == 1, "a kept set is not asked again")
        #expect(OfflineSearchResults.withoutAI.hasPrefix("Set up AI") && OfflineSearchResults.defaultReason.contains("set up AI"))
    }

    // MARK: - AI-38 briefing from every source

    @Test("AI-38: on a real ledger the briefing reads the case's money, claims register, findings and reviews, map links, intake, verified answers, history and the reference shelf — each line tied to a case document")
    func briefingEverySource() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let c = try await cases.createCase(workspaceID: ws, title: "Dalmia", actor: "u", at: Date(timeIntervalSinceReferenceDate: 0))
        let file = UUID(), ko = UUID(), version = UUID(), outside = UUID()
        let text = "Invoice INV-2041 for Rs 48,500 was approved by Asha Rao on 3 March 2026 and paid to Dalmia Traders."
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/inv.txt', 'txt');", [.uuid(file)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', ?, 0, 0);",
                          [.uuid(ko), .uuid(file), .text(text)])
        try await db.exec("INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, created_at) VALUES (?, ?, ?, 'h', 0, 0);",
                          [.uuid(version), .uuid(file), .uuid(ko)])
        let cid = c.id.uuidString
        try await db.exec("""
            INSERT INTO case_money_records (id, case_id, kind, amount_text, amount, amount_basis, currency, record_date, payer_name, payee_name, reference,
                                            source_version_id, recorded_by, recorded_at)
            VALUES (?, ?, 'payment', '48,500', '48500', 'stated', 'INR', '2026-03-03', 'Asha Rao', 'Dalmia Traders', 'INV-2041', ?, 'u', 1);
            """, [.uuid(UUID()), .text(cid), .uuid(version)])
        // A money record with no case document is never written.
        try await db.exec("""
            INSERT INTO case_money_records (id, case_id, kind, amount_text, amount_basis, recorded_by, recorded_at) VALUES (?, ?, 'payment', '1', 'stated', 'u', 1);
            """, [.uuid(UUID()), .text(cid)])
        let claim = UUID()
        try await db.exec("""
            INSERT INTO claims (id, subject_label, statement, created_at, evidence_basis, review_disposition, proposal_origin, availability_status, conflict_status)
            VALUES (?, 'INV-2041', 'Asha Rao approved INV-2041', 1, 'document', 'unreviewed', 'extraction', 'available', 'none');
            """, [.uuid(claim)])
        try await db.exec("INSERT INTO claim_evidence_ref (claim_id, knowledge_object_id, ordinal, evidence_role) VALUES (?, ?, 0, 'supports');", [.uuid(claim), .uuid(ko)])
        try await db.exec("INSERT INTO claim_evidence_ref (claim_id, knowledge_object_id, ordinal, evidence_role) VALUES (?, ?, 0, 'supports');", [.uuid(UUID()), .uuid(outside)])
        let note = UUID()
        try await db.exec("""
            INSERT INTO case_journal (id, case_id, entry_kind, text, evidence_ref, author, created_at, verification, review_state)
            VALUES (?, ?, 'note', 'Approval came before the delivery note', ?, 'u', 1, 'verified', 'accepted');
            """, [.uuid(note), .text(cid), .text(ko.uuidString)])
        try await db.exec("""
            INSERT INTO investigation_review_decisions (id, case_id, item_kind, item_id, decision, note, source_versions_json, actor, decided_at)
            VALUES (?, ?, 'contradiction', 'c1', 'confirmed', 'The two dates differ', ?, 'u', 2);
            """, [.uuid(UUID()), .text(cid), .text(Self.json([version.uuidString]))])
        try await db.exec("""
            INSERT INTO case_map_links (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at)
            VALUES (?, ?, 'supports', 'journal', ?, 'person', 'p-asha', 'The note supports the approval', 'u', 3);
            """, [.uuid(UUID()), .text(cid), .text(note.uuidString)])
        try await db.exec("""
            INSERT INTO case_intake_items (id, case_id, channel, content_form, source_version_id, label, provenance, supplied_by, entered_by, received_at, recorded_at)
            VALUES (?, ?, 'fileImport', 'sourceDocument', ?, 'Invoice scan', 'imported', 'Dalmia accounts team', 'u', 4, 4);
            """, [.uuid(UUID()), .text(cid), .uuid(version)])
        try await db.exec("""
            INSERT INTO case_document_attributions (id, case_id, source_version_id, supplied_by, note, recorded_by, recorded_at)
            VALUES (?, ?, ?, 'Vikram Shah', 'Forwarded by email', 'u', 5);
            """, [.uuid(UUID()), .text(cid), .uuid(version)])
        let answer = UUID(), aclaim = UUID()
        try await db.exec("INSERT INTO answers (id, question, answer_state, body, created_at, origin_scope_id) VALUES (?, 'Who approved INV-2041?', 'supported', 'Asha Rao approved it.', 6, ?);",
                          [.uuid(answer), .text(cid)])
        try await db.exec("INSERT INTO answer_claims (id, answer_id, claim_text, support_status, created_at) VALUES (?, ?, 'Asha Rao approved it.', 'supported', 6);",
                          [.uuid(aclaim), .uuid(answer)])
        try await db.exec("INSERT INTO claim_evidence (claim_id, object_id) VALUES (?, ?);", [.uuid(aclaim), .uuid(ko)])
        let artifact = UUID(), item = UUID()
        try await db.exec("""
            INSERT INTO history_artifacts (id, subject_kind, subject_label, engine_version, title, created_at) VALUES (?, 'entity', 'INV-2041', '1', 'The story of INV-2041', 7);
            """, [.uuid(artifact)])
        try await db.exec("INSERT INTO history_items (id, artifact_id, item_kind, title, description, status) VALUES (?, ?, 'event', 'Invoice approved', 'by Asha Rao', 'sourceAsserted');",
                          [.uuid(item), .uuid(artifact)])
        try await db.exec("INSERT INTO history_item_evidence (history_item_id, knowledge_object_id) VALUES (?, ?);", [.uuid(item), .uuid(ko)])
        let folder = UUID(), shelfDoc = UUID()
        try await db.exec("INSERT INTO reference_shelf_folders (id, path, label, added_at) VALUES (?, '/tmp/manuals', 'Manuals', 8);", [.uuid(folder)])
        try await db.exec("INSERT INTO reference_shelf_documents (id, folder_id, path, title, content_hash, status, added_at) VALUES (?, ?, '/tmp/manuals/gst.txt', 'GST manual', 'h', 'read', 8);",
                          [.uuid(shelfDoc), .uuid(folder)])
        try await db.exec("INSERT INTO reference_shelf_passages (id, document_id, ordinal, text) VALUES (?, ?, 0, 'Section 9.');", [.uuid(UUID()), .uuid(shelfDoc)])

        let m = try await CaseBriefingRepository(database: db).material(objectIDs: [ko], versionToObject: [version: ko], caseID: c.id, texts: [ko: text])
        #expect(m.money.count == 1 && m.money.first?.reference == "INV-2041" && m.money.first?.source == ko, "\(m.money)")
        #expect(m.claims.map(\.statement) == ["Asha Rao approved INV-2041"], "\(m.claims)")
        #expect(m.findings.contains { $0.text == "Approval came before the delivery note" && $0.review.contains("verified") }, "\(m.findings)")
        #expect(m.findings.contains { $0.kind == "contradiction review" && $0.review == "confirmed" }, "\(m.findings)")
        #expect(m.mapLinks.count == 1 && m.mapLinks.first?.from.contains("Approval came before") == true, "\(m.mapLinks)")
        #expect(m.intake.contains { $0.suppliedBy == "Dalmia accounts team" } && m.intake.contains { $0.suppliedBy == "Vikram Shah" }, "\(m.intake)")
        #expect(m.verifiedAnswers.map(\.question) == ["Who approved INV-2041?"], "\(m.verifiedAnswers)")
        #expect(m.history.first?.item.contains("Invoice approved") == true && m.history.first?.versions == 1, "\(m.history)")
        #expect(m.shelf == [.init(title: "GST manual", passages: 1)], "\(m.shelf)")
        let b = CaseLedgerBriefing.build(m, number: [ko: 1])
        for title in ["## Money (the case's money records)", "## Claims register", "## Case map links", "## Findings and their review",
                      "## Who supplied what (intake)", "## Answers already verified in this case", "## Reconstructed history", "## Your reference shelf"] {
            #expect(b.text.contains(title), "missing \(title)")
        }
        let sectionLines = b.text.split(separator: "\n").filter { $0.hasPrefix("- ") }
        let shelfStart = b.text.range(of: "## Your reference shelf")?.lowerBound
        for line in sectionLines where shelfStart.map({ b.text.range(of: String(line))!.lowerBound < $0 }) ?? true {
            #expect(line.contains("[D1]"), "every case line names its document: \(line)")
        }
        let shelfLines = (b.text.components(separatedBy: "## Your reference shelf").last ?? "").split(separator: "\n").dropFirst().filter { $0.hasPrefix("- ") }
        #expect(!shelfLines.isEmpty && shelfLines.allSatisfy { !$0.contains("[D") }, "the shelf is never numbered: \(shelfLines)")
    }

    // MARK: - AI-39 batch reads that survive a quit

    nonisolated final class Wire: @unchecked Sendable {
        private let l = NSLock(); private var urls: [String] = []
        func add(_ r: OutboundHTTPRequest) { l.withLock { urls.append((r.method ?? "POST") + " " + r.url) } }
        var all: [String] { l.withLock { urls } }
    }
    nonisolated final class Tally: @unchecked Sendable {
        private let l = NSLock(); private var n = 0
        func tick() { l.withLock { n += 1 } }
        var value: Int { l.withLock { n } }
    }

    static func batchProvider(db: Database, wire: Wire, batchTally: Tally, interactiveTally: Tally, reply: String,
                              permissions: CaseReadPermissionStore) -> OnlineCloudProvider {
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let message = Self.json(["content": [["type": "text", "text": reply]],
                                 "usage": ["input_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 5]])
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in false }, transport: { req in
            wire.add(req)
            if req.method != "GET", req.url.hasSuffix("/v1/messages/batches") {
                return OutboundHTTPResponse(status: 200, body: Data(#"{"id":"msgbatch_t3"}"#.utf8))
            }
            if req.url.hasSuffix("/results") {
                let line = Self.json(["custom_id": "case-read-1", "result": ["type": "succeeded", "message": try JSONSerialization.jsonObject(with: Data(message.utf8))]])
                return OutboundHTTPResponse(status: 200, body: Data(line.utf8))
            }
            if req.url.hasSuffix("/cancel") { return OutboundHTTPResponse(status: 200, body: Data("{}".utf8)) }
            if req.method == "GET", req.url.contains("/v1/messages/batches/") {
                return OutboundHTTPResponse(status: 200, body: Data(#"{"processing_status":"ended"}"#.utf8))
            }
            return OutboundHTTPResponse(status: 200, body: Data(message.utf8))
        })
        seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
        seams.ownKeyRefusal = { _ in nil }
        seams.ownKeyTally = { _, _ in interactiveTally.tick() }
        seams.ownKeyBatchTally = { _, _ in batchTally.tick() }
        return OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] }, protectedNames: { [] }, seams: seams)
    }

    @Test("AI-39: a background read is recorded as a batch job, tallied at the batch price and marked used; a result kept from an earlier run is reused without sending; at launch a waiting batch is polled to 'done' and one older than a day abandoned")
    func batchJournal() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let journal = AIBatchJobRepository(database: db)
        // The test's own journal for its task tree: every ledger booted by a suite running beside this one sets the shared one.
        try await CaseBatchJournal.TestOverride.$journal.withValue(journal) { try await Self.batchJournalBody(db: db, journal: journal) }
    }

    static func batchJournalBody(db: Database, journal: AIBatchJobRepository) async throws {
        let caseID = UUID(), o = UUID(), v = UUID()
        let binding = CloudScopeBinding(scopeID: caseID) { [o: [v]] }
        let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                              legacyPrivileged: { [] }).bound(to: binding).clear([o], purpose: "case.reading").clearance
        let permissions = CaseReadPermissionStore.inMemory()
        permissions.grant(caseID: caseID, fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: clearance.versions), documentCount: 1)
        let wire = Wire(), batch = Tally(), interactive = Tally()
        let provider = Self.batchProvider(db: db, wire: wire, batchTally: batch, interactiveTally: interactive,
                                          reply: #"{"checks": []}"#, permissions: permissions)
        let doc = CaseReader.Document(objectID: o, sourceVersionID: v, fileName: "a.txt", text: UnifiedPathCaseTests.sentencing)
        let send = CaseReadSend(caseID: caseID, prefix: CaseReader.prefix([doc]), suffix: "Task: method review", ttl: .oneHour,
                                purpose: "case.methods", clearance: clearance, batch: true)
        let out = try await provider.readCase(send)   // polls after 20 s (the batch poll interval)
        #expect(out.text.contains("checks"))
        #expect(wire.all.contains { $0.hasPrefix("POST") && $0.hasSuffix("/v1/messages/batches") }, "\(wire.all)")
        #expect(batch.value == 1 && interactive.value == 0, "tallied at the batch price")
        let row = try #require(try await db.query("SELECT id, state, request_digest, clearance_fingerprint, purpose FROM ai_batch_jobs;").first)
        #expect(row.string(1) == "used" && row.string(4) == "case.methods")
        // The same read again, with a result kept from an earlier run (as after a quit): used, nothing sent.
        try await db.exec("UPDATE ai_batch_jobs SET state = 'done', result_text = 'KEPT RESULT' WHERE id = ?;", [.text(row.string(0) ?? "")])
        let sentBefore = wire.all.count
        let again = try await provider.readCase(send)
        #expect(again.text == "KEPT RESULT" && wire.all.count == sentBefore, "a kept result is used, not re-sent")
        #expect(try await db.query("SELECT state FROM ai_batch_jobs;").first?.string(0) == "used")

        // At launch: a waiting batch is polled and kept 'done'; one older than a day is cancelled and abandoned.
        let fresh = try await journal.insert(batchID: "msgbatch_fresh", kind: "anthropic", model: "test-model", caseID: caseID, purpose: "case.conflicts",
                                             clearanceFingerprint: "f", requestDigest: "d1", mapping: ["[NAME_1]": "John Smith"])
        let old = try await journal.insert(batchID: "msgbatch_old", kind: "anthropic", model: "test-model", caseID: caseID, purpose: "case.conflicts",
                                           clearanceFingerprint: "f", requestDigest: "d2", mapping: [:], at: Date().addingTimeInterval(-2 * 86_400))
        await provider.resumeCaseBatches()
        let states = Dictionary(uniqueKeysWithValues: try await db.query("SELECT id, state, result_text FROM ai_batch_jobs;").compactMap { r in
            r.uuid(0).map { ($0, (r.string(1) ?? "", r.string(2))) } })
        #expect(states[fresh]?.0 == "done" && states[fresh]?.1?.contains("checks") == true, "\(String(describing: states[fresh]))")
        #expect(states[old]?.0 == "abandoned")
        #expect(wire.all.contains { $0.contains("msgbatch_old/cancel") }, "an abandoned own-key batch is cancelled")
        #expect(batch.value == 2, "the resumed result is tallied at the batch price")
        let kept = try #require(try await journal.job(caseID: caseID, requestDigest: "d1", clearanceFingerprint: "f", state: "done"))
        #expect(kept.mapping == ["[NAME_1]": "John Smith"], "the mask mapping survives, so the kept reply is restored on the Mac")
    }

    // MARK: - QA-21 / AI-37 / AI-39 erasure reach

    @Test("QA-21/AI-37/AI-39: a person erasure clears the reference shelf passages, AI suggestions and batch-job mappings and replies that name the person")
    @MainActor
    func erasureReachesShelfSuggestionsBatches() async throws {
        let dir = try Self.scratch("erase-r2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let db = try #require(state.database)
        let folder = dir.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Guidance note\n\nThe officer Meera Iyer reviews every customs refund above the limit.".utf8).write(to: folder.appendingPathComponent("guide.txt"))
        _ = try #require(await state.addReferenceShelfFolder(folder))
        #expect(await state.shelfToolLines("refund").contains("Meera Iyer"))
        let src = UUID(), fileID = UUID(), person = UUID(), caseID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/m.txt', 'txt');", [.uuid(fileID)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', 'Meera Iyer approved the refund.', 0, 0);",
                          [.uuid(src), .uuid(fileID)])
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?, 'person', 'Meera Iyer', 'meera iyer', ?, 0.9);",
                          [.uuid(person), .uuid(src)])
        try await db.exec("""
            INSERT INTO case_briefing_ai_suggestions (case_id, document_fingerprint, briefing_fingerprint, body, item_count, dropped_count, created_at)
            VALUES (?, 'fp', 'bf', '## AI suggestions\n- AI suggestion (question to ask): Ask Meera Iyer about the refund [D1]', 1, 0, 1);
            """, [.uuid(caseID)])
        try await db.exec("""
            INSERT INTO case_briefing_ai_suggestions (case_id, document_fingerprint, briefing_fingerprint, body, item_count, dropped_count, created_at)
            VALUES (?, 'fp2', 'bf', '## AI suggestions\n- AI suggestion (gap): No payment record [D1]', 1, 0, 1);
            """, [.uuid(caseID)])
        let job = try await AIBatchJobRepository(database: db).insert(batchID: "msgbatch_e", kind: "anthropic", model: "m", caseID: caseID, purpose: "case.methods",
                                                                     clearanceFingerprint: "f", requestDigest: "d", mapping: ["[NAME_1]": "Meera Iyer"])
        let out = try await state.erasePerson(person, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil)
        #expect(!(await state.shelfToolLines("refund")).contains("Meera Iyer"), "the shelf no longer names her")
        let bodies = try await db.query("SELECT body FROM case_briefing_ai_suggestions;").compactMap { $0.string(0) }
        #expect(bodies.count == 1 && !bodies.joined().contains("Meera"), "\(bodies)")
        let jr = try #require(try await db.query("SELECT mask_mapping_json, state, result_text FROM ai_batch_jobs WHERE id = ?;", [.uuid(job)]).first)
        #expect(jr.string(0) == "{}" && jr.string(1) == "abandoned" && jr.string(2) == nil)
        await state.shutdown()
    }

    // MARK: - PERF-19 stage workers

    nonisolated final class Gauge: @unchecked Sendable {
        private let l = NSLock(); private var now = 0, peak = 0
        func enter() { l.withLock { now += 1; peak = max(peak, now) } }
        func leave() { l.withLock { now -= 1 } }
        var highest: Int { l.withLock { peak } }
    }

    @Test("PERF-19: a stage's permits bound its concurrency, widen and narrow live, and a cancelled waiter gets no permit; widths follow memory, pressure and heat; a nested same-stage request cannot deadlock")
    func stagePermits() async throws {
        let permits = StagePermits(stage: .ocr, capacity: 2)
        let g = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let got = await permits.acquire()
                    g.enter(); try? await Task.sleep(nanoseconds: 20_000_000); g.leave()
                    if got { await permits.release() }
                }
            }
        }
        let running = await permits.running()
        #expect(g.highest == 2 && running == 0, "peak \(g.highest)")
        await permits.resize(4)
        #expect(await permits.currentCapacity() == 4)
        // A waiter that is cancelled stops waiting and gets no permit.
        let one = StagePermits(stage: .write, capacity: 1)
        #expect(await one.acquire())
        let waiter = Task { await one.acquire() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        #expect(await waiter.value == false)
        await one.release()
        #expect(await one.running() == 0)

        let roomy = WorkerBudget(availableBytes: 32 * 1_073_741_824, physicalBytes: 64 * 1_073_741_824, activeCores: 10, pressure: .normal, thermal: .nominal)
        #expect(PipelineStages.width(for: .parse, budget: roomy) == 9 && PipelineStages.width(for: .read, budget: roomy) == 16)
        #expect(PipelineStages.width(for: .embed, budget: roomy) == 2 && PipelineStages.width(for: .ocr, budget: roomy) == 8)
        let warn = WorkerBudget(availableBytes: roomy.availableBytes, physicalBytes: roomy.physicalBytes, activeCores: 10, pressure: .warning, thermal: .nominal)
        #expect(PipelineStages.width(for: .parse, budget: warn) == 4)
        let hot = WorkerBudget(availableBytes: roomy.availableBytes, physicalBytes: roomy.physicalBytes, activeCores: 10, pressure: .normal, thermal: .serious)
        #expect(PipelineStages.width(for: .parse, budget: hot) == 1)
        let tight = WorkerBudget(availableBytes: 600 * 1_048_576, physicalBytes: roomy.physicalBytes, activeCores: 10, pressure: .normal, thermal: .nominal)
        #expect(PipelineStages.width(for: .parse, budget: tight) == 1, "300 MB shareable / 256 MB per parse = 1")

        let nested = await PipelineStages.withPermit(.transcribe) { await PipelineStages.withPermit(.transcribe) { 42 } }
        #expect(nested == 42)
        let mapped = await StagedPipeline.map(Array(0..<20), stage: .chunk) { i, x in x * 2 + i * 0 }
        #expect(mapped == (0..<20).map { $0 * 2 }, "results in input order")
    }

    @Test("PERF-19: the bounded hand-off applies back-pressure; a long PDF is cut into page ranges that cover every page once")
    func channelAndPageRanges() async throws {
        let ch = BoundedChannel<Int>(capacity: 2)
        let s1 = await ch.send(1), s2 = await ch.send(2)
        #expect(s1 && s2)
        let third = Task { await ch.send(3) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await ch.receive() == 1)
        #expect(await third.value)
        let r2 = await ch.receive(), r3 = await ch.receive()
        #expect(r2 == 2 && r3 == 3)
        await ch.finish()
        let drained = await ch.receive(), late = await ch.send(9)
        #expect(drained == nil && !late, "finished: drained, sends dropped")

        let r = PDFPageRanges.ranges(pageCount: 100, width: 4)
        #expect(r.count == 8 && r.first?.lowerBound == 0 && r.last?.upperBound == 100)
        #expect(zip(r, r.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "no gap, no overlap: \(r)")
        #expect(r.allSatisfy { $0.count >= PDFPageRanges.minimumPagesPerRange })
        #expect(PDFPageRanges.ranges(pageCount: 6, width: 8) == [0..<3, 3..<6] || PDFPageRanges.ranges(pageCount: 6, width: 8).count == 1)
        #expect(PDFPageRanges.ranges(pageCount: 0, width: 4).isEmpty)
    }

    // MARK: - PERF-20 shard merge limits

    @Test("PERF-20: a shard's relationship that clashes on its UNIQUE key folds into the main row (weight added, evidence ids unioned); its vectors and erasure tombstones are merged")
    @MainActor
    func shardFoldVectorsRegisters() async throws {
        let dir = try Self.scratch("fold")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let main = try #require(state.database)
        let mainURL = await main.url, mainKey = await main.key
        let a = UUID(), b = UUID(), mainKO = UUID(), mainFile = UUID(), shardKO = UUID(), shardFile = UUID(), chunk = UUID()
        func seedCommon(_ db: Database, file: UUID, ko: UUID, url: String) async throws {
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, 'txt');", [.uuid(file), .text(url)])
            try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', 'x', 0, 0);",
                              [.uuid(ko), .uuid(file)])
        }
        try await seedCommon(main, file: mainFile, ko: mainKO, url: "/tmp/main.txt")
        for (id, n) in [(a, "Asha Rao"), (b, "Dalmia Traders")] {
            try await main.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?, 'person', ?, ?, ?, 0.9);",
                                [.uuid(id), .text(n), .text(n.lowercased()), .uuid(mainKO)])
        }
        try await main.exec("INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, source_object_id, weight, evidence_object_ids_json) VALUES (?, 'paid', ?, ?, ?, 1, ?);",
                            [.uuid(UUID()), .uuid(a), .uuid(b), .uuid(mainKO), .text(Self.json([mainKO.uuidString]))])
        let run = UUID()
        let shard = try await ShardLedger.open(runID: run, index: 0, besideLedgerAt: mainURL, key: mainKey)
        try await seedCommon(shard.database, file: shardFile, ko: shardKO, url: "/tmp/shard.txt")
        for (id, n) in [(a, "Asha Rao"), (b, "Dalmia Traders")] {
            try await shard.database.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?, 'person', ?, ?, ?, 0.9);",
                                          [.uuid(id), .text(n), .text(n.lowercased()), .uuid(shardKO)])
        }
        try await shard.database.exec("INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, source_object_id, weight, evidence_object_ids_json) VALUES (?, 'paid', ?, ?, ?, 2, ?);",
                                      [.uuid(UUID()), .uuid(a), .uuid(b), .uuid(shardKO), .text(Self.json([shardKO.uuidString]))])
        try await shard.database.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at) VALUES (?, ?, 0, 'Asha Rao paid Dalmia Traders', 0, 28, 0);", [.uuid(chunk), .uuid(shardKO)])
        try await shard.database.exec("INSERT INTO chunk_embeddings (chunk_id, model_id, dim, q, scale, created_at) VALUES (?, 'test-embedder', 4, ?, 1.0, 0);",
                                      [.uuid(chunk), .blob(Data([1, 2, 3, 4]))])
        let erasureID = UUID().uuidString
        try await shard.database.exec("INSERT INTO erasure_generations (kind, scope_hash, erasure_id, state, erased_at) VALUES ('person', ?, ?, 'done', 0);",
                                      [.text(String(repeating: "ab", count: 32)), .text(erasureID)])
        let gen = try #require(try await shard.database.query("SELECT generation FROM erasure_generations WHERE erasure_id = ?;", [.text(erasureID)]).first?.int(0))
        try await shard.database.exec("INSERT INTO erasure_tombstones (generation, tbl, row_key, recorded_at) VALUES (?, 'entities', 'gone-1', 0);", [.integer(gen)])
        await shard.close()
        try await main.recordShard(runID: run, index: 0, path: shard.url.path, state: "written", files: 1)
        guard case .merged = await ShardMerger(main: main).merge(runID: run, index: 0, shardURL: shard.url) else { Issue.record("merge failed"); return }
        let rels = try await main.query("SELECT weight, evidence_object_ids_json FROM relationships WHERE from_entity_id = ? AND to_entity_id = ?;", [.uuid(a), .uuid(b)])
        #expect(rels.count == 1, "one relationship, not two")
        #expect(rels.first?.int(0) == 3, "weights added: \(String(describing: rels.first?.int(0)))")
        let ids = rels.first?.string(1) ?? ""
        #expect(ids.contains(mainKO.uuidString) && ids.contains(shardKO.uuidString), "evidence ids unioned: \(ids)")
        #expect(try await main.query("SELECT COUNT(*) FROM chunk_embeddings WHERE chunk_id = ?;", [.uuid(chunk)]).first?.int(0) == 1, "vectors merged")
        let tomb = try await main.query("""
            SELECT t.generation, g.erasure_id FROM erasure_tombstones t LEFT JOIN erasure_generations g ON g.generation = t.generation WHERE t.row_key = 'gone-1';
            """).first
        #expect(tomb != nil && tomb?.string(1) == erasureID, "erasure register merged, the tombstone pointing at its re-numbered generation")
        #expect(try await main.query("SELECT COUNT(*) FROM entities WHERE id IN (?, ?);", [.uuid(a), .uuid(b)]).first?.int(0) == 2)
        await state.shutdown()
    }

    @Test("PERF-20: the same bytes in two batches of one run become one source; the merged custody events are sealed into an intact audit chain")
    @MainActor
    func shardSameContentAndAudit() async throws {
        let dir = try Self.scratch("samebytes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir)
        let main = try #require(state.database), ingest = try #require(state.ingest)
        let docs = dir.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let same = "Memo of Priya Nair, 14 March 2026. Priya Nair received 40 cartons at the Rotterdam terminal."
        let urls = [docs.appendingPathComponent("copy-a.txt"), docs.appendingPathComponent("copy-b.txt"), docs.appendingPathComponent("other.txt")]
        try Data(same.utf8).write(to: urls[0]); try Data(same.utf8).write(to: urls[1])
        try Data("Letter of Dev Malhotra, 12 March 2026. Dev Malhotra signed the delivery note.".utf8).write(to: urls[2])
        let files = try urls.map { IngestPlannedFile(url: $0, bytes: UInt64(try Data(contentsOf: $0).count)) }
        let plan = IngestBatchPlan(batches: files.map { f in var b = IngestBatch(); b.files = [f]; b.bytes = f.bytes; return b }, bytesPerBatch: 200, workers: 2)
        await state.runShardImport(plan: plan, ingest: ingest, counter: IngestCounter(), failures: IngestFailureLog(),
                                   run: nil, runs: nil, receipts: nil, arrivals: .folderReread)
        let hashes = try await main.query("SELECT COUNT(DISTINCT content_hash), COUNT(*) FROM source_versions;").first
        #expect(hashes?.int(0) == 2, "two distinct contents: \(String(describing: hashes?.int(0))) of \(String(describing: hashes?.int(1))) versions")
        let sameKOs = try await main.query("SELECT COUNT(*) FROM knowledge_objects WHERE content LIKE '%40 cartons%';").first?.int(0) ?? -1
        #expect(sameKOs == 1, "the same bytes are one source (\(sameKOs))")
        let chain = try #require(state.auditChain)
        let v = try await chain.verify()
        #expect(v.isIntact && v.unsealedCount == 0, "\(v.statusLine)")
        await state.shutdown()
    }

    // MARK: - IN-27 extraction backlog

    @Test("IN-27: values are tidied per shape without changing meaning; a pack outside the document's class runs strict; the counters add up and are kept across launches; oversized plain text is refused before reading")
    @MainActor
    func extractionBacklog() async throws {
        #expect(FactValueNormalizer.normalize("  Rs 48,500/- ", shape: .money) == "Rs 48,500")
        #expect(FactValueNormalizer.normalize("<mailto:Asha.Rao@Example.com>.", shape: .email) == "asha.rao@example.com")
        #expect(FactValueNormalizer.normalize("INV - 2041 / A,", shape: .identifier) == "INV-2041/A")
        #expect(FactValueNormalizer.normalize("Dalmia Traders Ltd.", shape: .text) == "Dalmia Traders Ltd.", "text keeps a final full stop")
        #expect(FactValueNormalizer.normalize(" ;, ", shape: .text) == nil, "empty after tidying: dropped")
        #expect(StrictPackPolicy.isStrict(.medical, for: .invoice) && !StrictPackPolicy.isStrict(.transaction, for: .invoice))
        #expect(!StrictPackPolicy.isStrict(.medical, for: nil) && !StrictPackPolicy.isStrict(.medical, for: .email), "classes that mention anything are never strict")
        func fact(_ value: String, raw: String?) -> GenericFact {
            GenericFact(subjectLabel: "doc", field: "amount", value: value, status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()],
                        producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1)
        }
        #expect(StrictPackPolicy.hasExplicitLabel(fact("48,500", raw: "Amount due: 48,500")))
        #expect(!StrictPackPolicy.hasExplicitLabel(fact("48,500", raw: "48,500")) && !StrictPackPolicy.hasExplicitLabel(fact("48,500", raw: nil)))

        let t = ExtractionTelemetry()
        t.recordDocument(documentClass: .invoice, facts: 3)
        t.recordDocument(documentClass: nil, facts: 0)
        t.recordPackPass(rejected: 2, downgraded: 1, emptied: 1, tidied: 4)
        var base = ExtractionTelemetry.Snapshot(); base.documents = 10; base.factsByClass = ["invoice": 5]
        t.seed(base)
        let s = t.snapshot()
        #expect(s.documents == 12 && s.documentsWithNoFacts == 1 && s.factsByClass["invoice"] == 8 && s.factsByClass["unclassified"] == 0)
        #expect(s.strictRejected == 2 && s.strictDowngraded == 1 && s.emptyValuesDropped == 1 && s.valuesTidied == 4)
        let round = try JSONDecoder().decode(ExtractionTelemetry.Snapshot.self, from: JSONEncoder().encode(s))
        #expect(round == s, "the snapshot is kept as JSON (counts only)")

        let dir = try Self.scratch("in27")
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: 4_096).write(to: big)
        #expect(throws: IngestorError.self) { try PlainTextSizeCap.check(big, kind: "text", limit: 1_024) }
        #expect(throws: Never.self) { try PlainTextSizeCap.check(big, kind: "text", limit: 1_000_000) }

        let state = await Self.booted(dir)
        let db = try #require(state.database)
        await ExtractionTelemetryRepository(database: db).persist()
        let json = try #require(try await db.query("SELECT snapshot_json FROM extraction_telemetry_totals WHERE id = 1;").first?.string(0))
        let kept = try JSONDecoder().decode(ExtractionTelemetry.Snapshot.self, from: Data(json.utf8))
        #expect(kept.documents >= 0 && !json.contains("Asha"), "counts only, never content")
        await state.shutdown()
    }

    // MARK: - Defect found in T3: a deep MetricKit payload crashed the app while it was being saved

    @Test("T3 defect: a diagnostic whose call-stack tree nests 120 frames deep is saved (cut below the depth limit) instead of overflowing the saving thread's stack")
    func deepDiagnosticPayloadIsSaved() throws {
        var json = #"{"address":1}"#
        for _ in 0..<120 { json = #"{"address":1,"subFrames":["# + json + "]}" }
        json = #"{"crashDiagnostics":[{"callStackTree":{"callStacks":[{"callStackRootFrames":["# + json + #"]}]},"diagnosticMetaData":{"reason":"secret"}}]}"#
        let out = DiagnosticsSanitizer.sanitize(Data(json.utf8))
        let text = String(decoding: out, as: UTF8.self)
        #expect(DiagnosticsSanitizer.isSanitized(out))
        #expect(text.contains(DiagnosticsSanitizer.deeperRemoved) && !text.contains("secret"), "\(text.prefix(300))")
        // A shallow payload is kept whole.
        let shallow = String(decoding: DiagnosticsSanitizer.sanitize(Data(#"{"a":{"b":[1,2,{"c":3}]}}"#.utf8)), as: UTF8.self)
        #expect(!shallow.contains(DiagnosticsSanitizer.deeperRemoved) && shallow.contains(#""c":3"#))
    }
}
