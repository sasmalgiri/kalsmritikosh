//
//  RerankerLadder.swift
//  Kalsmritikosh
//
//  G2-RERANK-LADDER — composable multi-tier reranking cascade.
//
//  Today, EvidenceVerifier picks ONE reranker (Ollama / Apple embedding
//  / none) via KALSMRITIKOSH_RERANKER. UPDATE_18 §4 Revision C proposes
//  a cascade instead, validated by chatmind-pipeline production:
//
//      heuristic → BM25 → cross-encoder → optional LLM
//
//  with **fast-path skips** when fewer than N candidates remain after a
//  cheap tier, the expensive tiers are bypassed entirely. This bounds
//  worst-case latency while preserving the relevance ceiling.
//
//  This file ships the protocol + ordered cascade type. Wiring into
//  EvidenceVerifier is a separate commit; the bge-reranker Core ML
//  model is a separate external task (download + coremltools convert +
//  bundle).
//

import Foundation

/// One tier in the reranker cascade.
///
/// Tiers are ordered cheap-to-expensive. Each tier takes the surviving
/// candidates from the previous tier and returns a scored, ordered
/// subset (or the same set with new scores). Returning `nil` means
/// "I have no opinion — pass through unchanged".
public protocol RerankerTier: Sendable {
    /// Stable id surfaced in logs. e.g. "tier.heuristic.keyword",
    /// "tier.bm25.fts5", "tier.crossencoder.bge", "tier.llm.ollama".
    var id: String { get }

    /// Cheap-to-expensive ordering hint. Smaller = cheaper / earlier.
    var costClass: Int { get }

    /// Score the given (question, candidates) pair. Implementations
    /// MUST return either:
    ///   - the same count as `candidates` (scores aligned by index), or
    ///   - nil (no opinion, pass through).
    func score(
        question: String,
        candidates: [String]
    ) async -> [Double]?
}

/// Composable cascade. Runs tiers cheap-first. After each tier, if the
/// number of HIGH-CONFIDENCE survivors (score above `fastPathFloor`)
/// is ≤ `fastPathMinSurvivors`, the remaining (expensive) tiers are
/// skipped — those few survivors are already the answer.
public struct RerankerLadder: Sendable {
    public let tiers: [any RerankerTier]
    public let fastPathFloor: Double
    public let fastPathMinSurvivors: Int

    public init(
        tiers: [any RerankerTier],
        fastPathFloor: Double = 0.7,
        fastPathMinSurvivors: Int = 3
    ) {
        // Always cheap-first.
        self.tiers = tiers.sorted { $0.costClass < $1.costClass }
        self.fastPathFloor = fastPathFloor
        self.fastPathMinSurvivors = fastPathMinSurvivors
    }

    /// Run the cascade. Returns scores aligned to `candidates` order.
    /// When all tiers pass through, returns identity (0.5 × N).
    public func score(
        question: String,
        candidates: [String]
    ) async -> [Double] {
        guard !candidates.isEmpty else { return [] }
        var scores = Array(repeating: 0.5, count: candidates.count)
        var consumed: [String] = []
        for tier in tiers {
            guard let next = await tier.score(question: question, candidates: candidates) else {
                continue
            }
            // Guard against tier misbehavior.
            if next.count != candidates.count { continue }
            scores = next
            consumed.append(tier.id)
            // Fast-path: stop early ONLY when this cheaper tier already produced
            // ENOUGH confident survivors (≥ fastPathMinSurvivors) — then the
            // expensive tiers add nothing. When it produced FEW or ZERO confident
            // candidates, that's exactly when the more powerful tier (cross-
            // encoder) should run, so keep going. (This was inverted: `<=` gave
            // up precisely when 0 candidates were confident — audit #5.)
            let confident = scores.filter { $0 >= fastPathFloor }.count
            if confident >= fastPathMinSurvivors {
                break
            }
        }
        return scores
    }
}

// MARK: - Built-in cheap tier: heuristic keyword overlap

/// Tier 1 — token-overlap heuristic. Free, deterministic. Provides a
/// fall-back signal when no other tier is wired and a simple sanity
/// score otherwise. Counts question-token presence in each candidate.
public struct HeuristicKeywordTier: RerankerTier {
    public let id = "tier.heuristic.keyword"
    public let costClass = 0
    public init() {}

    public func score(
        question: String,
        candidates: [String]
    ) async -> [Double]? {
        let qTokens = Set(
            question
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
        guard !qTokens.isEmpty else { return nil }
        return candidates.map { c in
            let cTokens = Set(
                c.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { $0.count >= 3 }
            )
            if cTokens.isEmpty { return 0.5 }
            let hit = qTokens.intersection(cTokens).count
            return min(1.0, Double(hit) / Double(qTokens.count))
        }
    }
}
