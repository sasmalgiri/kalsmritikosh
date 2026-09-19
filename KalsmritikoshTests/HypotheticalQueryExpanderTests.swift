//
//  HypotheticalQueryExpanderTests.swift
//  KalsmritikoshTests
//
//  Phase 1 · R4 — the HyDE expander's pure core: intent guard + RRF fusion,
//  plus the stubbed-reasoner gate. No model, no DB.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite struct HypotheticalQueryExpanderTests {

    @Test("Intent guard: a hypothetical sharing a content term is kept")
    func intentKept() {
        #expect(HypotheticalQueryExpander.preservesIntent(
            question: "who drafted the patent claims?",
            hypothetical: "The claims were drafted by the applicant's attorney."))
    }

    @Test("Intent guard: an off-topic hypothetical is rejected")
    func intentRejected() {
        #expect(!HypotheticalQueryExpander.preservesIntent(
            question: "who drafted the patent claims?",
            hypothetical: "The weather in Paris is mild during spring."))
    }

    @Test("Intent guard: an empty question cannot preserve intent")
    func emptyQuestionRejected() {
        #expect(!HypotheticalQueryExpander.preservesIntent(question: "   ", hypothetical: "anything"))
    }

    @Test("RRF fusion promotes an item ranked well in both lists")
    func rrfPromotesConsensus() {
        // "B" is 2nd in list A and 1st in list B → should top the fusion.
        let a = ["A", "B", "C"]
        let b = ["B", "D", "E"]
        let fused = HypotheticalQueryExpander.rrfFuse([a, b])
        #expect(fused.first == "B")
        #expect(Set(fused) == Set(["A", "B", "C", "D", "E"]))
    }

    @Test("RRF fusion is deterministic on ties (first appearance wins)")
    func rrfDeterministicTies() {
        let a = ["X", "Y"]
        let b = ["Y", "X"]      // symmetric → equal scores
        let fused = HypotheticalQueryExpander.rrfFuse([a, b])
        #expect(fused == ["X", "Y"])   // X appears first overall
    }

    @Test("Expander returns nil when the reasoner declines")
    func nilWhenNoReasoner() async {
        let expander = HypotheticalQueryExpander(reason: { _ in nil })
        let out = await expander.hypothetical(for: "who signed the lease?")
        #expect(out == nil)
    }

    @Test("Expander drops an off-intent rewrite from the reasoner")
    func dropsOffIntentRewrite() async {
        let expander = HypotheticalQueryExpander(reason: { _ in "Completely unrelated sentence about cooking." })
        let out = await expander.hypothetical(for: "who signed the lease agreement?")
        #expect(out == nil)
    }

    @Test("Expander keeps an on-intent rewrite")
    func keepsOnIntentRewrite() async {
        let expander = HypotheticalQueryExpander(reason: { _ in "The lease agreement was signed by the tenant." })
        let out = await expander.hypothetical(for: "who signed the lease agreement?")
        #expect(out == "The lease agreement was signed by the tenant.")
    }
}
