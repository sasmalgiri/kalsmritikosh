//
//  DateGrammar.swift
//  Kalsmritikosh
//
//  G2-TEMPORAL-GRAMMAR — Swift port of chatmind-pipeline's date parsing
//  primitive (`pek_batch_v8.py::normalize_date_span` + `commitment_extract.py::_find_due`).
//
//  Why this exists: Gate 1 temporal questions sit at 0.25 retrieval recall.
//  T1 cites NOTHING ("What changed in Project Delta between April and June 2024?")
//  because we never parse "April … June 2024" into a date range to filter against.
//  This module produces a `UserIntent.Timeframe` from natural-language date
//  expressions in a question, so downstream retrieval (HybridRetriever) and
//  event filtering (TimelineEngine) can use real ranges instead of `nil`.
//
//  Design:
//  - Pure, stateless, deterministic. No LLM. No actor. Pure value-typed API.
//  - Outputs `UserIntent.Timeframe` (start/end Date?, already the codebase type).
//  - All output dates are stored as UTC `Date` instances; presentation layer
//    handles local-time rendering separately.
//  - Priority cascade: absolute date(s) > date range > relative keyword > nil.
//  - Returns nil instead of guessing — callers should treat nil as "no temporal
//    constraint surfaced from this text" and proceed as before.
//
//  What's intentionally NOT here (yet):
//  - Multi-language. English only for v1.
//  - Holiday calendars ("after Christmas") — out of scope.
//  - Recurring patterns ("every Monday") — out of scope.
//  - Time-of-day refinement ("at 4pm") — commitment_extract.py handles that
//    for the event-extractor work; date grammar stops at day resolution.
//

import Foundation

public enum DateGrammar {

    /// One parsed date span. `evidence` is the literal text that triggered
    /// the parse — useful for UI display ("matched 'last week'") and for
    /// debugging in the eval log.
    public struct Match: Sendable, Equatable {
        public let timeframe: UserIntent.Timeframe
        public let evidence: String
    }

    /// Top-level entry point. Walks the input text looking for the
    /// strongest temporal signal and returns it as a `Match`. Returns nil
    /// when no recognized temporal expression is found.
    ///
    /// Priority:
    ///   1. Explicit ISO date range: `2024-04-08 to 2024-06-14`
    ///   2. Two absolute dates connected by "to"/"through"/"and"/"-"
    ///   3. Month-name year: "April 2024" / "Apr 2024" / "April"
    ///   4. Month-name range: "April through June 2024"
    ///   5. Quarter: `Q1 2024` / `Q2`
    ///   6. Relative range: "last week", "this month", "yesterday"
    ///   7. Single absolute date (ISO or `D Mon YYYY`)
    public static func parse(
        _ text: String,
        baseDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Match? {
        let calendar = makeCalendar(timeZone: timeZone)
        let lower = text.lowercased()

        // 1. ISO date range (highest precision)
        if let m = matchIsoRange(in: text, calendar: calendar) { return m }

        // 2. Two absolute dates connected by "to"/"through"/"and"/"-"
        if let m = matchAbsRange(in: text, calendar: calendar) { return m }

        // 3. Month-name range ("April through June 2024", "Apr-Jun 2024")
        if let m = matchMonthRange(in: lower, calendar: calendar, baseDate: baseDate) { return m }

        // 4. Month-name single ("April 2024" / "in April" / "Apr")
        if let m = matchMonthSingle(in: lower, calendar: calendar, baseDate: baseDate) { return m }

        // 5. Quarter ("Q1 2024", "Q2")
        if let m = matchQuarter(in: lower, calendar: calendar, baseDate: baseDate) { return m }

        // 6. Relative keyword ("last week", "this month", "yesterday")
        if let m = matchRelative(in: lower, calendar: calendar, baseDate: baseDate) { return m }

        // 7. Single absolute ISO date or "D Mon YYYY"
        if let m = matchSingleAbsolute(in: text, calendar: calendar) { return m }

        return nil
    }

    // MARK: - 1. ISO range

    /// `2024-04-08 to 2024-06-14`, `between 2024-04-08 and 2024-06-14`,
    /// `2024-04-08..2024-06-14`, `2024-04-08-2024-06-14`.
    /// `and` is included so natural-language "between X and Y" parses as
    /// a range — without it, the parser fell through to the single-date
    /// matcher and lost the end date.
    private static let isoRangeRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(\d{4}-\d{2}-\d{2})\s*(?:to|through|and|-|\.\.)\s*(\d{4}-\d{2}-\d{2})\b"#,
        options: [.caseInsensitive]
    )

