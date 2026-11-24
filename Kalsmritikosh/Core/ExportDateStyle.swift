//
//  ExportDateStyle.swift
//  Kalsmritikosh
//
//  ALCOA ALC-19 (DATA-29, owner 2026-11-24) — consistent. ONE date style for every export and the chronology:
//  • a date with a time is ISO 8601 with the zone stated — "2026-08-03T14:05+05:30 (Asia/Kolkata)";
//  • a day-level date is written "3 Aug 2026" (never the device's locale style, never a time invented for it);
//  • an amount always carries its ISO currency code — "INR 50,000.00" (a missing or ambiguous currency is said so).
//  Machine-readable files (JSON, CSV, the structured exchange) keep their ISO 8601 fields; this is the human wording.
//

import Foundation

public nonisolated enum ExportDateStyle {

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// A day-level date: "3 Aug 2026" in `zone` (the reader's by default).
    public static func day(_ date: Date, zone: TimeZone = .current) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        let m = months[max(0, min(11, (c.month ?? 1) - 1))]
        return "\(c.day ?? 1) \(m) \(c.year ?? 0)"
    }

    /// A day-level date or "—" when there is none.
    public static func day(_ date: Date?, zone: TimeZone = .current) -> String {
        date.map { day($0, zone: zone) } ?? "—"
    }

    /// "+05:30", "-04:00" or "Z" for `zone` at `date`.
    public static func offset(_ date: Date, zone: TimeZone) -> String {
        let off = zone.secondsFromGMT(for: date)
        if off == 0 { return "Z" }
        return (off < 0 ? "-" : "+") + String(format: "%02d:%02d", abs(off) / 3600, abs(off) % 3600 / 60)
    }

    /// A date with a time: ISO 8601 with the zone stated — "2026-08-03T14:05+05:30 (Asia/Kolkata)";
    /// `seconds` adds the seconds (an instant).
    public static func stamp(_ date: Date, zone: TimeZone = .current, seconds: Bool = false) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let d = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let t = seconds ? String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
                        : String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return "\(d)T\(t)\(offset(date, zone: zone)) (\(zone.identifier))"
    }

    /// A date with a time or "—" when there is none.
    public static func stamp(_ date: Date?, zone: TimeZone = .current) -> String {
        date.map { stamp($0, zone: zone) } ?? "—"
    }

    /// The sentence an export states once, so a reader knows how its dates are written.
    public static func zoneStatement(zone: TimeZone = .current, at date: Date = Date()) -> String {
        let off = offset(date, zone: zone)
        return "Dates and times are ISO 8601 with the zone stated (this export: \(zone.identifier), UTC\(off == "Z" ? "+00:00" : off)); "
            + "a date without a time is written like \(day(date, zone: zone))."
    }

    /// An amount with its ISO currency code: "INR 50,000.00". Empty or ambiguous currency is said so, never guessed.
    public static func money(_ amount: Decimal, currency: String) -> String {
        if currency.isEmpty { return FAMoney.format(amount, currency: "") + " (currency not stated)" }
        if currency == FAMoney.ambiguousDollar { return "$" + FAMoney.format(amount, currency: "") + " (currency not stated)" }
        return "\(currency) \(FAMoney.format(amount, currency: currency))"
    }

    /// A drop-in for the report builders that used a locale DateFormatter (`df.string(from:)`): the export style.
    public struct Writer: Sendable {
        let time: Bool
        public func string(from date: Date) -> String { time ? ExportDateStyle.stamp(date) : ExportDateStyle.day(date) }
    }
    public static let dayWriter = Writer(time: false)
    public static let stampWriter = Writer(time: true)
}
