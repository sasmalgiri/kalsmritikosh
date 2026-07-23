//
//  ReasoningExpertFactClaimsTests.swift
//  KalsmritikoshTests
//
//  SEM (per-expert consumption) — the generalist expert turns the assertable
//  domain facts riding a retrieval into deterministic coarse claims, each cited
//  to its backing document; orphan / non-assertable facts are skipped so the
//  claim–evidence contract holds.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("ReasoningExpert fact claims")
struct ReasoningExpertFactClaimsTests {

    private func chunk(_ obj: UUID, _ blk: UUID?, _ text: String) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: obj, ordinal: 0, text: text,
                         characterRange: 0..<text.count, evidenceBlockID: blk),
            score: 1.0, viaLayer: .metadata)
    }

    @Test("An assertable fact becomes a coarse claim cited to its backing document")
    func factBecomesClaim() {
        let obj = UUID(), blk = UUID()
        let chunks = [chunk(obj, blk, "Amount ₹3,800 paid.")]
        let facts = [GenericFact(subjectLabel: "r", field: "amount", value: "₹3,800",
                                 status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [blk])]
        let result = RetrievalResult(chunks: chunks, genericFacts: facts,
                                     claimEvaluations: ClaimEvaluator.evaluate(facts: facts, chunks: chunks))
        let claims = ReasoningExpert.factClaims(from: result)
        #expect(claims.count == 1)
        #expect(claims[0].statement == "Amount: ₹3,800")
        #expect(claims[0].supportingObjectIDs == [obj])
        #expect(claims[0].evidenceGranularity == .coarse)
    }

    @Test("Orphan and non-assertable facts are skipped")
    func skips() {
        let obj = UUID(), blk = UUID(), orphan = UUID()
        let chunks = [chunk(obj, blk, "passage")]
        let facts = [
            GenericFact(subjectLabel: "r", field: "amount", value: "₹1",
                        status: .inferred, confidence: 0.5, sourceBlockIDs: [blk]),        // → inference, not assertive
            GenericFact(subjectLabel: "r", field: "employer", value: "Orchid",
                        status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [orphan]) // orphan block → refused
        ]
        let result = RetrievalResult(chunks: chunks, genericFacts: facts,
                                     claimEvaluations: ClaimEvaluator.evaluate(facts: facts, chunks: chunks))
        #expect(ReasoningExpert.factClaims(from: result).isEmpty)
    }
}
