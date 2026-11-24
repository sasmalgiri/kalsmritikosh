//
//  AgentSplitX2Tests.swift
//  KalsmritikoshTests
//
//  AI split X2 (owner 2026-11-23) — AI-44 the agent loop (READ / EXACT / WRITE tools, every write quote-checked, a rejected
//  write returned with its reason), AI-45 the AI case picture as the briefing (stable prefix, incremental, erased with the
//  case or the person), AI-46 the AI's own conclusion shown first, only with verified support. Scripted readers only: no
//  model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI split X2 — agent loop, case picture, conclusion", .serialized)
struct AgentSplitX2Tests {

    // Two payments and a refund, the INV-104 shape in miniature.
    static let bank = "Bank statement, March 2026. 05 Mar 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77120. 12 Mar 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77985. 19 Mar 2026: credit INR 50,000 refund from Kestrel Supplies."
    static let memo = "Amendment A: the second debit KS-77985 settles PO-561 / INV-109; the two settlements are distinct payments. Approved by Meera Iyer."

    static func docs() -> [UnifiedPathCaseTests.Doc] {
        [UnifiedPathCaseTests.Doc(version: UUID(), object: UUID(), name: "a-bank.txt", text: bank),
         UnifiedPathCaseTests.Doc(version: UUID(), object: UUID(), name: "b-amendment.txt", text: memo)]
    }

    struct Rig {
        let service: InvestigationAnswerService
        let caseID: UUID
        let recorder: UnifiedPathCaseTests.Recorder
        let plan: CaseWholeReading
        let db: Database
        let repo: CaseAIRecordRepository
    }

