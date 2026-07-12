//
//  ReconstructionOutlineTests.swift
//  KalsmritikoshTests
//
//  A7.1 — ReconstructionOutlineBuilder produces a deterministic outline
//  (chronological events with status/actors/date-phrase, distinct actors,
//  largest silent gap, in-scope causal candidates) with no LLM. Add to the
//  test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct ReconstructionOutlineTests {

    private func event(_ day: Double, _ title: String, actors: [Entity.ID] = [], status: EventStatus = .observed) -> Event {
        Event(kind: .meetingHeld, date: Date(timeIntervalSince1970: day * 86_400),
              title: title, entityIDs: actors, sourceObjectID: UUID(),
              datePrecision: .day, status: status)
    }

    @Test func eventsAreChronologicalWithStatusAndDatePhrase() {
        let out = ReconstructionOutlineBuilder().build(
            scope: "Project Delta",
            events: [event(30, "Later"), event(0, "First")]
        )
        #expect(out.scope == "Project Delta")
        #expect(out.events.map(\.title) == ["First", "Later"])
        #expect(out.events.first?.status == .observed)
        #expect(out.events.first?.datePhrase.isEmpty == false)
        #expect(out.eventCount == 2)
    }

    @Test func distinctActorsInFirstAppearanceOrder() {
        let alice = UUID(), bob = UUID()
        let out = ReconstructionOutlineBuilder().build(
            scope: "s",
            events: [event(0, "A", actors: [alice]), event(1, "B", actors: [bob, alice])],
            entityNames: [alice: "Alice", bob: "Bob"]
        )
        #expect(out.actors == ["Alice", "Bob"])
    }

    @Test func largestGapIsBiggestSilentStretch() {
        let out = ReconstructionOutlineBuilder().build(
            scope: "s",
            events: [event(0, "A"), event(5, "B"), event(45, "C")]  // gaps: 5d then 40d
        )
        #expect(out.largestGapDays == 40)
        #expect(out.windowStart == Date(timeIntervalSince1970: 0))
        #expect(out.windowEnd == Date(timeIntervalSince1970: 45 * 86_400))
    }

    @Test func causalCandidatesFilteredToStoryEvents() {
        let a = event(0, "A"), b = event(1, "B")
        let stray = UUID()
        let inStory = CausalLink(sourceEventID: a.id, targetEventID: b.id, relation: .caused, confidence: 0.8)
        let outOfStory = CausalLink(sourceEventID: a.id, targetEventID: stray, relation: .caused, confidence: 0.8)
        let out = ReconstructionOutlineBuilder().build(
            scope: "s", events: [a, b], causalLinks: [inStory, outOfStory]
        )
        #expect(out.causalCandidates.count == 1)
        #expect(out.causalCandidates.first?.targetEventID == b.id)
    }

    @Test func emptyStoryIsEmptyOutline() {
        let out = ReconstructionOutlineBuilder().build(scope: "s", events: [])
        #expect(out.events.isEmpty)
        #expect(out.windowStart == nil)
        #expect(out.largestGapDays == 0)
    }
}
