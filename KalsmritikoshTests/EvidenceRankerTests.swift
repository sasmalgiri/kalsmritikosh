//
//  EvidenceRankerTests.swift
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EvidenceRanker — Vol 17 §A10")
struct EvidenceRankerTests {
    let ranker = EvidenceRanker()

    /// Independence: when every citation points to a distinct
    /// objectID, every score's independence == 1.0. When all share
    /// one objectID, independence collapses near zero (clamped at 0.05).
    @Test("independence rewards distinct sources")
    func independenceFavorsDistinct() {
        let distinct: [VerifiedAnswer.Citation] = (0..<3).map { _ in
            VerifiedAnswer.Citation(objectID: UUID(), snippet: "x")
        }
        let allSame = UUID()
        let same: [VerifiedAnswer.Citation] = (0..<3).map { _ in
            VerifiedAnswer.Citation(objectID: allSame, snippet: "x")
        }
        let distinctScores = ranker.rank(citations: distinct)
        let sameScores = ranker.rank(citations: same)
        #expect(distinctScores.allSatisfy { $0.independence >= 0.99 })
        #expect(sameScores.allSatisfy { $0.independence <= 0.10 })
    }

    /// Corroboration rises when multiple citations point at the same
    /// event id. Citations without an eventID get a neutral 0.5.
    @Test("corroboration tracks event-id density")
    func corroborationTracksEventDensity() {
        let sharedEvent = UUID()
        let cited: [VerifiedAnswer.Citation] = [
            VerifiedAnswer.Citation(objectID: UUID(), chunkID: nil, eventID: sharedEvent, snippet: "a"),
            VerifiedAnswer.Citation(objectID: UUID(), chunkID: nil, eventID: sharedEvent, snippet: "b"),
            VerifiedAnswer.Citation(objectID: UUID(), chunkID: nil, eventID: UUID(),       snippet: "c"),
        ]
        let scores = ranker.rank(citations: cited)
        // First two citations share an event → highest corroboration.
        #expect(scores[0].corroboration == 1.0)
        #expect(scores[1].corroboration == 1.0)
        // Third is alone → 1 / max(2) = 0.5.
        #expect(scores[2].corroboration == 0.5)
    }

    /// Composite gives meaningful ordering: a fully-corroborated +
    /// independent + provenance-1.0 citation outranks a duplicated
    /// one regardless of freshness.
    @Test("composite ranks strong evidence higher")
    func compositeOrdering() {
        let strongID = UUID()
        let weakID = UUID()
        let citations = [
            VerifiedAnswer.Citation(objectID: strongID, snippet: "strong"),
            VerifiedAnswer.Citation(objectID: weakID,   snippet: "weak-a"),
            VerifiedAnswer.Citation(objectID: weakID,   snippet: "weak-b"),
            VerifiedAnswer.Citation(objectID: weakID,   snippet: "weak-c"),
        ]
        let provenance: [KnowledgeObject.ID: Double] = [strongID: 1.0, weakID: 0.5]
        let ranked = ranker.ranked(citations: citations, objectConfidence: provenance)
        #expect(ranked.first?.citation.objectID == strongID)
    }
}
