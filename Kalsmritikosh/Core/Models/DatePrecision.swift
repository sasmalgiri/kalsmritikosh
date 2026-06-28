//
//  DatePrecision.swift
//  Kalsmritikosh
//
//  HISTORY Phase G.1 — temporal precision tier on Events.
//
//  Modeled on Wikidata's integer precision scale + EDTF Level 1.
//  Each precision level is the COARSEST true granularity the source
//  can support. An email Date: header is .instant (or .minute if
//  no seconds). A forensic-PDF entry that says "March 11, 2025" is
//  .day. A body sentence saying "in Q1 2025" is .quarter.
//
//  The composer reads this enum at render time and produces precision-
//  appropriate prose: "in March 2025" for .month, "during 2025" for
//  .year, "On Mar 14, 2025 at 09:00 UTC" for .instant.
//
//  Critical anti-pattern from the design research: NEVER pad a low-
//  precision date to midnight UTC and forget the precision flag. That
//  produces false "08:00 AM" claims in narrative prose and corrupts
//  the ledger permanently. Precision must travel with the timestamp.
//

import Foundation

/// Coarsest-true granularity of an Event's `date` field.
///
/// Integer raw values mirror Wikidata so future ontology imports
/// drop in. Drop in cleanly. Higher value = finer precision.
public nonisolated enum DatePrecision: Int, Codable, Sendable, Hashable, CaseIterable {
    case unknown = 0
    case decade = 1
    case year = 2
    case quarter = 3
    case month = 4
    case day = 5
    case minute = 6
    case instant = 7

    /// Display label for UI badges ("month-precision", "instant").
    public var displayName: String {
        switch self {
        case .unknown:  return "unknown"
        case .decade:   return "decade"
        case .year:     return "year"
        case .quarter:  return "quarter"
        case .month:    return "month"
        case .day:      return "day"
        case .minute:   return "minute"
        case .instant:  return "instant"
        }
    }

    /// Whether this event should sort to the END of a timeline view
    /// when ordering by date — unknown-precision events have no real
    /// claim to a position, so they're shown after everything else.
    public var deprioritizeInTimeline: Bool {
        self == .unknown
    }

    /// Render the `date` (and optional `endDate`) as natural-language
    /// prose, respecting precision. The composer calls this when
    /// filling the WHEN slot or starting a sentence.
    ///
    /// Examples:
    ///   .instant → "On March 14, 2025 at 09:12 UTC"
    ///   .minute  → "On March 14, 2025 at 09:12"
    ///   .day     → "On March 14, 2025"
    ///   .month   → "In March 2025"
    ///   .quarter → "In Q1 2025"
    ///   .year    → "During 2025"
    ///   .decade  → "In the 2020s"
    ///   .unknown → "At an unknown time"
    public func renderPhrase(date: Date, endDate: Date? = nil, calendar: Calendar = .current) -> String {
        switch self {
        case .unknown:
            return "at an unknown time"
        case .decade:
            let year = calendar.component(.year, from: date)
            let decadeStart = (year / 10) * 10
            return "in the \(decadeStart)s"
        case .year:
            let year = calendar.component(.year, from: date)
            return "during \(year)"
        case .quarter:
            let comps = calendar.dateComponents([.year, .month], from: date)
            let quarter = ((comps.month ?? 1) - 1) / 3 + 1
            return "in Q\(quarter) \(comps.year ?? 0)"
        case .month:
            let f = DateFormatter()
            f.dateFormat = "MMMM yyyy"
            return "in \(f.string(from: date))"
        case .day:
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return "on \(f.string(from: date))"
        case .minute:
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy 'at' HH:mm"
            return "on \(f.string(from: date))"
        case .instant:
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy 'at' HH:mm 'UTC'"
            f.timeZone = TimeZone(identifier: "UTC")
            return "on \(f.string(from: date))"
        }
    }

    /// Infer precision from a `dateConfidence` value when the
    /// extractor didn't set precision explicitly. Conservative —
    /// only promotes to .instant when confidence is very high
    /// (header-derived emails); otherwise stays at .day to avoid
    /// the midnight-padding trap.
    public static func inferFromConfidence(_ confidence: Double) -> DatePrecision {
        if confidence >= 0.95 { return .instant }
        if confidence >= 0.85 { return .day }
        if confidence >= 0.70 { return .day }
        if confidence >= 0.40 { return .month }
        return .unknown
    }
}
