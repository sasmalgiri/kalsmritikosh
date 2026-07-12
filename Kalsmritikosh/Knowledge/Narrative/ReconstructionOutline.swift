//
//  ReconstructionOutline.swift
//  Kalsmritikosh
//
//  A7.1 — the deterministic reconstruction outline built BEFORE any narrative
//  LLM call. It gathers everything a reconstruction is accountable to — scope,
//  time window, the events (each with its evidentiary status, actors, date
//  precision and source), the distinct actors, the contradictions and
//  missing-evidence gaps that touch the story, the causal candidates, and
//  coverage (largest silent gap) — purely from the ledger. No model is
//  consulted. The narrative composer then renders FROM this outline, and the
//  outline itself is shown so the user sees the skeleton the prose is built on.
//

import Foundation

public struct ReconstructionOutline: Sendable, Hashable {

    /// One event as it enters the outline: what, when (with precision), how
    /// well-supported, who was involved, and the source that carries it.
    public struct OutlineEvent: Sendable, Hashable, Identifiable {
        public let id: Event.ID
        public let title: String
        public let date: Date
        public let datePhrase: String        // precision-aware ("In March 2025")
        public let status: EventStatus        // observed / asserted / derived / inferred / …
        public let actors: [String]           // participant names (deduped)
        public let sourceObjectID: KnowledgeObject.ID
    }

    public let scope: String                  // "Project Delta", "everything", …
    public let windowStart: Date?
    public let windowEnd: Date?
    public let events: [OutlineEvent]         // chronological
    public let actors: [String]               // distinct across all events
    public let contradictions: [Contradiction]
    public let gaps: [GapNode]
    public let causalCandidates: [CausalLink]
    /// Largest silent stretch between consecutive events (days) — the biggest
    /// place the reconstruction can't see.
    public let largestGapDays: Double

    public var eventCount: Int { events.count }
}

public struct ReconstructionOutlineBuilder: Sendable {

    public nonisolated init() {}

    /// Build the outline deterministically. `entityNames` maps entity ids to
    /// display names for actor listing (missing ids are skipped). Contradictions
    /// / gaps / causal links are filtered to those that reference the outline's
    /// events (contradictions/causal by event, gaps left as-supplied since they
    /// reference objects). Pure — no DB, no LLM.
    public func build(
        scope: String,
        events: [Event],
        entityNames: [Entity.ID: String] = [:],
        contradictions: [Contradiction] = [],
        gaps: [GapNode] = [],
        causalLinks: [CausalLink] = []
    ) -> ReconstructionOutline {
        let sorted = events.sorted { $0.date < $1.date }
        let outlineEvents = sorted.map { e in
            ReconstructionOutline.OutlineEvent(
                id: e.id,
                title: e.title,
                date: e.date,
                datePhrase: e.datePrecision.renderPhrase(date: e.date),
                status: e.status,
                actors: e.entityIDs.compactMap { entityNames[$0] },
                sourceObjectID: e.sourceObjectID
            )
        }

        // Distinct actors across the story, in first-appearance order.
        var seenActor = Set<String>()
        var actors: [String] = []
        for oe in outlineEvents {
            for a in oe.actors where seenActor.insert(a).inserted { actors.append(a) }
        }

        // Largest silent stretch between consecutive events.
        var largestGap = 0.0
        for pair in zip(sorted, sorted.dropFirst()) {
            largestGap = max(largestGap, pair.1.date.timeIntervalSince(pair.0.date) / 86_400)
        }

        // Keep only causal candidates whose endpoints are both in the story.
        let eventIDs = Set(sorted.map(\.id))
        let relevantCausal = causalLinks.filter {
            eventIDs.contains($0.sourceEventID) && eventIDs.contains($0.targetEventID) && $0.supersededBy == nil
        }

        return ReconstructionOutline(
            scope: scope,
            windowStart: sorted.first?.date,
            windowEnd: sorted.last?.date,
            events: outlineEvents,
            actors: actors,
            contradictions: contradictions,
            gaps: gaps,
            causalCandidates: relevantCausal,
            largestGapDays: largestGap
        )
    }
}
