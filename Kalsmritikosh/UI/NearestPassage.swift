//
//  NearestPassage.swift
//  Kalsmritikosh
//
//  §1.3 (owner decision 2026-09-27) — the closest-match line on a "not found"
//  answer. When the archive lane cannot ground an answer, the Ask surface shows
//  the ONE passage in the user's documents that shares the most informative
//  terms with the question, labelled plainly as NOT an answer, openable at the
//  passage. It lives in the Ask surface (like the general-knowledge block),
//  never in the brain: the refusal text, the evidence gate, the ledger and the
//  sealed answers are untouched.
//
//  Honest by construction: a passage qualifies only when it shares at least
//  two informative question terms (one when the question has only one), so a
//  lone common word never masquerades as a near miss. No qualifier → no line.
//

import Foundation

public struct NearestPassage: Sendable, Equatable {
    public let objectID: UUID
    public let quote: String
    /// The question terms the passage shares — shown so the user can judge
    /// the closeness themselves.
    public let sharedTerms: [String]
}

public enum NearestPassageFinder {
    static let maxQuote = 240

    /// Informative question terms — the same rule the keyword index uses
    /// (identifier-shaped tokens always; alpha tokens ≥2 chars, not stopwords).
    public nonisolated static func terms(in question: String) -> [String] {
        var seen = Set<String>()
        return question.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { tok in
                if tok.contains(where: \.isNumber) { return true }
                return tok.count >= 2 && !FTSQuerySanitizer.stopwords.contains(tok)
            }
            .filter { seen.insert($0).inserted }
    }

    /// Pick the closest passage among keyword-ranked candidates (best rank
    /// first). The winner shares the most question terms; ties keep rank order.
    public nonisolated static func pick(question: String,
                                        candidates: [(objectID: UUID, text: String)]) -> NearestPassage? {
        let wanted = terms(in: question)
        guard !wanted.isEmpty else { return nil }
        let floor = min(2, wanted.count)
        var best: (index: Int, shared: [String])? = nil
        for (i, c) in candidates.enumerated() {
            let words = Set(c.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let shared = wanted.filter { words.contains($0) }
            guard shared.count >= floor else { continue }
            if best == nil || shared.count > best!.shared.count { best = (i, shared) }
        }
        guard let best else { return nil }
        let winner = candidates[best.index]
        let quote = window(in: winner.text, around: best.shared)
        guard !quote.isEmpty else { return nil }
        return NearestPassage(objectID: winner.objectID, quote: quote, sharedTerms: best.shared)
    }

    /// The sentence holding the first shared term, whitespace-collapsed and
    /// capped; an ellipsis marks any cut so the quote never pretends to be whole.
    nonisolated static func window(in text: String, around shared: [String]) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let lower = flat.lowercased()
        var anchor = lower.startIndex
        for term in shared {
            if let r = firstWholeWord(term, in: lower) { anchor = r.lowerBound; break }
        }
        let offset = lower.distance(from: lower.startIndex, to: anchor)
        let chars = Array(flat)
        var start = offset
        while start > 0, offset - start < maxQuote / 2, !".!?".contains(chars[start - 1]) { start -= 1 }
        var end = offset
        while end < chars.count, end - start < maxQuote, !".!?".contains(chars[end]) { end += 1 }
        if end < chars.count, ".!?".contains(chars[end]) { end += 1 }
        var quote = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > 0, !".!?".contains(chars[start - 1]) { quote = "…" + quote }
        if end < chars.count, !".!?".contains(chars[end - 1]) { quote += "…" }
        return quote
    }

    private nonisolated static func firstWholeWord(_ term: String, in text: String) -> Range<String.Index>? {
        var from = text.startIndex
        while let r = text.range(of: term, range: from..<text.endIndex) {
            let beforeOK = r.lowerBound == text.startIndex
                || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber)
            let afterOK = r.upperBound == text.endIndex
                || !(text[r.upperBound].isLetter || text[r.upperBound].isNumber)
            if beforeOK && afterOK { return r }
            from = text.index(after: r.lowerBound)
        }
        return nil
    }
}
