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
            // Case bench: OSHA forms put the date on the line after the event title.
            ("Event: Two employees sustain burns when LP gas tank explodes\nEvent date: December 3, 2003\n", 2003, 12, 3),
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
            "The complaint was filed on May 1, 1990. The plaintiff alleges she was injured at work.",
            "The accident airplane's engine was installed on January 5, 2004, and overhauled in 2006.",
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

@Suite("Incident answers — the date leads")
struct IncidentAnswerComposerTests {
    @Test("When-did-it-happen questions are recognised; others are not",
          arguments: [("When did the accident in NTSB case SEA08LA057 happen?", true),
                      ("When did the accident in OSHA investigation 200072106 happen?", true),
                      ("When was the collision?", true),
                      ("When was the contract signed?", false),
                      ("What happened in OSHA investigation 200072106?", false)])
    func shape(question: String, expected: Bool) {
        #expect(IncidentAnswerComposer.asksWhenItHappened(question) == expected)
    }

    @Test("The answer opens with the incident date and cites the event")
    func leadsWithDate() {
        let e = Event(kind: .incidentOccurred, date: Date(timeIntervalSince1970: 1_199_145_600), // 2008-01-01 UTC
                      title: "Two airplanes collided", summary: "On January 1, 2008, a Piper and a Glastar collided in flight.",
                      sourceObjectID: UUID())
        let c = IncidentAnswerComposer.compose(question: "When did the accident in NTSB case SEA08LA057 happen?", events: [e])
        #expect(c?.text.hasPrefix("January 1, 2008.") == true, "\(c?.text ?? "nil")")
        #expect(c?.events.count == 1)
        #expect(IncidentAnswerComposer.compose(question: "When did it happen?", events: []) == nil)
    }

    @Test("The report's own labeled date picks the incident; a mismatch composes nothing")
    func labeledDateDecides() {
        let background = Event(kind: .incidentOccurred, date: Date(timeIntervalSince1970: 1_116_892_800), // 2005-05-24
                               title: "Pilot injured his back", sourceObjectID: UUID())
        let crash = Event(kind: .incidentOccurred, date: Date(timeIntervalSince1970: 1_200_528_000), // 2008-01-17
                          title: "The airplane struck terrain", sourceObjectID: UUID())
        let page = GenericFact(subjectLabel: "NTSB X", field: "dateandtime", value: "January 17, 2008, 1530 PST",
                               status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [UUID()])
        let q = "When did the accident in NTSB case X happen?"
        #expect(IncidentAnswerComposer.compose(question: q, events: [background, crash], facts: [page])?.events.first?.title == "The airplane struck terrain")
        #expect(IncidentAnswerComposer.compose(question: q, events: [background], facts: [page]) == nil,
                "a background incident that contradicts the report's date must not be the answer")
    }
}
