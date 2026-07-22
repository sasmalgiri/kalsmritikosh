//
//  ClaimGrounding.swift
//  Kalsmritikosh
//
//  CLM-001 — claim grounding. The claim–evidence contract requires that every MATERIAL
//  specific in an answer claim (a monetary amount, a date/year, a proper-noun name) is
//  actually present in the evidence cited for that claim. A claim whose specifics are not
//  grounded is an unsupported material claim and must be flagged (and kept out of a final
//  answer), never presented as fact.
//
//  Deterministic, offline. This does not judge prose or opinion — only checks that the
//  concrete, checkable tokens a claim asserts appear (normalized) in its supporting text.
//

import Foundation

public struct ClaimGrounding: Sendable {
    public nonisolated init() {}

    public struct Result: Sendable, Hashable {
        public let materialTokens: [String]
        public let groundedTokens: [String]
        public let ungroundedTokens: [String]
        /// True when the claim asserts a checkable specific that the evidence does not contain.
        public var hasUngroundedMaterial: Bool { !ungroundedTokens.isEmpty }
        /// Fraction of material tokens found in the evidence (1.0 when the claim has none).
        public var groundedFraction: Double {
            materialTokens.isEmpty ? 1.0 : Double(groundedTokens.count) / Double(materialTokens.count)
        }
    }

    /// Check a claim's material specifics against its supporting evidence text.
    public nonisolated func check(claim: String, evidenceTexts: [String]) -> Result {
        let tokens = Self.materialTokens(in: claim)
        let evidence = evidenceTexts.joined(separator: " \n ")
        let normEvidence = Self.normalizeDigits(evidence.lowercased())

        var grounded: [String] = []
        var ungrounded: [String] = []
        for tok in tokens {
            if Self.isPresent(tok, in: evidence, normalizedEvidence: normEvidence) {
                grounded.append(tok)
            } else {
                ungrounded.append(tok)
            }
        }
        return Result(materialTokens: tokens, groundedTokens: grounded, ungroundedTokens: ungrounded)
    }

    // MARK: - Material token extraction

    /// Extract the checkable specifics of a claim: monetary amounts, years/dates, and
    /// multi-word proper-noun names. Opinion/filler words are ignored.
    nonisolated static func materialTokens(in claim: String) -> [String] {
        var tokens: [String] = []

        // Monetary amounts: ₹3,800  $1200  Rs. 500  2.70 lac
        if let re = try? NSRegularExpression(
            pattern: #"(?:₹|rs\.?|inr|usd|\$)\s?[\d,]+(?:\.\d+)?|\b[\d,]+(?:\.\d+)?\s?(?:lac|lakh|crore|k)\b"#,
            options: [.caseInsensitive]) {
            tokens.append(contentsOf: matches(re, in: claim))
        }
        // Years and dd/mm/yyyy dates
        if let re = try? NSRegularExpression(
            pattern: #"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b|\b(?:19|20)\d{2}\b"#) {
            tokens.append(contentsOf: matches(re, in: claim))
        }
        // Proper-noun names: 2+ consecutive Capitalized words (skip sentence-start noise
        // by only taking runs of length >= 2).
        if let re = try? NSRegularExpression(
            pattern: #"\b(?:[A-Z][a-zA-Z]+)(?:\s+[A-Z][a-zA-Z]+)+\b"#) {
            tokens.append(contentsOf: matches(re, in: claim))
        }

        // Dedup, drop trivial one-char artifacts.
        var seen = Set<String>()
        return tokens.filter { $0.count > 1 && seen.insert($0.lowercased()).inserted }
    }

    nonisolated static func matches(_ re: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - Presence check

    nonisolated static func isPresent(_ token: String, in evidence: String, normalizedEvidence: String) -> Bool {
        // Amounts/dates: compare on digits only, so "₹3,800" matches "Rs 3800".
        let digits = normalizeDigits(token.lowercased())
        if digits.contains(where: \.isNumber) {
            return normalizedEvidence.contains(digits)
        }
        // Names: case-insensitive substring.
        return evidence.localizedCaseInsensitiveContains(token)
    }

    /// Keep only digits (drops currency symbols, commas, separators) for robust amount/date matching.
    nonisolated static func normalizeDigits(_ s: String) -> String {
        String(s.filter { $0.isNumber })
    }
}
