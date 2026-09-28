//
//  StatusAnswerTests.swift
//  KalsmritikoshTests
//
//  L5 — "what is the status of …" is answered by the subject's latest dated
//  lifecycle milestone, not by a status FIELD that holds every value ever
//  stated. Deterministic; cited; correspondence never outranks a milestone.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("L5 — where a matter stands")
struct StatusAnswerTests {
    let doc = UUID()
    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("Status questions route to .status; ordinary questions do not")
    func routing() {
        for q in ["What is the status of patent application 202331019665?", "Current status of the contract?",
                  "what's the status of my application", "Where does it stand with the patent?"] {
            #expect(QuestionShapeRouter.route(q).shape == .status, "\(q)")
        }
        for q in ["Where does Gopinath work?", "Who drafted the claims?", "Is the patent granted?"] {
            #expect(QuestionShapeRouter.route(q).shape != .status, "\(q)")
        }
    }

    @Test("The latest dated lifecycle milestone is the status; earlier ones follow; mail never leads")
    func latestMilestoneLeads() throws {
        let events = [
            Event(kind: .other, date: day(2023, 3, 22), title: "Application filed", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 8, 14), title: "Hearing held before the Controller", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 11, 28), title: "Patent granted and recorded in the Register of Patents", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .emailReceived, date: day(2024, 12, 5), title: "Intimation regarding the grant", sourceObjectID: doc, dateConfidence: 0.95),
            Event(kind: .emailReceived, date: day(2025, 1, 2), title: "Hearing reminder", sourceObjectID: doc, dateConfidence: 0.95),
        ]
        let out = try #require(EventAnswerComposer.composeStatus(question: "status?", events: events, documentsSearched: 1))
        #expect(out.primaryText.hasPrefix("Current status: granted — patent granted and recorded in the Register of Patents on 28 November 2024."))
        #expect(out.primaryText.contains("22 March 2023 — Application filed"))
        #expect(out.primaryText.contains("14 August 2024 — Hearing held"))
        #expect(!out.primaryText.contains("Hearing reminder") || out.primaryText.contains("Latest correspondence"),
                "a reminder email is correspondence, never a milestone")
        #expect(out.supportingEvents.first?.title.hasPrefix("Patent granted") == true)
    }

    @Test("An extraction-time date never leads — the invoice stamped 'today' is not the status")
    func untrustworthyDateIgnored() throws {
        let events = [
            Event(kind: .other, date: day(2024, 11, 28), title: "Patent granted", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .invoiceIssued, date: day(2026, 9, 25), title: "Invoice issued", sourceObjectID: doc, dateConfidence: 0.24),
        ]
        let out = try #require(EventAnswerComposer.composeStatus(question: "status?", events: events, documentsSearched: 1))
        #expect(out.primaryText.hasPrefix("Current status: granted"))
        #expect(!out.primaryText.contains("2026"))
    }

    @Test("On the same day a decisive state outranks a procedural one; no milestone → nil (pipeline runs)")
    func decisiveAndNil() throws {
        let same = [
            Event(kind: .other, date: day(2024, 11, 28), title: "Hearing concluded", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 11, 28), title: "Application refused", sourceObjectID: doc, dateConfidence: 0.85),
        ]
        let out = try #require(EventAnswerComposer.composeStatus(question: "status?", events: same, documentsSearched: 1))
        #expect(out.primaryText.hasPrefix("Current status: refused"))
        let chatter = [Event(kind: .emailReceived, date: day(2024, 1, 1), title: "hi", sourceObjectID: doc),
                       Event(kind: .other, date: day(2024, 2, 1), title: "Lunch meeting", sourceObjectID: doc)]
        #expect(EventAnswerComposer.composeStatus(question: "status?", events: chatter, documentsSearched: 1) == nil)
    }

    @Test("Subject events: the hearing records of the named subject, dated and ordered; mail after milestones; none → nil")
    func subjectEvents() throws {
        let events = [
            Event(kind: .emailReceived, date: day(2024, 8, 13), title: "Hearing reminder", sourceObjectID: doc, dateConfidence: 0.95),
            Event(kind: .other, date: day(2024, 8, 13), title: "Hearing held", summary: "Agent appeared before the Controller", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 8, 5), title: "Hearing notice issued", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2026, 9, 25), title: "Hearing held", sourceObjectID: doc, dateConfidence: 0.24),
            Event(kind: .other, date: day(2024, 11, 28), title: "Patent granted", sourceObjectID: doc, dateConfidence: 0.85),
        ]
        let out = try #require(EventAnswerComposer.composeSubjectEvents(
            question: "What happened at the hearing for application 202331019665?", events: events,
            subjectLabel: "Application 202331019665"))
        let lines = out.primaryText.components(separatedBy: "\n")
        #expect(lines[0] == "3 hearing-related records for Application 202331019665:")
        #expect(lines[1] == "5 August 2024 — Hearing notice issued")
        #expect(lines[2] == "13 August 2024 — Hearing held: Agent appeared before the Controller", "the milestone precedes the reminder")
        #expect(!out.primaryText.contains("2026"), "an extraction-time date is not a hearing date")
        #expect(!out.primaryText.contains("granted"), "only the asked-about events")
        #expect(EventAnswerComposer.composeSubjectEvents(question: "What happened?", events: events, subjectLabel: nil) == nil)
    }

    @Test("Same day: the state leads its own notice; the state reads as a word; summaries start and end on whole words")
    func polish() throws {
        let events = [
            Event(kind: .other, date: day(2024, 11, 28), title: "Intimation of grant issued", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 11, 28), title: "Patent granted", sourceObjectID: doc, dateConfidence: 0.85),
        ]
        let out = try #require(EventAnswerComposer.composeStatus(question: "status?", events: events, documentsSearched: 1))
        #expect(out.primaryText.hasPrefix("Current status: granted — patent granted on 28 November 2024."))
        #expect(EventAnswerComposer.cleanSummary("nder [and hearing held on 06/08/2024 ] a patent is hereby granted")
                == "[and hearing held on 06/08/2024 ] a patent is hereby granted")
        #expect(EventAnswerComposer.cleanSummary("short") == nil)
    }

    @Test("A year question: month by month, milestones first, ≤4 lines a month, undated left out; subject questions excluded")
    func period() throws {
        #expect(EventAnswerComposer.askedYear("What happened in 2024?") == 2024)
        #expect(EventAnswerComposer.askedYear("Is 2024 a leap year?") == nil)
        #expect(EventAnswerComposer.hasSubjectReference("What happened to application 202331019665 in 2024?"))
        #expect(!EventAnswerComposer.hasSubjectReference("What happened in 2024?"))
        let events = [
            Event(kind: .emailReceived, date: day(2024, 3, 2), title: "Quote for spec drafting", sourceObjectID: doc, dateConfidence: 0.95),
            Event(kind: .other, date: day(2024, 3, 9), title: "Application filed", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .emailReceived, date: day(2024, 3, 10), title: "Quote for spec drafting", sourceObjectID: doc, dateConfidence: 0.95),
            Event(kind: .other, date: day(2024, 11, 28), title: "Patent granted", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 6, 1), title: "Undated thing", sourceObjectID: doc, dateConfidence: 0.24),
            Event(kind: .emailReceived, date: day(2024, 3, 1), title: "Archived entry — GDPR_Report.pdf", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2023, 5, 1), title: "Last year", sourceObjectID: doc, dateConfidence: 0.85),
        ]
        let out = try #require(EventAnswerComposer.composePeriod(year: 2024, events: events))
        let lines = out.primaryText.components(separatedBy: "\n")
        #expect(lines[0] == "5 dated records in 2024, across 2 months:")
        #expect(!out.primaryText.contains("Archived entry"), "a listing line never crowds out a real happening")
        #expect(out.primaryText.contains("March 2024 — 4 records\n2 March 2024 — Quote for spec drafting\n9 March 2024 — Application filed"))
        #expect(out.primaryText.contains("November 2024 — 1 record\n28 November 2024 — Patent granted"))
        #expect(!out.primaryText.contains("Undated") && !out.primaryText.contains("Last year"))
        #expect(EventAnswerComposer.composePeriod(year: 1999, events: events) == nil)
    }

    @Test("Happenings, not notices: count, existence and 'when' answers")
    func happeningsNotNotices() throws {
        let events = [
            Event(kind: .other, date: day(2024, 7, 13), title: "Hearing notice issued", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .emailReceived, date: day(2024, 7, 31), title: "Payment made for hearing", sourceObjectID: doc, dateConfidence: 0.95),
            Event(kind: .other, date: day(2024, 8, 6), title: "Hearing held", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 8, 6), title: "Hearing held before the Controller", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 8, 14), title: "Hearing held", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .emailReceived, date: day(2024, 8, 20), title: "Archived entry — Hearing Notice.pdf", sourceObjectID: doc, dateConfidence: 0.85),
        ]
        let count = try #require(EventAnswerComposer.composeCount(question: "How many hearings were there?", events: events, documentsSearched: 1))
        #expect(count.primaryText.hasPrefix("2 hearings:"), "two hearing days; notices, payments and listings are not hearings")

        let grant = [
            Event(kind: .other, date: day(2024, 11, 28), title: "Intimation of grant issued", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .other, date: day(2024, 11, 28), title: "Patent granted", sourceObjectID: doc, dateConfidence: 0.85),
            Event(kind: .emailReceived, date: day(2024, 3, 22), title: "Archived entry — Intimation of Grant.pdf", sourceObjectID: doc, dateConfidence: 0.85),
        ]
        let exists = try #require(EventAnswerComposer.composeExistence(question: "Is the patent granted?", events: grant, documentsSearched: 1))
        #expect(exists.primaryText.hasPrefix("Yes — patent granted on 28 November 2024."))
        let when = try #require(EventAnswerComposer.composeSubjectEvents(question: "When was the patent granted?", events: grant, subjectLabel: nil))
        #expect(when.primaryText.hasPrefix("Patent granted on 28 November 2024."))
        #expect(!when.primaryText.contains("Archived entry"))
    }
}

@Suite("P4.4 — date questions are 'when' questions")
struct WhenPhrasingTests {
    @Test("'On which date was …' asks for the day, as 'When was …' does")
    func phrasing() {
        for q in ["When was the patent granted?", "On which date was the patent granted", "What date was the hearing?", "on what day was it filed"] {
            #expect(EventAnswerComposer.asksWhen(q), "\(q)")
        }
        for q in ["What happened at the hearing?", "Which dates matter?", "How many hearings were there?"] {
            #expect(!EventAnswerComposer.asksWhen(q), "\(q)")
        }
    }
}
