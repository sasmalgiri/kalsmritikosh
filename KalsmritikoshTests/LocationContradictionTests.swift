//
//  LocationContradictionTests.swift
//  KalsmritikoshTests
//
//  A5.6 — ContradictionDetector.detectEventLocationConflicts: two sources
//  placing the same event in different locations. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct LocationContradictionTests {

    private func meeting(_ location: String, source: UUID, title: String = "Meeting held") -> Event {
        Event(kind: .meetingHeld, date: Date(timeIntervalSince1970: 1_700_000_000),
              title: title, sourceObjectID: source, confidence: .medium,
              attributes: ["location": AnyCodable(.string(location))])
    }

    @Test func differentLocationsDifferentSourcesConflict() {
        let found = ContradictionDetector().detectEventLocationConflicts([
            meeting("London", source: UUID()), meeting("Paris", source: UUID())
        ])
        #expect(found.count == 1)
        #expect(found.first?.kind == .location)
    }

    @Test func sameLocationDoesNotConflict() {
        let found = ContradictionDetector().detectEventLocationConflicts([
            meeting("London", source: UUID()), meeting("london", source: UUID())
        ])
        #expect(found.isEmpty)   // case-insensitive match
    }

    @Test func sameSourceDoesNotConflict() {
        let s = UUID()
        let found = ContradictionDetector().detectEventLocationConflicts([
            meeting("London", source: s), meeting("Paris", source: s)
        ])
        #expect(found.isEmpty)
    }

    @Test func differentEventsDoNotConflict() {
        let found = ContradictionDetector().detectEventLocationConflicts([
            meeting("London", source: UUID(), title: "Kickoff meeting"),
            meeting("Paris", source: UUID(), title: "Closing meeting")
        ])
        #expect(found.isEmpty)
    }
}
