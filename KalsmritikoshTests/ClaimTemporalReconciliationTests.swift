//
//  ClaimTemporalReconciliationTests.swift
//  KalsmritikoshTests
//
//  PA-SEL correction — anchor reconciliation by PRECISION-SUPPORTED INTERVAL overlap, not raw
//  start equality. Two same-month anchors agree; a year that contains a day agrees with it;
//  disjoint periods conflict; `.unknown` never anchors; equally-precise compatible sources
//  choose deterministically.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PA-SEL — temporal anchor reconciliation")
struct ClaimTemporalReconciliationTests {

    private func d(_ y: Int, _ m: Int = 1, _ day: Int = 1, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }
    private func anchor(_ start: Date, _ precision: DatePrecision, end: Date? = nil, source: UUID = UUID()) -> ClaimTemporalAnchor {
        ClaimTemporalAnchor(start: start, end: end, precision: precision, source: DerivedReference(kind: .temporalClaim, id: source))
    }

    @Test("Two different days within the same month at month precision are compatible")
    func sameMonthCompatible() {
        let a = anchor(d(2005, 3, 10), .month)
        let b = anchor(d(2005, 3, 20), .month)
        let (anchorOut, ambiguous) = ClaimSelectionService.reconcile([a, b])
        #expect(ambiguous == false)
        #expect(anchorOut != nil)                          // not falsely conflicting
    }

    @Test("A year anchor that contains a day anchor is compatible; the finer (day) is chosen")
    func yearContainsDay() {
        let year = anchor(d(2005, 1, 1), .year)
        let day = anchor(d(2005, 6, 15), .day)
        let (anchorOut, ambiguous) = ClaimSelectionService.reconcile([year, day])
        #expect(ambiguous == false)
        #expect(anchorOut?.precision == .day)              // finest compatible
    }

    @Test("Same start with differing ends still overlap → compatible (ends are considered)")
    func sameStartDifferingEndsOverlap() {
        let a = anchor(d(2005, 1, 1), .day, end: d(2005, 1, 11))
        let b = anchor(d(2005, 1, 1), .day, end: d(2007, 1, 1))
        let (anchorOut, ambiguous) = ClaimSelectionService.reconcile([a, b])
        #expect(ambiguous == false)                        // supported intervals overlap at the start
        #expect(anchorOut != nil)
    }

    @Test("Disjoint periods are ambiguous, never guessed")
    func disjointAmbiguous() {
        let a = anchor(d(2001, 1, 1), .year)
        let b = anchor(d(2005, 1, 1), .year)
        let (anchorOut, ambiguous) = ClaimSelectionService.reconcile([a, b])
        #expect(anchorOut == nil)
        #expect(ambiguous == true)
    }

    @Test("Equally-precise compatible sources choose deterministically by source id")
    func equalPrecisionDeterministic() {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let a = anchor(d(2005, 6, 15), .day, source: ids[1])
        let b = anchor(d(2005, 6, 15), .day, source: ids[0])
        let (anchorOut, ambiguous) = ClaimSelectionService.reconcile([a, b])
        #expect(ambiguous == false)
        #expect(anchorOut?.source.id == ids[0])            // smallest id wins the tie
    }

    @Test("An unknown-precision anchor cannot establish a date")
    func unknownNotDated() {
        let (anchorOut, ambiguous) = ClaimSelectionService.reconcile([anchor(d(2005), .unknown)])
        #expect(anchorOut == nil)
        #expect(ambiguous == false)                        // plainly undated, not ambiguous
        #expect(ClaimSelectionService.normalizedExtent(anchor(d(2005), .unknown)) == nil)
    }
}
