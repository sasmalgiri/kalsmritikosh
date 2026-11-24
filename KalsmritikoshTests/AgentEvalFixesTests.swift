//
//  AgentEvalFixesTests.swift
//  KalsmritikoshTests
//
//  The three app defects the fair hard-case evaluation found (docs/evidence/agent-eval-2026-11-23/HARD.md §5, §7):
//  1. number words in a claim or conclusion were required in a quote ("the two airplanes"); "x4" was not read as 4;
//  2. no check that an answer addresses its question (the AI restates it; the second look says yes/no);
//  3. background work outliving a closed ledger / case ("database not open" after the Mac woke from sleep).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI-50 eval fixes — number words, relevance, background work after close", .serialized)
struct AgentEvalFixesTests {

    // MARK: - 1. Number words

    @Test("Fix 1: plain number words are not required in a quote; digits, money, percentages, dates and worded amounts still are")
    func numberWords() {
        let p = "passage"
        #expect(VerifiedAnswerComposer.valueMissing(claim: "The two airplanes met at 1430 at the Sonoma County Airport (OQ3).",
                                                    quote: "about 1430 Pacific standard time at the Sonoma County Airport (OQ3)", passage: p) == nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "One delivery, on 2026-05-09.", quote: "2026-05-09,Larkfield,Reading kits,4,boxes", passage: p) == nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "All three give the same address.", quote: "Unit 4, Quay Street", passage: p) == nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "It was debited twice, both times by Kestrel.", quote: "debit to Kestrel Supplies", passage: p) == nil)
        // "x4" / "4x" are 4.
        #expect(VerifiedAnswerComposer.valueMissing(claim: "4 BW-V900 units were bought.", quote: "BW-V900 x4 at 12,500.00", passage: p) == nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "4 units were bought.", quote: "BW-V900 4x at 12,500.00", passage: p) == nil)
        #expect(VerifiedAnswerComposer.values(in: "BW-V900 x4").numbers.contains(4))
        #expect(VerifiedAnswerComposer.values(in: "4x boxes").numbers.contains(4))
        #expect(!VerifiedAnswerComposer.values(in: "BW-V900").numbers.contains(900), "a model number is not a count")
        // Still required: digits, money, percentages, dates, number words with a unit.
        #expect(VerifiedAnswerComposer.valueMissing(claim: "They met at 1430.", quote: "they met in the afternoon at the airport", passage: p) == "the number 1430")
        #expect(VerifiedAnswerComposer.valueMissing(claim: "Paid $310,000.", quote: "paid $300,000 to Larkfield", passage: p) == "the amount")
        #expect(VerifiedAnswerComposer.valueMissing(claim: "It rose 50%.", quote: "it rose 40% that year", passage: p) == "the number 50")
        #expect(VerifiedAnswerComposer.valueMissing(claim: "It rose fifty percent.", quote: "it rose 40% that year", passage: p) == "the number 50")
        #expect(VerifiedAnswerComposer.valueMissing(claim: "It rose fifty percent.", quote: "it rose 50% that year", passage: p) == nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "Two million was paid.", quote: "a payment of $2,000,000", passage: p) == nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "Two million was paid.", quote: "a payment of $3,000,000", passage: p) != nil)
        #expect(VerifiedAnswerComposer.valueMissing(claim: "Paid on 2 June.", quote: "paid on 28 April", passage: p) == "the date")
        // The quote's number word still backs the claim's digit.
        #expect(VerifiedAnswerComposer.valueMissing(claim: "2 airplanes were involved.", quote: "the two airplanes collided", passage: p) == nil)
        // The older reading (comparisons, rules finders) still reads every number word.
        #expect(VerifiedAnswerComposer.values(in: "the two airplanes").numbers.contains(2))
    }

    @Test("Fix 1: a conclusion with plain number words is shown; its amounts must still come from a checked quote or the app's arithmetic (AI-46)")
    func conclusionNumberWords() {
        let claims = [VerifiedAnswerComposer.VerifiedClaim(text: "Rowe logged one Larkfield delivery on 2026-05-09.",
                                                           quote: "2026-05-09,Larkfield Educational Supplies Ltd,(none),Reading kits,4,boxes", passage: 1),
                      VerifiedAnswerComposer.VerifiedClaim(text: "The order was BW-V900 x4.", quote: "BW-V900 x4 at 12,500.00 each", passage: 2)]
        #expect(VerifiedAnswerComposer.conclusionWithheld("One delivery, on 2026-05-09 — four boxes.", claims: claims, arithmetic: []) == nil)
        #expect(VerifiedAnswerComposer.conclusionWithheld("All three documents agree: the four BW-V900 units.", claims: claims, arithmetic: []) == nil)
        #expect(VerifiedAnswerComposer.conclusionWithheld("The net is INR 30,000.", claims: claims, arithmetic: [])?.contains("30000") == true)
        #expect(VerifiedAnswerComposer.conclusionWithheld("The net is INR 30,000.", claims: claims, arithmetic: ["INR 50,000 − INR 20,000 = INR 30,000"]) == nil)
        #expect(VerifiedAnswerComposer.conclusionWithheld("Paid on 2026-06-02.", claims: claims, arithmetic: []) != nil)
    }

    @Test("Fix 1: a claim saying 'the two airplanes' is no longer dropped")
    func claimNotDroppedForNumberWord() {
        let passage = VerifiedAnswerComposer.Passage(objectID: UUID(), text: "The accident occurred about 1430 Pacific standard time at the Sonoma County Airport (OQ3), Sebastopol, California.")
        let claim = VerifiedAnswerComposer.Claim(text: "The two airplanes collided at about 1430 at the Sonoma County Airport (OQ3).",
                                                 quote: "about 1430 Pacific standard time at the Sonoma County Airport (OQ3)", passage: 1, about: nil)
        #expect(VerifiedAnswerComposer.whyNot(claim, passages: [passage]) == nil)
    }

    // MARK: - 2. Relevance

    static let question = "When was John Smith sentenced?"
    static func reply(answers: String?, conclusion: String? = "Sentenced on March 3, 2021.") -> String {
        var o: [String: Any] = ["status": "answered", "answer": "x",
                                "claims": [["text": "John Smith was sentenced on March 3, 2021.",
                                            "quote": "On March 3, 2021, John Smith was sentenced to 60 months in prison", "passage": 1]]]
        if let answers { o["answers_question"] = answers }
        if let conclusion { o["conclusion"] = conclusion }
        return UnifiedPathCaseTests.json(o)
    }
    static func caseDocs() -> [CaseReader.Document] {
        UnifiedPathCaseTests.docs().map { CaseReader.Document(objectID: $0.object, sourceVersionID: $0.version, fileName: $0.name, text: $0.text) }
    }

    @Test("Fix 2: the restated question is compared after normalising only — no understanding")
    func sameQuestion() {
        #expect(VerifiedAnswerComposer.sameQuestion("Question: who owns  Garside & Co Bookkeeping", "Who owns Garside & Co Bookkeeping?"))
        #expect(VerifiedAnswerComposer.sameQuestion("Who is Bradley Kerr’s partner?", "who is bradley kerr's partner"))
        #expect(!VerifiedAnswerComposer.sameQuestion("Who owns Garside & Co?", "Who owns Garside & Co Bookkeeping?"))
        #expect(!VerifiedAnswerComposer.sameQuestion("", "Q?"))
    }

    @Test("Fix 2: a reply for another question shows no conclusion and its checked claims as related evidence; a matching one shows the conclusion")
    func relevanceInVerdict() throws {
        let docs = Self.caseDocs()
        guard case .answered(let ok) = CaseReader.verdict(reply: Self.reply(answers: Self.question), question: Self.question, documents: docs, rules: nil) else {
            Issue.record("not answered"); return
        }
        #expect(ok.body.hasPrefix(VerifiedAnswerComposer.conclusionLabel + " Sentenced on March 3, 2021."))
        guard case .answered(let other) = CaseReader.verdict(reply: Self.reply(answers: "Who charged John Smith?"), question: Self.question,
                                                             documents: docs, rules: nil) else { Issue.record("not answered"); return }
        #expect(!other.body.contains(VerifiedAnswerComposer.conclusionLabel))
        #expect(other.body.hasPrefix("(The AI's conclusion is not shown: the AI's reply answers a different question"))
        #expect(other.body.contains(VerifiedAnswerComposer.relatedEvidenceLabel))
        #expect(other.citations.count == 1 && other.confidence.value <= 0.4, "the claim stays, as related evidence")
        guard case .answered(let silent) = CaseReader.verdict(reply: Self.reply(answers: nil), question: Self.question, documents: docs, rules: nil) else {
            Issue.record("not answered"); return
        }
        #expect(silent.body.hasPrefix("(The AI's conclusion is not shown: the AI did not say which question it answers"))
        guard case .answered(let noConclusion) = CaseReader.verdict(reply: Self.reply(answers: nil, conclusion: nil), question: Self.question,
                                                                    documents: docs, rules: nil) else { Issue.record("not answered"); return }
        #expect(!noConclusion.body.contains(VerifiedAnswerComposer.relatedEvidenceLabel) && noConclusion.confidence.value == 0.7,
                "an older reply shape without a conclusion is unchanged")
    }

    @Test("Fix 2: merging parts drops the conclusion of a part that names another question; the second look's 'no' wins")
    func relevanceMerge() throws {
        let a = Self.reply(answers: Self.question, conclusion: "Sentenced on March 3, 2021.")
        let b = Self.reply(answers: "Who charged John Smith?", conclusion: "Charged by the grand jury.")
        let merged = try #require(CaseReader.parsePart(CaseReader.merge([a, b], question: Self.question)))
        #expect(merged.conclusion == "Sentenced on March 3, 2021.")
        #expect(merged.answersQuestion == Self.question)
        let onlyOther = try #require(CaseReader.parsePart(CaseReader.merge([b], question: Self.question)))
        #expect(onlyOther.conclusion == nil && onlyOther.answersQuestion == "Who charged John Smith?")
        let looks = CaseReader.merge([#"{"status":"not_stated","addresses_question":"yes","why":"fine","claims":[]}"#,
                                      #"{"status":"not_stated","addresses_question":"no","why":"It names the charge, not the sentencing date","claims":[]}"#])
        let warning = try #require(CaseReader.relevanceWarning(look: looks))
        #expect(warning.hasPrefix("(" + CaseReader.mayNotAnswerLead + ": It names the charge"))
        #expect(CaseReader.relevanceWarning(look: #"{"status":"not_stated","addresses_question":false,"claims":[]}"#) == "(" + CaseReader.mayNotAnswerLead + ".)")
        #expect(CaseReader.relevanceWarning(look: #"{"status":"not_stated","addresses_question":"yes","claims":[]}"#) == nil)
        #expect(CaseReader.relevanceWarning(look: #"{"status":"not_stated","claims":[]}"#) == nil)
    }

    @Test("Fix 2: the reply schemas ask for answers_question (question, part, archive) and addresses_question + why (second look)")
    func relevancePrompts() {
        #expect(CaseReader.questionSuffix("Q?").contains(#""answers_question": "...""#))
        #expect(CaseReader.partSuffix("Q?", related: [], toolsAllowed: false, toolResults: nil, agent: true).contains("answers_question"))
        let look = CaseReader.secondLookSuffix("Q?", answer: "A")
        #expect(look.hasPrefix(UnifiedPathCaseTests.secondLookTask) && look.contains(#""addresses_question""#) && look.contains(#""why""#))
    }

    @Test("Fix 2: on the case path, a second look saying 'no' leads the answer with 'The AI says this may not answer your question'")
    func relevanceOnCasePath() async throws {
        let f = try await UnifiedPathCaseTests.fixture(UnifiedPathCaseTests.docs(), reply: { send in
            if send.suffix.hasPrefix(UnifiedPathCaseTests.secondLookTask) {
                return #"{"status":"not_stated","addresses_question":"no","why":"It gives the prison term, not the date asked","claims":[],"answer":""}"#
            }
            return AgentEvalFixesTests.reply(answers: AgentEvalFixesTests.question)
        })
        let a = try await f.service.answer(caseID: f.caseID, question: Self.question, access: .testUnrestricted()).verified
        #expect(a.body.hasPrefix("(" + CaseReader.mayNotAnswerLead + ": It gives the prison term"), "\(a.body.prefix(200))")
        #expect(a.body.contains(VerifiedAnswerComposer.conclusionLabel) && a.confidence.value <= 0.4)
        await f.service.cancelBackgroundWork()
    }

    // MARK: - 3. Background work after close

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0, cancelled = 0
        func start() { lock.withLock { started += 1 } }
        func cancel() { lock.withLock { cancelled += 1 } }
        var counts: (started: Int, cancelled: Int) { lock.withLock { (started, cancelled) } }
    }

    @Test("Fix 3: closing cancels the case's after-answer AI work at once (a send that would hang ends), and a closed service starts no more")
    func backgroundWorkCancelled() async throws {
        let flag = Flag()
        let f = try await UnifiedPathCaseTests.fixture(UnifiedPathCaseTests.docs(), configure: { plan, recorder in
            plan.briefing = { _, d in
                var m = CaseLedgerBriefing.Material()
                m.entities = [.init(id: UUID(), kind: "person", value: "John Smith", tier: "T1", source: d[0].objectID, confidence: 0.9, aliases: [])]
                return CaseLedgerBriefing.build(m, number: Dictionary(uniqueKeysWithValues: d.enumerated().map { ($1.objectID, $0 + 1) }))
            }
            plan.reader = { CaseReader { send in
                recorder.add(send)
                if send.purpose == "case.suggestions" {
                    flag.start()
                    do { try await Task.sleep(for: .seconds(600)) } catch { flag.cancel(); throw error }   // a send that never comes back
                }
                return CaseReader.Reply(text: AgentEvalFixesTests.reply(answers: AgentEvalFixesTests.question))
            } }
        })
        let t0 = Date()
        _ = try await f.service.answer(caseID: f.caseID, question: Self.question, access: .testUnrestricted())
        #expect(Date().timeIntervalSince(t0) < 30, "the answer never waits for the background read")
        for _ in 0..<200 where flag.counts.started == 0 { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(flag.counts.started == 1)
        #expect(await f.service.backgroundWorkCount(caseID: f.caseID) == 1)
        let t1 = Date()
        await f.service.cancelBackgroundWork()
        for _ in 0..<200 where flag.counts.cancelled == 0 { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(flag.counts.cancelled == 1 && Date().timeIntervalSince(t1) < 5, "the hanging read ends promptly")
        let closed = await f.service.isClosed
        #expect(await f.service.backgroundWorkCount() == 0 && closed)
        _ = try await f.service.answer(caseID: f.caseID, question: Self.question, access: .testUnrestricted())
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await f.service.backgroundWorkCount() == 0 && flag.counts.started == 1, "no new background work after close")
    }

    @Test("Fix 3: a case's after-answer work is cancelled for that case only")
    func backgroundWorkPerCase() async throws {
        let f = try await UnifiedPathCaseTests.fixture(UnifiedPathCaseTests.docs())
        await f.service.cancelBackgroundWork(caseID: UUID())
        let closed = await f.service.isClosed
        #expect(!closed, "cancelling one case does not close the service")
    }

    @Test("Fix 3: shutdown stops every background loop boot started before the ledger closes, promptly, and never hangs")
    @MainActor
    func shutdownStopsBackgroundLoops() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("us-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let state = AppState(bookmarks: BookmarkStore(ephemeral: true))
        await state.boot(databaseURL: temp.appendingPathComponent("ledger.sqlite"))
        #expect(state.registeredBackgroundStops >= 8, "the community detector, co-occurrence builder, drains, idle maintenance … are registered")
        let t0 = Date()
        await state.shutdown()
        #expect(Date().timeIntervalSince(t0) < 20, "shutdown only cancels")
        #expect(state.isShutDown && state.registeredBackgroundStops == 0)
        let closed = await state.investigationAnswers?.isClosed
        #expect(closed != false)
        await state.shutdown()   // idempotent
    }
}
