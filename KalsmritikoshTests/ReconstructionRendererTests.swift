//
//  ReconstructionRendererTests.swift
//  KalsmritikoshTests
//
//  A7.1 / A7.3 — ReconstructionOutlineRenderer turns the outline + alternative
//  histories into the markdown addendum shown beneath a reconstruction, and a
//  plain no-LLM timeline. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct ReconstructionRendererTests {

    private func event(_ day: Double, _ title: String) -> Event {
        Event(kind: .meetingHeld, date: Date(timeIntervalSince1970: day * 86_400),
              title: title, sourceObjectID: UUID(), datePrecision: .day, status: .observed)
    }

    @Test func addendumShowsCoverageAndLargeGap() {
        let outline = ReconstructionOutlineBuilder().build(
            scope: "Project Delta", events: [event(0, "Kickoff"), event(90, "Delivery")]
        )
        let md = ReconstructionOutlineRenderer().addendum(outline: outline, alternatives: [])
        #expect(md.contains("Coverage"))
        #expect(md.contains("2 events"))
        #expect(md.contains("90 days"))   // the silent stretch
    }

    @Test func addendumRendersAlternativesWithDecisiveEvidence() {
        let alt = AlternativeHistoryBuilder().build(contradictions: [
            Contradiction(kind: .amount, description: "Conflicting amounts",
                          claimA: "USD 1000", claimB: "USD 1200",
                          evidenceA: UUID(), evidenceB: UUID())
        ])
        let outline = ReconstructionOutlineBuilder().build(scope: "s", events: [event(0, "A")])
        let md = ReconstructionOutlineRenderer().addendum(outline: outline, alternatives: alt)
        #expect(md.contains("Alternative accounts"))
        #expect(md.contains("USD 1000"))
        #expect(md.contains("USD 1200"))
        #expect(md.contains("Decisive missing evidence"))
    }

    @Test func plainTimelineIsPrecisionAwareAndStatusLabelled() {
        let outline = ReconstructionOutlineBuilder().build(
            scope: "Deal", events: [event(0, "Signed")]
        )
        let md = ReconstructionOutlineRenderer().plainTimeline(outline: outline)
        #expect(md.contains("Timeline (Deal)"))
        #expect(md.contains("Signed"))
        #expect(md.contains("observed"))
    }

    @Test func emptyOutlineYieldsEmptyRenderings() {
        let outline = ReconstructionOutlineBuilder().build(scope: "s", events: [])
        #expect(ReconstructionOutlineRenderer().addendum(outline: outline, alternatives: []).isEmpty)
        #expect(ReconstructionOutlineRenderer().plainTimeline(outline: outline).isEmpty)
    }
}
