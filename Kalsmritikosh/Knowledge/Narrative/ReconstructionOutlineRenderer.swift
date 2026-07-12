//
//  ReconstructionOutlineRenderer.swift
//  Kalsmritikosh
//
//  A7.1 / A7.3 — render the deterministic reconstruction outline and any
//  alternative histories as a markdown addendum appended beneath a
//  reconstruction's narrative. This is what makes the A7 skeleton VISIBLE to the
//  user: coverage (window, event count, largest silent gap), the competing
//  accounts when evidence conflicts (with the decisive missing evidence that
//  would settle each), and — when no prose narrative was produced — a plain
//  chronological timeline so the "no-LLM reconstruction is still useful"
//  guarantee holds. Pure, no model.
//

import Foundation

public struct ReconstructionOutlineRenderer: Sendable {

    public nonisolated init() {}

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// The coverage + alternatives addendum shown under a narrative. Empty
    /// string when there's nothing to add (no gaps worth noting, no conflicts).
    public func addendum(
        outline: ReconstructionOutline,
        alternatives: [AlternativeHistory]
    ) -> String {
        var md = ""

        if let start = outline.windowStart, let end = outline.windowEnd {
            md += "\n## Coverage\n\n"
            md += "- \(outline.eventCount) event\(outline.eventCount == 1 ? "" : "s") from "
            md += "\(Self.dateFormatter.string(from: start)) to \(Self.dateFormatter.string(from: end)).\n"
            if outline.largestGapDays >= 30 {
                md += "- Largest unrecorded stretch: \(Int(outline.largestGapDays.rounded())) days — the archive shows nothing in that window.\n"
            }
            if !outline.actors.isEmpty {
                md += "- Actors: \(outline.actors.prefix(8).joined(separator: ", ")).\n"
            }
        }

        if !alternatives.isEmpty {
            md += "\n## Alternative accounts\n\n"
            md += "The archive supports more than one account of the following — both are preserved, not reconciled automatically:\n\n"
            for alt in alternatives {
                md += "- **\(alt.subject)**\n"
                for (i, account) in alt.accounts.enumerated() {
                    let lead = alt.leadingIndex == i ? " _(better corroborated)_" : ""
                    md += "    - \(account.claim)\(lead)\n"
                }
                md += "    - _Decisive missing evidence:_ \(alt.decisiveMissingEvidence)\n"
            }
        }

        return md
    }

    /// A7.6 "no-LLM timeline still useful" — a plain chronological rendering of
    /// the outline, used as the deterministic reconstruction when no narrative
    /// prose was produced. Each line is precision-aware and status-labelled.
    public func plainTimeline(outline: ReconstructionOutline) -> String {
        guard !outline.events.isEmpty else { return "" }
        var md = "## Timeline (\(outline.scope))\n\n"
        for e in outline.events {
            let actors = e.actors.isEmpty ? "" : " — \(e.actors.prefix(3).joined(separator: ", "))"
            md += "- **\(e.datePhrase)** \(e.title)\(actors)  ·  _\(e.status.rawValue)_\n"
        }
        return md
    }
}
