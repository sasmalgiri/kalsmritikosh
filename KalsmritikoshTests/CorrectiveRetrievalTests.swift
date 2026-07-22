//
//  CorrectiveRetrievalTests.swift
//  KalsmritikoshTests
//
//  RET-007 — the bounded corrective-retrieval orchestration in MasterBrain:
//  merge is lossless + deduped; a pass fires only when a requested field is
//  missing AND there's something to build on; capped at one pass.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Corrective retrieval (RET-007)")
struct CorrectiveRetrievalTests {

    private actor Recorder { var count = 0; func bump() { count += 1 } }

    private func chunk(_ obj: UUID, _ id: UUID, _ text: String) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(id: id, objectID: obj, ordinal: 0, text: text, characterRange: 0..<text.count),
            score: 1.0, viaLayer: .metadata)
    }

    @Test("merge is lossless and deduped, base order preserved")
    func merge() {
        let obj = UUID(), cA = UUID(), cB = UUID()
        let f1 = GenericFact(subjectLabel: "s", field: "a", value: "1", status: .sourceAsserted,
                             confidence: 0.5, sourceBlockIDs: [])
        let f2 = GenericFact(subjectLabel: "s", field: "b", value: "2", status: .sourceAsserted,
                             confidence: 0.5, sourceBlockIDs: [])
        let base = RetrievalResult(chunks: [chunk(obj, cA, "A")], genericFacts: [f1])
        let extra = RetrievalResult(chunks: [chunk(obj, cA, "A-dup"), chunk(obj, cB, "B")], genericFacts: [f1, f2])
        let merged = MasterBrain.mergeRetrievals(base, extra)
        #expect(merged.chunks.map(\.chunk.id) == [cA, cB])   // dup dropped, order kept
        #expect(merged.genericFacts.count == 2)
    }

    @Test("no corrective pass when the first result is empty (nothing to build on)")
    func noPassOnEmpty() async {
        let rec = Recorder()
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "how much was paid?")
        let out = await MasterBrain.applyCorrectiveRetrieval(
            first: RetrievalResult(), intent: intent, layers: [.metadata],
            retrieve: { _ in await rec.bump(); return RetrievalResult() })
        #expect(await rec.count == 0)
        #expect(out.chunks.isEmpty)
    }

    @Test("one focused pass fires when a requested field is missing, then merges")
    func firesOnce() async {
        let rec = Recorder()
        let obj = UUID(), c1 = UUID(), c2 = UUID()
        // First pass has a chunk with NO amount → monetaryAmount is missing.
        let first = RetrievalResult(chunks: [chunk(obj, c1, "General meeting notes about the schedule.")],
                                    layersUsed: [.metadata])
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "how much was paid?")
        let out = await MasterBrain.applyCorrectiveRetrieval(
            first: first, intent: intent, layers: [.metadata],
            retrieve: { focused in
                await rec.bump()
                // The focused question carries the missing field label.
                #expect(focused.rawQuestion.contains("amount"))
                return RetrievalResult(chunks: [self.chunk(obj, c2, "Amount ₹500 paid.")], layersUsed: [.vector])
            })
        #expect(await rec.count == 1)                 // exactly one pass
        #expect(out.chunks.map(\.chunk.id) == [c1, c2])   // merged, base first
    }
}
