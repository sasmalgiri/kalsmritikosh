//
//  DeterministicFactRenderingTests.swift
//  KalsmritikoshTests
//
//  SEM consumption — the zero-LLM answer path renders the domain-pack facts that
//  ride the retrieval, as a lead section, each cited via the surfaced chunk that
//  shares its evidence block. No fact is shown without a backing chunk.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Deterministic fact rendering")
struct DeterministicFactRenderingTests {

    private func intent() -> UserIntent {
        UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "where did they work?")
    }

    private func chunk(objectID: UUID, blockID: UUID?, text: String) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: objectID, ordinal: 0, text: text,
                         characterRange: 0..<text.count, evidenceBlockID: blockID),
            score: 1.0, viaLayer: .metadata)
    }

    @Test("A backed fact renders in the lead section and is cited")
    func backedFactRenders() async throws {
        let obj = UUID(), blk = UUID()
        let retrieval = RetrievalResult(
            chunks: [chunk(objectID: obj, blockID: blk, text: "Worked at Orchid Pharma as a chemist.")],
            layersUsed: [.metadata],
            genericFacts: [GenericFact(subjectLabel: "cv", field: "employer", value: "Orchid Pharma",
                                       status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blk])])
        let answer = await DeterministicEvidenceFallback.build(
            question: "where did they work?", intent: intent(), retrieval: retrieval)
        let a = try #require(answer)
        #expect(a.body.contains("## Extracted facts (from your evidence)"))
        #expect(a.body.contains("Orchid Pharma"))
        #expect(a.citations.contains { $0.objectID == obj })
    }

    @Test("A fact whose block isn't in the surfaced set is NOT shown")
    func unbackedFactDropped() async throws {
        let obj = UUID(), shownBlk = UUID(), orphanBlk = UUID()
        let retrieval = RetrievalResult(
            chunks: [chunk(objectID: obj, blockID: shownBlk, text: "Some passage of at least twenty chars here.")],
            layersUsed: [.metadata],
            genericFacts: [GenericFact(subjectLabel: "cv", field: "amount", value: "₹9,999",
                                       status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [orphanBlk])])
        let answer = await DeterministicEvidenceFallback.build(
            question: "how much?", intent: intent(), retrieval: retrieval)
        let a = try #require(answer)
        #expect(!a.body.contains("Extracted facts"))
        #expect(!a.body.contains("₹9,999"))
    }
}
