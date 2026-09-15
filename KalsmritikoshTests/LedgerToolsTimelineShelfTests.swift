//
//  LedgerToolsTimelineShelfTests.swift
//  KalsmritikoshTests
//
//  U-7 — the two new deterministic tools the FM lane will call:
//  timelineSlice (date-windowed chain) and shelfLookup (reference lane).
//  Pure over injected reads; fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-7 ledger tools — timelineSlice + shelfLookup")
struct LedgerToolsTimelineShelfTests {

    private func event(_ title: String, _ date: Date) -> Event {
        Event(kind: .other, date: date, title: title, sourceObjectID: UUID(), confidence: .high)
    }

    private func cal(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!   // align with the tool's UTC formatter
        return c.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func timelineSliceBoundsTheWindow() async {
        let events = [
            event("patent filed", cal(2022, 3, 1)),
            event("patent granted", cal(2024, 11, 28)),
            event("renewal paid", cal(2025, 6, 1)),
        ]
        let tools = LedgerTools(
            events: { _ in events },
            facts: { _ in [] },
            chunksForQuestion: { _ in [] })

        // Only 2024 events survive the window.
        let slice = await tools.timelineSlice(question: "granted",
                                              from: self.cal(2024, 1, 1),
                                              to: self.cal(2024, 12, 31))
        #expect(slice.count == 1)
        #expect(slice.first?.text.contains("28 November 2024") == true)

        // Open-ended window (from only) keeps everything on/after the bound.
        let openEnd = await tools.timelineSlice(question: "granted",
                                                from: self.cal(2024, 1, 1), to: nil)
        #expect(openEnd.count == 2)
    }

    @Test func shelfLookupReturnsNothingWithoutAShelf() async {
        let tools = LedgerTools(
            events: { _ in [] }, facts: { _ in [] }, chunksForQuestion: { _ in [] })
        let r = await tools.shelfLookup("force majeure")
        #expect(r.isEmpty)   // no shelf wired → archive/GK lanes still answer
    }

    @Test func shelfLookupUsesTheInjectedShelf() async {
        var tools = LedgerTools(
            events: { _ in [] }, facts: { _ in [] }, chunksForQuestion: { _ in [] })
        tools.shelf = { term in
            [ToolResult(id: "R1", text: "From your reference shelf: \(term) — a defined term.",
                        objectIDs: [])]
        }
        let r = await tools.shelfLookup("force majeure")
        #expect(r.count == 1)
        #expect(r.first?.id == "R1")
        #expect(r.first?.text.contains("reference shelf") == true)
    }
}
