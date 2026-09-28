//
//  TimelineGapsTests.swift
//  KalsmritikoshTests
//
//  P3.3 — silent stretches on the timeline axis.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3.3 — timeline gap markers")
struct TimelineGapsTests {
    func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = day; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("Only stretches longer than the zoom's threshold are gaps")
    func gaps() {
        let dates = [d(2023, 1, 10), d(2023, 2, 1), d(2023, 9, 20), d(2023, 10, 1)]
        let month = TimelineGaps.gaps(in: dates, minimumDays: TimelineGaps.thresholdDays(for: "month"))
        #expect(month.count == 1)
        #expect(month.first?.from == d(2023, 2, 1) && month.first?.to == d(2023, 9, 20))
        #expect(TimelineGaps.gaps(in: dates, minimumDays: TimelineGaps.thresholdDays(for: "year")).isEmpty)
        #expect(TimelineGaps.gaps(in: [d(2023, 1, 1)], minimumDays: 30).isEmpty)
    }

    @Test("The marker reads as a span and a range")
    func label() throws {
        let gap = try #require(TimelineGaps.gaps(in: [d(2023, 2, 1), d(2023, 9, 20)], minimumDays: 90).first)
        #expect(TimelineGaps.label(gap).hasPrefix("No dated records for 7 months (Feb 2023 – Sep 2023)"))
    }
}
