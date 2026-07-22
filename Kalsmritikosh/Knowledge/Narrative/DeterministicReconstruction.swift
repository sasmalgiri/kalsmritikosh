//
//  DeterministicReconstruction.swift
//  Kalsmritikosh
//
//  REC-003 — a useful reconstruction with ZERO model calls. Given the dated events for a
//  scope, produce a chronological, cited outline that respects each date's precision and
//  never invents ordering it cannot support. This is the offline fallback the locked
//  contract requires ("a no-model mode still provides useful timelines") and the
//  deterministic outline REC-001 constrains narrative generation with.
//
//  Rules honored:
//  • Order strictly by date; events sharing a date keep a stable, deterministic order.
//  • Show each date at its real precision (year-only stays year-only — no false "day").
//  • Undated / unknown-precision events go in a separate, clearly-labelled section, never
//    forced into a fake position on the line.
//  • Every line carries its source (KnowledgeObject id short) — claim–evidence contract.
//  • No causal language is added (adjacency is not causation — CLM-002).
//

import Foundation

public struct DeterministicReconstruction: Sendable {
    public nonisolated init() {}

    public struct Entry: Sendable, Hashable {
        public let dateLabel: String
        public let title: String
        public let sourceObjectID: KnowledgeObject.ID
        public let isDated: Bool
    }

    public struct Outline: Sendable, Hashable {
        public let dated: [Entry]
        public let undated: [Entry]
        public nonisolated var isEmpty: Bool { dated.isEmpty && undated.isEmpty }
    }

    /// Build the ordered outline from events. Deterministic and pure.
    public nonisolated func outline(from events: [Event]) -> Outline {
        let dated = events.filter { $0.datePrecision != .unknown && $0.dateConfidence >= 0.34 }
        let undated = events.filter { !($0.datePrecision != .unknown && $0.dateConfidence >= 0.34) }

        // Stable chronological sort: by date, then by title, then by id, so equal dates
        // never reorder run-to-run.
        let sortedDated = dated.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id.uuidString < $1.id.uuidString
        }
        let sortedUndated = undated.sorted {
            $0.title != $1.title ? $0.title < $1.title : $0.id.uuidString < $1.id.uuidString
        }

        return Outline(
            dated: sortedDated.map { Entry(dateLabel: Self.format($0.date, precision: $0.datePrecision),
                                           title: Self.cleanTitle($0.title),
                                           sourceObjectID: $0.sourceObjectID, isDated: true) },
            undated: sortedUndated.map { Entry(dateLabel: "date unknown",
                                               title: Self.cleanTitle($0.title),
                                               sourceObjectID: $0.sourceObjectID, isDated: false) }
        )
    }

    /// Render the outline as a plain-text, cited timeline. No model, no causal wording.
    public nonisolated func render(from events: [Event]) -> String {
        let o = outline(from: events)
        guard !o.isEmpty else { return "No dated events are available to reconstruct a timeline." }
        var lines: [String] = []
        for e in o.dated {
            lines.append("• \(e.dateLabel) — \(e.title)  [src \(e.sourceObjectID.uuidString.prefix(8))]")
        }
        if !o.undated.isEmpty {
            lines.append("")
            lines.append("Undated (position not determinable from evidence):")
            for e in o.undated {
                lines.append("• \(e.title)  [src \(e.sourceObjectID.uuidString.prefix(8))]")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    nonisolated static func format(_ date: Date, precision: DatePrecision) -> String {
        let cal = Calendar(identifier: .gregorian)
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        switch precision {
        case .unknown:  return "date unknown"
        case .decade:
            let y = cal.component(.year, from: date); return "\(y / 10 * 10)s"
        case .year:     f.dateFormat = "yyyy"
        case .quarter:
            let m = cal.component(.month, from: date); let y = cal.component(.year, from: date)
            return "Q\((m - 1) / 3 + 1) \(y)"
        case .month:    f.dateFormat = "MMM yyyy"
        case .day:      f.dateFormat = "d MMM yyyy"
        case .minute:   f.dateFormat = "d MMM yyyy HH:mm"
        case .instant:  f.dateFormat = "d MMM yyyy HH:mm:ss"
        }
        return f.string(from: date)
    }

    nonisolated static func cleanTitle(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(untitled event)" : t
    }
}
