//
//  RecorderClock.swift
//  Kalsmritikosh
//
//  ALCOA ALC-11/12 (owner 2026-11-24) — the time a log row is recorded with: the recorder's time zone (an IANA
//  identifier) and where the wall clock came from. Every log row written from schema v216/v217 on carries both.
//

import Foundation

public nonisolated enum RecorderClock {

    /// This Mac's system clock (set by macOS; network time when the person allows it in System Settings).
    public static let systemSource = "system"

    public struct Stamp: Sendable, Equatable {
        public let timeZone: String
        public let clockSource: String
    }

    /// The stamp for a row recorded now.
    public static func stamp() -> Stamp {
        Stamp(timeZone: TimeZone.current.identifier, clockSource: systemSource)
    }
}
