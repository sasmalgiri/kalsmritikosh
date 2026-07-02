//
//  InvestigationTemplates.swift
//  Kalsmritikosh
//
//  System 3 investigation templates — deterministic root-cause
//  (5 Whys) and Ishikawa/Fishbone analysis over the causal-link
//  ledger. No LLM.
//

import Foundation

// MARK: - 5 Whys

/// One rung of a 5-Whys root-cause chain: the answer to "why did
/// the current effect happen?" resolved to the highest-confidence
/// incoming cause.
public struct WhyStep: Sendable, Identifiable {
    public let id = UUID()
    public let depth: Int
    public let question: String
    public let cause: Event
    public let relation: CausalRelation
    public let confidence: Double
}

/// The linear highest-confidence causal chain leading into `effect`.
public struct FiveWhysResult: Sendable {
    public let effect: Event
    public let chain: [WhyStep]
}

/// Walks backwards along incoming causal links, at each step picking
/// the single highest-confidence cause, to build a linear root-cause
/// chain. Pure and deterministic.
public struct FiveWhysAnalyzer: Sendable {
    public init() {}

    public func analyze(
        effect: Event,
        links: [CausalLink],
        events: [Event],
        maxDepth: Int = 5
    ) -> FiveWhysResult {
        let eventsByID: [Event.ID: Event] = Dictionary(
            events.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var chain: [WhyStep] = []
        var visited: Set<Event.ID> = [effect.id]
        var current = effect
        var depth = 0

        while depth < maxDepth {
            // Highest-confidence incoming, causal (not FOLLOWED) link
            // whose resolved source event is unvisited.
            let candidate = links
                .filter { $0.targetEventID == current.id }
                .filter { $0.relation.isCausal }
                .sorted { $0.confidence > $1.confidence }
                .lazy
                .compactMap { link -> (CausalLink, Event)? in
                    guard let src = eventsByID[link.sourceEventID],
                          !visited.contains(src.id) else { return nil }
                    return (link, src)
                }
                .first

            guard let (link, cause) = candidate else { break }

            depth += 1
            chain.append(
                WhyStep(
                    depth: depth,
                    question: "Why did \(current.title)?",
                    cause: cause,
                    relation: link.relation,
                    confidence: link.confidence
                )
            )
            visited.insert(cause.id)
            current = cause
        }

        return FiveWhysResult(effect: effect, chain: chain)
    }
}

// MARK: - Fishbone (Ishikawa)

/// A single direct cause on a Fishbone "bone" (category).
public struct FishboneCause: Sendable, Identifiable {
    public let id = UUID()
    public let event: Event
    public let relation: CausalRelation
    public let confidence: Double
}

/// One category ("bone") of the Ishikawa diagram, holding the direct
/// causes that fall under it.
public struct FishboneBone: Sendable, Identifiable {
    public let id = UUID()
    public let category: String
    public let causes: [FishboneCause]
}

/// A full cause-and-effect (Ishikawa) diagram: the effect plus its
/// direct causes grouped by category.
public struct Fishbone: Sendable {
    public let effect: Event
    public let bones: [FishboneBone]
}

/// Groups all DIRECT incoming causal links to an effect into Ishikawa
/// categories via a deterministic keyword/kind rule. Pure.
public struct FishboneAnalyzer: Sendable {
    public init() {}

    public func analyze(
        effect: Event,
        links: [CausalLink],
        events: [Event]
    ) -> Fishbone {
        let eventsByID: [Event.ID: Event] = Dictionary(
            events.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Direct, causal (non-FOLLOWED) incoming links, resolved.
        var byCategory: [String: [FishboneCause]] = [:]
        for link in links where link.targetEventID == effect.id {
            guard link.relation.isCausal,
                  let cause = eventsByID[link.sourceEventID] else { continue }
            let category = Self.category(for: cause)
            byCategory[category, default: []].append(
                FishboneCause(
                    event: cause,
                    relation: link.relation,
                    confidence: link.confidence
                )
            )
        }

        let bones = byCategory
            .map { FishboneBone(category: $0.key, causes: $0.value) }
            .sorted { lhs, rhs in
                if lhs.causes.count != rhs.causes.count {
                    return lhs.causes.count > rhs.causes.count
                }
                return lhs.category < rhs.category  // stable tie-break
            }

        return Fishbone(effect: effect, bones: bones)
    }

    /// Deterministic categorization rule. Exposed as a static so the
    /// classification can be unit-tested independently of graph walks.
    public static func category(for event: Event) -> String {
        let kind = event.kind.rawValue.lowercased()
        let title = event.title.lowercased()
        let hay = kind + " " + title

        func contains(_ needles: [String]) -> Bool {
            needles.contains { hay.contains($0) }
        }

        // Supplier / External: money and goods flowing across the org
        // boundary.
        if contains(["invoice", "payment", "paid", "delivery",
                     "deliver", "supplier", "vendor", "shipment",
                     "procure", "contract"]) {
            return "Supplier/External"
        }

        // Timing: schedule pressure and slippage.
        if contains(["deadline", "delay", "delayed", "schedule",
                     "overdue", "late", "timeline"]) {
            return "Timing"
        }

        // Process: internal workflow verbs.
        if contains(["task", "meeting", "decision", "review",
                     "approval", "assigned", "workflow", "process"]) {
            return "Process"
        }

        // People: person-ish signals.
        if contains(["email", "call", "sent", "received", "message",
                     "assigned to", "manager", "team", "staff",
                     "hire", "resign"]) {
            return "People"
        }

        return "Other"
    }
}
