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
        // The question must SHARE terms with the surfaced passage, or the W4
        // relevance gate abstains (returns nil) before this test's real
        // invariant is ever reached. The original wording — "how much?" against
        // a passage about nothing in particular — passed only because the gate
        // did not yet exist, and it hid what is being checked here: that an
        // orphan fact is dropped for want of a BACKING CHUNK, not for want of
        // relevance.
        let retrieval = RetrievalResult(
            chunks: [chunk(objectID: obj, blockID: shownBlk,
                           text: "The invoice passage of at least twenty chars here.")],
            layersUsed: [.metadata],
            genericFacts: [GenericFact(subjectLabel: "cv", field: "amount", value: "₹9,999",
                                       status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [orphanBlk])])
        let answer = await DeterministicEvidenceFallback.build(
            question: "what does the invoice say?", intent: intent(), retrieval: retrieval)
        let a = try #require(answer, "the relevant passage should still compose an answer")
        // The fact's ONLY evidence block was never surfaced, so no chunk backs
        // it — it must not appear however relevant its field looks.
        #expect(!a.body.contains("Extracted facts"))
        #expect(!a.body.contains("₹9,999"))
    }

    @Test("An orphan fact stays out even when the question names its field exactly")
    func unbackedFactDroppedEvenWhenAsked() async throws {
        // The complement of the above, and the case the relevance widening
        // could have broken: here the question asks for the amount BY NAME, so
        // the relevance gate would happily admit the fact. The backing-chunk
        // requirement is what must still refuse it — a fact with no surfaced
        // evidence is unciteable, and showing it would be a claim the answer
        // cannot support.
        let obj = UUID(), shownBlk = UUID(), orphanBlk = UUID()
        let retrieval = RetrievalResult(
            chunks: [chunk(objectID: obj, blockID: shownBlk,
                           text: "The amount payable is stated in the annexure to this invoice.")],
            layersUsed: [.metadata],
            genericFacts: [GenericFact(subjectLabel: "cv", field: "amount", value: "₹9,999",
                                       status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [orphanBlk])])
        let answer = await DeterministicEvidenceFallback.build(
            question: "what amount was paid on the invoice?", intent: intent(), retrieval: retrieval)
        let a = try #require(answer)
        #expect(!a.body.contains("₹9,999"), "an unbacked fact was shown because the question asked for it")
        #expect(!a.body.contains("Extracted facts"))
    }

    @Test("A relevant passage carries its fact even when the question does not name the field")
    func factRidesItsRelevantPassage() async throws {
        // THE defect this suite caught. The user asks "where did they work?";
        // the ledger holds `employer = Orchid Pharma`. Those share no words, so
        // a field-name-matching gate dropped the one fact that answers the
        // question — while showing the chunk that says the same thing in prose.
        let obj = UUID(), blk = UUID()
        let retrieval = RetrievalResult(
            chunks: [chunk(objectID: obj, blockID: blk, text: "Worked at Orchid Pharma as a chemist.")],
            layersUsed: [.metadata],
            genericFacts: [GenericFact(subjectLabel: "cv", field: "employer", value: "Orchid Pharma",
                                       status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blk])])
        let a = try #require(await DeterministicEvidenceFallback.build(
            question: "where did they work?", intent: intent(), retrieval: retrieval))
        #expect(a.body.contains("## Extracted facts (from your evidence)"))
        #expect(a.body.contains("Orchid Pharma"))
    }

    @Test("A fact riding an UNRELATED passage is still dumped out")
    func irrelevantFactOnIrrelevantPassageStaysOut() async throws {
        // The regression guard for the widening: the witnessed junk was riding
        // facts from unrelated documents (a hearing date on a lease question).
        // Both the fact AND its passage are off-topic, so both gates refuse and
        // the composer abstains rather than dumping a pile.
        let obj = UUID(), blk = UUID()
        let retrieval = RetrievalResult(
            chunks: [chunk(objectID: obj, blockID: blk,
                           text: "Hearing in the patent opposition was listed before the Controller.")],
            layersUsed: [.metadata],
            genericFacts: [GenericFact(subjectLabel: "patent", field: "hearingdate", value: "2024-08-29",
                                       status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blk])])
        let answer = await DeterministicEvidenceFallback.build(
            question: "who signed the lease?", intent: intent(), retrieval: retrieval)
        // Nothing relevant survived, so the honest outcome is no answer at all —
        // the caller keeps its not-found instead of showing a hearing date.
        if let a = answer {
            #expect(!a.body.contains("2024-08-29"), "an unrelated fact was dumped into the answer")
            #expect(!a.body.contains("Hearing in the patent opposition"),
                    "an unrelated passage was dumped into the answer")
        }
    }
}
