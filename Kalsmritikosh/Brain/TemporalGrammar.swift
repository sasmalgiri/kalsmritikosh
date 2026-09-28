//
//  TemporalGrammar.swift
//  Kalsmritikosh
//
//  Plan B6 — parse a question's time expression into a concrete [from, to]
//  window so temporal questions ("what happened in 2024", "between 2013 and
//  2015", "since 2020") retrieve the right slice instead of the whole archive.
//  Deterministic, UTC, no model. Returns nil when there is no temporal cue (the
//  caller then leaves the timeframe open). Year-granular on purpose: robust and
//  unambiguous; finer grains can layer on later.
//

import Foundation

public enum TemporalGrammar {

    public struct Window: Equatable, Sendable {
        public let from: Date?
        public let to: Date?
        public init(from: Date?, to: Date?) { self.from = from; self.to = to }
    }

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private static func yearStart(_ y: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: 1, day: 1))!
    }
    private static func yearEnd(_ y: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: 12, day: 31, hour: 23, minute: 59, second: 59))!
    }

    /// Parse a time window from the question, or nil if none is expressed.
    public nonisolated static func parse(_ question: String, now: Date) -> Window? {
        let q = question.lowercased()
        let years = fourDigitYears(in: q)
        let nowYear = utc.component(.year, from: now)

        // "between YYYY and YYYY" (or any two years present with a range cue).
        if years.count >= 2, q.contains("between") || q.contains(" and ") || q.contains(" to ") {
            let lo = years.min()!, hi = years.max()!
            return Window(from: yearStart(lo), to: yearEnd(hi))
        }
        // "since / after / from YYYY" → open-ended forward.
        if let y = years.first, q.contains("since ") || q.contains("after ") || q.contains("from ") {
            return Window(from: yearStart(y), to: nil)
        }
        // "before / until / up to YYYY" → open-ended backward.
        if let y = years.first, q.contains("before ") || q.contains("until ") || q.contains("up to ") {
            return Window(from: nil, to: yearEnd(y - 1))
        }
        // A single explicit year → that whole year.
        if years.count == 1 {
            return Window(from: yearStart(years[0]), to: yearEnd(years[0]))
        }
        // Relative: "this year" / "last year".
        if q.contains("this year") { return Window(from: yearStart(nowYear), to: yearEnd(nowYear)) }
        if q.contains("last year") { return Window(from: yearStart(nowYear - 1), to: yearEnd(nowYear - 1)) }
        return nil
    }

    /// Distinct 19xx/20xx years in first-seen order.
    nonisolated static func fourDigitYears(in text: String) -> [Int] {
        var out: [Int] = []; var seen = Set<Int>()
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            if scalars[i].isNumber {
                var j = i
                var digits = ""
                while j < scalars.count, scalars[j].isNumber { digits.append(scalars[j]); j += 1 }
                if digits.count == 4, let y = Int(digits), (1900...2099).contains(y), seen.insert(y).inserted {
                    out.append(y)
                }
                i = j
            } else { i += 1 }
        }
        return out
    }
}
