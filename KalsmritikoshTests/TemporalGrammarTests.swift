//
//  TemporalGrammarTests.swift
//  KalsmritikoshTests
//
//  Plan B6 — a question's time expression parses into a concrete UTC window;
//  no temporal cue → nil. Year-granular, deterministic.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Plan B6 — temporal window grammar")
struct TemporalGrammarTests {

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func y(_ v: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: v, month: m, day: d))!
    }
    private let now = Date(timeIntervalSince1970: 1_760_000_000) // 2025

    @Test func singleYear() {
        let w = TemporalGrammar.parse("what happened in 2024?", now: now)
        #expect(w?.from == y(2024, 1, 1))
        #expect(cal.component(.year, from: w!.to!) == 2024)
    }

    @Test func betweenTwoYears() {
        let w = TemporalGrammar.parse("events between 2013 and 2015", now: now)
        #expect(w?.from == y(2013, 1, 1))
        #expect(cal.component(.year, from: w!.to!) == 2015)
    }

    @Test func sinceIsOpenEnded() {
        let w = TemporalGrammar.parse("anything since 2020?", now: now)
        #expect(w?.from == y(2020, 1, 1))
        #expect(w?.to == nil)
    }

    @Test func beforeIsBackwardOpen() {
        let w = TemporalGrammar.parse("filings before 2016", now: now)
        #expect(w?.from == nil)
        #expect(cal.component(.year, from: w!.to!) == 2015)
    }

    @Test func lastYearRelative() {
        let w = TemporalGrammar.parse("what changed last year?", now: now)
        #expect(cal.component(.year, from: w!.from!) == 2024)
    }

    @Test func noTemporalCueIsNil() {
        #expect(TemporalGrammar.parse("who drafted the claims?", now: now) == nil)
    }
}
