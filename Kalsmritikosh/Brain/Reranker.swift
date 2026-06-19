//
//  Reranker.swift
//  Kalsmritikosh
//
//  G2-1 — closes the citation-precision gap at Gate 1 (lookup 0.33 → ≥ 0.6).
//
//  EvidenceVerifier previously ranked citation survivors by
//  `scoreByObject` (max retrieval similarity per KO). That's a *question*
//  vs *chunk* signal — which is what made contract.md win L1 (it ranks
//  #1 by similarity) but lose L2 (an invoice's "delivery date" wording
//  scored higher than the contract's). A reranker fixes that by scoring
//  (question, candidate-evidence-text) pairs directly, so the model
//  weighs whether a passage actually *answers* the question, not just
//  whether it shares words with it.
//
//  Implementation: prompted scoring via whichever provider resolves
//  `CapabilitySpec.reranking()`. Ollama (`provider.local.network`) is
//  the path on macOS 15.6; FoundationModels can plug in on macOS 26 if
//  it ever declares the capability. When NO provider resolves, the
//  reranker returns a constant 0.5 for every candidate — preserving the
//  existing `scoreByObject` order so behavior matches pre-G2-1 (no
//  regression on heuristic-floor runs).
//

import Foundation
import OSLog

public actor Reranker {
    public let id = "brain.reranker"

    private let capabilities: CapabilityRegistry

    public init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
    }

    /// Score how strongly each candidate's text supports the question.
    /// Returns scores in [0, 1] aligned to the input order.
    ///
    /// One prompt per question (not per candidate) — the model is asked
    /// to emit a JSON array of scores in candidate order. This keeps
    /// reranker latency at ~one LLM round-trip per answer instead of
    /// N (which would have multiplied the eval wall-clock by ~6×).
    ///
    /// Identity fallback (all 0.5) when no provider supports
    /// `.reranking` OR when the model output can't be parsed — both
    /// safe-default to "no opinion", so the upstream
    /// `(rerankScore, scoreByObject)` ordering collapses back to the
    /// pre-G2-1 score-by-object ranking. No regression possible.
    public func score(
        question: String,
        candidates: [String]
    ) async -> [Double] {
        guard !candidates.isEmpty else { return [] }
        let spec = CapabilitySpec.reranking(purpose: "brain.reranker")
        guard let provider = try? await capabilities.resolve(spec) else {
            AtlasLog.brain.info("reranker: no provider resolved for spec; identity scoring \(candidates.count, privacy: .public) candidates")
            return Array(repeating: 0.5, count: candidates.count)
        }
        guard await provider.isAvailable() else {
            AtlasLog.brain.info("reranker: provider=\(provider.id, privacy: .public) available=false; identity scoring \(candidates.count, privacy: .public) candidates")
            return Array(repeating: 0.5, count: candidates.count)
        }
        let prompt = buildPrompt(question: question, candidates: candidates)
        let options = GenerationOptions(
            maxTokens: 200,
            temperature: 0.0,
            systemPrompt: "You are a precise relevance scorer. Reply with exactly one JSON array of numbers between 0 and 1, nothing else."
        )
        do {
            let response = try await provider.generate(prompt: prompt, options: options)
            let parsed = Self.parseScores(response, expectedCount: candidates.count)
            AtlasLog.brain.info("reranker: provider=\(provider.id, privacy: .public) scored \(parsed.count, privacy: .public) candidates")
            return parsed
        } catch {
            AtlasLog.brain.error("reranker: provider=\(provider.id, privacy: .public) call failed → \(String(describing: error), privacy: .public); identity scoring")
            return Array(repeating: 0.5, count: candidates.count)
        }
    }

    private func buildPrompt(question: String, candidates: [String]) -> String {
        var lines: [String] = []
        for (i, c) in candidates.enumerated() {
            let snippet = String(c.prefix(400))
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(i + 1)] \(snippet)")
        }
        let block = lines.joined(separator: "\n")
        return """
        Rate how strongly each numbered passage supports answering the question.
        Give a single decimal number between 0 (irrelevant) and 1 (directly answers it) per passage.
        Reply with ONE JSON array of \(candidates.count) numbers in passage order, nothing else.

        Question: \(question)

        Passages:
        \(block)

        Scores (JSON array):
        """
    }

    /// Pulls the first JSON array of numbers out of the model's reply
    /// and trims/pads to `expectedCount`. Identity fallback for any
    /// parse failure or count mismatch — never throws.
    static func parseScores(_ response: String, expectedCount: Int) -> [Double] {
        guard let arrayText = extractFirstJSONArray(from: response),
              let data = arrayText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            return Array(repeating: 0.5, count: expectedCount)
        }
        var scores: [Double] = parsed.compactMap { element -> Double? in
            if let d = element as? Double { return clamp01(d) }
            if let n = element as? NSNumber { return clamp01(n.doubleValue) }
            if let s = element as? String, let d = Double(s) { return clamp01(d) }
            return nil
        }
        if scores.count < expectedCount {
            scores.append(contentsOf: Array(repeating: 0.5, count: expectedCount - scores.count))
        } else if scores.count > expectedCount {
            scores = Array(scores.prefix(expectedCount))
        }
        return scores
    }

    /// Walks the response looking for the first balanced `[...]` block.
    /// Tolerates code fences, prose preambles, and trailing commentary.
    private static func extractFirstJSONArray(from response: String) -> String? {
        guard let start = response.firstIndex(of: "[") else { return nil }
        var depth = 0
        var cursor = start
        while cursor < response.endIndex {
            let ch = response[cursor]
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return String(response[start...cursor])
                }
            }
            cursor = response.index(after: cursor)
        }
        return nil
    }

    private static func clamp01(_ x: Double) -> Double {
        if x.isNaN { return 0.5 }
        return min(1, max(0, x))
    }
}
