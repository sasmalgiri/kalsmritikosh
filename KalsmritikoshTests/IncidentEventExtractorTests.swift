//
//  IncidentEventExtractorTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-18: investigation documents produced no events. The incident sentence
//  with a full written date is now a dated event; prose without a full date, or without harm,
//  stays silent.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Incident events — the chronology's first line")
struct IncidentEventExtractorTests {

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal.date(from: DateComponents(year: y, month: m, day: d)) ?? .distantPast
    }

    @Test("NTSB and OSHA narratives yield the incident on its own date",
          arguments: [
            ("On January 1, 2008, about 1430 Pacific standard time, a Piper PA 28-180 and a Glastar collided in flight at the Sonoma County Airport.", 2008, 1, 1),
            ("On January 4, 2008, Employee #1 entered a sand hopper. The frozen sand gave way, and Employee #1 became engulfed. He was killed.", 2008, 1, 4),
            ("The plaintiff was injured on 3 March 1990 when the scaffold collapsed.", 1990, 3, 3),
            ("Two employees sustained burns when an LP gas tank exploded on 2003-12-03.", 2003, 12, 3),
          ])
    func incidentsAreDated(text: String, y: Int, m: Int, d: Int) {
        let events = IncidentEventExtractor.extract(text: text, sourceObjectID: UUID(), entityIDs: [])
        #expect(events.count == 1, "\(events.map(\.title))")
        #expect(events.first?.kind == .incidentOccurred)
        #expect(events.first?.date == day(y, m, d))
    }

    @Test("No full date, no harm, or an impossible date: nothing is invented",
          arguments: [
            "The pilot reported that the airplane collided with terrain in 2008.",
            "The meeting was held on January 1, 2008 to review the budget.",
            "He was fired on March 3, 2020 after the review.",
            "The accident happened on February 31, 2008.",
            "The court affirmed the judgment on May 2, 1999.",
          ])
    func silentWithoutFullDateOrHarm(text: String) {
        #expect(IncidentEventExtractor.extract(text: text, sourceObjectID: UUID(), entityIDs: []).isEmpty)
    }

    @Test("One event per day, earliest first, at most three")
    func boundedAndOrdered() {
        let text = """
        On May 5, 2010, a fire broke out in the warehouse. On May 1, 2010, a forklift struck by a truck overturned.
        On May 1, 2010, a second worker was injured. On June 2, 2010, a worker fell from a ladder.
        On July 9, 2010, a tank exploded.
        """
        let events = IncidentEventExtractor.extract(text: text, sourceObjectID: UUID(), entityIDs: [])
        #expect(events.map(\.date) == [day(2010, 5, 1), day(2010, 5, 5), day(2010, 6, 2)])
    }
}