    private static func matchIsoRange(in text: String, calendar: Calendar) -> Match? {
        guard let rx = isoRangeRx,
              let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text),
              let evidenceR = Range(m.range, in: text)
        else { return nil }
        let startStr = String(text[r1])
        let endStr = String(text[r2])
        guard let start = parseIsoDate(startStr, calendar: calendar),
              let end = endOfDay(parseIsoDate(endStr, calendar: calendar), calendar: calendar)
        else { return nil }
        return Match(
            timeframe: .init(start: start, end: end),
            evidence: String(text[evidenceR])
        )
    }

    // MARK: - 2. Two absolute dates

    /// `8 April 2024 to 14 June 2024`, `April 8 - June 14, 2024`.
    /// Implementation is the cross-product of "absolute date pattern" twice.
    /// We anchor on the simpler "Mon DD YYYY" / "DD Mon YYYY" forms.
    private static let dayMonYearRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*(?:[,\s]+(\d{4}))?"#,
        options: [.caseInsensitive]
    )
    private static let monDayYearRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+(\d{1,2})(?:[,\s]+(\d{4}))?"#,
        options: [.caseInsensitive]
    )

    private static func matchAbsRange(in text: String, calendar: Calendar) -> Match? {
        // Collect all absolute-date hits with their positions, then look
        // for two that are connected by a range word.
        var hits: [(start: String.Index, end: String.Index, date: Date)] = []
        for rx in [dayMonYearRx, monDayYearRx].compactMap({ $0 }) {
            let matches = rx.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches {
                guard let r = Range(m.range, in: text),
                      let date = parseAbsoluteDate(String(text[r]), calendar: calendar)
                else { continue }
                hits.append((r.lowerBound, r.upperBound, date))
            }
        }
        guard hits.count >= 2 else { return nil }
        hits.sort { $0.start < $1.start }

        // Two adjacent hits separated by "to" / "through" / "and" / "-"
        for i in 0..<(hits.count - 1) {
            let a = hits[i]
            let b = hits[i + 1]
            let between = text[a.end..<b.start].lowercased()
            let isConnector = between.contains(" to ")
                || between.contains(" through ")
                || between.contains(" and ")
                || between.contains(" - ")
                || between.contains("–")
                || between.contains("—")
            if isConnector, a.date <= b.date,
               let end = endOfDay(b.date, calendar: calendar) {
                let evidence = String(text[a.start..<b.end])
                return Match(
                    timeframe: .init(start: a.date, end: end),
                    evidence: evidence
                )
            }
        }
        return nil
    }

    // MARK: - 3. Month-name range

    /// "April through June 2024", "Apr-Jun 2024", "from April to June 2024".
    /// Year falls back to the most recent occurrence near the phrase, then
    /// to `baseDate`'s year. Month boundaries are full calendar months.
    private static let monthRangeRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s*(?:to|through|and|-|–|—)\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*(?:[,\s]+(\d{4}))?\b"#,
        options: [.caseInsensitive]
    )

    private static func matchMonthRange(in lower: String, calendar: Calendar, baseDate: Date) -> Match? {
        guard let rx = monthRangeRx,
              let m = rx.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let r1 = Range(m.range(at: 1), in: lower),
              let r2 = Range(m.range(at: 2), in: lower),
              let evidenceR = Range(m.range, in: lower),
              let m1 = monthIndex(String(lower[r1])),
              let m2 = monthIndex(String(lower[r2])),
              m1 <= m2
        else { return nil }
        let year: Int = {
            if let yR = Range(m.range(at: 3), in: lower), let y = Int(lower[yR]) { return y }
            return calendar.component(.year, from: baseDate)
        }()
        guard let start = startOfMonth(year: year, month: m1, calendar: calendar),
              let end = endOfMonth(year: year, month: m2, calendar: calendar)
        else { return nil }
        return Match(
            timeframe: .init(start: start, end: end),
            evidence: String(lower[evidenceR])
        )
    }

    // MARK: - 4. Month-name single

    /// "April 2024", "in April", "Apr". When no year is given, year is `baseDate`'s.
    private static let monthSingleRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*(?:[,\s]+(\d{4}))?\b"#,
        options: [.caseInsensitive]
    )

    private static func matchMonthSingle(in lower: String, calendar: Calendar, baseDate: Date) -> Match? {
        guard let rx = monthSingleRx,
              let m = rx.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let r1 = Range(m.range(at: 1), in: lower),
              let evidenceR = Range(m.range, in: lower),
              let monthIdx = monthIndex(String(lower[r1]))
        else { return nil }
        let year: Int = {
            if let yR = Range(m.range(at: 2), in: lower), let y = Int(lower[yR]) { return y }
            return calendar.component(.year, from: baseDate)
        }()
        guard let start = startOfMonth(year: year, month: monthIdx, calendar: calendar),
              let end = endOfMonth(year: year, month: monthIdx, calendar: calendar)
        else { return nil }
        return Match(
            timeframe: .init(start: start, end: end),
            evidence: String(lower[evidenceR])
        )
    }

    // MARK: - 5. Quarter

    /// "Q1 2024", "Q2", "in q3 2023". Quarter = 3 calendar months.
    private static let quarterRx: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\bq([1-4])(?:[,\s]+(\d{4}))?\b"#,
        options: [.caseInsensitive]
    )

    private static func matchQuarter(in lower: String, calendar: Calendar, baseDate: Date) -> Match? {
        guard let rx = quarterRx,
              let m = rx.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let qR = Range(m.range(at: 1), in: lower),
              let q = Int(lower[qR]), (1...4).contains(q),
              let evidenceR = Range(m.range, in: lower)
        else { return nil }
        let year: Int = {
            if let yR = Range(m.range(at: 2), in: lower), let y = Int(lower[yR]) { return y }
            return calendar.component(.year, from: baseDate)
        }()
        let startMonth = (q - 1) * 3 + 1
        let endMonth = q * 3
        guard let start = startOfMonth(year: year, month: startMonth, calendar: calendar),
              let end = endOfMonth(year: year, month: endMonth, calendar: calendar)
        else { return nil }
        return Match(
            timeframe: .init(start: start, end: end),
            evidence: String(lower[evidenceR])
        )
    }

    // MARK: - 6. Relative keywords

    private static func matchRelative(in lower: String, calendar: Calendar, baseDate: Date) -> Match? {
        // Order: longest phrase first so "last week" wins over "last".
        let phrases: [(String, Int)] = [
            ("last week", -7),
            ("next week", +7),
            ("this week", 0),
            ("last month", -30),
            ("next month", +30),
            ("this month", 0),
            ("last year", -365),
            ("next year", +365),
            ("this year", 0),
            ("yesterday", -1),
            ("tomorrow", +1),
            ("today", 0)
        ]
        for (phrase, offset) in phrases {
            if let r = lower.range(of: phrase) {
                let evidence = String(lower[r])
                return Match(
                    timeframe: relativeTimeframe(
                        phrase: phrase,
                        offset: offset,
                        calendar: calendar,
                        baseDate: baseDate
                    ),
                    evidence: evidence
                )
            }
        }
        return nil
    }

    /// Expands a phrase into a (start, end) span. Day phrases span one day;
    /// week phrases span 7 days; month / year phrases span the calendar unit.
    private static func relativeTimeframe(
        phrase: String,
        offset: Int,
        calendar: Calendar,
        baseDate: Date
    ) -> UserIntent.Timeframe {
        let shifted = calendar.date(byAdding: .day, value: offset, to: baseDate) ?? baseDate
        switch phrase {
        case "yesterday", "today", "tomorrow":
            let dayStart = calendar.startOfDay(for: shifted)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? shifted
            return .init(start: dayStart, end: dayEnd.addingTimeInterval(-1))
        case "last week", "next week", "this week":
            // Start = Monday of the week containing `shifted`. End = following Sunday 23:59:59.
            let weekday = calendar.component(.weekday, from: shifted)
            let daysFromMonday = (weekday + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: calendar.startOfDay(for: shifted)) ?? shifted
            let sundayEnd = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
            return .init(start: monday, end: sundayEnd.addingTimeInterval(-1))
        case "last month", "next month", "this month":
            let comps = calendar.dateComponents([.year, .month], from: shifted)
            guard let monthStart = calendar.date(from: comps),
                  let monthEnd = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart)
            else { return .init(start: nil, end: nil) }
            return .init(start: monthStart, end: monthEnd)
        case "last year", "next year", "this year":
            let year = calendar.component(.year, from: shifted)
            var comps = DateComponents()
            comps.year = year; comps.month = 1; comps.day = 1
            guard let yearStart = calendar.date(from: comps),
                  let yearEnd = calendar.date(byAdding: DateComponents(year: 1, second: -1), to: yearStart)
            else { return .init(start: nil, end: nil) }
            return .init(start: yearStart, end: yearEnd)
        default:
            return .init(start: shifted, end: shifted)
        }
    }

    // MARK: - 7. Single absolute date

    /// "2024-04-08", "8 April 2024", "April 8 2024" → a 1-day span.
    private static func matchSingleAbsolute(in text: String, calendar: Calendar) -> Match? {
        // Try ISO first.
        let isoRx = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#)
        if let rx = isoRx,
           let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let evidenceR = Range(m.range, in: text),
           let date = parseIsoDate(String(text[evidenceR]), calendar: calendar),
           let end = endOfDay(date, calendar: calendar) {
            return Match(
                timeframe: .init(start: date, end: end),
                evidence: String(text[evidenceR])
            )
        }
        // Then named month.
        for rx in [dayMonYearRx, monDayYearRx].compactMap({ $0 }) {
            if let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let evidenceR = Range(m.range, in: text),
               let date = parseAbsoluteDate(String(text[evidenceR]), calendar: calendar),
               let end = endOfDay(date, calendar: calendar) {
                return Match(
                    timeframe: .init(start: date, end: end),
                    evidence: String(text[evidenceR])
                )
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func makeCalendar(timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2 // Monday — chatmind convention; tweak per locale if needed.
        return cal
    }

    private static func parseIsoDate(_ s: String, calendar: Calendar) -> Date? {
        // Strict YYYY-MM-DD parser anchored to the calendar's TZ at start-of-day.
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return calendar.date(from: comps)
    }

    private static func parseAbsoluteDate(_ s: String, calendar: Calendar) -> Date? {
        // Handles "8 April 2024", "Apr 8 2024", "April 8", "8 Apr".
        let lower = s.lowercased()
        // Day-month-year
        let dmyRx = try? NSRegularExpression(
            pattern: #"(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*(?:[,\s]+(\d{4}))?"#,
            options: [.caseInsensitive]
        )
        if let rx = dmyRx,
           let m = rx.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let dR = Range(m.range(at: 1), in: lower),
           let mR = Range(m.range(at: 2), in: lower),
           let day = Int(lower[dR]),
           let month = monthIndex(String(lower[mR])) {
            let year: Int = {
                if let yR = Range(m.range(at: 3), in: lower), let y = Int(lower[yR]) { return y }
                return calendar.component(.year, from: Date())
            }()
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return calendar.date(from: comps)
        }
        // Month-day-year
        let mdyRx = try? NSRegularExpression(
            pattern: #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s+(\d{1,2})(?:[,\s]+(\d{4}))?"#,
            options: [.caseInsensitive]
        )
        if let rx = mdyRx,
           let m = rx.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let mR = Range(m.range(at: 1), in: lower),
           let dR = Range(m.range(at: 2), in: lower),
           let day = Int(lower[dR]),
           let month = monthIndex(String(lower[mR])) {
            let year: Int = {
                if let yR = Range(m.range(at: 3), in: lower), let y = Int(lower[yR]) { return y }
                return calendar.component(.year, from: Date())
            }()
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return calendar.date(from: comps)
        }
        return nil
    }

    private static func monthIndex(_ s: String) -> Int? {
        let key = String(s.lowercased().prefix(3))
        let map: [String: Int] = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        return map[key]
    }

    private static func startOfMonth(year: Int, month: Int, calendar: Calendar) -> Date? {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return calendar.date(from: comps)
    }

    private static func endOfMonth(year: Int, month: Int, calendar: Calendar) -> Date? {
        guard let start = startOfMonth(year: year, month: month, calendar: calendar) else { return nil }
        return calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start)
    }

    private static func endOfDay(_ date: Date?, calendar: Calendar) -> Date? {
        guard let date else { return nil }
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start)
    }
}
