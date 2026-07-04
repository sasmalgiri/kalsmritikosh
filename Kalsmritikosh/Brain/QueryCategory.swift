//
//  QueryCategory.swift
//  Kalsmritikosh
//
//  Phase J.6 — Vol 09 §Query Categories. The reference standard lists
//  nine first-class question shapes that future planner steering and
//  prompt-engineering should branch on:
//
//      fact, timeline, root-cause, comparison, trend, compliance,
//      narrative, counterfactual, risk
//
//  The existing `UserIntent.Kind` covers a subset of this but
//  collapses cause-asking and comparison into "factualLookup", and
//  has no representation for "counterfactual" or "risk". This adds
//  the missing axis without disturbing the existing routing — the
//  category surfaces in the ReasoningTrace and the planner can
//  branch on it later without an intent-detector rewrite.
//
//  Quality-or-nothing: a question that doesn't match any keyword
//  set classifies as `.fact` by default rather than something that
//  pretends to be more specific.
//

import Foundation

public enum QueryCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case fact           = "fact"
    case timeline       = "timeline"
    case rootCause      = "root_cause"
    case comparison     = "comparison"
    case trend          = "trend"
    case compliance     = "compliance"
    case narrative      = "narrative"
    case counterfactual = "counterfactual"
    case risk           = "risk"

    public var humanLabel: String {
        switch self {
        case .fact:           return "Fact"
        case .timeline:       return "Timeline"
        case .rootCause:      return "Root cause"
        case .comparison:     return "Comparison"
        case .trend:          return "Trend"
        case .compliance:     return "Compliance"
        case .narrative:      return "Narrative"
        case .counterfactual: return "Counterfactual"
        case .risk:           return "Risk"
        }
    }
}

/// Lightweight keyword-pattern classifier. Ranks each category by
/// the number of matching phrases in the question and picks the
/// best-scoring one; ties break by the priority order declared in
/// `priorityOrder` (counterfactual > root-cause > risk > … > fact).
/// The intent-detector's `UserIntent.Kind` is used as a tiebreaker:
/// reconstructive intents prefer .narrative; executive briefings
/// prefer .trend.
public nonisolated struct QueryCategoryClassifier: Sendable {
    public init() {}

    public func classify(question: String, intent: UserIntent? = nil) -> QueryCategory {
        let lower = question.lowercased()
        var scores: [QueryCategory: Int] = [:]
        for (category, patterns) in Self.patterns {
            for pattern in patterns where lower.contains(pattern) {
                scores[category, default: 0] += 1
            }
        }
        // Intent-derived nudges. Reconstructive intents lean narrative;
        // executiveBriefing leans trend; riskDetection leans risk.
        if let intent {
            switch intent.kind {
            case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
                scores[.narrative, default: 0] += 1
            case .executiveBriefing:
                scores[.trend, default: 0] += 1
            case .riskDetection:
                scores[.risk, default: 0] += 2
            default:
                break
            }
        }
        // No keyword match → default to .fact.
        guard !scores.isEmpty else { return .fact }
        // Highest score wins; ties broken by priority order.
        let priority = Self.priorityOrder
        var best: QueryCategory = .fact
        var bestScore = -1
        for category in priority {
            let s = scores[category, default: 0]
            if s > bestScore {
                bestScore = s
                best = category
            }
        }
        return bestScore <= 0 ? .fact : best
    }

    /// Tiebreaker order — earlier wins on equal score. `.narrative`
    /// is placed ahead of `.timeline` so a question like "tell me the
    /// story of Project Delta" (which matches "tell me the story" in
    /// narrative AND "story of" in timeline) classifies as narrative.
    /// Bug found by running the executable test snippet 2026-06-30.
    static let priorityOrder: [QueryCategory] = [
        .counterfactual, .rootCause, .risk, .compliance,
        .comparison, .trend, .narrative, .timeline, .fact
    ]

    /// Lowercased substring keywords per category. Curated for
    /// English correspondence and personal-archive questions; expand
    /// over time. Substring matching is good enough for the scoring
    /// purpose — false positives cost is "wrong category surfaced in
    /// the trace", not "wrong answer".
    static let patterns: [QueryCategory: [String]] = [
        .counterfactual: [
            "what if", "would have", "if we hadn't", "if we had not",
            "instead of", "had it not", "would not have", "hypothetical"
        ],
        .rootCause: [
            "why did", "why is", "why was", "because of", "root cause",
            "cause of", "reason for", "led to", "what caused"
        ],
        .risk: [
            "risk", "exposure", "vulnerability", "liability",
            "compliance gap", "what could go wrong", "danger", "threat"
        ],
        .compliance: [
            "compliant", "complies with", "in compliance", "violation",
            "policy", "regulation", "audit", "must we", "required to",
            "deadline", "obligation"
        ],
        .comparison: [
            "compare", "versus", " vs ", " vs.",
            "difference between", "how does .* compare",
            "better than", "worse than", "more than", "less than"
        ],
        .trend: [
            "trend", "over time", "what changed", "how has",
            "growth", "decline", "trajectory", "rate of",
            "year over year", "month over month"
        ],
        .timeline: [
            "when did", "when was", "when will", "timeline",
            "in chronological order", "history of", "story of",
            "evolution of", "sequence of"
        ],
        .narrative: [
            "tell me the story", "tell me about", "reconstruct",
            "walk me through", "what happened with",
            "what's the history of", "give me the narrative",
            "narrative of"
        ],
        .fact: [
            "what is", "who is", "where is", "how many",
            "what was", "who was"
        ]
    ]
}
