//
//  TimelineExportTests.swift
//  KalsmritikoshTests
//
//  The Timeline screen's export: the events shown, oldest first, the date as the screen
//  shows it, each event's source file (or an explicit "(source not found)"), both
//  confidences; CSV quoting and the Markdown footer.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite struct TimelineExportTests {

    private let koA = UUID()
    private let koB = UUID()

    private func events() -> [Event] {
        [Event(kind: .emailReceived, date: Date(timeIntervalSince1970: 1_712_000_000), title: "Contract modified",
               summary: "Amendment 7, signed by Carter, Lopez", sourceObjectID: koA, confidence: .high, dateConfidence: 0.95),
         Event(kind: .emailReceived, date: Date(timeIntervalSince1970: 1_700_000_000), title: "Invoice 432 issued",
               sourceObjectID: koB, dateConfidence: 0.3)]
    }

    @Test func rowsAreTheShownEventsOldestFirstWithSources() {
        let t = TimelineExport.table(events: events(), scope: "Person: Maria Lopez",
                                     dateLabel: { $0.dateConfidence < 0.6 ? "~ label" : "label" },
                                     sourceNames: [koA: "amendment-7.md"])
        #expect(t.title == "Timeline — Person: Maria Lopez")
        #expect(t.columns == TimelineExport.columns)
        #expect(t.rows.count == 2)
        // Oldest first, whatever order the screen held them in.
        #expect(t.rows[0][3] == "Invoice 432 issued")
        #expect(t.rows[1][3] == "Contract modified")
        // The screen's date label, including the "~" for an untrusted date.
        #expect(t.rows[0][0] == "~ label")
        #expect(t.rows[1][0] == "label")
        // A source whose name could not be read is said so, never left blank.
        #expect(t.rows[0][5] == "(source not found)")
        #expect(t.rows[1][5] == "amendment-7.md")
        #expect(t.rows[1][7] == "95 %")
        #expect(t.rows[0][7] == "30 %")
        // Receipt passages: the summary, or the title when there is none.
        #expect(t.passages == ["Invoice 432 issued", "Amendment 7, signed by Carter, Lopez"])
    }

    @Test func csvQuotesAndMarkdownFooter() {
        let t = TimelineExport.table(events: events(), scope: "Global", dateLabel: { _ in "d" }, sourceNames: [:])
        let csv = TimelineExport.render(t, format: .csv)
        #expect(csv.hasPrefix("Date,Date precision,Kind,Event,Summary,Source,Event confidence,Date confidence\r\n"))
        #expect(csv.contains("\"Amendment 7, signed by Carter, Lopez\""))
        let md = TimelineExport.render(t, format: .markdown)
        #expect(md.hasPrefix("# Timeline — Global\n"))
        #expect(md.contains("2 events, oldest first. A date marked ~ is approximate."))
    }

    @Test func emptyTimelineStillHasHeader() {
        let t = TimelineExport.table(events: [], scope: "Global", dateLabel: { _ in "" }, sourceNames: [:])
        #expect(t.rows.isEmpty)
        #expect(TimelineExport.render(t, format: .markdown).contains("0 events"))
    }
}
