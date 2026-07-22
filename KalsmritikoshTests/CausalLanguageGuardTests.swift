//
//  CausalLanguageGuardTests.swift
//  KalsmritikoshTests
//
//  CLM-002 — verifies the guard flags a causal over-claim (claim asserts cause, evidence
//  shows only sequence) and stays silent when the evidence genuinely asserts causation or
//  the claim is not causal. Pack rule: temporal adjacency is never presented as causation.
//

import Testing
@testable import Kalsmritikosh

@Suite("CLM-002 CausalLanguageGuard")
struct CausalLanguageGuardTests {

    private let guardEngine = CausalLanguageGuard()

    @Test("Causal claim + sequence-only evidence is flagged")
    func adjacencyIsNotCausation() {
        let v = guardEngine.assess(
            claim: "The delay caused the contract to be cancelled.",
            evidenceTexts: ["The shipment was delayed on 3 March. The contract was cancelled on 10 March."])
        #expect(v.claimIsCausal)
        #expect(!v.evidenceSupportsCausation)
        #expect(v.isUnsupportedCausalClaim)
        #expect(!v.caution.isEmpty)
    }

    @Test("Causal claim + causal evidence is not flagged")
    func genuineCausationAllowed() {
        let v = guardEngine.assess(
            claim: "The delay caused the cancellation.",
            evidenceTexts: ["We are cancelling due to the shipment delay."])
        #expect(v.claimIsCausal)
        #expect(v.evidenceSupportsCausation)
        #expect(!v.isUnsupportedCausalClaim)
    }

    @Test("Non-causal claim is never flagged")
    func nonCausalUntouched() {
        let v = guardEngine.assess(
            claim: "The contract was signed on 10 March.",
            evidenceTexts: ["Contract executed 10 March 2024."])
        #expect(!v.claimIsCausal)
        #expect(!v.isUnsupportedCausalClaim)
    }

    @Test("Multi-claim assess returns a caution if ANY claim over-states cause")
    func multiClaim() {
        let caution = guardEngine.assess(
            claims: ["The contract was signed on 10 March.", "The delay led to the loss."],
            evidenceTexts: ["Signed 10 March. Loss recorded 20 March."])
        #expect(!caution.isEmpty)
    }
}
