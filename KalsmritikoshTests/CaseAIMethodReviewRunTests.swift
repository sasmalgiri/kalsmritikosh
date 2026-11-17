//
//  CaseAIMethodReviewRunTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (AI-15, schema v195) — the AI method review through the case assistant: the same gates as any run
//  (mode, set-up, the case's permission asked once, privileged documents never sent), the reply kept only as checked by
//  AIMethodReviewContract against exactly the documents sent, stored labelled, never a proposal. Scripted reader only:
//  no network, no key, no model.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AI method review through the case assistant (AI-15)", .serialized)
@MainActor
struct CaseAIMethodReviewRunTests {

    nonisolated static let methods = [CaseMethodReviewMethod(id: CaseMethodReview.prefix + "fishbone", version: 1, label: "Fishbone"),
                          CaseMethodReviewMethod(id: CaseMethodReview.prefix + "five-whys", version: 1, label: "Five whys")]

    nonisolated static func reply() -> CaseReader.Reply {
        let body: [String: Any] = ["methods": [
            ["method_id": CaseMethodReview.prefix + "fishbone", "outcome": "usefulNow", "reason": "Two transfers against one invoice",
             "checks": [["observation": "The supplier's ledger for March 2026", "target": "Dalmia Traders",
                         "predicts": ["duplicate": "two receipts", "two invoices": "a second invoice"],
                         "evidence": [["document": 1, "quote": "A second transfer of ₹10,000 followed on 9 March 2026"],
                                      ["document": 2, "quote": "A second transfer of ₹10,000 followed on 9 March 2026"]]],
                        ["observation": "Ask the bank", "target": "the bank", "evidence": [["document": 1, "quote": "words in no document"]]]]],
            ["method_id": "not.registered", "outcome": "usefulNow", "reason": "x"],
        ]]
        var u = CloudCallUsage(inputTokens: 50, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 80, purpose: "case.assist", provider: "test")
        u.stopReason = "end_turn"
        return CaseReader.Reply(text: s10JSON(body), usage: u)
    }

    @Test("A run sends the method task once, keeps the checked result labelled, and records a methodReview run")
    func keptAndLabelled() async throws {
        let r = try await S10Rig.make(reply: { _, _ in Self.reply() })
        let run = try await r.ai.runMethodReview(caseID: r.caseID, question: "Was the supplier paid twice?", methods: Self.methods, actor: "Ada")
        #expect(run.report.outcome == .done, "\(run.report.reason ?? "")")
        let kept = try #require(run.result)
        #expect(r.script.sends.count == 1 && r.script.consents == 1)
        #expect(r.script.sends.first?.suffix.contains(CaseMethodReview.prefix + "fishbone") == true, "the task names the registered methods")
        // One assessment per registered method: the AI's (labelled) or not assessed; the unregistered one is dropped.
        #expect(kept.assessments.count == 2)
        #expect(kept.assessments.first { $0.methodID.hasSuffix("fishbone") }?.reason.hasPrefix("The AI's suggestion:") == true)
        #expect(kept.assessments.first { $0.methodID.hasSuffix("five-whys") }?.outcome == CaseMethodApplicability.notAssessed.rawValue)
        #expect(kept.notCovered == [CaseMethodReview.prefix + "five-whys"])
        #expect(kept.dropped.contains { $0.contains("not a registered method") })
        // The quote verified in its document is kept; the made-up one leaves its check ungrounded.
        let grounded = try #require(kept.checks.first { $0.observation.hasPrefix("The supplier's ledger") })
        #expect(!grounded.ungrounded && grounded.quotes.contains("A second transfer of ₹10,000 followed on 9 March 2026"))
        #expect(kept.checks.first { $0.observation == "Ask the bank" }?.ungrounded == true)
        // Stored and read back; the run is a methodReview run; nothing became a proposal.
        #expect(try await r.ai.methodReviews(caseID: r.caseID) == [kept])
        #expect(try await r.ai.runs(caseID: r.caseID).last?.taskKind == .methodReview)
        #expect(try await r.ai.proposals(caseID: r.caseID).isEmpty)
        // A kept review is never edited.
        await #expect(throws: (any Error).self) { try await r.db.exec("UPDATE case_ai_method_reviews SET question = 'x';", []) }
    }

    @Test("Off, not set up, or permission refused: nothing is sent and nothing is kept; the proposal path refuses the kind")
    func gates() async throws {
        let off = try await S10Rig.make(reply: { _, _ in Self.reply() })
        try await off.setAI(CaseAIPolicy(mode: .off))
        await #expect(throws: (any Error).self) {
            _ = try await off.ai.runMethodReview(caseID: off.caseID, question: "q", methods: Self.methods, actor: "Ada")
        }
        let noKey = try await S10Rig.make(identityOn: false, reply: { _, _ in Self.reply() })
        let r1 = try await noKey.ai.runMethodReview(caseID: noKey.caseID, question: "q", methods: Self.methods, actor: "Ada")
        #expect(r1.report.outcome == .notRun && r1.result == nil && noKey.script.sends.isEmpty)
        let refused = try await S10Rig.make(reply: { _, _ in Self.reply() })
        refused.script.setAllow(false)
        let r2 = try await refused.ai.runMethodReview(caseID: refused.caseID, question: "q", methods: Self.methods, actor: "Ada")
        #expect(r2.report.outcome == .declined && r2.result == nil && refused.script.sends.isEmpty)
        #expect(try await refused.ai.methodReviews(caseID: refused.caseID).isEmpty)
        let viaRun = try await refused.ai.run(caseID: refused.caseID, task: CaseAIAssistTask(kind: .methodReview), actor: "Ada")
        #expect(viaRun.outcome == .notRun)
    }

    @Test("A privileged document is never sent with the method task")
    func privilegedNotSent() async throws {
        let r = try await S10Rig.make(privileged: true, reply: { _, _ in Self.reply() })
        _ = try await r.ai.runMethodReview(caseID: r.caseID, question: "Was the supplier paid twice?", methods: Self.methods, actor: "Ada")
        let sent = r.script.sends.flatMap(\.prefix).joined()
        #expect(!sent.contains("Counsel advises"), "the privileged memo stays on this Mac")
    }
}
