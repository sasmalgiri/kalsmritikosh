//
//  PIIRedactor.swift
//  Kalsmritikosh
//
//  RED-001 — a deterministic text redaction engine. When a work product is exported under a
//  redaction policy, protected values must be REMOVED from the underlying text, not merely
//  visually covered — so re-extraction can't recover them (RED-002 verifies this). This
//  engine redacts emails, phone numbers, and caller-specified terms (names, ids, amounts),
//  replacing them with a fixed token and reporting exactly what was removed.
//
//  Deterministic, offline. Pure string transform — it does not touch stored evidence, only
//  the exported copy. Visual/binary redaction of PDFs/images is RED-002 (separate, gated).
//

import Foundation

public struct RedactionPolicy: Sendable, Hashable {
    public var redactEmails: Bool
    public var redactPhones: Bool
    /// Exact terms to remove (names, account numbers, amounts) — matched case-insensitively.
    public var customTerms: [String]
    public var token: String

    public nonisolated init(redactEmails: Bool = true, redactPhones: Bool = true,
                            customTerms: [String] = [], token: String = "[REDACTED]") {
        self.redactEmails = redactEmails
        self.redactPhones = redactPhones
        self.customTerms = customTerms
        self.token = token
    }
}

public struct PIIRedactor: Sendable {
    public nonisolated init() {}

    public struct Result: Sendable, Hashable {
        public let redactedText: String
        public let redactionCount: Int
        public let categories: [String]
        /// True when no protected term survives in the output (RED-002 pre-check).
        public func isClean(of terms: [String]) -> Bool {
            let lower = redactedText.lowercased()
            return !terms.contains { !$0.isEmpty && lower.contains($0.lowercased()) }
        }
    }

    nonisolated static let emailPattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    nonisolated static let phonePattern = #"(?<!\d)(?:\+?\d[\d \-]{8,}\d)(?!\d)"#

    public nonisolated func redact(_ text: String, policy: RedactionPolicy) -> Result {
        var out = text
        var count = 0
        var categories: [String] = []

        // Custom terms FIRST (names/ids/amounts) so they're removed even inside other spans.
        for term in policy.customTerms where !term.isEmpty {
            let (replaced, n) = replaceAll(term, in: out, with: policy.token, caseInsensitive: true, literal: true)
            if n > 0 { out = replaced; count += n; if !categories.contains("term") { categories.append("term") } }
        }
        if policy.redactEmails {
            let (replaced, n) = replaceRegex(Self.emailPattern, in: out, with: policy.token)
            if n > 0 { out = replaced; count += n; categories.append("email") }
        }
        if policy.redactPhones {
            let (replaced, n) = replaceRegex(Self.phonePattern, in: out, with: policy.token)
            if n > 0 { out = replaced; count += n; categories.append("phone") }
        }
        return Result(redactedText: out, redactionCount: count, categories: categories)
    }

    // MARK: - Helpers

    nonisolated func replaceRegex(_ pattern: String, in s: String, with token: String) -> (String, Int) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return (s, 0) }
        let ns = NSMutableString(string: s)
        let n = re.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: token)
        return (ns as String, n)
    }

    nonisolated func replaceAll(_ needle: String, in s: String, with token: String,
                                caseInsensitive: Bool, literal: Bool) -> (String, Int) {
        var count = 0
        var result = s
        let opts: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        while let r = result.range(of: needle, options: opts) {
            result.replaceSubrange(r, with: token)
            count += 1
            if count > 10_000 { break }  // safety
        }
        return (result, count)
    }
}
