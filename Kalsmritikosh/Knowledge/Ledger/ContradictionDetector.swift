//
//  ContradictionDetector.swift
//  Kalsmritikosh
//
//  System 3 — rule-based conflict detection. Pure, stateless, NO LLM and
//  NO database access: a function over already-extracted Events that
//  returns Contradictions for a repository to persist.
//
//  Current rule — SAME-EVENT TEMPORAL CONFLICT:
//    When two INDEPENDENT sources describe what looks like the same event
//    (same kind + same normalized title) but assign materially different
//    dates, that's a contradiction in the archive. We only compare dates
//    that are day-precision or finer (a month-precision "in March" can't
//    contradict "March 14"), and only across different source documents
//    (one document isn't in conflict with itself).
//
//  Design guards:
//    * Coarse-precision events (month / quarter / year / unknown) are
//      excluded — comparing them by day would manufacture false conflicts.
//    * A conflict needs TWO distinct source objects.
//    * Output is capped so one pathological title can't flood the ledger.
//

import Foundation

public nonisolated struct ContradictionDetector: Sendable {

    public nonisolated init() {}

    /// Flag events that appear to be the same occurrence but are dated
    /// differently by different sources.
    ///
    /// - Parameters:
    ///   - events: candidate events (already fetched from the ledger).
    ///   - toleranceDays: how far two dates may differ before it counts
    ///     as a conflict. Default 2 days absorbs timezone / rounding noise.
    ///   - limit: max contradictions returned.
    public func detectEventDateConflicts(
        _ events: [Event],
        toleranceDays: Double = 2,
        limit: Int = 50
    ) -> [Contradiction] {
        // Only day-precision-or-finer events can meaningfully conflict on date.
        let dated = events.filter { $0.datePrecision.rawValue >= DatePrecision.day.rawValue }

        // Group by (kind + normalized title) — our proxy for "same event".
        var groups: [String: [Event]] = [:]
        for e in dated {
            let key = Self.normalizedTitle(e.title)
            guard key.count >= 4 else { continue }   // skip junk / too-generic titles
            groups["\(e.kind.rawValue)|\(key)", default: []].append(e)
        }

        let tolerance = toleranceDays * 86_400
        var out: [Contradiction] = []

        for (_, group) in groups {
            guard group.count >= 2 else { continue }
            let sorted = group.sorted { $0.date < $1.date }
            guard let earliest = sorted.first, let latest = sorted.last else { continue }

            // Two distinct sources, dates far enough apart.
            guard earliest.sourceObjectID != latest.sourceObjectID else { continue }
            let gap = latest.date.timeIntervalSince(earliest.date)
            guard gap > tolerance else { continue }

            let gapDays = gap / 86_400
            out.append(Contradiction(
                kind: .date,
                description: "Conflicting dates for \"\(latest.title)\"",
                claimA: "\(earliest.title) \(earliest.datePrecision.renderPhrase(date: earliest.date))",
                claimB: "\(latest.title) \(latest.datePrecision.renderPhrase(date: latest.date))",
                evidenceA: earliest.sourceObjectID,
                evidenceB: latest.sourceObjectID,
                severity: Self.severity(
                    gapDays: gapDays,
                    confidenceA: earliest.dateConfidence,
                    confidenceB: latest.dateConfidence
                )
            ))
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Helpers

    /// A bigger disagreement between two confidently-dated sources is more
    /// severe than a few days' slip between shaky ones.
    private static func severity(gapDays: Double, confidenceA: Double, confidenceB: Double) -> Contradiction.Severity {
        let bothConfident = min(confidenceA, confidenceB) >= 0.7
        if gapDays > 30 && bothConfident { return .high }
        if gapDays > 7 { return .medium }
        return .low
    }

    /// Lowercase, trim, collapse internal whitespace — so "Kickoff  Call"
    /// and "kickoff call" group together.
    static func normalizedTitle(_ title: String) -> String {
        let lowered = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = lowered.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}
