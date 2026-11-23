//
//  UnifiedPathCaseTests.swift
//  KalsmritikoshTests
//
//  Test phase T2 (2026-11-22) — the one case path of the unified-path program (docs/UNIFIED_PATH_PROGRAM_2026-11-22.md §1):
//  AI-17 one path, AI-18 briefing, AI-19 cleaned / de-duplicated text, AI-20 ledger tools loop, AI-21 second look,
//  AI-22 Brain steps, AI-23 analysis on the same path, AI-24 batch reads, AI-25 mask-send-restore, PERF-18 parts.
//  Scripted readers and transports only: no model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Unified path — the one case path", .serialized)
struct UnifiedPathCaseTests {

    nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [CaseReadSend] = []
        private var _tools: [[CaseReader.ToolRequest]] = []
        private var _inFlight = 0, _maxInFlight = 0
        func add(_ r: CaseReadSend) { lock.withLock { _requests.append(r) } }
        func tool(_ r: [CaseReader.ToolRequest]) { lock.withLock { _tools.append(r) } }
        func enter() { lock.withLock { _inFlight += 1; _maxInFlight = max(_maxInFlight, _inFlight) } }
        func leave() { lock.withLock { _inFlight -= 1 } }
        var requests: [CaseReadSend] { lock.withLock { _requests } }
        var tools: [[CaseReader.ToolRequest]] { lock.withLock { _tools } }
        var maxInFlight: Int { lock.withLock { _maxInFlight } }
    }

    nonisolated final class Suffixes: @unchecked Sendable {
        private let lock = NSLock(); private var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
        var list: [String] { lock.withLock { all } }
    }

    struct Doc { let version: UUID; let object: UUID; let name: String; let text: String }

    static let sentencing = CaseWholeReadingTests.sentencing
    static let charging = CaseWholeReadingTests.charging
    static let secondLookTask = "Task: a check of an answer already given"

    static func docs() -> [Doc] {
        [Doc(version: UUID(), object: UUID(), name: "a-sentencing.txt", text: sentencing),
         Doc(version: UUID(), object: UUID(), name: "b-indictment.txt", text: charging)]
    }

    struct Fixture {
        let service: InvestigationAnswerService
        let caseID: UUID
        let recorder: Recorder
        let plan: CaseWholeReading
        let byVersion: [UUID: Doc]
    }

    /// A ledger with one case over `docs`; the reader replies `reply(request)`; `configure` adjusts the plan.
    static func fixture(_ docs: [Doc], limit: Int = 300_000,
                        configure: (inout CaseWholeReading, Recorder) -> Void = { _, _ in },
                        reply: @escaping @Sendable (CaseReadSend) -> String = { _ in CaseWholeReadingTests.answered() }) async throws -> Fixture {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = try await cases.createCase(workspaceID: ws, title: "Smith", actor: "u", at: t0)
        for d in docs {
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: d.version.uuidString,
                                              sourceKind: .sourceVersion, actor: "u", at: t0)
        }
        let byVersion = Dictionary(uniqueKeysWithValues: docs.map { ($0.version, $0) })
        let recorder = Recorder()
        var plan = CaseWholeReading(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                CaseReader.Document(objectID: $0.object, sourceVersionID: $0.version, fileName: $0.name, text: $0.text) } },
            gate: { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                    legacyPrivileged: { [] }) },
            reader: { CaseReader { send in
                recorder.add(send)
                return CaseReader.Reply(text: reply(send), usage: CloudCallUsage(inputTokens: 40, cacheWriteTokens: 900, cacheReadTokens: 0,
                                                                                 outputTokens: 120, purpose: send.purpose, provider: "test"))
            } },
            permissions: CaseReadPermissionStore.inMemory(),
            askConsent: { _ in true },
            wholeCaseLimit: { limit })
        configure(&plan, recorder)
        let service = InvestigationAnswerService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), baseRetriever: CaseWholeReadingTests.EmptyRetriever(),
            evidence: evidence, makeBrain: { MasterBrain(retriever: $0) },
            objectVersions: { versions in
                Dictionary(uniqueKeysWithValues: versions.compactMap { byVersion[$0] }.map { ($0.object, Set([$0.version])) })
            },
            caseReading: plan)
        return Fixture(service: service, caseID: c.id, recorder: recorder, plan: plan, byVersion: byVersion)
    }

    static func padded(_ base: String, _ line: (Int) -> String) -> String {
        ([base] + (0..<700).map(line)).joined(separator: "\n\n")
    }

    /// Two documents that cannot share one read at a limit of 10 tokens (parts budget = 8,000 tokens).
    static func largeDocs() -> [Doc] {
        let d = docs()
        return [Doc(version: d[0].version, object: d[0].object, name: d[0].name,
                    text: padded(sentencing) { "Court clerk note \($0): exhibit list page \($0) reviewed for the sentencing file." }),
                Doc(version: d[1].version, object: d[1].object, name: d[1].name,
                    text: padded(charging) { "Grand jury minute \($0): witness roster entry \($0) logged by the foreperson." })]
    }

    static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    // MARK: - AI-17 / PERF-18 — one path, parts

    @Test("AI-17: a small and a large case take the same steps — every read carries the briefing, the question and a second look; only the part count differs")
    func onePathForEverySize() async throws {
        // Updated for AI-43 (owner 2026-11-23): rule entity kinds are not passed as facts — the name is a labelled hint.
        let briefingLine = "- John Smith [D1]"
        func configure(_ plan: inout CaseWholeReading, _ r: Recorder) {
            plan.briefing = { _, docs in
                var m = CaseLedgerBriefing.Material()
                m.entities = [.init(id: UUID(), kind: "person", value: "John Smith", tier: "T1", source: docs[0].objectID, confidence: 0.9, aliases: [])]
                return CaseLedgerBriefing.build(m, number: Dictionary(uniqueKeysWithValues: docs.enumerated().map { ($1.objectID, $0 + 1) }))
            }
        }
        let small = try await Self.fixture(Self.docs(), configure: configure)
        let large = try await Self.fixture(Self.largeDocs(), limit: 10, configure: configure)
        for f in [small, large] {
            let a = try await f.service.answer(caseID: f.caseID, question: "When was John Smith sentenced?", access: .testUnrestricted()).verified
            #expect(await f.service.lastCasePath == .wholeCase, "one path, whatever the size")
            #expect(a.intentKind == VerifiedAnswerComposer.verifiedKind, "\(a.body)")
            // (the AI-37 suggestions read runs in the background after the answer; it is not a question read)
            let questions = f.recorder.requests.filter { $0.purpose == "case.question" && !$0.suffix.hasPrefix(Self.secondLookTask) }
            let looks = f.recorder.requests.filter { $0.purpose == "case.question" && $0.suffix.hasPrefix(Self.secondLookTask) }
            #expect(!questions.isEmpty && looks.count == questions.count, "a second look per part")
            for q in questions {
                #expect(q.prefix.joined().contains(briefingLine), "every part carries the briefing")
                #expect(q.suffix.contains("When was John Smith sentenced?"))
            }
        }
        #expect(small.recorder.requests.filter { $0.purpose == "case.question" && !$0.suffix.hasPrefix(Self.secondLookTask) }.count == 1, "a small case is one part")
        #expect(large.recorder.requests.filter { $0.purpose == "case.question" && !$0.suffix.hasPrefix(Self.secondLookTask) }.count >= 2, "a large case is several parts")
    }

    @Test("PERF-18: part budget from the limit, documents packed in order, a large document split into numbered pieces; parts read at most `concurrency` at once")
    func partsAndConcurrency() async throws {
        #expect(CaseReader.partBudget(limit: 300_000, briefingTokens: 1_000) == 293_000)
        #expect(CaseReader.partBudget(limit: 10, briefingTokens: 1_000) == 8_000, "never below the floor")
        let small = (0..<5).map { CaseReader.Document(objectID: UUID(), fileName: "d\($0).txt", text: String(repeating: "word ", count: 300)) }
        let packed = CaseReader.parts(small, budgetTokens: 1_200)
        #expect(packed.flatMap { $0 }.map(\.document) == [0, 1, 2, 3, 4], "every document, in order")
        #expect(packed.count >= 2 && packed.allSatisfy { part in CaseReader.estimatedTokens(part.map(\.text)) <= 1_200 + 64 * part.count })
        let big = CaseReader.Document(objectID: UUID(), fileName: "big.txt",
                                      text: (0..<400).map { "Paragraph \($0) of the long statement about the shipment." }.joined(separator: "\n\n"))
        let split = CaseReader.parts([big], budgetTokens: 1_000)
        #expect(split.count >= 2 && split.allSatisfy { $0.count == 1 })
        #expect(split.map { $0[0].piece } == Array(1...split.count) && split.allSatisfy { $0[0].pieces == split.count })
        #expect(split.map { $0[0].text }.joined(separator: "\n\n") == big.text, "the pieces cover the document exactly")
        let prefix = CaseReader.partPrefix(briefing: "B", documents: [big], part: split[1], index: 1, count: split.count)
        #expect(prefix[0].contains("This is part 2 of \(split.count)") && prefix.last?.contains("[Document 1] file: big.txt (piece 2 of \(split.count))") == true)

        // Concurrency is bounded by the worker count.
        let r = Recorder()
        let reader = CaseReader { _ in CaseReader.Reply(text: "") }
        let parts = (0..<6).map { ["part \($0)"] }
        _ = try await reader.readCase(parts: parts, question: "Q?", related: [], context: .init(concurrency: 2, secondLook: false)) { _, _ in
            r.enter(); defer { r.leave() }
            try await Task.sleep(for: .milliseconds(40))
            return CaseReader.Reply(text: #"{"status":"not_stated","claims":[],"answer":""}"#)
        }
        #expect(r.maxInFlight == 2, "at most two parts in flight (\(r.maxInFlight))")
    }

    @Test("PERF-18: the parts' claims are merged — a duplicate (same document + quote) kept once, not_stated only when every part says so")
    func mergeParts() throws {
        let claim: [String: Any] = ["text": "T", "quote": "On March 3, 2021", "passage": 1]
        let a = Self.json(["status": "answered", "claims": [claim], "answer": "A1"])
        let b = Self.json(["status": "answered", "claims": [claim, ["text": "U", "quote": "June 9, 2019", "passage": 2]], "answer": "A2"])
        let none = #"{"status":"not_stated","claims":[],"answer":""}"#
        let merged = try #require(CaseReader.parsePart(CaseReader.merge([a, none, b])))
        #expect(merged.status == "answered" && merged.claims?.count == 2 && merged.answer == "A1 A2")
        #expect(CaseReader.parsePart(CaseReader.merge([none, none]))?.status == "not_stated")
    }

    // MARK: - AI-18 — the briefing

    @Test("AI-18: briefing lines carry [D<n>]; a row whose document is not in the case is left out; fixed order, byte-identical on rebuild")
    func briefingBuild() {
        let d1 = UUID(), d2 = UUID(), outside = UUID()
        var m = CaseLedgerBriefing.Material()
        m.entities = [.init(id: UUID(), kind: "person", value: "John Smith", tier: "T1", source: d1, confidence: 0.9, aliases: ["J. Smith"]),
                      .init(id: UUID(), kind: "person", value: "Outsider", tier: "T2", source: outside, confidence: 0.9, aliases: [])]
        m.events = [.init(id: UUID(), kind: "sentencing", date: Date(timeIntervalSince1970: 1_614_729_600), endDate: nil, title: "Sentenced",
                          summary: nil, source: d1, dateConfidence: 0.4, tier: "T1")]
        m.relationships = [.init(kind: "charged by", from: "John Smith", to: "Grand jury", source: d2)]
        m.fields = [.init(type: "amount", value: "USD 5,000", confidence: 0.8, method: "ocr", source: d2)]
        m.contradictions = [.init(description: "Date differs", claimA: "3 March", claimB: "4 March", sourceA: d1, sourceB: d2, severity: "high")]
        m.coverageGaps = [(name: "scan.pdf", reason: "not read: password protected")]
        let number = [d1: 1, d2: 2]
        let b = CaseLedgerBriefing.build(m, number: number)
        // Updated for AI-43 (owner 2026-11-23): AI does the thinking — no rule entity kind, no rule relationship and no
        // rule-only conflict is passed as a fact; names stay as a labelled hint; exact items (dates, typed values,
        // coverage) stay. An AI-found conflict is passed, labelled.
        let hints = CaseLedgerBriefing.hintsTitle + ": names seen in the documents"
        #expect(b.text.contains("- John Smith (also written: J. Smith) [D1]") && !b.text.contains("— person"), "\(b.text)")
        #expect(!b.text.contains("Outsider"), "a line without a case document is never written")
        #expect(b.text.contains("3 Mar 2021 (date approximate): Sentenced [D1]"), "\(b.text)")
        #expect(!b.text.contains("charged by") && !b.text.contains("## Relationships"))
        #expect(b.text.contains("- amount: USD 5,000 (read from a scan) [D2]"))
        #expect(!b.text.contains("\"3 March\" / \"4 March\""), "a rule-only conflict is not a fact")
        #expect(b.text.contains("## Not read on this Mac\n- scan.pdf: not read: password protected"))
        let order = ["## Timeline", "## Recorded values", "## " + hints, "## Not read on this Mac"]
        let positions = order.compactMap { b.text.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count && positions == positions.sorted(), "fixed section order")
        #expect(CaseLedgerBriefing.build(m, number: number).text == b.text, "deterministic")
        #expect(b.lineCounts[hints]?.shown == 1)
        var ai = m
        ai.contradictions[0].foundByAI = true
        #expect(CaseLedgerBriefing.build(ai, number: number).text.contains("## Conflicts already found (found by AI, quote checked)\n- Date differs: \"3 March\" / \"4 March\" [D1] vs [D2]"))
        // The retired path restores the old sections.
        RetiredPaths.TestOverride.$paths.withValue([.ruleBriefingFacts: true]) {
            let old = CaseLedgerBriefing.build(m, number: number).text
            #expect(old.contains("- John Smith — person (also written: J. Smith), tier T1 [D1]") && old.contains("- John Smith — charged by — Grand jury [D2]"))
        }
        #expect(CaseLedgerBriefing.build(CaseLedgerBriefing.Material(), number: number).text.isEmpty)
    }

    @Test("AI-18: the briefing is read from a real ledger — every section's SQL runs on the current schema and the ingested names come back tagged [D1]")
    @MainActor
    func briefingFromRealLedger() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("us-brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest), db = try #require(state.database)
        let file = temp.appendingPathComponent("statement.txt")
        let text = "Statement of Asha Rao, 3 March 2026.\nAsha Rao said she approved invoice INV-2041 for Dalmia Traders on 3 March 2026."
        try Data(text.utf8).write(to: file)
        let r = try await ingest.ingest(fileAt: file)
        let id = r.object.id
        var versionToObject: [UUID: UUID] = [:]
        if let v = r.sourceVersionID { versionToObject[v] = id }
        let material = try await CaseBriefingRepository(database: db).material(objectIDs: [id], versionToObject: versionToObject,
                                                                               caseID: UUID(), texts: [id: text])
        #expect(!material.entities.isEmpty, "the ingested names are read back")
        let b = CaseLedgerBriefing.build(material, number: [id: 1])
        // Updated for AI-43 (owner 2026-11-23): the names come back as a labelled hint, without a rule kind.
        #expect(b.text.contains("## " + CaseLedgerBriefing.hintsTitle) && b.text.contains("- Asha Rao [D1]"), "\(b.text)")
        let lines = b.text.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(!lines.isEmpty && lines.allSatisfy { $0.hasSuffix("[D1]") }, "\(lines)")
        await state.shutdown()
    }

    // MARK: - AI-19 — cleaned, de-duplicated text

    @Test("AI-19: the ingest stores a cleaned copy (signature, disclaimer, quoted reply removed) beside the untouched content")
    @MainActor
    func cleanedCopyStored() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("us-clean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        let ingest = try #require(state.ingest), objects = try #require(state.objects)
        let file = temp.appendingPathComponent("note.txt")
        let body = """
        The shipment left Mumbai on 4 May 2026 with 40 cartons.

        > earlier line one
        > earlier line two

        CONFIDENTIALITY NOTICE: this message is for the named recipient only and may be privileged.

        --
        Priya Nair
        Logistics desk
        """
        try Data(body.utf8).write(to: file)
        let r = try await ingest.ingest(fileAt: file)
        let stored = try #require(try await objects.fetchReaderText(id: r.object.id))
        let clean = try #require(stored.clean)
        #expect(clean.contains("The shipment left Mumbai on 4 May 2026 with 40 cartons."))
        #expect(!clean.contains("CONFIDENTIALITY NOTICE") && !clean.contains("Logistics desk") && !clean.contains("earlier line one"), "\(clean)")
        #expect(clean.contains("[quoted earlier message collapsed]"))
        #expect(stored.content.contains("CONFIDENTIALITY NOTICE"), "the evidence text is never rewritten")
        await state.shutdown()
    }

    @Test("AI-19: near-identical copies and same-text copies are sent once, the kept one names its copies; each document keeps its source version")
    func nearDuplicatesSentOnce() async throws {
        let base = (0..<40).map { "Line \($0): the consignment of forty cartons was inspected at the Mumbai warehouse by the agent." }.joined(separator: "\n")
        var docs = Self.docs()
        let v = UUID(), o = UUID(), v2 = UUID(), o2 = UUID(), v3 = UUID(), o3 = UUID()
        docs.append(Doc(version: v, object: o, name: "c-report.txt", text: base))
        docs.append(Doc(version: v2, object: o2, name: "d-report-copy.txt", text: base + "\nForwarded."))
        docs.append(Doc(version: v3, object: o3, name: "e-report-same.txt", text: base))
        let f = try await Self.fixture(docs)
        let binding = CloudScopeBinding(scopeID: f.caseID) { Dictionary(uniqueKeysWithValues: docs.map { ($0.object, Set([$0.version])) }) }
        let (prepared, _) = await f.plan.prepare(caseID: f.caseID, versions: Set(docs.map(\.version)), binding: binding)
        let p = try #require(prepared)
        #expect(p.documents.count == 3, "two copies dropped: \(p.documents.map { $0.fileName ?? "" })")
        let kept = try #require(p.documents.first { $0.objectID == o })
        #expect(kept.text.contains("[Near-identical copies of this document in the case, not repeated: d-report-copy.txt]"), "\(kept.text.suffix(200))")
        #expect(p.documents.allSatisfy { d in d.sourceVersionID == docs.first { $0.object == d.objectID }?.version }, "pinned to its version")
    }

    // MARK: - AI-20 — ledger tools loop

    @Test("AI-20: the reader asks for ledger tools as plain JSON; the app answers locally and asks again; rounds are bounded")
    func ledgerToolsLoop() async throws {
        let r = Recorder()
        let reader = CaseReader { _ in CaseReader.Reply(text: "") }
        let tools: @Sendable ([CaseReader.ToolRequest]) async -> String = { reqs in r.tool(reqs); return "timeline(sentenced): \n- Sentenced 3 Mar 2021 [D1]" }
        let need = #"{"status":"need_tools","requests":[{"tool":"timeline","arg":"sentenced"}]}"#
        // A reader that asks once, then answers.
        let s1 = Suffixes()
        let (merged, _) = try await reader.readCase(parts: [["p"]], question: "When?", related: [1], context: .init(tools: tools, toolRounds: 2, secondLook: false)) { _, suffix in
            s1.add(suffix)
            return CaseReader.Reply(text: suffix.contains("Ledger tool results") ? CaseWholeReadingTests.answered() : need)
        }
        #expect(s1.list.count == 2 && r.tools.count == 1 && r.tools[0] == [CaseReader.ToolRequest(tool: "timeline", arg: "sentenced")])
        #expect(s1.list[0].contains("Ledger tools:") && s1.list[0].contains("most related to the question: Document 1"))
        #expect(s1.list[1].contains("- Sentenced 3 Mar 2021 [D1]"), "the local result goes back with its document number")
        #expect(CaseReader.parsePart(merged)?.status == "answered")
        // A reader that always asks: at most toolRounds rounds of tools, then a last read without tools offered.
        let s2 = Suffixes()
        _ = try await reader.readCase(parts: [["p"]], question: "When?", related: [], context: .init(tools: tools, toolRounds: 2, secondLook: false)) { _, suffix in
            s2.add(suffix); return CaseReader.Reply(text: need)
        }
        #expect(s2.list.count == 3 && !(s2.list.last ?? "").contains("Ledger tools:"), "bounded: \(s2.list.count) reads")
    }

    @Test("AI-20: on the case path the plan's tools are offered to the reader and its requests answered")
    func ledgerToolsOnThePath() async throws {
        let f = try await Self.fixture(Self.docs(), configure: { plan, r in
            plan.tools = { _, docs in
                { reqs in r.tool(reqs); return "field(sentence): \n- 60 months [D1] (of \(docs.count) documents)" }
            }
        }, reply: { send in
            if send.suffix.hasPrefix(Self.secondLookTask) { return #"{"status":"not_stated","claims":[],"answer":""}"# }
            return send.suffix.contains("Ledger tool results") ? CaseWholeReadingTests.answered()
                : #"{"status":"need_tools","requests":[{"tool":"field","arg":"sentence"}]}"#
        })
        let a = try await f.service.answer(caseID: f.caseID, question: "When was John Smith sentenced?", access: .testUnrestricted()).verified
        #expect(f.recorder.tools.count == 1 && f.recorder.tools.first?.first?.tool == "field")
        #expect(a.intentKind == VerifiedAnswerComposer.verifiedKind, "\(a.body)")
    }

    // MARK: - AI-21 — second look

    @Test("AI-21: the second look's verified claims are shown as 'Also worth checking'; an unverifiable one is not")
    func secondLookShown() async throws {
        let f = try await Self.fixture(Self.docs(), reply: { send in
            guard send.suffix.hasPrefix(Self.secondLookTask) else { return CaseWholeReadingTests.answered() }
            #expect(send.suffix.contains("Answer given: John Smith was sentenced on March 3, 2021."))
            return Self.json(["status": "answered", "answer": "Charged earlier.", "claims": [
                ["text": "A grand jury charged John Smith on June 9, 2019.", "quote": "A federal grand jury charged John Smith with wire fraud on June 9, 2019", "passage": 2],
                ["text": "He was pardoned in 2022.", "quote": "John Smith was pardoned in 2022", "passage": 1]]])
        })
        let a = try await f.service.answer(caseID: f.caseID, question: "When was John Smith sentenced?", access: .testUnrestricted()).verified
        #expect(a.body.contains("Also worth checking (a second AI look"), "\(a.body)")
        #expect(a.body.contains("A federal grand jury charged John Smith with wire fraud on June 9, 2019"))
        #expect(!a.body.contains("pardoned"), "a second-look claim that does not verify is never shown")
        #expect(CaseReader.secondLookNote(reply: #"{"status":"not_stated","claims":[]}"#, question: "Q", documents: []) == nil)
    }

    // MARK: - AI-22 — Brain steps

    @Test("AI-22: the Brain steps run first on the case path — a message to the app (not a case question) is refused and nothing is sent")
    func brainStepsRefuseFirst() async throws {
        let f = try await Self.fixture(Self.docs())
        let a = try await f.service.answer(caseID: f.caseID, question: "hello there", access: .testUnrestricted()).verified
        #expect(a.refused, "\(a.body)")
        #expect(f.recorder.requests.isEmpty, "no case read for a message to the app")
        let steps = await MasterBrain(retriever: CaseWholeReadingTests.EmptyRetriever()).caseEvidenceSteps(question: "thanks", access: .testUnrestricted())
        #expect(steps.refusal != nil)
        let real = await MasterBrain(retriever: CaseWholeReadingTests.EmptyRetriever()).caseEvidenceSteps(question: "When was John Smith sentenced?", access: .testUnrestricted())
        #expect(real.refusal == nil, "a case question goes on to the reader")
    }

    // MARK: - AI-23 / AI-24 — analysis on the same path, batch reads

    @Test("AI-23 + AI-24: a large case's analysis is read whole in parts (not passages), as background batch reads; replies merged into one JSON")
    func analysisOnTheSamePath() async throws {
        let docs = Self.largeDocs()
        let f = try await Self.fixture(docs, limit: 10, reply: { send in
            send.prefix.joined().contains(Self.sentencing)
                ? Self.json(["status": "not_stated", "items": [["a": 1]], "complete": true, "note": "first"])
                : Self.json(["status": "answered", "items": [["a": 1], ["b": 2]], "complete": false, "note": "second"])
        })
        let binding = CloudScopeBinding(scopeID: f.caseID) { Dictionary(uniqueKeysWithValues: docs.map { ($0.object, Set([$0.version])) }) }
        let versions = Set(docs.map(\.version))
        guard case .passages = await f.plan.analysisRoute(caseID: f.caseID, versions: versions, binding: binding) else {
            Issue.record("without the case's permission analysis must not read whole"); return
        }
        let (prepared, _) = await f.plan.prepare(caseID: f.caseID, versions: versions, binding: binding)
        let p = try #require(prepared)
        f.plan.permissions.grant(caseID: f.caseID, fingerprint: p.fingerprint, documentCount: p.documents.count)
        guard case .wholeCase(let reader, let prep) = await f.plan.analysisRoute(caseID: f.caseID, versions: versions, binding: binding) else {
            Issue.record("a large case with permission is read whole in parts"); return
        }
        #expect(prep.parts.count >= 2 && !prep.fits)
        let reply = try await f.plan.readForAnalysis(reader, prep, caseID: f.caseID, task: "TASK: conflicts", replyTokens: 1_000,
                                                     purpose: "case.analysis", background: true)
        #expect(f.recorder.requests.count == prep.parts.count && f.recorder.requests.allSatisfy { $0.batch && $0.suffix == "TASK: conflicts" })
        let root = try #require(try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any])
        #expect(root["status"] as? String == "answered", "first status that is not not_stated")
        #expect((root["items"] as? [Any])?.count == 2, "arrays joined, a repeated item kept once")
        #expect(root["complete"] as? Bool == false, "booleans AND-ed")
        #expect(root["note"] as? String == "first second")
        #expect(reply.usage?.inputTokens == 40 * prep.parts.count, "usage summed over the parts")
        // Questions stay interactive.
        _ = try await f.service.answer(caseID: f.caseID, question: "When was John Smith sentenced?", access: .testUnrestricted())
        #expect(f.recorder.requests.dropFirst(prep.parts.count).allSatisfy { !$0.batch })
    }

    @Test("AI-24: the batch transport — one-request Anthropic batch without fallbacks; relay route for the plan; no batch path for other providers; ids and results parsed strictly")
    func batchTransport() throws {
        let create = try #require(try OnlineRequestBuilder.buildCaseBatchCreate(kind: .anthropic, model: "test-model", apiKey: "k", prefix: ["P"],
                                                                                suffix: "S", replyTokens: 500, ttl: .oneHour, effort: .high))
        #expect(create.url.hasSuffix("/v1/messages/batches"))
        let body = String(decoding: create.body, as: UTF8.self)
        #expect(body.contains(#""custom_id":"case-read-1""#) && !body.contains("fallbacks"), "\(body.prefix(300))")
        // (the AI-plan relay route needs a subscription token; not built here)
        #expect(try OnlineRequestBuilder.buildCaseBatchCreate(kind: .openai, model: "m", apiKey: "k", prefix: ["P"], suffix: "S",
                                                              replyTokens: 500, ttl: .oneHour, effort: .high) == nil, "no batch path: interactive")
        let poll = try OnlineRequestBuilder.buildCaseBatchPoll(kind: .anthropic, apiKey: "k", batchID: "msgbatch_01")
        #expect(poll.method == "GET" && poll.purpose == "batch")
        #expect(OnlineRequestBuilder.isBatchID("msgbatch_01-x") && !OnlineRequestBuilder.isBatchID("../v1/x") && !OnlineRequestBuilder.isBatchID(""))
        #expect(try OnlineRequestBuilder.batchID(OutboundHTTPResponse(status: 200, body: Data(#"{"id":"msgbatch_01"}"#.utf8))) == "msgbatch_01")
        #expect(throws: OnlineRequestBuilder.BatchError.self) { _ = try OnlineRequestBuilder.batchID(OutboundHTTPResponse(status: 200, body: Data(#"{"id":"a/b"}"#.utf8))) }
        #expect(try OnlineRequestBuilder.batchEnded(OutboundHTTPResponse(status: 200, body: Data(#"{"processing_status":"ended"}"#.utf8))))
        #expect(!(try OnlineRequestBuilder.batchEnded(OutboundHTTPResponse(status: 200, body: Data(#"{"processing_status":"in_progress"}"#.utf8)))))
        let lines = #"{"custom_id":"other","result":{"type":"succeeded","message":{}}}"# + "\n" +
            #"{"custom_id":"case-read-1","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"OK"}]}}}"#
        let msg = try OnlineRequestBuilder.batchMessage(OutboundHTTPResponse(status: 200, body: Data(lines.utf8)))
        #expect(String(decoding: msg.body, as: UTF8.self).contains("OK"))
        let failed = #"{"custom_id":"case-read-1","result":{"type":"errored","error":{"error":{"message":"overloaded"}}}}"#
        #expect(throws: OnlineRequestBuilder.BatchError.failed("overloaded")) { _ = try OnlineRequestBuilder.batchMessage(OutboundHTTPResponse(status: 200, body: Data(failed.utf8))) }
        #expect(try OnlineRequestBuilder.relayBatchResult(OutboundHTTPResponse(status: 202, body: Data())) == nil, "still running")
    }

    // MARK: - AI-25 — mask, send, restore

    nonisolated final class Bodies: @unchecked Sendable {
        private let lock = NSLock(); private var items: [Data] = []
        func add(_ d: Data) { lock.withLock { items.append(d) } }
        var all: [Data] { lock.withLock { items } }
    }

    @Test("AI-25: names are masked before the send and restored on the Mac before the verifier — the reply's quote then verifies against the document")
    func maskSendRestore() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let caseID = UUID(), o = UUID(), v = UUID()
        let binding = CloudScopeBinding(scopeID: caseID) { [o: [v]] }
        let clearance = await CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) },
                                              legacyPrivileged: { [] }).bound(to: binding).clear([o], purpose: "case.reading").clearance
        let bodies = Bodies()
        let snapshot = OnlineSnapshot(cloudAllowed: true, kind: .anthropic, model: "test-model", apiKey: "test-key",
                                      confirmedDocumentTerms: OnlineProviderKind.anthropic.documentTermsVersion, dailyByteCap: nil)
        let permissions = CaseReadPermissionStore.inMemory()
        permissions.grant(caseID: caseID, fingerprint: CaseReadPermission.fingerprint(caseID: caseID, versions: clearance.versions), documentCount: 1)
        var seams = OnlineCloudProvider.Seams(settings: { snapshot }, consent: { _ in false }, transport: { req in
            bodies.add(req.body)
            // The scripted provider answers with the placeholder it was sent.
            let sent = String(decoding: req.body, as: UTF8.self)
            let token = sent.range(of: #"\[NAME_\d+\]"#, options: .regularExpression).map { String(sent[$0]) } ?? "?"
            let inner = Self.json(["status": "answered", "answer": "\(token) was sentenced on March 3, 2021.",
                                   "claims": [["text": "\(token) was sentenced on March 3, 2021.",
                                               "quote": "On March 3, 2021, \(token) was sentenced to 60 months in prison", "passage": 1]]])
            let reply = Self.json(["content": [["type": "text", "text": inner]],
                                   "usage": ["input_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0, "output_tokens": 5]])
            return OutboundHTTPResponse(status: 200, body: Data(reply.utf8))
        })
        seams.casePermission = { id, fp in permissions.isGranted(caseID: id, fingerprint: fp) }
        let provider = OnlineCloudProvider(outboundLog: OutboundLogRepository(database: db), knownNames: { [] },
                                           protectedNames: { ["John Smith"] }, seams: seams)
        let doc = CaseReader.Document(objectID: o, sourceVersionID: v, fileName: "a.txt", text: Self.sentencing)
        let send = CaseReadSend(caseID: caseID, prefix: CaseReader.prefix([doc]), suffix: CaseReader.questionSuffix("When was John Smith sentenced?"),
                                ttl: .fiveMinutes, purpose: "case.question", clearance: clearance)
        let out = try await provider.readCase(send)
        let sent = String(decoding: try #require(bodies.all.first), as: UTF8.self)
        #expect(!sent.contains("John Smith") && sent.contains("[NAME_1]"), "the name never leaves the Mac")
        #expect(out.text.contains("John Smith was sentenced") && !out.text.contains("[NAME_"), "restored on the Mac: \(out.text)")
        guard case .answered(let a) = CaseReader.verdict(reply: out.text, question: "When was John Smith sentenced?", documents: [doc], rules: nil) else {
            Issue.record("the restored quote verifies against the document"); return
        }
        #expect(a.intentKind == VerifiedAnswerComposer.verifiedKind)
    }
}
