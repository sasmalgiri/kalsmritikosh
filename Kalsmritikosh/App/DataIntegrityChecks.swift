//
//  DataIntegrityChecks.swift
//  Kalsmritikosh
//
//  ALCOA ALC-12 / ALC-16 (owner 2026-11-24) — the data-integrity lines of the data health check: the clock (jumps
//  against the monotonic clock this session). Each check says what it found; a check that could not run says so and
//  counts as an issue (never a silent pass).
//

import Foundation
import os

public nonisolated enum DataIntegrityChecks {

    public struct Line: Sendable, Equatable {
        public let title: String
        public let text: String
        /// True when the line is a problem (or a check that could not run).
        public let issue: Bool
    }

    /// Every integrity line for the open ledger.
    @MainActor
    public static func run(_ state: AppState) async -> [Line] {
        var out: [Line] = []
        if let clock = state.clockMonitor {
            let line = await clock.healthLine()
            out.append(Line(title: "Clock", text: line, issue: await !clock.jumps.isEmpty))
        } else {
            out.append(Line(title: "Clock", text: "Clock: not checked — the clock check did not start with this ledger.", issue: true))
        }
        return out
    }

    /// The report section.
    public static func section(_ lines: [Line]) -> String {
        var md = "## Data integrity (ALCOA++ checks)\n\n"
        for l in lines { md += "- **\(l.title)** — \(l.text)\(l.issue ? " ⚠︎" : "")\n" }
        return md + "\n"
    }
}
