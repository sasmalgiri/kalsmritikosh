//
//  CounterfactualSimulator.swift
//  Kalsmritikosh
//
//  Phase J.10 — Vol 09 §Counterfactual / Vol 25 ¶7. Given a user
//  hypothetical ("what if the contract hadn't been signed?"), this
//  simulator walks the verified causal graph forward from the
//  prevented event and returns the set of events that transitively
//  depended on it.
//
//  The math is reachability over a directed graph whose edges are
//  the non-superseded causal links with `isCausal == true`
//  (CAUSED / CONTRIBUTED_TO / ENABLED). FOLLOWED edges are pure
//  temporal — they don't propagate the "would not have happened"
//  semantics.
//
//  Each downstream event carries the path it was reached by + a
//  cumulative dependency strength (product of link confidences).
//  The UI displays the head of the path ("if E2 had been prevented,
//  then E5 (via E3 contributed_to E5, conf 0.7 × 0.6 = 0.42)
//  wouldn't have happened").
//
//  Quality-or-nothing: no event is added to the "would not have
//  happened" set without an explicit causal-edge chain. We don't
//  invent paths. PREVENTED edges are skipped (those are themselves
//  counterfactual claims; we don't compose them into deeper
//  counterfactuals in v1 — that's a research-grade move).
//

import Foundation

public struct CounterfactualImpact: Sendable, Identifiable {
    public let id: UUID
    public let targetEventID: Event.ID
    public let pathLength: Int
    public let dependencyStrength: Double
    public let pathSummary: String

    public nonisolated init(
        id: UUID = UUID(),
        targetEventID: Event.ID,
        pathLength: Int,
        dependencyStrength: Double,
        pathSummary: String
    ) {
        self.id = id
        self.targetEventID = targetEventID
        self.pathLength = pathLength
        self.dependencyStrength = dependencyStrength
        self.pathSummary = pathSummary
    }
}

public struct CounterfactualSimulator: Sendable {
    public init() {}

    /// Walk reachability from `preventedEventID` over the supplied
    /// link set. Returns one CounterfactualImpact per downstream
    /// event ranked by `dependencyStrength * (1 / pathLength)`.
    ///
    /// The traversal is bounded by `maxDepth` (default 5) to keep
    /// runtime sublinear in the link graph on archives with
    /// thousands of links.
    public func simulate(
        preventedEventID: Event.ID,
        links: [CausalLink],
        events: [Event],
        maxDepth: Int = 5
    ) -> [CounterfactualImpact] {
        // Build adjacency: source -> [(link, target)] with only
        // causal-claim edges.
        var adjacency: [Event.ID: [CausalLink]] = [:]
        for link in links where link.relation.isCausal && link.relation != .prevented {
            adjacency[link.sourceEventID, default: []].append(link)
        }
        let eventByID: [Event.ID: Event] = Dictionary(
            uniqueKeysWithValues: events.map { ($0.id, $0) }
        )

        // BFS with per-node best strength + path summary.
        struct PathHead: Sendable {
            let eventID: Event.ID
            let depth: Int
            let strength: Double
            let summary: String
        }
        var visited: [Event.ID: PathHead] = [:]
        var queue: [PathHead] = [
            PathHead(eventID: preventedEventID, depth: 0, strength: 1.0, summary: "")
        ]
        while !queue.isEmpty {
            let head = queue.removeFirst()
            if head.depth >= maxDepth { continue }
            for link in adjacency[head.eventID] ?? [] {
                let nextStrength = head.strength * max(0.05, link.confidence)
                // Skip if we've already reached this node with a
                // stronger path.
                if let existing = visited[link.targetEventID],
                   existing.strength >= nextStrength { continue }
                let aTitle = eventByID[link.sourceEventID]?.title ?? "Event \(link.sourceEventID.uuidString.prefix(8))"
                let bTitle = eventByID[link.targetEventID]?.title ?? "Event \(link.targetEventID.uuidString.prefix(8))"
                let segment = "\(aTitle) \(link.relation.renderVerb) \(bTitle)"
                let nextSummary = head.summary.isEmpty
                    ? segment
                    : head.summary + " → " + segment
                let next = PathHead(
                    eventID: link.targetEventID,
                    depth: head.depth + 1,
                    strength: nextStrength,
                    summary: nextSummary
                )
                visited[link.targetEventID] = next
                queue.append(next)
            }
        }
        // Drop the seed event itself (depth 0).
        visited.removeValue(forKey: preventedEventID)
        let impacts: [CounterfactualImpact] = visited.values.map { head in
            CounterfactualImpact(
                targetEventID: head.eventID,
                pathLength: head.depth,
                dependencyStrength: head.strength,
                pathSummary: head.summary
            )
        }
        return impacts.sorted { lhs, rhs in
            if lhs.dependencyStrength != rhs.dependencyStrength {
                return lhs.dependencyStrength > rhs.dependencyStrength
            }
            return lhs.pathLength < rhs.pathLength
        }
    }
}
