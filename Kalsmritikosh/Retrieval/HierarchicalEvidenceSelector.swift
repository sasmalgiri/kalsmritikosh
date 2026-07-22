//
//  HierarchicalEvidenceSelector.swift
//  Kalsmritikosh
//
//  RET-004 — when an authoritative document is injected/promoted, select the chunks that
//  actually MATCH the question, not just the document's first N chunks ("no prefix-only
//  injection"). Chunks are ranked within their document by query-term overlap, so a résumé's
//  "Work Experience" paragraph is chosen for "where worked", not its header.
//
//  Deterministic, offline. Pure ranking over the chunk texts + the query plan's terms.
//

import Foundation

public struct HierarchicalEvidenceSelector: Sendable {
    public nonisolated init() {}

    /// Score a chunk by how many distinct query terms it contains (case-insensitive, word-ish).
    public nonisolated func relevance(ofText text: String, terms: [String]) -> Int {
        let hay = text.lowercased()
        var hits = 0
        for t in terms {
            let needle = t.lowercased()
            if needle.count >= 2 && hay.contains(needle) { hits += 1 }
        }
        return hits
    }

    /// Query terms from a QueryPlan: subjects + a keyword per requested field.
    public nonisolated func terms(from plan: QueryPlan) -> [String] {
        var t = plan.targetSubjects.flatMap { $0.split(separator: " ").map(String.init) }
        for f in plan.requestedFields {
            switch f {
            case .employment: t += ["work", "employ", "company", "experience", "designation"]
            case .monetaryAmount: t += ["amount", "paid", "total", "₹", "$"]
            case .counterparty: t += ["paid to", "payee", "to"]
            case .date: t += ["date", "on", "when"]
            case .terms: t += ["terms", "clause", "shall"]
            case .status: t += ["status", "granted", "approved"]
            default: break
            }
        }
        return t
    }

    /// Select up to `limit` chunks of ONE document, ranked by relevance (desc), stable on ties
    /// by original order. Replaces taking the first `limit` chunks blindly.
    public nonisolated func selectWithinDocument(
        chunkTexts: [String], terms: [String], limit: Int = 4
    ) -> [Int] {
        var scored: [(idx: Int, score: Int)] = []
        for (idx, text) in chunkTexts.enumerated() {
            scored.append((idx, relevance(ofText: text, terms: terms)))
        }
        scored.sort { a, b in
            a.score != b.score ? a.score > b.score : a.idx < b.idx
        }
        return scored.prefix(limit).map { $0.idx }
    }
}
