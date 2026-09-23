//
//  ChatTimestampResolver.swift
//  Kalsmritikosh
//
//  DISC-6 — resolves the timestamps of a text chat export, treating DATE ORDER as
//  a property of the whole file rather than of a single line.
//
//  WhatsApp writes `3/4/25` and gives no hint whether that is 3 April or 4 March;
//  the order follows the exporting phone's locale, which the file does not record.
//  Guessing moves a message by up to eleven months, and it does so invisibly —
//  the date still looks like a date. So the order is decided once, from all the
//  stamps together, by two rules in order of strength:
//
//    1. DECISIVE — any component above 12 can only be a day. One such stamp
//       settles the entire file.
//    2. CHRONOLOGY — a chat export is written in order. When exactly one of the
//       two readings yields a non-decreasing sequence, that reading is correct.
//       This settles most files that rule 1 cannot.
//
//  When neither settles it, no dates are produced and the ambiguity is reported.
//  The messages are still evidence and still in order, because the mapper numbers
//  them by sequence — but nothing here will state a time it cannot support.
//

import Foundation

enum ChatTimestampResolver {

    struct Resolution {
        /// One entry per input stamp, positionally. `nil` where no date could be
        /// supported — never a guess.
        let dates: [Date?]
        /// Which reading was used, for the record.
        let order: Order
        let warning: ParserWarning?
    }

    enum Order: String {
        case dayFirst = "day/month"
        case monthFirst = "month/day"
        /// Unambiguous formats (ISO) and files where no date could be resolved.
        case notApplicable = "unambiguous"
    }

    /// Resolves every stamp in one pass over the file.
    static func resolve(_ stamps: [String], shape: TextChatExportMapper.Shape) -> Resolution {
        // Signal and Slack write ISO-ordered dates (yyyy-MM-dd), so there is
        // nothing to disambiguate.
        if shape != .whatsapp {
            return Resolution(dates: stamps.map { parseISOStyle($0) },
                              order: .notApplicable, warning: nil)
        }

        let parts = stamps.map { components(of: $0) }

        // Rule 1: a component above 12 can only be a day.
        var decisive: Order?
        for part in parts.compactMap({ $0 }) {
            if part.first > 12 { decisive = .dayFirst; break }
            if part.second > 12 { decisive = .monthFirst; break }
        }

        // Rule 2: the reading that stays chronological.
        if decisive == nil {
            let dayFirst = parts.map { $0.flatMap { date($0, order: .dayFirst) } }
            let monthFirst = parts.map { $0.flatMap { date($0, order: .monthFirst) } }
            let dayOK = isNonDecreasing(dayFirst)
            let monthOK = isNonDecreasing(monthFirst)
            if dayOK != monthOK { decisive = dayOK ? .dayFirst : .monthFirst }
        }

        guard let order = decisive else {
            // Every stamp fits both readings — typically a short chat inside the
            // first twelve days of a month. Stating a date here would be a coin
            // flip presented as a fact.
            return Resolution(
                dates: stamps.map { _ in nil },
                order: .notApplicable,
                warning: ParserWarning(
                    severity: .warning, code: "chatexport.ambiguous_date_order",
                    message: "Every date in this export fits both day/month and month/day "
                           + "(no component above 12, and both readings stay chronological). "
                           + "Messages are recorded WITHOUT timestamps rather than assuming an "
                           + "order; their sequence is preserved."))
        }

        let resolved = parts.map { $0.flatMap { date($0, order: order) } }
        let unreadable = zip(stamps, resolved).filter { $1 == nil && !$0.isEmpty }.count
        let warning: ParserWarning? = unreadable > 0
            ? ParserWarning(severity: .warning, code: "chatexport.unreadable_dates",
                            message: "\(unreadable) timestamp(s) did not parse as \(order.rawValue) "
                                   + "and those messages are recorded without a date.")
            : nil
        return Resolution(dates: resolved, order: order, warning: warning)
    }

    // MARK: - Stamp decomposition

    private struct Parts {
        let first: Int, second: Int, year: Int
        let hour: Int, minute: Int, second2: Int
    }

    /// `3/14/25, 9:12:34 AM` → its numeric parts, with the first two left
    /// deliberately unordered because that is the question being resolved.
    private static func components(of stamp: String) -> Parts? {
        let halves = stamp.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let datePart = halves.first else { return nil }
        let timePart = halves.count > 1 ? halves[1] : ""

        let dateNumbers = datePart.split(whereSeparator: { "/.-".contains($0) })
            .compactMap { Int($0) }
        guard dateNumbers.count == 3 else { return nil }

        var year = dateNumbers[2]
        // Two-digit years: a chat export is not from the 1900s.
        if year < 100 { year += 2000 }

        let isPM = timePart.lowercased().contains("pm")
        let isAM = timePart.lowercased().contains("am")
        let timeNumbers = timePart.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        var hour = timeNumbers.count > 0 ? timeNumbers[0] : 0
        let minute = timeNumbers.count > 1 ? timeNumbers[1] : 0
        let seconds = timeNumbers.count > 2 ? timeNumbers[2] : 0
        if isPM, hour < 12 { hour += 12 }
        if isAM, hour == 12 { hour = 0 }

        return Parts(first: dateNumbers[0], second: dateNumbers[1], year: year,
                     hour: hour, minute: minute, second2: seconds)
    }

    private static func date(_ parts: Parts, order: Order) -> Date? {
        let day = order == .dayFirst ? parts.first : parts.second
        let month = order == .dayFirst ? parts.second : parts.first
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = parts.year
        components.month = month
        components.day = day
        components.hour = parts.hour
        components.minute = parts.minute
        components.second = parts.second2
        // UTC, because the export states no zone. Stating the zone we assumed is
        // what keeps this honest rather than silently local.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components)
    }

    private static func isNonDecreasing(_ dates: [Date?]) -> Bool {
        let known = dates.compactMap { $0 }
        guard known.count > 1 else { return true }
        // Every real date must parse for a reading to be considered ordered; a
        // reading that drops dates is not evidence of chronology.
        guard known.count == dates.count else { return false }
        return zip(known, known.dropFirst()).allSatisfy { $0 <= $1 }
    }

    /// Signal / Slack: `2026-03-14 09:12:34` or `2026-03-14, 09:12 AM`. Written
    /// self-contained rather than reusing the WhatsApp decomposer, which assumes a
    /// comma between date and time — Signal's format has none, so sharing it
    /// silently produced midnight for every message.
    private static func parseISOStyle(_ stamp: String) -> Date? {
        // Split date from time on comma or whitespace, whichever the app used.
        let tokens = stamp.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        guard let datePart = tokens.first else { return nil }
        let dateNumbers = datePart.split(whereSeparator: { "/.-".contains($0) })
            .compactMap { Int($0) }
        guard dateNumbers.count == 3 else { return nil }

        let rest = tokens.dropFirst().joined(separator: " ").lowercased()
        let isPM = rest.contains("pm"), isAM = rest.contains("am")
        let timeNumbers = rest.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        var hour = timeNumbers.count > 0 ? timeNumbers[0] : 0
        if isPM, hour < 12 { hour += 12 }
        if isAM, hour == 12 { hour = 0 }

        var components = DateComponents()
        components.year = dateNumbers[0]
        components.month = dateNumbers[1]
        components.day = dateNumbers[2]
        components.hour = hour
        components.minute = timeNumbers.count > 1 ? timeNumbers[1] : 0
        components.second = timeNumbers.count > 2 ? timeNumbers[2] : 0
        guard (1...12).contains(dateNumbers[1]), (1...31).contains(dateNumbers[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components)
    }
}
