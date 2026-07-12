//
//  NarrativePrecisionVerifyTests.swift
//  KalsmritikoshTests
//
//  A7.4 — NarrativeClaimVerifier drops a sentence that states a clock time when
//  no cited event is minute/instant precision (the false-"08:00 AM" anti-
//  pattern). Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct NarrativePrecisionVerifyTests {

    @Test func clockTimeDetection() {
        #expect(NarrativeClaimVerifier.statesClockTime("The call began at 9:00."))
        #expect(NarrativeClaimVerifier.statesClockTime("Signed at 3 PM."))
        #expect(NarrativeClaimVerifier.statesClockTime("Met at 09:12 UTC."))
        #expect(NarrativeClaimVerifier.statesClockTime("Started at eight o'clock."))
        #expect(!NarrativeClaimVerifier.statesClockTime("The contract was signed in March 2025."))
        #expect(!NarrativeClaimVerifier.statesClockTime("Delivered 500 units."))
    }

    private func event(_ precision: DatePrecision) -> Event {
        Event(kind: .meetingHeld, date: Date(timeIntervalSince1970: 1_700_000_000),
              title: "Meeting", sourceObjectID: UUID(), datePrecision: precision)
    }

    @Test func exaggeratedTimeIsDroppedForCoarseEvent() {
        let events = [event(.month)]
        let chapter = NarrativeChapter(
            title: "March", timeframeStart: events[0].date, timeframeEnd: events[0].date,
            eventIDs: events.map(\.id),
            prose: "The kickoff happened in March [E1]. It started at 9:00 AM [E1].",
            claimCitations: [], contradictions: [], confidence: 0.8
        )
        let out = NarrativeClaimVerifier().verify(chapter: chapter, events: events)
        // The month-precision "in March" sentence survives; the "9:00 AM" one is dropped.
        #expect(out.prose.contains("March"))
        #expect(!out.prose.contains("9:00"))
    }

    @Test func clockTimeKeptWhenEventIsInstantPrecision() {
        let events = [event(.instant)]
        let chapter = NarrativeChapter(
            title: "Call", timeframeStart: events[0].date, timeframeEnd: events[0].date,
            eventIDs: events.map(\.id),
            prose: "The call began at 9:00 AM [E1].",
            claimCitations: [], contradictions: [], confidence: 0.8
        )
        let out = NarrativeClaimVerifier().verify(chapter: chapter, events: events)
        #expect(out.prose.contains("9:00"))
    }
}
