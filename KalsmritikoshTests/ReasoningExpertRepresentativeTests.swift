//
//  ReasoningExpertRepresentativeTests.swift
//  KalsmritikoshTests
//
//  V2 determinism (owner Tie-Inclusive Cut Law, 2026-09-02). A factClaim's
//  single supporting object must be chosen by a CRITERION, never by array
//  position: eval.evidence is an order-independent set by design, and the old
//  `.first` read let a co-equal evidence object (a peripheral email tying with
//  the real evidence) win intermittently — the seal-#3 Q2 confidence wobble.
//  The representative is now the least objectID: invariant to array order.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("V2 — claim representative is order-independent (Tie-Inclusive Cut Law)")
struct ReasoningExpertRepresentativeTests {

    private func ev(_ id: String) -> AssertabilityEvidence {
        AssertabilityEvidence(objectID: UUID(uuidString: id)!)
    }

    @Test("Least-objectID representative is invariant to evidence array order")
    func representativeOrderIndependent() {
        let a = ev("0EE90103-4EB2-4709-872B-310A35386578")   // the peripheral Google-Contacts email
        let b = ev("2EE6A9C3-4121-496B-AF7F-394556D02B7B")
        let c = ev("FA1A6CFA-7BFE-40B2-9715-08189847BD95")   // attorney-firm email
        let forward  = ReasoningExpert.stableRepresentative([a, b, c])
        let reversed = ReasoningExpert.stableRepresentative([c, b, a])
        let shuffled = ReasoningExpert.stableRepresentative([b, c, a])
        #expect(forward == reversed)
        #expect(forward == shuffled)
        #expect(forward == a.objectID, "least objectID (0EE9…) must win regardless of position")
    }

    @Test("Empty evidence → no representative; single evidence → itself")
    func edgeCases() {
        #expect(ReasoningExpert.stableRepresentative([]) == nil)
        let only = ev("1A9BCBC1-50C6-438A-8E50-14D34563102E")
        #expect(ReasoningExpert.stableRepresentative([only]) == only.objectID)
    }

    @Test("With scores, the most-relevant object wins (order-independent); ties fall to least objectID")
    func representativePrefersRelevance() {
        let lo = ev("0EE90103-4EB2-4709-872B-310A35386578")   // least uuid, but LOW relevance
        let hi = ev("FA1A6CFA-7BFE-40B2-9715-08189847BD95")   // higher uuid, HIGH relevance
        let scores: [UUID: Double] = [lo.objectID: 0.1, hi.objectID: 0.9]
        #expect(ReasoningExpert.stableRepresentative([lo, hi], scoreByObject: scores) == hi.objectID)
        #expect(ReasoningExpert.stableRepresentative([hi, lo], scoreByObject: scores) == hi.objectID,
                "highest-score wins regardless of array order")
        // Equal score → deterministic tiebreak to least objectID.
        let tie: [UUID: Double] = [lo.objectID: 0.5, hi.objectID: 0.5]
        #expect(ReasoningExpert.stableRepresentative([lo, hi], scoreByObject: tie) == lo.objectID)
    }
}