    /// A ledger with one case over `docs`, the record store wired, and a scripted reader.
    /// ALCOA ALC-02 / ALC-08 — `served`: the model each scripted reply says answered (nil: the reply carries no usage);
    /// `requested`: the model the plan asks for.
    static func rig(_ docs: [UnifiedPathCaseTests.Doc], served: (@Sendable (CaseReadSend) -> String?)? = nil, requested: String? = nil,
                    reply: @escaping @Sendable (CaseReadSend) -> String) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let evidence = EvidenceStore(database: db)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var c = try await cases.createCase(workspaceID: ws, title: "Kestrel", actor: "u", at: t0)
        for d in docs {
            c = try await cases.includeSource(caseID: c.id, expectedRevision: c.revision, sourceRef: d.version.uuidString,
                                              sourceKind: .sourceVersion, actor: "u", at: t0)
        }
        let byVersion = Dictionary(uniqueKeysWithValues: docs.map { ($0.version, $0) })
        let recorder = UnifiedPathCaseTests.Recorder()
        let repo = CaseAIRecordRepository(database: db)
        let briefingRepo = CaseBriefingRepository(database: db)
        let caseID = c.id
        var plan = CaseWholeReading(
            documents: { versions in versions.compactMap { byVersion[$0] }.map {
                CaseReader.Document(objectID: $0.object, sourceVersionID: $0.version, fileName: $0.name, text: $0.text) } },
            gate: { CloudSourceGate(resolve: { _ in .resolved(ProtectionLabel(sensitivity: .internalLevel, privileged: false)) }, legacyPrivileged: { [] }) },
            reader: { CaseReader { send in
                recorder.add(send)
                guard let model = served?(send) else { return CaseReader.Reply(text: reply(send)) }
                var usage = CloudCallUsage(inputTokens: 100, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 10, purpose: send.purpose, provider: "anthropic")
                usage.model = model
                return CaseReader.Reply(text: reply(send), usage: usage)
            } },
            permissions: CaseReadPermissionStore.inMemory(),
            askConsent: { _ in true })
        plan.aiRecords = repo
        if let requested { plan.modelRequested = { requested }; plan.providerID = { "anthropic" } }
        plan.briefing = { id, d in
            let number = Dictionary(uniqueKeysWithValues: d.enumerated().map { ($1.objectID, $0 + 1) })
            do {
                let m = try await briefingRepo.material(objectIDs: d.map(\.objectID), versionToObject: [:], caseID: id,
                                                        texts: Dictionary(uniqueKeysWithValues: d.map { ($0.objectID, $0.text) }))
                return CaseLedgerBriefing.build(m, number: number)
            } catch { return nil }
        }
        let service = InvestigationAnswerService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: evidence), baseRetriever: CaseWholeReadingTests.EmptyRetriever(),
            evidence: evidence, makeBrain: { MasterBrain(retriever: $0) },
            objectVersions: { versions in Dictionary(uniqueKeysWithValues: versions.compactMap { byVersion[$0] }.map { ($0.object, Set([$0.version])) }) },
            caseReading: plan)
        return Rig(service: service, caseID: caseID, recorder: recorder, plan: plan, db: db, repo: repo)
    }

    static func json(_ o: [String: Any]) -> String { UnifiedPathCaseTests.json(o) }

    /// The picture reply: round 0 writes an entity, a good fact and a BAD fact (quote not in the document); round 1 sees the
    /// rejection and sends the corrected fact; then "done".
    static func pictureReply(_ send: CaseReadSend) -> String {
        if !send.suffix.contains("Tool results so far") {
            return json(["status": "need_tools", "requests": [
                ["tool": "record_entity", "name": "Kestrel Supplies", "type": "organisation", "role": "supplier paid",
                 "quote": "debit INR 50,000 to Kestrel Supplies, ref KS-77120", "document": 1],
                ["tool": "record_event", "date": "19 Mar 2026", "what": "refund of INR 50,000 from Kestrel",
                 "quote": "19 Mar 2026: credit INR 50,000 refund from Kestrel Supplies", "document": 1],
                ["tool": "record_fact", "text": "The second debit settles INV-109.", "quote": "the second debit settles invoice INV-109 in full", "document": 2],
            ] as [[String: Any]]])
        }
        if send.suffix.contains("REJECTED"), !send.suffix.contains("Step 2:") {
            return json(["status": "need_tools", "requests": [
                ["tool": "record_fact", "text": "The second debit KS-77985 settles INV-109.",
                 "quote": "the second debit KS-77985 settles PO-561 / INV-109", "document": 2],
            ] as [[String: Any]]])
        }
        return #"{"status": "done"}"#
    }

    /// The question a task asks (its "Question: …" line) — the reply's "answers_question" (AI-50 fix).
    static func asked(_ task: String) -> String {
        task.components(separatedBy: "\n").first { $0.hasPrefix("Question: ") }.map { String($0.dropFirst("Question: ".count)) } ?? ""
    }

    static func questionReply(_ send: CaseReadSend) -> String {
        if send.suffix.hasPrefix(UnifiedPathCaseTests.secondLookTask) { return #"{"status": "not_stated", "claims": [], "answer": ""}"# }
        if !send.suffix.contains("Tool results so far") {
            return json(["status": "need_tools", "requests": [
                ["tool": "sum", "items": ["INR 50,000", "INR 50,000"], "minus": ["INR 50,000"]],
                ["tool": "search", "words": "KS-77985"],
            ] as [[String: Any]]])
        }
        return json(["status": "answered", "answers_question": asked(send.suffix),
                     "conclusion": "No — paid once; the second debit settles a different invoice (INV-109), and the net outflow is INR 50,000.",
                     "claims": [["text": "The second debit KS-77985 settles PO-561 / INV-109.", "quote": "the second debit KS-77985 settles PO-561 / INV-109", "passage": 2],
                                ["text": "A debit of INR 50,000 went to Kestrel Supplies.", "quote": "debit INR 50,000 to Kestrel Supplies, ref KS-77120", "passage": 1]],
                     "answer": "Paid once."] as [String: Any])
    }

    // MARK: - AI-44 EXACT tools

    @Test("AI-44 sum: the app parses INR 50,000, $2.75 million, 5 lakh and crore, and returns the exact total with every term; currencies never mix")
    func sumTool() {
        let a = CaseAgent.sum(plus: ["INR 50,000", "INR 50,000"], minus: ["INR 50,000"])
        #expect(a?.totals["INR"] == 50_000 && a?.text.hasPrefix("INR 50,000 + INR 50,000 − INR 50,000 = INR 50,000") == true, "\(a?.text ?? "")")
        // ALCOA ALC-03: "$" and "Rs" name no single currency — read, but the currency is unclear (never assumed USD / INR).
        #expect(CaseAgent.amount("$2.75 million")?.value == 2_750_000 && CaseAgent.amount("$2.75 million")?.isCurrencyUnclear == true)
        #expect(CaseAgent.amount("US$2.75 million") == CaseAgent.Amount(value: 2_750_000, currency: "USD", text: "US$2.75 million"))
        #expect(CaseAgent.amount("5 lakh")?.value == 500_000)
        #expect(CaseAgent.amount("Rs 1.2 crore")?.value == 12_000_000 && CaseAgent.amount("Rs 1.2 crore")?.candidates.contains("INR") == true)
        #expect(CaseAgent.amount("Rs. 1,00,000")?.value == 100_000)
        let mixed = CaseAgent.sum(plus: ["INR 50,000", "5 lakh"], minus: [])
        #expect(mixed?.totals["INR"] == 550_000 && mixed?.text.contains("taken as INR") == true, "\(mixed?.text ?? "")")
        let two = CaseAgent.sum(plus: ["$2.75 million", "INR 50,000"], minus: [])
        #expect(two?.totals.count == 2 && two?.text.contains("never added together") == true)
        #expect(CaseAgent.sum(plus: ["no amount here"], minus: []) == nil)
        #expect(CaseAgent.compareDates("5 March 2026", "19 March 2026").contains("14 days before"))
    }

    // MARK: - AI-44 the loop, with a rejected write

    @Test("AI-44 loop: picture writes are verified (a bad quote is REJECTED with its reason, the AI corrects it), the question's sum result comes back in the next step, records are stored labelled")
    func agentLoopRoundTrips() async throws {
        let r = try await Self.rig(Self.docs()) { send in send.purpose == "case.picture" ? Self.pictureReply(send) : Self.questionReply(send) }
        let a = try await r.service.answer(caseID: r.caseID, question: "Was Kestrel Supplies paid twice for INV-104?", access: .testUnrestricted()).verified
        let pictures = r.recorder.requests.filter { $0.purpose == "case.picture" }
        #expect(pictures.count == 3 && pictures.allSatisfy(\.batch), "picture: write, correct, done — \(pictures.count)")
        #expect(pictures[1].suffix.contains("REJECTED — quote not in Document 2"), "the rejection reason goes back to the AI")
        let stored = try await r.repo.records(caseID: r.caseID)
        #expect(Set(stored.map(\.kind)) == [.entity, .event, .fact], "\(stored)")
        #expect(stored.allSatisfy { $0.origin == "picture" })
        #expect(try await CaseErasureTests.count(r.db, "SELECT COUNT(*) FROM case_ai_records WHERE checked = 'found by AI, quote checked';", []) == 3)
        let questions = r.recorder.requests.filter { $0.purpose == "case.question" && !$0.suffix.hasPrefix(UnifiedPathCaseTests.secondLookTask) }
        #expect(questions.count == 2)
        #expect(questions[1].suffix.contains("INR 50,000 + INR 50,000 − INR 50,000 = INR 50,000") && questions[1].suffix.contains("[D1]"))
        // AI-46: the conclusion first, then the checked statements and the app's arithmetic.
        #expect(a.body.hasPrefix("AI's conclusion: No — paid once"), "\(a.body)")
        #expect(a.body.contains("The app's arithmetic (exact, computed on this Mac):\n• INR 50,000 + INR 50,000 − INR 50,000 = INR 50,000"))
        // The second look was asked about the verified answer.
        let look = try #require(r.recorder.requests.first { $0.suffix.hasPrefix(UnifiedPathCaseTests.secondLookTask) })
        #expect(look.suffix.contains("AI's conclusion: No — paid once") && look.suffix.contains("settles PO-561 / INV-109"))
    }

    // MARK: - AI-45 stable prefix, picture briefing, incremental

    @Test("AI-45: the briefing is the AI picture; every question sends the same prefix; nothing question-specific is in it; unchanged documents are not read again")
    func stablePrefix() async throws {
        let r = try await Self.rig(Self.docs()) { send in send.purpose == "case.picture" ? Self.pictureReply(send) : Self.questionReply(send) }
        for q in ["Was Kestrel Supplies paid twice for INV-104?", "Who approved the amendment?", "What came back on 19 March?"] {
            _ = try await r.service.answer(caseID: r.caseID, question: q, access: .testUnrestricted())
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let qs = r.recorder.requests.filter { $0.purpose == "case.question" }
        let prefixes = Set(qs.map { CasePartReplyRepository.digest($0.prefix) })
        #expect(prefixes.count == 1, "one prefix for the case: \(prefixes.count)")
        let briefing = try #require(qs.first?.prefix[1])
        #expect(briefing.contains("## People and organisations (found by AI, quote checked)\n- Kestrel Supplies — organisation; supplier paid [D1]"), "\(briefing)")
        #expect(briefing.contains("## Dated events (found by AI, quote checked)\n- 19 Mar 2026: refund of INR 50,000 from Kestrel [D1]"))
        #expect(briefing.contains("- Read whole by the AI for this picture: 2 of 2"))
        #expect(!briefing.contains("Answers already verified") && !briefing.contains("AI suggestions") && !briefing.contains(CaseLedgerBriefing.hintsTitle))
        #expect(r.recorder.requests.filter { $0.purpose == "case.picture" }.count == 3, "unchanged documents are not read again")
        // A line clipped for length keeps its document tag.
        let clipped = CaseLedgerBriefing.clip("- " + String(repeating: "word ", count: 100) + "[D3] [D7]")
        #expect(clipped.count <= 300 && clipped.hasSuffix("… [D3] [D7]"), "\(clipped)")
    }

    @Test("AI-45 erasure: a case erase deletes the case's AI records and picture state (another case's stay); a person erase deletes the records naming them")
    func pictureErased() async throws {
        let f = try await CaseErasureTests.boot()
        defer { try? FileManager.default.removeItem(at: f.temp) }
        let repo = CaseAIRecordRepository(database: f.db)
        let doc = UUID()
        for c in [f.caseA, f.caseB] {
            try await repo.record(caseID: c, [CaseAIRecord(kind: .fact, text: "A fact of the case", quote: "a quote of the case", document: doc, origin: "picture")])
            try await repo.markRead(caseID: c, documents: [(doc, "fp")], records: 1, rejected: 0)
        }
        let out = try await f.state.eraseCase(f.caseA, eraseExclusiveSources: false, reason: "Client request", legalBasis: nil, actor: "Tester")
        #expect(out.report.refused == nil, "\(out.report.refused ?? "")")
        for t in ["case_ai_records", "case_ai_picture_documents"] {
            #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM \(t) WHERE upper(case_id) = upper(?);", [.uuid(f.caseA)]) == 0, "\(t)")
            #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM \(t) WHERE upper(case_id) = upper(?);", [.uuid(f.caseB)]) == 1, "\(t)")
        }
        let row = try #require(try await f.db.query("SELECT id, value FROM entities WHERE kind = 'person' AND value LIKE '%Roberts%' LIMIT 1;", []).first)
        let personID = try #require(row.string(0).flatMap(UUID.init(uuidString:)))
        let name = try #require(row.string(1))
        try await repo.record(caseID: f.caseB, [CaseAIRecord(kind: .entity, text: name, entityType: "person", quote: "\(name) was charged", document: doc, origin: "picture")])
        let person = try await f.state.erasePerson(personID, reason: "Subject request", legalBasis: nil, actor: "Tester")
        #expect(person.report.refused == nil)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_records WHERE kind = 'entity';", []) == 0)
        #expect(try await CaseErasureTests.count(f.db, "SELECT COUNT(*) FROM case_ai_records WHERE upper(case_id) = upper(?);", [.uuid(f.caseB)]) == 1)
        await f.state.shutdown()
    }

    // MARK: - AI-46 conclusion only with verified support

    @Test("AI-46: the AI's conclusion is shown first only when its claims check out and its numbers are in a checked quote or the app's arithmetic")
    func conclusionNeedsSupport() {
        let docs = Self.docs().map { CaseReader.Document(objectID: $0.object, fileName: $0.name, text: $0.text) }
        let good = ["text": "A debit of INR 50,000 went to Kestrel Supplies.", "quote": "debit INR 50,000 to Kestrel Supplies, ref KS-77120", "passage": 1] as [String: Any]
        let bad = ["text": "Kestrel was paid INR 90,000.", "quote": "Kestrel was paid INR 90,000 in total", "passage": 1] as [String: Any]
        func verdict(_ claims: [[String: Any]], _ conclusion: String, arithmetic: [String] = []) -> VerifiedAnswerComposer.Outcome {
            CaseReader.verdict(reply: Self.json(["status": "answered", "answers_question": "Was Kestrel paid twice?", "conclusion": conclusion, "claims": claims, "answer": "x"]),
                               question: "Was Kestrel paid twice?", documents: docs, rules: nil, arithmetic: arithmetic)
        }
        guard case .answered(let shown) = verdict([good], "Yes — an INR 50,000 debit went to Kestrel.") else { Issue.record("not answered"); return }
        #expect(shown.body.hasPrefix(VerifiedAnswerComposer.conclusionLabel + " Yes — an INR 50,000 debit went to Kestrel."))
        guard case .notStated(let none) = verdict([bad], "Yes — paid INR 90,000.") else { Issue.record("expected not confirmed"); return }
        #expect(!none.body.contains(VerifiedAnswerComposer.conclusionLabel), "every claim dropped: no conclusion")
        guard case .answered(let withheld) = verdict([good], "The net outflow is INR 30,000.") else { Issue.record("not answered"); return }
        #expect(!withheld.body.hasPrefix(VerifiedAnswerComposer.conclusionLabel) && withheld.body.hasPrefix("(The AI's conclusion is not shown: the number 30000"))
        guard case .answered(let summed) = verdict([good], "The net outflow is INR 30,000.", arithmetic: ["INR 50,000 − INR 20,000 = INR 30,000"]) else { Issue.record("not answered"); return }
        #expect(summed.body.hasPrefix(VerifiedAnswerComposer.conclusionLabel), "a number from the app's arithmetic is supported")
    }
}
