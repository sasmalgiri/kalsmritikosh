//
//  SentenceFactChecker.swift
//  Kalsmritikosh
//
//  I-6 — fact-check a sentence the USER wrote against their own evidence.
//  Deterministic, no model call. For one sentence and the passages a keyword
//  search returned for it:
//
//   supported     — a passage shares most of the sentence's subject terms AND
//                   contains every date and amount the sentence states;
//   contradicted  — a passage sentence shares 2+ subject terms but gives a
//                   different date or amount, or the opposite polarity;
//   unsupported   — neither (the archive does not say it, as far as search sees).
//
//  It never says a sentence is "false" — only what the archive supports.
//

import Foundation

public nonisolated struct SentenceCheck: Sendable, Equatable, Identifiable {
    public enum Verdict: String, Sendable { case supported, contradicted, unsupported }
    public var id: Int { index }
    public let index: Int
    public let sentence: String
    public let verdict: Verdict
    public let objectID: KnowledgeObject.ID?
    public let evidence: String?
    public let reason: String
}

public nonisolated enum SentenceFactChecker {

    public static func check(index: Int, sentence: String,
                             candidates: [DisconfirmationScanner.Candidate]) -> SentenceCheck {
        let terms = DisconfirmationScanner.subjectTerms(question: sentence, answer: "")
        let dates = Set(DisconfirmationScanner.dates(in: sentence))
        let amounts = Set(DisconfirmationScanner.amounts(in: sentence))
        let negated = DisconfirmationScanner.hasNegation(sentence)
        guard !terms.isEmpty else {
            return SentenceCheck(index: index, sentence: sentence, verdict: .unsupported, objectID: nil, evidence: nil,
                                 reason: "Nothing specific enough to check.")
        }
        let needed = max(2, Int((Double(terms.count) * 0.6).rounded(.up)))

        // Supported: one passage carries the subject and every stated value.
        for c in candidates {
            let lower = c.text.lowercased()
            let shared = terms.filter { lower.contains($0) }.count
            let passageDates = Set(DisconfirmationScanner.dates(in: c.text))
            let passageAmounts = Set(DisconfirmationScanner.amounts(in: c.text))
            if shared >= min(needed, terms.count),
               dates.isSubset(of: passageDates), amounts.isSubset(of: passageAmounts),
               DisconfirmationScanner.hasNegation(c.text) == negated || (dates.isEmpty && amounts.isEmpty && !negated) {
                return SentenceCheck(index: index, sentence: sentence, verdict: .supported, objectID: c.objectID,
                                     evidence: String(c.text.prefix(240)), reason: "A source says this.")
            }
        }
        // Contradicted: same subject, different value or polarity, in one source sentence.
        for c in candidates {
            for s in DisconfirmationScanner.sentences(c.text) {
                let lower = s.lowercased()
                guard terms.filter({ lower.contains($0) }).count >= 2 else { continue }
                let d = Set(DisconfirmationScanner.dates(in: s))
                let a = Set(DisconfirmationScanner.amounts(in: s))
                var reason: String?
                if !dates.isEmpty, !d.isEmpty, d.isDisjoint(with: dates) {
                    reason = "A source gives a different date (\(d.sorted().joined(separator: ", ")))."
                } else if !amounts.isEmpty, !a.isEmpty, a.isDisjoint(with: amounts) {
                    reason = "A source gives a different amount (\(a.sorted().map(DisconfirmationScanner.formatAmount).joined(separator: ", ")))."
                } else if DisconfirmationScanner.hasNegation(s) != negated {
                    reason = negated ? "A source states it in the positive." : "A source denies or reverses this."
                }
                if let reason {
                    return SentenceCheck(index: index, sentence: sentence, verdict: .contradicted, objectID: c.objectID,
                                         evidence: s.trimmingCharacters(in: .whitespacesAndNewlines), reason: reason)
                }
            }
        }
        return SentenceCheck(index: index, sentence: sentence, verdict: .unsupported, objectID: nil, evidence: nil,
                             reason: "No source found that says this.")
    }
}
