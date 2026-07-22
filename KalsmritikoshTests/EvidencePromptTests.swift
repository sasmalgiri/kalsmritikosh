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
        let prompt = MasterBrain.buildEvidencePrompt(question: "how much?", chunks: chunks, facts: facts)
        #expect(prompt.contains("Verified facts"))
        #expect(prompt.contains("amount: ₹3,800 [C2]"))   // b2 is the 2nd chunk → C2
    }

    @Test("A fact whose block isn't among the chunks is omitted")
    func orphanFactOmitted() {
        let obj = UUID(), shown = UUID(), orphan = UUID()
        let chunks = [chunk(obj, shown, "some passage")]
        let facts = [GenericFact(subjectLabel: "r", field: "employer", value: "Orchid",
                                 status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [orphan])]
        let prompt = MasterBrain.buildEvidencePrompt(question: "who?", chunks: chunks, facts: facts)
        #expect(!prompt.contains("Verified facts"))
        #expect(!prompt.contains("Orchid"))
    }

    @Test("A non-assertable fact is never injected")
    func nonAssertableOmitted() {
        let obj = UUID(), b = UUID()
        let chunks = [chunk(obj, b, "passage")]
        let facts = [GenericFact(subjectLabel: "r", field: "amount", value: "₹1",
                                 status: .inferred, confidence: 0.5, sourceBlockIDs: [b])]
        let prompt = MasterBrain.buildEvidencePrompt(question: "?", chunks: chunks, facts: facts)
        #expect(!prompt.contains("Verified facts"))
    }
}
