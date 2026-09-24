//
//  EvidencePromptTests.swift
//  KalsmritikoshTests
//
//  SEM consumption (LLM path) — the fallback prompt builder injects the assertable
//  domain-pack facts as a VERIFIED-FACTS block, each tagged with the [C#] of the
//  chunk that backs it, and omits any fact whose block isn't among the chunks.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Evidence prompt builder")
struct EvidencePromptTests {

    private func chunk(_ obj: UUID, _ blk: UUID?, _ text: String) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: obj, ordinal: 0, text: text,
                         characterRange: 0..<text.count, evidenceBlockID: blk),
            score: 1.0, viaLayer: .metadata)
    }

    @Test("A backed assertable fact appears, tagged with its chunk label")
    func factTagged() {
        let obj = UUID(), b1 = UUID(), b2 = UUID()
        let chunks = [chunk(obj, b1, "first passage"), chunk(obj, b2, "Amount ₹3,800 paid.")]
        let facts = [GenericFact(subjectLabel: "r", field: "amount", value: "₹3,800",
                                 status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [b2])]
        let evals = ClaimEvaluator.evaluate(facts: facts, chunks: chunks)
        let prompt = MasterBrain.buildEvidencePrompt(question: "how much?", chunks: chunks, facts: facts, evaluations: evals)
        #expect(prompt.contains("Verified facts"))
        #expect(prompt.contains("amount: ₹3,800 [C2]"))   // b2 is the 2nd chunk → C2
    }

    @Test("An interrogative names a field by SHAPE: 'when' admits a date, 'who' admits nothing")
    func shapeCuesAdmitOnlyMoneyAndDates() {
        // The gate compares question words against a fact's field NAME, so
        // "how much?" — which shares no term with `amount = ₹3,800`, nor with
        // the passage "Amount ₹3,800 paid." — withheld the decisive fact from
        // the prompt. `shapeCues` closes that by reading the question's grammar.
        #expect(SlotFieldResolver.questionRequestsShape(ofField: "amount", in: "how much did I pay?"))
        #expect(SlotFieldResolver.questionRequestsShape(ofField: "grantdate", in: "when was it granted?"))
        // AND the bound that keeps this safe: the fields a "who"/"what"/"where"
        // question ranges over are all text-shaped, so admitting them by shape
        // would readmit the witnessed fact dump. No cue fires.
        #expect(SlotFieldResolver.requestedValueShapes(in: "who drafted the claims?").isEmpty)
        #expect(!SlotFieldResolver.questionRequestsShape(ofField: "applicant", in: "who drafted the claims?"))
        #expect(!SlotFieldResolver.questionRequestsShape(ofField: "employer", in: "where did they work?"))
        // A question naming no shape leaves the ordinary term rules in charge.
        #expect(SlotFieldResolver.requestedValueShapes(in: "tell me about the patent").isEmpty)
    }

    @Test("A shape-cued fact is injected, an off-shape one riding the same chunks is not")
    func shapeCuedFactInjectedButNotTheRest() {
        let obj = UUID(), b1 = UUID(), b2 = UUID()
        let chunks = [chunk(obj, b1, "Signed by the authorised agent."),
                      chunk(obj, b2, "Amount ₹3,800 paid.")]
        let facts = [
            GenericFact(subjectLabel: "r", field: "amount", value: "₹3,800",
                        status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [b2]),
            GenericFact(subjectLabel: "r", field: "applicant", value: "Eco Sanskriti",
                        status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [b1])
        ]
        let evals = ClaimEvaluator.evaluate(facts: facts, chunks: chunks)
        let prompt = MasterBrain.buildEvidencePrompt(
            question: "how much?", chunks: chunks, facts: facts, evaluations: evals)
        #expect(prompt.contains("₹3,800"), "the money fact was withheld from a 'how much' question")
        #expect(!prompt.contains("applicant: Eco Sanskriti"),
                "an off-shape fact rode in on the money cue")
    }

    @Test("A fact whose block isn't among the chunks is omitted")
    func orphanFactOmitted() {
        let obj = UUID(), shown = UUID(), orphan = UUID()
        let chunks = [chunk(obj, shown, "some passage")]
        let facts = [GenericFact(subjectLabel: "r", field: "employer", value: "Orchid",
                                 status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [orphan])]
        let evals = ClaimEvaluator.evaluate(facts: facts, chunks: chunks)
        let prompt = MasterBrain.buildEvidencePrompt(question: "who?", chunks: chunks, facts: facts, evaluations: evals)
        #expect(!prompt.contains("Verified facts"))
        #expect(!prompt.contains("Orchid"))
    }

    @Test("A non-assertable fact is never injected")
    func nonAssertableOmitted() {
        let obj = UUID(), b = UUID()
        let chunks = [chunk(obj, b, "passage")]
        let facts = [GenericFact(subjectLabel: "r", field: "amount", value: "₹1",
                                 status: .inferred, confidence: 0.5, sourceBlockIDs: [b])]
        let evals = ClaimEvaluator.evaluate(facts: facts, chunks: chunks)
        let prompt = MasterBrain.buildEvidencePrompt(question: "?", chunks: chunks, facts: facts, evaluations: evals)
        #expect(!prompt.contains("Verified facts"))   // inferred fact → inference, not an assertive verified fact
    }
}
