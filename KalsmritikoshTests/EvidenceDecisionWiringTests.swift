//
//  EvidenceDecisionWiringTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, Commit C2 (decision wiring). The single ClaimEvaluation produced at
//  retrieval threads UNCHANGED to the expert layer and export validator. These tests lock:
//  equality across stages, refuse-exclusion, inference/conflict visibility-not-assertion,
//  no fake corroboration from unkeyed sources, human-confirmed-unknown-basis → userAttributed,
//  MasterBrain cannot strengthen, validator anti-tamper (decision + presentation), exact
//  GenericFact citations, and zero evaluation work when there are no facts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 C2 — decision wiring")
struct EvidenceDecisionWiringTests {

    private func chunk(_ obj: UUID, _ blk: UUID?, _ text: String = "t") -> RetrievedChunk {
        RetrievedChunk(chunk: Chunk(objectID: obj, ordinal: 0, text: text,
                                    characterRange: 0..<text.count, evidenceBlockID: blk),
                       score: 1.0, viaLayer: .metadata)
    }
    private func fact(_ status: EvidenceStatus, blocks: [UUID]) -> GenericFact {
        GenericFact(subjectLabel: "S", field: "employer", value: "Orchid",
                    status: status, confidence: 0.8, sourceBlockIDs: blocks)
    }

    @Test("The retrieval evaluation is carried UNCHANGED into the ReasoningExpert claim")
    func equalityRetrievalToExpert() {
        let obj = UUID(), blk = UUID()
        let f = fact(.sourceAsserted, blocks: [blk])
        let evals = ClaimEvaluator.evaluate(facts: [f], chunks: [chunk(obj, blk)])
        let result = RetrievalResult(chunks: [chunk(obj, blk)], genericFacts: [f], claimEvaluations: evals)
        let claims = ReasoningExpert.factClaims(from: result)
        #expect(claims.count == 1)
        #expect(claims.first?.evaluation == evals.first)      // whole-envelope equality
        #expect(claims.first?.evaluation?.id == f.id)          // ledger identity preserved
    }

    @Test("An unresolved (orphan) block yields no invented evidence → refused → not surfaced")
    func orphanRefused() {
        let obj = UUID(), shown = UUID(), orphan = UUID()
        let evals = ClaimEvaluator.evaluate(facts: [fact(.sourceAsserted, blocks: [orphan])], chunks: [chunk(obj, shown)])
        #expect(evals.isEmpty)                                 // refuse → excluded
    }

    @Test("Inference is visible but not an assertion; exact citation carried")
    func inferenceVisibleNotAssertive() {
        let obj = UUID(), blk = UUID()
        let eval = ClaimEvaluator.evaluate(facts: [fact(.inferred, blocks: [blk])], chunks: [chunk(obj, blk)]).first
        #expect(eval?.decision == .presentAsInference)
        #expect(eval?.maySurface == true)                      // stays visible
        #expect(eval?.decision.isAssertiveDecision == false)   // but not asserted
        #expect(eval?.presentation == .inference)
        #expect(eval?.evidence.first?.objectID == obj && eval?.evidence.first?.blockID == blk)  // exact
    }

    @Test("Unkeyed / duplicate sources cannot corroborate; two keyed sources can")
    func corroborationRequiresIndependence() {
        let o1 = UUID(), o2 = UUID(), b1 = UUID(), b2 = UUID()
        let f = fact(.sourceAsserted, blocks: [b1, b2])
        let chunks = [chunk(o1, b1), chunk(o2, b2)]
        // No independence keys → attribution, NOT corroboration.
        let unkeyed = ClaimEvaluator.evaluate(facts: [f], chunks: chunks).first
        #expect(unkeyed?.decision == .assertWithAttribution)
        // Two reliably-independent keys → corroboration.
        let keyed = ClaimEvaluator.evaluate(facts: [f], chunks: chunks, independenceKeys: [o1: "h1", o2: "h2"]).first
        #expect(keyed?.decision == .assertAsCorroborated)
    }

