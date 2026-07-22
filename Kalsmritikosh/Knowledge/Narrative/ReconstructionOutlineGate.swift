//
//  ReconstructionOutlineGate.swift
//  Kalsmritikosh
//
//  REC-001 — the deterministic outline is built BEFORE any narrative generation, and the
//  narrative is CONSTRAINED by it: a generated reconstruction may not assert a date/year or
//  a period the evidence outline does not contain. This turns the outline (REC-003) into a
//  guardrail — the model narrates the known events, it does not invent new dated facts.
//
//  Deterministic, offline. The gate does not generate; it validates a candidate narrative
//  against the outline and reports ungrounded temporal assertions so the caller can reject
//  or repair the narrative before it ships.
//

import Foundation

public struct ReconstructionOutlineGate: Sendable {
    public nonisolated init() {}

    public struct Verdict: Sendable, Hashable {
        public let outlineDateTokens: [String]
        public let ungroundedDates: [String]   // years the narrative asserts that the outline lacks
        public var isConstrained: Bool { ungroundedDates.isEmpty }
    }

    private let recon = DeterministicReconstruction()

    /// Validate a candidate narrative against the deterministic outline built from `events`.
    public nonisolated func check(narrative: String, events: [Event]) -> Verdict {
        let outline = recon.outline(from: events)
        // Ground truth: the set of YEARS present in the outline's dated entries.
        let outlineYears = Set(outline.dated.flatMap { Self.years(in: $0.dateLabel) })
        let narrativeYears = Set(Self.years(in: narrative))
        let ungrounded = narrativeYears.subtracting(outlineYears).sorted()
        return Verdict(outlineDateTokens: outline.dated.map(\.dateLabel),
                       ungroundedDates: ungrounded)
    }

    /// The outline that MUST be produced before generation (REC-003), for the caller to
    /// feed the model as the constraint.
    public nonisolated func outline(for events: [Event]) -> DeterministicReconstruction.Outline {
        recon.outline(from: events)
    }

    /// Extract 4-digit years (19xx/20xx) from text.
    nonisolated static func years(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
