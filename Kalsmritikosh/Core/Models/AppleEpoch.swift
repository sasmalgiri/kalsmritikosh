//
//  AppleEpoch.swift
//  Kalsmritikosh
//
//  HOST-7 — Apple's Core Data / CoreDuet reference date: seconds since
//  2001-01-01 00:00:00 UTC, not 1970. Shared because it is not one artifact's
//  quirk: knowledgeC.db, chat.db, Photos.sqlite, CallHistory.storedata,
//  Safari's History.db and most Core Data stores all date this way.
//
//  Read as a Unix timestamp instead, 2026 becomes 1994 — a 31-year error that
//  still looks like a plausible date, which is exactly why it needs one
//  well-named conversion rather than an inline `+ 978307200` per call site.
//

import Foundation

public enum AppleEpoch {

    /// Seconds between the Unix epoch (1970) and Apple's (2001).
    /// `kCFAbsoluteTimeIntervalSince1970`.
    public nonisolated static let offset: Double = 978_307_200

    /// Sanity window for a device artifact: 2001 (the epoch itself) to 2100.
    /// Values outside it are not dates — usually a column that happens to hold a
    /// number, or a Unix timestamp already converted by mistake.
    private nonisolated static let earliest: Double = 0
    private nonisolated static let latest: Double = 3_155_760_000   // ~2100-01-01

    /// Apple-epoch seconds → Date, or nil when the value cannot be a date.
    /// Zero returns nil: in these schemas it means "never", and converting it
    /// would date the evidence to 2001-01-01.
    public nonisolated static func date(fromAppleSeconds seconds: Double?) -> Date? {
        guard let seconds, seconds > earliest, seconds < latest else { return nil }
        return Date(timeIntervalSince1970: seconds + offset)
    }

    /// Apple-epoch NANOseconds → Date. `chat.db` switched to nanoseconds in
    /// macOS 10.13 / iOS 11 while keeping the same column, so a message store can
    /// hold either. The magnitude tells them apart: a nanosecond value for any
    /// real date is astronomically larger than a seconds value.
    public nonisolated static func date(fromAppleSecondsOrNanoseconds value: Double?) -> Date? {
        guard let value, value > earliest else { return nil }
        // 1e11 Apple-seconds would be the year 5169; anything above it is
        // nanoseconds. Below, it is seconds.
        return value > 1e11
            ? date(fromAppleSeconds: value / 1_000_000_000)
            : date(fromAppleSeconds: value)
    }

    /// Formats a device-local UTC offset the way an artifact records it
    /// (`ZSECONDSFROMGMT`), e.g. 19800 → "+05:30". This is forensically load
    /// bearing: it states the time zone the DEVICE was in, which the timestamps
    /// themselves do not.
    public nonisolated static func utcOffsetLabel(secondsFromGMT: Int?) -> String? {
        guard let secondsFromGMT, abs(secondsFromGMT) <= 14 * 3600 else { return nil }
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let total = abs(secondsFromGMT)
        return String(format: "%@%02d:%02d", sign, total / 3600, (total % 3600) / 60)
    }

    /// Human duration for a start/end pair, e.g. "5m 7s". Nil when the pair does
    /// not describe a span.
    public nonisolated static func durationLabel(from start: Date?, to end: Date?) -> String? {
        guard let start, let end, end > start else { return nil }
        let total = Int(end.timeIntervalSince(start).rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
