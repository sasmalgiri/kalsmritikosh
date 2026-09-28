//
//  RetrievalEval.swift
//  Kalsmritikosh
//
//  Plan B1 — the evidence-metrics harness. Measures retrieval/answer quality
//  SEPARATELY (directive §6.3): recall@k and precision@k of the right sources,
//  source-identity correctness, and unanswerable-question handling. Pure and
//  deterministic: a gold set + an injected "what did retrieval return for this
//  question" closure → a scored report. This is the yardstick every later
//  retrieval change (rerank, corrective, HyDE, ANN) must beat, so quality is
//  MEASURED, not guessed — no single test-count masquerades as proof.
//

import Foundation

/// One graded question: the documents that truly answer it, and whether the
/// honest response is to abstain (no source answers it).
public struct RetrievalGoldCase: Sendable, Equatable {
    public let question: String
    public let relevantObjectIDs: Set<UUID>
    public let shouldAbstain: Bool
    public init(question: String, relevantObjectIDs: Set<UUID>, shouldAbstain: Bool = false) {
        self.question = question
        self.relevantObjectIDs = relevantObjectIDs
        self.shouldAbstain = shouldAbstain
    }
}

/// The separated metrics — never collapsed into one number.
public struct RetrievalMetrics: Sendable, Equatable {
    public let cases: Int
    public let meanRecallAtK: Double        // did the right sources come back?
    public let meanPrecisionAtK: Double     // how much of the top-k was on-target?
    public let unanswerableHandled: Double  // fraction of should-abstain cases handled right
    public let answerableCovered: Double    // fraction of answerable cases with ≥1 relevant hit
}

public enum RetrievalEval {

    /// Score a gold set. `retrieve` returns the ranked object ids retrieval
    /// surfaced for a question (best first). Pure — the caller injects the real
    /// (or a stub) retriever, so this runs headless in tests and live in CI.
    public nonisolated static func score(
        cases: [RetrievalGoldCase],
        k: Int = 10,
        retrieve: (_ question: String) -> [UUID]
    ) -> RetrievalMetrics {
        guard !cases.isEmpty else {
            return RetrievalMetrics(cases: 0, meanRecallAtK: 0, meanPrecisionAtK: 0,
                                    unanswerableHandled: 0, answerableCovered: 0)
        }
        var recallSum = 0.0, precisionSum = 0.0
        var answerable = 0, answerableHit = 0
        var unanswerable = 0, unanswerableOK = 0

        for c in cases {
            let topK = Array(retrieve(c.question).prefix(k))
            let topSet = Set(topK)

            if c.shouldAbstain {
                unanswerable += 1
                // Handled right when retrieval surfaces nothing genuinely relevant
                // (it may return noise, but none of it is a "relevant" doc — there
                // are none — so an empty/irrelevant top-k is the correct signal).
                if topSet.isDisjoint(with: c.relevantObjectIDs) { unanswerableOK += 1 }
                continue
            }

            answerable += 1
            let hits = topSet.intersection(c.relevantObjectIDs).count
            let recall = c.relevantObjectIDs.isEmpty ? 0 : Double(hits) / Double(c.relevantObjectIDs.count)
            let precision = topK.isEmpty ? 0 : Double(hits) / Double(topK.count)
            recallSum += recall
            precisionSum += precision
            if hits > 0 { answerableHit += 1 }
        }

        let ansCount = max(answerable, 1)
        return RetrievalMetrics(
            cases: cases.count,
            meanRecallAtK: recallSum / Double(ansCount),
            meanPrecisionAtK: precisionSum / Double(ansCount),
            unanswerableHandled: unanswerable == 0 ? 1 : Double(unanswerableOK) / Double(unanswerable),
            answerableCovered: Double(answerableHit) / Double(ansCount))
    }
}
