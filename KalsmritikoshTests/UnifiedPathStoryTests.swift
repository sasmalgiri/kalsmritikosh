//
//  UnifiedPathStoryTests.swift
//  KalsmritikoshTests
//
//  Test phase T3 (2026-11-22) — the round-1 rows T2 left unverified that a headless test can reach through the real
//  AppState: AI-27 story rewording at its call site, AI-30 table questions across sheets and inside a case, HISTORY-09
//  "what changed" (this session and across sessions) with "where to look next", HISTORY-10 the merged multi-subject
//  story. Ephemeral ledgers; an on-device spy provider stands in for the AI; no network.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — stories and tables", .serialized)
struct UnifiedPathStoryTests {

    static func scratch(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("us-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Boots on `url` with the ledger's own key when given (the test host's key store is shared by concurrent suites).
    @MainActor
    static func booted(_ url: URL, key: LedgerKey? = nil) async -> AppState {
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        if let key { state.bootRecoveryKey = key }
        await state.boot(databaseURL: url)
        return state
    }

    static var owner: SensitiveAccessContext { SensitiveAccessContext(scope: SensitiveScope.globalOwnerRetrieval()) }

    /// An on-device stand-in for the AI that rewrites the notes by returning them unchanged (so the grounding gate passes).
    nonisolated final class EchoProvider: ModelProvider, @unchecked Sendable {
        let id = "provider.test.t3-echo-\(UUID().uuidString)"
        let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning]
        let manifest: ModelManifest
        private let lock = NSLock(); private var prompts: [String] = []
        init() { manifest = ModelManifest(id: id, displayName: "Echo", capabilities: [.textGeneration, .reasoning], privacyLevel: .onDevice) }
        var seen: [String] { lock.withLock { prompts } }
        func isAvailable() async -> Bool { true }
        func generate(prompt: String, options: GenerationOptions) async throws -> String {
            lock.withLock { prompts.append(prompt) }
            guard let r = prompt.range(of: "Notes:\n") else { return "" }
            return String(prompt[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func embed(text: String) async throws -> [Float] { throw ModelProviderError.unavailable(providerID: id) }
    }

    static func seedSource(_ db: Database, _ name: String) async throws -> UUID {
        let file = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, 'txt');", [.uuid(file), .text("/tmp/\(name)")])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?, ?, 'txt', ?, 0, 0);",
                          [.uuid(ko), .uuid(file), .text(name)])
        return ko
    }

    static func event(_ db: Database, _ title: String, _ epoch: TimeInterval, source: UUID, entity: UUID) async throws {
        let id = UUID()
        // Stamped with the current events producer version: the booted app's background drain re-derives (and replaces)
        // events written by an older extractor, which would wipe a seed that carries no version.
        try await db.exec("INSERT INTO events (id, kind, date, title, source_object_id, confidence, producer_version) VALUES (?, 'contractSigned', ?, ?, ?, 0.9, ?);",
                          [.uuid(id), .real(epoch), .text(title), .uuid(source), .integer(Int64(DerivedProducerVersions.events))])
        try await db.exec("INSERT INTO event_entities (event_id, entity_id) VALUES (?, ?);", [.uuid(id), .uuid(entity)])
    }

    /// The StoryGold patent: filed 2019, a five-year silence, a hearing, granted (two accounts of the grant date).
    static func seedPatent(_ db: Database) async throws -> (anchor: UUID, letter: UUID) {
        let letter = try await seedSource(db, "grant-letter.txt"), receipt = try await seedSource(db, "fee-receipt.txt")
        let anchor = UUID()
        try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
            VALUES (?, ?, 'patentnumber|555489', 'patentnumber|555489', ?, 0.95, '{}', 'T1');
            """, [.uuid(anchor), .text(Entity.Kind.identifierAnchor.rawValue), .uuid(letter)])
        // The anchor is derived from a fact: the booted app's upkeep sweeps an anchor no current fact names.
        try await GenericFactRepository(database: db).upsert(GenericFact(
            subjectID: anchor, subjectLabel: "patent", field: "patentNumber", value: "555489", status: .sourceAsserted, confidence: 0.95,
            sourceBlockIDs: [UUID()], producerVersion: DerivedProducerVersions.facts, rawMatch: "Patent No. 555489", sourceCount: 1))
        try await event(db, "Patent filed", 1_553_126_400, source: letter, entity: anchor)
        try await event(db, "Hearing held", 1_722_816_000, source: letter, entity: anchor)
        try await event(db, "Patent granted", 1_732_752_000, source: letter, entity: anchor)
        try await event(db, "Patent granted", 1_734_220_800, source: receipt, entity: anchor)
        return (anchor, letter)
    }

    // MARK: - AI-27 + HISTORY-09

    @Test("AI-27 + HISTORY-09: a story answer's chapters are reworded by the AI under the grounding gate; asked again it says what changed since the previous history, and after a relaunch since the saved one; it names where to look next")
    @MainActor
    func storyRewordingAndWhatChanged() async throws {
        let dir = try Self.scratch("story")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.sqlite")
        let state = await Self.booted(url)
        let db = try #require(state.database), caps = try #require(state.capabilities)
        let key = await db.key
        let patent = try await Self.seedPatent(db)
        let echo = EchoProvider()
        await caps.register(echo)
        let question = "tell me the story of the patent"
        let first = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) { await state.composeStoryAnswer(question: question, access: Self.owner) }
        let a = try #require(first, "the story path answered")
        #expect(!echo.seen.isEmpty && echo.seen.contains { $0.contains("Keep every number and date EXACTLY") }, "chapters went to the AI: \(echo.seen.count)")
        #expect(a.body.contains(LegalNotice.modelStamp()), "the reworded prose carries its author's stamp")
        #expect(a.body.contains("Where to look next:"), "the silent period gives a next step: \(a.body.suffix(400))")
        #expect(!a.body.contains("Since the previous history") && !a.body.contains("Since the history saved"), "nothing to compare yet")
        #expect(a.body.contains("This story was saved to your archive and awaits your review."))

        let second = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) { await state.composeStoryAnswer(question: question, access: Self.owner) }
        let evs = try await db.query("SELECT title, source_object_id, review_status FROM events ORDER BY date;").map { r in (0..<3).map { r.string($0) ?? "nil" }.joined(separator: "/") }
        let others = echo.seen.filter { !$0.contains("Keep every number and date EXACTLY") }.map { String($0.prefix(160)) }
        #expect(second?.body.contains("Since the previous history: nothing changed.") == true, "\(second?.body.suffix(400) ?? "nil")\nEVENTS \(evs)\nOTHER PROMPTS \(others)")

        // A gate rejection keeps the deterministic prose: an AI that adds a number is not used.
        nonisolated final class Inventor: ModelProvider, @unchecked Sendable {
            let id = "provider.test.t3-inventor"; let capabilities: Set<ModelCapability> = [.textGeneration, .reasoning]
            let manifest = ModelManifest(id: "provider.test.t3-inventor", displayName: "Inventor", capabilities: [.textGeneration, .reasoning], privacyLevel: .onDevice)
            func isAvailable() async -> Bool { true }
            func generate(prompt: String, options: GenerationOptions) async throws -> String { "The patent was filed in 1999 for 7,777 rupees." }
            func embed(text: String) async throws -> [Float] { [] }
        }
        let hw = HardwareProfile(totalRAMBytes: 16 * 1_073_741_824, availableRAMBytes: 8 * 1_073_741_824, processorCount: 8,
                                 isAppleSilicon: true, chipName: "T3Chip-\(UUID().uuidString)", hasNeuralEngine: true)
        let lone = CapabilityRegistry(hardware: hw, benchmark: PerformanceBenchmark(hardwareProfile: hw))
        await lone.register(Inventor())
        let rejected = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(false) {
            await StoryProseRephraser.rephrase(gist: "Patent filed", sentences: "On 21 March 2019 the patent was filed.", capabilities: lone)
        }
        #expect(rejected == nil, "a new number fails the grounding gate")

        // A new event, then a relaunch: the change is measured against the history saved in the earlier session.
        try await Self.event(db, "Renewal fee paid", 1_750_000_000, source: patent.letter, entity: patent.anchor)
        await state.shutdown()
        let again = await Self.booted(url, key: key)
        let third = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) { await again.composeStoryAnswer(question: question, access: Self.owner) }
        let body = try #require(third?.body)
        let db2 = try #require(again.database)
        // Compared with the newest history saved before this answer. The app's own background upkeep may already have
        // rebuilt the story after the relaunch (then "nothing changed" since that save); otherwise the new event is "1 new".
        #expect(body.contains("Since the history saved") && (body.contains(": 1 new,") || body.contains(": nothing changed.")), "\(body.suffix(300))")
        // Every saved history has its items (a rebuild that kept items used to leave a header with none), the rebuilt one
        // holds the new event, and the earlier one is superseded, not deleted.
        let rows = try await db2.query("""
            SELECT a.superseded_by, (SELECT COUNT(*) FROM history_items i WHERE i.artifact_id = a.id),
                   (SELECT COUNT(*) FROM history_items i WHERE i.artifact_id = a.id AND i.title = 'Renewal fee paid')
            FROM history_artifacts a;
            """)
        #expect(rows.count >= 2 && rows.allSatisfy { ($0.int(1) ?? 0) > 0 }, "no history saved without its items")
        #expect(rows.contains { $0.string(0) != nil } && rows.contains { $0.string(0) == nil && ($0.int(2) ?? 0) == 1 })
        #expect(!body.contains(LegalNotice.modelStamp()), "AI off: the deterministic prose")
        await again.shutdown()
    }

    // MARK: - HISTORY-10

    @Test("HISTORY-10: a story question joining two named subjects gives one story with both subjects' chapters merged by date, each subject's story saved")
    @MainActor
    func mergedMultiSubjectStory() async throws {
        let dir = try Self.scratch("multistory")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir.appendingPathComponent("ledger.sqlite"))
        let db = try #require(state.database)
        let src = try await Self.seedSource(db, "ledger-notes.txt")
        let asha = UUID(), dalmia = UUID()
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, quality_tier) VALUES (?, 'person', 'Asha Rao', 'asha rao', ?, 0.9, 'T1');",
                          [.uuid(asha), .uuid(src)])
        try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, quality_tier) VALUES (?, 'organization', 'Dalmia Traders', 'dalmia traders', ?, 0.9, 'T1');",
                          [.uuid(dalmia), .uuid(src)])
        try await Self.event(db, "Asha Rao joined the purchase team", 1_700_000_000, source: src, entity: asha)
        try await Self.event(db, "Dalmia Traders registered as a vendor", 1_710_000_000, source: src, entity: dalmia)
        try await Self.event(db, "Asha Rao approved invoice INV-2041", 1_720_000_000, source: src, entity: asha)
        try await Self.event(db, "Dalmia Traders was paid for INV-2041", 1_730_000_000, source: src, entity: dalmia)
        let a = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            await state.composeStoryAnswer(question: "Tell the story of Asha Rao and Dalmia Traders", access: Self.owner)
        }
        let body = try #require(a?.body, "a merged story")
        #expect(body.contains("Asha Rao") && body.contains("Dalmia Traders") && body.contains("Each subject's story was saved"), "\(body.prefix(600))")
        // Chapters (one subject and one year each) are merged by their first date; a chapter's own items stay together.
        let order = ["## Asha Rao — 2023", "## Dalmia Traders — 2024", "## Asha Rao — 2024"].compactMap { body.range(of: $0)?.lowerBound }
        #expect(order.count == 3 && order == order.sorted(), "chapters merged in date order: \(body.prefix(900))")
        let saved = try await db.query("SELECT COUNT(DISTINCT subject_label) FROM history_artifacts;").first?.int(0) ?? 0
        #expect(saved >= 2, "each subject's story persisted (\(saved))")
        // One subject and a phrase that is not an entity: no merged story is invented.
        let single = await PrivacyGate.TestOverride.$offlineNoLLM.withValue(true) {
            await state.composeStoryAnswer(question: "Tell the story of Asha Rao and the missing crates", access: Self.owner)
        }
        #expect(single?.body.contains("Each subject's story was saved") != true)
        await state.shutdown()
    }

    // MARK: - AI-30

    // Updated for AI-47/48 (owner 2026-11-23): verifies a retired rule path — run with the switches turned back on.
    @Test("AI-30: a table question over several sheets lists each sheet's own answer (never added together); inside a case only the case's sheets are read", .ruleAnswering)
    @MainActor
    func tableQuestions() async throws {
        let dir = try Self.scratch("tables")
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = await Self.booted(dir.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest), db = try #require(state.database)
        let a = dir.appendingPathComponent("march.csv"), b = dir.appendingPathComponent("april.csv")
        try Data("Item,Amount\nCartons,100\nPallets,250\n".utf8).write(to: a)
        try Data("Item,Amount\nCartons,40\nCrates,60\nDrums,5\n".utf8).write(to: b)
        let ra = try await ingest.ingest(fileAt: a)
        _ = try await ingest.ingest(fileAt: b)
        let question = "What is the total of Amount in the spreadsheet?"
        let both = await state.brain.answer(question: question, access: Self.owner)
        #expect(both.body.contains("2 sheets answer this") && both.body.contains("350") && both.body.contains("105") && !both.body.contains("455"),
                "\(both.body)")
        #expect(both.citations.count == 2)
        let versionA = try #require(try await db.query("""
            SELECT sv.id FROM source_versions sv JOIN knowledge_objects k ON k.file_id = sv.logical_source_id WHERE k.id = ?;
            """, [.uuid(ra.object.id)]).first?.uuid(0))
        await state.brain.setTableScope([versionA])
        let inCase = await state.brain.answer(question: question, access: .testUnrestricted())
        await state.brain.setTableScope(nil)
        #expect(inCase.body.contains("is 350") && !inCase.body.contains("105"), "only the case's sheet: \(inCase.body)")
        #expect(inCase.citations.map(\.objectID) == [ra.object.id])
        await state.shutdown()
    }
}
