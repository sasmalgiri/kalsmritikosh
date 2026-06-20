//
//  EmbeddingReranker.swift
//  Kalsmritikosh
//
//  Apple-native bi-encoder reranker. Embeds the question and each
//  candidate passage with Apple's NLEmbedding.sentenceEmbedding and
//  scores via cosine similarity. Free Apple-native quality lift while
//  the Core ML cross-encoder (UPDATE_17B T2–T7) is in flight.
//
//  Why bi-encoder, not cross-encoder:
//  - Apple ships no cross-encoder out of the box; the cross-encoder
//    path lives in UPDATE_17B (Core ML conversion of MiniLM).
//  - Bi-encoders are ~3-5 NDCG points behind cross-encoders on
//    relevance benchmarks, but they're DETERMINISTIC, sandbox-safe,
//    have zero external deps, and run in single-digit ms per pair.
//  - That makes them strictly better than the current Ollama
//    prompted-scoring path for evals (no non-determinism), and a
//    good first-pass filter when the cross-encoder lands.
//
//  Toggled via KALSMRITIKOSH_RERANKER=embed env var in EvidenceVerifier.
//

import Foundation
import NaturalLanguage
import OSLog

public actor EmbeddingReranker {
    public let id = "brain.reranker.embedding"

    private let language: NLLanguage
    /// Cache of question/candidate embeddings within a single batch.
    /// Apple's sentenceEmbedding is fast (~ms) but repeated identical
    /// candidate strings still benefit from skip-on-hit.
    private var batchCache: [String: [Double]] = [:]

    public init(language: NLLanguage = .english) {
        self.language = language
    }

    /// Score each candidate against the question via cosine similarity
    /// in Apple's sentence-embedding space. Scores are in [0,1] (clamped).
    /// Identity fallback (0.5) when the embedding model isn't available
    /// or returns nil for a particular sentence — never throws.
    public func score(
        question: String,
        candidates: [String]
    ) async -> [Double] {
        guard !candidates.isEmpty else { return [] }
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
            AtlasLog.brain.info("embedding-reranker: no NLEmbedding for language; identity scoring \(candidates.count, privacy: .public) candidates")
            return Array(repeating: 0.5, count: candidates.count)
        }
        batchCache.removeAll(keepingCapacity: true)
        guard let qVec = vector(for: question, using: model) else {
            AtlasLog.brain.info("embedding-reranker: question embedding nil; identity scoring \(candidates.count, privacy: .public) candidates")
            return Array(repeating: 0.5, count: candidates.count)
        }
        var scores: [Double] = []
        scores.reserveCapacity(candidates.count)
        for c in candidates {
            if let v = vector(for: c, using: model) {
                scores.append(Self.cosine(qVec, v))
            } else {
                scores.append(0.5)
            }
        }
        AtlasLog.brain.info("embedding-reranker: scored \(scores.count, privacy: .public) candidates (cosine)")
        return scores
    }

    private func vector(for text: String, using model: NLEmbedding) -> [Double]? {
        let key = String(text.prefix(400))
        if let cached = batchCache[key] { return cached }
        guard let v = model.vector(for: key) else { return nil }
        batchCache[key] = v
        return v
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.5 }
        var dot = 0.0
        var na = 0.0
        var nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        guard denom > 0 else { return 0.5 }
        // Cosine in [-1,1]; map to [0,1] so it composes with the
        // existing scoreByObject sort which expects higher = better.
        let raw = dot / denom
        return min(1, max(0, (raw + 1) / 2))
    }
}
