//
//  AgentSplitX3Tests.swift
//  KalsmritikoshTests
//
//  AI split X3 (owner 2026-11-23) — AI-47: the archive Ask on the agent loop (scripted reader), the rule answer path retired
//  (MasterBrain answers with search results; no composer, gate or interpretation decides), no AI → "Set up AI" + a search
//  list. AI-48: the understanding consumers read the AI's records — money (the AI classifies, the app sums), people roles,
//  method applicability, causal judgement, merge decisions (the app proposes, the AI decides). Scripted readers only: no
//  model, no network, no API spend.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI split X3 — archive agent, rule paths retired, AI understanding", .serialized)
struct AgentSplitX3Tests {

    static let bank = "Bank statement, March 2026. 05 Mar 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77120. 12 Mar 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77985."
    static let refund = "Credit note. 19 Mar 2026: INR 50,000 refunded by Kestrel Supplies to the company."
    static let privileged = "Privileged legal advice about Kestrel Supplies: counsel's view of the INR 50,000 payments."

    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var prompts: [String] = []
        func add(_ p: String) { lock.withLock { prompts.append(p) } }
        var all: [String] { lock.withLock { prompts } }
    }

    static func json(_ o: [String: Any]) -> String { UnifiedPathCaseTests.json(o) }

    /// A three-document archive: bank (cleared), refund note (cleared, found only by the AI's own search), privileged advice
    /// (never cleared). The scripted reader searches, sums, then answers.
    static func agent(_ sent: Sent, reply: @escaping @Sendable (String) -> String) -> (ArchiveAgent, [UUID]) {
        let ids = [UUID(), UUID(), UUID()]
        let texts = [ids[0]: bank, ids[1]: refund, ids[2]: privileged]
        let names = [ids[0]: "bank.txt", ids[1]: "credit-note.txt", ids[2]: "advice.txt"]
        let agent = ArchiveAgent(
            search: { words in
                if words.lowercased().contains("refund") { return [ArchiveAgent.Hit(objectID: ids[1], snippet: refund), ArchiveAgent.Hit(objectID: ids[2], snippet: privileged)] }
                return [ArchiveAgent.Hit(objectID: ids[0], snippet: bank), ArchiveAgent.Hit(objectID: ids[2], snippet: privileged)]
            },
            document: { id in texts[id].map { CaseReader.Document(objectID: id, fileName: names[id], text: $0) } },
            clear: { list in
                var denied: [UUID: String] = [:]
                for id in list where id == ids[2] { denied[id] = "privileged" }
                let cleared = Set(list).subtracting(denied.keys)
                return (CloudSourceClearance(clearedObjectIDs: cleared, deniedCount: denied.count, checkedAt: Date(), purpose: "archive.reading"), denied)
            },
            send: { prompt, clearance in
                #expect(!clearance.clearedObjectIDs.contains(ids[2]))
                sent.add(prompt)
                return reply(prompt)
            })
        return (agent, ids)
    }

    static func reader(_ prompt: String) -> String {
        if !prompt.contains("Tool results so far") {
            return json(["status": "need_tools", "requests": [
                ["tool": "search", "words": "refund"],
                ["tool": "sum", "items": ["INR 50,000", "INR 50,000"], "minus": ["INR 50,000"]],
            ] as [[String: Any]]])
        }
        return json(["status": "answered", "answers_question": AgentSplitX2Tests.asked(prompt),
                     "conclusion": "Kestrel Supplies kept INR 50,000 net: the debits less the refund.",
                     "claims": [["text": "A debit of INR 50,000 went to Kestrel Supplies.", "quote": "debit INR 50,000 to Kestrel Supplies, ref KS-77120", "passage": 1],
                                ["text": "INR 50,000 was refunded by Kestrel Supplies.", "quote": "INR 50,000 refunded by Kestrel Supplies", "passage": 2]],
                     "answer": "Paid twice, one refunded."] as [String: Any])
    }

    // MARK: - AI-47

    @Test func archiveAskRunsTheAgentLoop() async throws {
        let sent = Sent()
        let (agent, _) = Self.agent(sent, reply: Self.reader)
        guard case .read(let a, let documents, let steps) = await agent.answer(question: "How much did Kestrel Supplies keep?") else {
            Issue.record("the archive reading did not answer"); return
        }
        #expect(steps == 2)
        #expect(documents == 2)   // the bank (first search) + the credit note (the AI's own search); never the advice
        #expect(sent.all.count == 2)
        #expect(sent.all.allSatisfy { !$0.contains("Privileged legal advice") })
        #expect(sent.all[1].contains("[Document 2] file: credit-note.txt"))
        #expect(sent.all[1].contains("INR 50,000 + INR 50,000 − INR 50,000 = INR 50,000"))
        #expect(a.body.hasPrefix(VerifiedAnswerComposer.conclusionLabel))
        #expect(a.body.contains("of your archive that its searches found"))
        #expect(a.body.contains("privileged or restricted: never sent to the AI"))
        #expect(Set(a.citations.map(\.objectID)).count == 2)
    }

    @Test func archiveReadingUnconfirmedIsNotShownAsFound() async {
        let sent = Sent()
        let (agent, _) = Self.agent(sent) { _ in
            Self.json(["status": "answered", "claims": [["text": "Kestrel was paid INR 90,000.", "quote": "paid INR 90,000 to Kestrel", "passage": 1]],
                       "answer": "INR 90,000"] as [String: Any])
        }
        guard case .read(let a, _, _) = await agent.answer(question: "How much was Kestrel paid?") else { Issue.record("no reading"); return }
        #expect(a.body.hasPrefix(CaseReader.unconfirmedLead))
        #expect(!a.body.contains("of this case"))
    }

    @Test func archiveNothingSendable() async {
        let ids = [UUID()]
        let agent = ArchiveAgent(search: { _ in [ArchiveAgent.Hit(objectID: ids[0], snippet: "x")] },
                                 document: { _ in nil },
                                 clear: { l in (CloudSourceClearance(clearedObjectIDs: [], deniedCount: l.count, checkedAt: Date(), purpose: "p"), [ids[0]: "privileged"]) },
                                 send: { _, _ in Issue.record("nothing may be sent"); return "" })
        guard case .noDocuments(let withheld) = await agent.answer(question: "anything") else { Issue.record("expected no documents"); return }
        #expect(withheld == 1)
    }

    struct OneChunkRetriever: Retriever {
        let chunk: Chunk
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
            RetrievalResult(chunks: [RetrievedChunk(chunk: chunk, score: 1, viaLayer: .metadata)])
        }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
            AuthorizedRetrievalResult(result: try await retrieve(for: intent, layers: layers), accessContext: access)
        }
    }

    @Test func ruleComposersRetiredByDefault() async {
        #expect(!RetiredPaths.isOn(.ruleAnswerComposers))
        #expect(!RetiredPaths.isOn(.ruleQuestionInterpretation))
        #expect(!RetiredPaths.isOn(.ruleUnderstanding))
        let chunk = Chunk(objectID: UUID(), ordinal: 0, text: "On March 3, 2021, John Smith was sentenced to 60 months in prison.", characterRange: 0..<66)
        let brain = MasterBrain(retriever: OneChunkRetriever(chunk: chunk))
        let access = SensitiveAccessContext(scope: .globalOwnerRetrieval())
        // A small-talk line is not refused by the rules any more, and a sentencing question is not composed: search results.
        for q in ["When was John Smith sentenced?", "how are you?"] {
            let a = await brain.answer(question: q, access: access)
            #expect(a.intentKind == MasterBrain.searchAnswerKind)
            #expect(a.citations.map(\.objectID) == [chunk.objectID])
            #expect(a.body.isEmpty)
        }
        let steps = await brain.caseEvidenceSteps(question: "how are you?", access: access)
        #expect(steps.refusal == nil)
        #expect(steps.answer.intentKind == MasterBrain.searchAnswerKind)
        // Switched back on, the rule path runs again (here it is not booted, so it says so — never a search result).
        await RetiredPaths.TestOverride.$paths.withValue(RetiredPaths.ruleAnswering) {
            let a = await brain.answer(question: "When was John Smith sentenced?", access: access)
            #expect(a.intentKind != MasterBrain.searchAnswerKind)
        }
    }

    @Test func noAISetUpShowsGuidanceAndAList() {
        let id = UUID()
        let found = VerifiedAnswer(body: "", intentKind: MasterBrain.searchAnswerKind,
                                   citations: [.init(objectID: id, snippet: "Classification: Class II\nIssued by the regional office.")],
                                   confidence: .low, refused: false, answerState: .unverified)
        let shown = OfflineSearchResults.present(found, question: "What is the classification?", reason: nil)
        #expect(shown.intentKind == OfflineSearchResults.searchKind)
        #expect(shown.body.contains("set up AI (your key or a plan)"))
        #expect(shown.body.contains("\n1. "))
        #expect(!shown.body.contains("Found in the record"))
        #expect(shown.answerText == nil)
        let none = OfflineSearchResults.present(VerifiedAnswer(body: "", intentKind: MasterBrain.searchAnswerKind, citations: [], confidence: .zero,
                                                               refused: true, refusalReason: "No matching passage was found."),
                                                question: "q", reason: nil)
        #expect(none.body.contains("Set up AI (your own key or a plan"))
    }

    // MARK: - AI-48

    static func records(_ doc: UUID) -> [CaseAIRecord] {
        let tools = CaseAgentTools(documents: [CaseReader.Document(objectID: doc, fileName: "bank.txt", text: bank + " " + refund)], origin: "picture")
        let calls: [[String: Any]] = [
            ["tool": "record_money", "kind": "payment", "amount": "INR 50,000", "from": "the company", "to": "Kestrel Supplies", "date": "05 Mar 2026",
             "reference": "KS-77120", "quote": "05 Mar 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77120", "document": 1],
            ["tool": "record_money", "kind": "payment", "amount": "INR 50,000", "to": "Kestrel Supplies", "date": "12 Mar 2026",
             "quote": "12 Mar 2026: debit INR 50,000 to Kestrel Supplies, ref KS-77985", "document": 1],
            ["tool": "record_money", "kind": "refund", "amount": "INR 50,000", "from": "Kestrel Supplies", "date": "19 Mar 2026",
             "quote": "19 Mar 2026: INR 50,000 refunded by Kestrel Supplies", "document": 1],
            ["tool": "record_entity", "name": "Kestrel Supplies", "type": "organisation", "role": "supplier paid", "role_kind": "other",
             "also_written_as": ["Kestrel"], "quote": "debit INR 50,000 to Kestrel Supplies, ref KS-77120", "document": 1],
        ]
        return calls.compactMap { o -> CaseAIRecord? in
            let call = CaseAgent.Call(tool: o["tool"] as? String ?? "", fields: o.filter { $0.key != "tool" }.mapValues(CaseAgent.Value.init))
            switch tools.verify(call) {
            case .success(let r): return r
            case .failure(let why): Issue.record("rejected: \(why.reason)"); return nil
            }
        }
    }

    @Test func moneyIsClassifiedByTheAIAndSummedByTheApp() {
        let doc = UUID()
        let recs = Self.records(doc)
        #expect(recs.count == 4)
        let m = CaseAIUnderstanding.money(recs)
        #expect(m.records.count == 3)
        let fig = Dictionary(uniqueKeysWithValues: m.figures.map { ($0.figure, $0) })
        #expect(fig["Paid"]?.totals["INR"] == 100_000)
        #expect(fig["Returned"]?.totals["INR"] == 50_000)
        // Accuracy F2 (2026-11-25): the cross-party "Net outflow" is gone (it added money paid by different parties); the
        // per-party flows replace it (AccuracyF2Tests).
        #expect(fig["Net outflow (paid + fees − returned)"] == nil)
        // The ledger's unclassified amount in the same document takes the AI's kind; another document's does not.
        #expect(CaseAIUnderstanding.classification(amount: "50000.00 INR", document: doc, in: recs) == "payment")
        #expect(CaseAIUnderstanding.classification(amount: "INR 50,000", document: UUID(), in: recs) == nil)
        // A bad classification is rejected with its reason.
        let tools = CaseAgentTools(documents: [CaseReader.Document(objectID: doc, text: Self.bank)])
        let bad = CaseAgent.Call(tool: "record_money", fields: ["kind": .string("theft"), "amount": .string("INR 50,000"),
                                                                 "quote": .string("debit INR 50,000 to Kestrel Supplies"), "document": .number(1)])
        if case .failure(let r) = tools.verify(bad) { #expect(r.reason.hasPrefix("kind must be")) } else { Issue.record("accepted a bad kind") }
        // The statement import's description words only hint; the column decides (the AI classifies the rest).
        let row = CaseMoneyStatementRow(row: 1, date: "2026-03-19", dateText: "2026-03-19", description: "Refund from Kestrel", reference: nil, debit: nil, credit: "50000")
        let off = CaseMoneyStatementParser.proposedKind(row)
        #expect(off.kind == .receipt && off.basis.contains("hint"))
        RetiredPaths.TestOverride.$paths.withValue([.ruleUnderstanding: true]) {
            #expect(CaseMoneyStatementParser.proposedKind(row).kind == .refund)
        }
    }

    @Test func peopleRolesAndStoryFromAIRecords() {
        let doc = UUID()
        let recs = Self.records(doc)
        let orgs = CaseAIUnderstanding.organisations(recs)
        #expect(orgs.map(\.name) == ["Kestrel Supplies"])
        #expect(orgs.first?.roles == ["supplier paid"])
        #expect(orgs.first?.roleKinds == ["other"])
        #expect(orgs.first?.alsoWrittenAs == ["Kestrel"])
        #expect(CaseAIUnderstanding.status(of: recs[0], in: recs) == .foundByAI)
        // A role kind outside the vocabulary is rejected.
        let tools = CaseAgentTools(documents: [CaseReader.Document(objectID: doc, text: Self.bank)])
        let bad = CaseAgent.Call(tool: "record_entity", fields: ["name": .string("Kestrel Supplies"), "type": .string("organisation"), "role_kind": .string("villain"),
                                                                  "quote": .string("debit INR 50,000 to Kestrel Supplies"), "document": .number(1)])
        if case .failure(let r) = tools.verify(bad) { #expect(r.reason.hasPrefix("role_kind must be")) } else { Issue.record("accepted a bad role kind") }
    }

    @Test func mergeIsDecidedByTheAIOnTheAppsCandidates() {
        let doc = UUID()
        let recs = Self.records(doc)
        #expect(CaseAIUnderstanding.mergeDecision("Kestrel Supplies", "Kestrel", records: recs) == .same)
        #expect(CaseAIUnderstanding.mergeDecision("Kestrel Supplies", "Kestral Supplies", records: recs) == .undecided)
        let other = CaseAIRecord(kind: .entity, text: "Kestral Supplies", entityType: "organisation", quote: "q", document: doc)
        #expect(CaseAIUnderstanding.mergeDecision("Kestrel Supplies", "Kestral Supplies", records: recs + [other]) == .different)
        #expect(!CaseAIUnderstanding.rulesDecide)
    }

    @Test func causalLanguageIsTheAIsJudgement() {
        let guardian = CausalLanguageGuard()
        let evidence = ["The pump failed because the seal was worn."]
        // Retired rule: no AI judgement → no caution from marker words.
        #expect(guardian.assess(claim: "The leak caused the outage.", evidenceTexts: ["The leak happened. Then the outage."]).caution.isEmpty)
        #expect(!guardian.assess(claim: "The leak caused the outage.", evidenceTexts: evidence, aiJudgement: false).caution.isEmpty)
        #expect(guardian.assess(claim: "The leak caused the outage.", evidenceTexts: evidence, aiJudgement: true).caution.isEmpty)
        RetiredPaths.TestOverride.$paths.withValue([.ruleUnderstanding: true]) {
            #expect(!guardian.assess(claim: "The leak caused the outage.", evidenceTexts: ["The leak happened. Then the outage."]).caution.isEmpty)
        }
        let rel = CaseAIRecord(kind: .relationship, text: "worn seal — caused — pump failure", relation: "caused", quote: "The pump failed because the seal was worn.")
        #expect(CaseAIUnderstanding.sourceStatesCause(claim: "x", evidenceTexts: evidence, records: [rel]) == true)
        #expect(CaseAIUnderstanding.sourceStatesCause(claim: "x", evidenceTexts: ["unrelated"], records: [rel]) == nil)
    }
}