    @Test("Human-confirmed unknown-basis fact is user-attributed, never a fact")
    func humanConfirmedUserAttributed() {
        let obj = UUID(), blk = UUID()
        let eval = ClaimEvaluator.evaluate(facts: [fact(.humanConfirmed, blocks: [blk])], chunks: [chunk(obj, blk)]).first
        #expect(eval?.decision == .assertWithUserAttribution)
        #expect(eval?.presentation == .userAttributed)
        #expect(eval?.decision != .assertAsFact)
    }

    @Test("MasterBrain renders only assertive evaluations as verified facts (no strengthening)")
    func brainDoesNotStrengthen() {
        let obj = UUID(), blk = UUID()
        let f = fact(.inferred, blocks: [blk])                 // inference, not assertive
        let evals = ClaimEvaluator.evaluate(facts: [f], chunks: [chunk(obj, blk)])
        let prompt = MasterBrain.buildEvidencePrompt(question: "?", chunks: [chunk(obj, blk)], facts: [f], evaluations: evals)
        #expect(!prompt.contains("Verified facts"))            // an inference is never a verified fact
    }

    @Test("Zero evaluation work when there are no facts")
    func zeroWorkNoFacts() {
        #expect(ClaimEvaluator.evaluate(facts: [], chunks: [chunk(UUID(), UUID())]).isEmpty)
    }

    // MARK: Validator anti-tamper (via mutated persisted envelopes)

    private func requireSection(_ claim: ComposedClaim, manifest: Set<UUID>) -> ComposedWorkProduct {
        let bp = BlueprintSection(title: "Facts", kind: .matrix, requiresEvidence: true, minEvidencePerClaim: 1)
        let blueprint = WorkProductBlueprint(name: "wp", persona: .general, sections: [bp])
        return ComposedWorkProduct(blueprint: blueprint,
                                   sections: [ComposedSection(blueprint: bp, claims: [claim])],
                                   manifestSourceIDs: manifest)
    }

    @Test("A consistent carried evaluation validates; a decision-tampered one is caught")
    func validatorCatchesDecisionTamper() throws {
        let obj = UUID(), blk = UUID()
        let eval = try #require(ClaimEvaluator.evaluate(facts: [fact(.sourceAsserted, blocks: [blk])], chunks: [chunk(obj, blk)]).first)
        let good = ComposedClaim(text: "x", sourceBlockIDs: [blk], status: .sourceAsserted, evaluation: eval)
        #expect(WorkProductValidator().validate(requireSection(good, manifest: [blk])).isValid)

        // Tamper: force the recorded decision to a STRONGER value than its context supports.
        var obj2 = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(eval)) as! [String: Any]
        obj2["decision"] = "assertAsFact"                      // context only supports attribution
        let tampered = try JSONDecoder().decode(ClaimEvaluation.self, from: try JSONSerialization.data(withJSONObject: obj2))
        let bad = ComposedClaim(text: "x", sourceBlockIDs: [blk], status: .sourceAsserted, evaluation: tampered)
        let report = WorkProductValidator().validate(requireSection(bad, manifest: [blk]))
        #expect(!report.isValid)
        #expect(report.violations.contains { if case .claimDecisionMismatch = $0 { return true } else { return false } })
    }

    @Test("A refused/ inference export claim is rejected as non-assertive")
    func validatorRejectsNonAssertive() throws {
        let obj = UUID(), blk = UUID()
        let infEval = try #require(ClaimEvaluator.evaluate(facts: [fact(.inferred, blocks: [blk])], chunks: [chunk(obj, blk)]).first)
        let claim = ComposedClaim(text: "x", sourceBlockIDs: [blk], status: .inferred, evaluation: infEval)
        let report = WorkProductValidator().validate(requireSection(claim, manifest: [blk]))
        #expect(!report.isValid)
        #expect(report.violations.contains { if case .claimUnsupportedStatus = $0 { return true } else { return false } })
    }
}
