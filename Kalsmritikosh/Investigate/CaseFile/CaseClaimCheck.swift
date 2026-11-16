//
//  CaseClaimCheck.swift
//  Kalsmritikosh
//
//  Case plan 2026-11-16 (SEARCH-15) — "Check this claim" without AI: from the words of a point, a question or any item, two
//  editable queries in the case search's own syntax (CaseSearchQuery):
//    • supporting — records that name the claim's subject and state its figures;
//    • contrary   — records that name the same subject but do NOT state those figures (candidates that may say something
//                   else; reading them decides, the query does not).
//  Both are shown before anything runs, with what each means; the person edits them, and the case search runs them with its
//  usual receipt (what was searched, what was not). A quote matching a record never verifies a causal reading.
//  Deterministic text handling; nothing calls a model.
//

import Foundation

public nonisolated enum CaseClaimCheck {

    public struct Plan: Sendable, Equatable {
        public let claim: String
        /// The words or names the claim is about (each becomes a clause of both queries).
        public let subject: [String]
        /// The figures the claim states (amount clauses).
        public let figures: [String]
        public let supporting: String
        /// nil: the claim states no figure, so there is no "same subject, other figure" query to run.
        public let contrary: String?
        /// What the two queries mean, in plain words.
        public let explanation: String
    }

    static let stopWords: Set<String> = [
        "about", "after", "again", "against", "also", "because", "been", "before", "being", "between", "both", "but", "could", "does",
        "during", "each", "from", "have", "having", "into", "more", "most", "only", "other", "over", "said", "same", "should", "since",
        "such", "than", "that", "their", "them", "then", "there", "these", "they", "this", "those", "through", "under", "until", "very",
        "was", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will", "with", "would", "your", "investigate",
        "paid", "payment", "twice", "claim", "point", "question",
    ]

    /// Build the two queries from the claim's words. `maxTerms` bounds the subject so the query stays readable.
    public static func plan(claim: String, maxTerms: Int = 4) -> Plan {
        let text = claim.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Names first (two or more capitalised words in a row, as written), then distinctive words.
        var subject: [String] = []
        let ns = text as NSString
        if let re = try? NSRegularExpression(pattern: #"\b[A-Z][\p{L}'’-]+(?:\s+[A-Z][\p{L}'’-]+)+\b"#) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range)
                if !subject.contains(name) { subject.append(name) }
            }
        }
        let named = Set(subject.flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        let words = text.components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0.lowercased()) && !named.contains($0.lowercased()) }
        for w in words where !subject.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { subject.append(w) }
        subject = Array(subject.prefix(maxTerms))

        // Amounts written with a currency (₹, Rs, INR, $, USD, €, £ …, lakh and crore read exactly), in the order written,
        // each once; the clause matches the figure in any currency (the search never converts).
        var figures: [String] = []
        for a in CaseContradictionFinder.amounts(in: text).sorted(by: { $0.range.location < $1.range.location }) {
            let clause = "amount:" + NSDecimalNumber(decimal: a.value).stringValue
            if !figures.contains(clause) { figures.append(clause) }
        }

        func clause(_ s: String) -> String { s.contains(" ") ? "\"\(s)\"" : s }
        let subjectQuery = subject.map(clause).joined(separator: " ")
        let figureQuery = figures.count > 1 ? "(" + figures.joined(separator: " OR ") + ")" : (figures.first ?? "")
        let supporting = [subjectQuery, figureQuery].filter { !$0.isEmpty }.joined(separator: " ")
        let contrary = figures.isEmpty || subjectQuery.isEmpty ? nil : subjectQuery + " NOT " + figureQuery

        var explanation = subject.isEmpty
            ? "The claim names nothing distinctive to search for; type the words to look for."
            : "Supporting: records naming " + subject.map { "“\($0)”" }.joined(separator: ", ")
              + (figures.isEmpty ? "." : " and stating " + figures.map { $0.replacingOccurrences(of: "amount:", with: "") }.joined(separator: " or ") + ".")
        if let contrary, !contrary.isEmpty {
            explanation += " Contrary: records naming the same but not stating that figure — they may give another one; read them to decide."
        } else if !subject.isEmpty {
            explanation += " The claim states no figure, so there is no other-figure query; read the supporting records for statements against it."
        }
        return Plan(claim: claim, subject: subject, figures: figures, supporting: supporting, contrary: contrary, explanation: explanation)
    }

}
