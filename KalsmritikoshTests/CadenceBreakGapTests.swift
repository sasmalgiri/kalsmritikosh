//
//  CadenceBreakGapTests.swift
//  KalsmritikoshTests
//
//  A5.7 — GapDetector.detectCadenceBreaks: a skipped period in a regular
//  (weekly/monthly) series of same-titled items. Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct CadenceBreakGapTests {

    private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: n * 86_400) }

    @Test func weeklySeriesWithASkipIsAGap() {
        // Weekly on days 0, 7, 14, then a jump to 28 (day-21 occurrence missing).
        let items = [0.0, 7, 14, 28].map {
            (seriesKey: "Weekly status report", date: day($0), objectID: UUID())
        }
        let gaps = GapDetector().detectCadenceBreaks(items: items)
        #expect(gaps.count == 1)
        #expect(gaps.first?.kind == .cadenceBreak)
        #expect(gaps.first?.reason.contains("weekly") == true)
    }

    @Test func regularSeriesHasNoGap() {
        let items = [0.0, 7, 14, 21, 28].map {
            (seriesKey: "Weekly status", date: day($0), objectID: UUID())
        }
        #expect(GapDetector().detectCadenceBreaks(items: items).isEmpty)
    }

    @Test func tooFewOccurrencesIsNotACadence() {
        let items = [0.0, 30].map {
            (seriesKey: "Monthly", date: day($0), objectID: UUID())
        }
        #expect(GapDetector().detectCadenceBreaks(items: items).isEmpty)
    }

    @Test func irregularIntervalsAreNotACadence() {
        // 3, 19, 40-day gaps — no recognizable cadence band.
        let items = [0.0, 3, 22, 62].map {
            (seriesKey: "Ad hoc note", date: day($0), objectID: UUID())
        }
        #expect(GapDetector().detectCadenceBreaks(items: items).isEmpty)
    }

    @Test func seriesKeyNormalizationDropsDigits() {
        #expect(GapDetector.normalizeSeriesKey("Weekly Report #12") == "weekly report")
        #expect(GapDetector.normalizeSeriesKey("Weekly  Report  13") == "weekly report")
    }
}
