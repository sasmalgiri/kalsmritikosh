//
//  ContradictionFinder.swift
//  Kalsmritikosh
//
//  Phase J.2 — A15 from Vol 17 (Core Historical Intelligence
//  Algorithms): the real finder behind the evidence gate's
//  "surface-conflict" branch. NarrativeClaimVerifier already catches
//  the per-chapter "same WHO + same kind, different WHEN" case;
//  this finder runs over the brain's full retrieval set + the
//  causal-link graph touching it, picking up:
//
//   1. Date conflicts that cross chapter boundaries.
//   2. Cycles in the causal graph (A caused B AND B caused A).
//   3. Opposing causal claims (X CAUSED Y AND X PREVENTED Y) when
//      both are non-superseded.
//
//  Output is a `[VerifiedAnswer.Contradiction]` so MasterBrain can
//  merge straight into the existing field — no new schema, no new
//  UI plumbing. The Quality Strip's conflict disclosure renders
//  these alongside the per-chapter ones.
//
//  Quality-or-nothing: every contradiction names the specific events
//  and the conflict shape. No "you have N conflicts somewhere" —
//  the user can always click through to the source.
//

import Foundation

public struct ContradictionFinder: Sendable {
    public init() {}

    public func find(
        events: [Event],
        links: [CausalLink]
    ) -> [VerifiedAnswer.Contradiction] {
        var out: [VerifiedAnswer.Contradiction] = []
        out.append(contentsOf: detectDateConflicts(events: events))
        out.append(contentsOf: detectCausalCycles(links: links, events: events))
        out.append(contentsOf: detectOpposingCausalClaims(links: links, events: events))
        // De-dupe by (description + claimA + claimB) so the same
        // conflict doesn't show up twice if multiple chapter spans
        // touch it.
        var seen: Set<String> = []
        return out.filter { c in
            let key = "\(c.description)|\(c.claimA)|\(c.claimB)"
            return seen.insert(key).inserted
        }
    }

    // MARK: - 1. Cross-chapter date conflicts

    /// Same kind + same primary entity, but dates > 1 day apart.
    /// Mirrors NarrativeClaimVerifier.detectContradictions but at
    /// retrieval-set scope so conflicts that span chapter boundaries
    /// still surface.
    private func detectDateConflicts(events: [Event]) -> [VerifiedAnswer.Contradiction] {
        guard events.count >= 2 else { return [] }
        var groups: [String: [Event]] = [:]
        for event in events {
            let key = "\(event.kind.rawValue)|\(event.entityIDs.first?.uuidString ?? "_")"
            groups[key, default: []].append(event)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var out: [VerifiedAnswer.Contradiction] = []
        for (_, group) in groups where group.count >= 2 {
            let sorted = group.sorted { $0.date < $1.date }
            guard let first = sorted.first, let last = sorted.last,
                  abs(last.date.timeIntervalSince(first.date)) > 86_400 else {
                continue
            }
            out.append(
                VerifiedAnswer.Contradiction(
                    description: "Multiple \(first.kind.rawValue) events for the same subject",
                    claimA: "\(first.title) on \(formatter.string(from: first.date))",
                    claimB: "\(last.title) on \(formatter.string(from: last.date))"
                )
            )
        }
        return out
    }

    // MARK: - 2. Cycles in the causal graph

    /// Detect A → B + B → A (both non-superseded). Cycles indicate
    /// the discoverer found bi-directional evidence which is almost
    /// always a real disagreement, not a real causal loop.
    private func detectCausalCycles(
        links: [CausalLink],
        events: [Event]
    ) -> [VerifiedAnswer.Contradiction] {
        guard links.count >= 2 else { return [] }
        let eventByID: [Event.ID: Event] = Dictionary(
            uniqueKeysWithValues: events.map { ($0.id, $0) }
        )
        // Build a quick lookup keyed on the ORDERED pair so we can
        // find the reverse with a single dict probe.
        var byPair: [String: CausalLink] = [:]
        for link in links {
            let key = "\(link.sourceEventID.uuidString)|\(link.targetEventID.uuidString)"
            byPair[key] = link
        }
        var out: [VerifiedAnswer.Contradiction] = []
        var reportedPairs: Set<String> = []
        for link in links where link.relation.isCausal {
            let reverseKey = "\(link.targetEventID.uuidString)|\(link.sourceEventID.uuidString)"
            guard let reverse = byPair[reverseKey], reverse.relation.isCausal else { continue }
            // Canonicalize the pair so A↔B is reported once.
            let canonical = link.sourceEventID.uuidString < link.targetEventID.uuidString
                ? "\(link.sourceEventID.uuidString)|\(link.targetEventID.uuidString)"
                : reverseKey
            guard reportedPairs.insert(canonical).inserted else { continue }
            let aTitle = eventByID[link.sourceEventID]?.title ?? "Event \(link.sourceEventID.uuidString.prefix(8))"
            let bTitle = eventByID[link.targetEventID]?.title ?? "Event \(link.targetEventID.uuidString.prefix(8))"
            out.append(
                VerifiedAnswer.Contradiction(
                    description: "Causal cycle between two events",
                    claimA: "\(aTitle) \(link.relation.renderVerb) \(bTitle)",
                    claimB: "\(bTitle) \(reverse.relation.renderVerb) \(aTitle)"
                )
            )
        }
        return out
    }

    // MARK: - 3. Opposing causal claims

    /// Same (source → target) pair carrying both a positive causal
    /// claim (CAUSED / CONTRIBUTED_TO / ENABLED) and a negative one
    /// (PREVENTED) in the verified table. This usually reflects a
    /// genuine disagreement between two sources or a user assertion
    /// that contradicts the heuristic.
    private func detectOpposingCausalClaims(
        links: [CausalLink],
        events: [Event]
    ) -> [VerifiedAnswer.Contradiction] {
        guard links.count >= 2 else { return [] }
        let eventByID: [Event.ID: Event] = Dictionary(
            uniqueKeysWithValues: events.map { ($0.id, $0) }
        )
        var byPair: [String: [CausalLink]] = [:]
        for link in links {
            let key = "\(link.sourceEventID.uuidString)|\(link.targetEventID.uuidString)"
            byPair[key, default: []].append(link)
        }
        var out: [VerifiedAnswer.Contradiction] = []
        for (_, group) in byPair where group.count >= 2 {
            let hasPositive = group.contains { $0.relation == .caused || $0.relation == .contributedTo || $0.relation == .enabled }
            let hasNegative = group.contains { $0.relation == .prevented }
            guard hasPositive && hasNegative else { continue }
            let pos = group.first { $0.relation == .caused || $0.relation == .contributedTo || $0.relation == .enabled }!
            let neg = group.first { $0.relation == .prevented }!
            let aTitle = eventByID[pos.sourceEventID]?.title ?? "Event \(pos.sourceEventID.uuidString.prefix(8))"
            let bTitle = eventByID[pos.targetEventID]?.title ?? "Event \(pos.targetEventID.uuidString.prefix(8))"
            out.append(
                VerifiedAnswer.Contradiction(
                    description: "Opposing causal claims for the same event pair",
                    claimA: "\(aTitle) \(pos.relation.renderVerb) \(bTitle) (source: \(pos.source.rawValue))",
                    claimB: "\(aTitle) \(neg.relation.renderVerb) \(bTitle) (source: \(neg.source.rawValue))"
                )
            )
        }
        return out
    }
}
