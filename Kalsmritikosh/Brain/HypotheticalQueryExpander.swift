//
//  HypotheticalQueryExpander.swift
//  Kalsmritikosh
//
//  Phase 1 · R4 — HyDE (Hypothetical Document Embeddings) query expansion.
//  When the literal query underperforms in the vector layer (vocabulary
//  mismatch: the user asks in different words than the archive uses), ask the
//  on-device reasoning model for a short HYPOTHETICAL answer, embed THAT, and
//  RRF-fuse its neighbors with the literal query's. The hypothetical is a
//  retrieval bridge only — never shown, never cited, never allowed to assert.
//
//  Two guards keep it honest and on-device-cheap:
//   • Intent preservation — a rewrite that shares no content term with the
//     question has drifted; it is dropped and the literal ranking stands.
//   • Gated by the caller — only invoked when the first pass is weak, so an
//     ordinary well-matched question spends no extra model budget.
//
//  The fusion + intent guard are pure and deterministic (unit-tested with a
//  stubbed reasoner); only `hypothetical(for:)` touches the model.
//

import Foundation

public struct HypotheticalQueryExpander: Sendable {

    /// Produce a 1–2 sentence hypothetical answer for a question, or nil when no
    /// reasoning model is available. Injected so tests can stub it.
    public typealias Reasoner = @Sendable (_ prompt: String) async -> String?

    private let reason: Reasoner

    public init(reason: @escaping Reasoner) { self.reason = reason }

    /// Ask the reasoner for a hypothetical answer, keep it only if it preserves
    /// the question's intent. Returns the bridging text (never surfaced) or nil.
    public func hypothetical(for question: String) async -> String? {
        guard let raw = await reason(Self.prompt(for: question)) else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              Self.preservesIntent(question: question, hypothetical: text) else { return nil }
        return text
    }

    // MARK: - Pure core (unit-tested)

    nonisolated static func prompt(for question: String) -> String {
        """
        Write a brief, plausible 1–2 sentence answer to the question below, as it \
        might appear in a document. Do not hedge, do not say you are unsure, do not \
        add commentary — just the hypothetical passage. This is used only to find \
        relevant passages; it will not be shown to anyone.

        Question: \(question)
        """
    }

    /// The hypothetical must share at least one content term with the question,
    /// else it has drifted off-intent and is rejected.
    public nonisolated static func preservesIntent(question: String, hypothetical: String) -> Bool {
        let selector = PassageAnswerSelector()
        let q = selector.contentTerms(question)
        guard !q.isEmpty else { return false }
        return !q.intersection(selector.contentTerms(hypothetical)).isEmpty
    }

    /// Reciprocal Rank Fusion over ranked ID lists (earlier = better). Ties break
    /// by first appearance across the lists, so fusion is fully deterministic.
    public nonisolated static func rrfFuse<ID: Hashable>(_ lists: [[ID]], k: Int = 60) -> [ID] {
        var score: [ID: Double] = [:]
        var firstSeen: [ID: Int] = [:]
        var seq = 0
        for list in lists {
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += 1.0 / Double(k + rank + 1)
                if firstSeen[id] == nil { firstSeen[id] = seq; seq += 1 }
            }
        }
        return score.keys.sorted { a, b in
            let sa = score[a] ?? 0, sb = score[b] ?? 0
            if sa != sb { return sa > sb }
            return (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
        }
    }
}
