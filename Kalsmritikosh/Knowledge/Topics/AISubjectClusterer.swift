//
//  AISubjectClusterer.swift
//  Kalsmritikosh
//
//  M2 (module .aiSubjectResolution) — the topic leap the live-DB evidence demanded:
//  one real subject was split across several document-keyed topics (five separate
//  topics for one résumé). The deterministic minimizer folds THIN subjects into a
//  substantive one but never merges two SUBSTANTIVE document-copies of the same
//  subject. This asks the on-device model to propose which subject labels name the
//  SAME real-world subject, then applies each proposed merge ONLY when a
//  deterministic guard confirms the two share enough evidence terms — so the model
//  suggests, the evidence decides, and facts only move (never change).
//
//  Pure + deterministic except the single reason() call; the parse + guard are
//  unit-tested with a stubbed reasoner.
//

import Foundation

public struct AISubjectClusterer: Sendable {

    /// Injected so tests stub the model; nil result ⇒ no clustering (identity).
    public typealias Reasoner = @Sendable (_ prompt: String) async -> String?

    private let reason: Reasoner
    public init(reason: @escaping Reasoner) { self.reason = reason }

    /// Map every subject label to its canonical label. Singletons map to
    /// themselves; a merged copy maps to the group's largest member — but ONLY
    /// when the two share ≥ `minSharedTerms` content terms (the guard).
    public func canonicalize(
        _ input: [TopicConsolidator.SubjectFacts], minSharedTerms: Int = 3
    ) async -> [String: String] {
        var identity: [String: String] = [:]
        for s in input { identity[s.subject] = s.subject }
        guard input.count > 1 else { return identity }

        let labels = input.map(\.subject)
        guard let raw = await reason(Self.prompt(labels: labels)) else { return identity }

        let terms = input.map { Self.terms(of: $0) }
        var canonical = identity
        for group in Self.parseGroups(raw, count: labels.count) where group.count > 1 {
            // Canonical = the member carrying the most distinct facts (stable tie → lowest index).
            let canon = group.max(by: { a, b in
                let fa = input[a].facts.count, fb = input[b].facts.count
                return fa != fb ? fa < fb : a > b
            })!
            for m in group where m != canon {
                // GUARD: never merge on the model's word alone — require shared evidence terms.
                if terms[m].intersection(terms[canon]).count >= minSharedTerms {
                    canonical[labels[m]] = labels[canon]
                }
            }
        }
        return canonical
    }

    // MARK: - Pure core (unit-tested)

    nonisolated static func prompt(labels: [String]) -> String {
        let numbered = labels.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        Below is a numbered list of subject labels from one person's private knowledge base. \
        Some are DIFFERENT copies or versions of the SAME real-world subject (e.g. several \
        copies of one résumé, or the same patent under different file names). Group the numbers \
        that refer to the same real-world subject. Reply with ONE group per line as \
        comma-separated numbers (e.g. "1, 3, 5"); put a number alone on its own line if it has \
        no match. Use ONLY the numbers shown. Do not explain.

        \(numbered)
        """
    }

    /// Parse "1, 3, 5" lines into 0-based index groups, keeping only in-range,
    /// de-duplicated indices. Robust to prose/bullets around the numbers.
    nonisolated static func parseGroups(_ raw: String, count: Int) -> [[Int]] {
        var groups: [[Int]] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let nums = line.split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
                .map { $0 - 1 }
                .filter { $0 >= 0 && $0 < count }
            var seen = Set<Int>()
            let deduped = nums.filter { seen.insert($0).inserted }
            if !deduped.isEmpty { groups.append(deduped) }
        }
        return groups
    }

    nonisolated static func terms(of s: TopicConsolidator.SubjectFacts) -> Set<String> {
        let selector = PassageAnswerSelector()
        var out = selector.contentTerms(s.subject)
        for f in s.facts.prefix(20) {
            out.formUnion(selector.contentTerms(f.field + " " + f.value))
        }
        return out
    }
}
