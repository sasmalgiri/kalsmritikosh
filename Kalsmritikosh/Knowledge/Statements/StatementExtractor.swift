//
//  StatementExtractor.swift
//  Kalsmritikosh
//
//  A5 extraction — attributed statements ("Alice confirmed that the shipment
//  left on Monday"). These become source-ASSERTED assertions: the ledger
//  records WHO claimed WHAT, with the verbatim quote and the source that
//  carries it, WITHOUT adjudicating whether the claim is true. This is the
//  data a future testimony-contradiction detector needs, and it's useful on its
//  own ("what did X say about Y?"). Deterministic regex over block text — no
//  model, and it never invents: a statement is emitted only when an explicit
//  attribution verb ties a named speaker to a clause.
//

import Foundation

public struct StatementExtractor: Sendable {

    public nonisolated init() {}

    public struct Statement: Sendable, Hashable {
        public let speaker: String
        public let verb: String          // said / stated / confirmed / denied / …
        public let claim: String         // the attributed clause (trimmed)
    }

    // Speaker (1-4 capitalized words) + attribution verb + optional "that" +
    // the clause up to sentence end. Verbs chosen to be genuine attributions,
    // not narration ("went", "arrived").
    private static let regex = try? NSRegularExpression(
        pattern: #"\b([A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,3})\s+(said|stated|claimed|wrote|testified|reported|confirmed|denied|alleged|asserted|acknowledged|admitted)\s+(?:that\s+)?([^.!?\n]{8,240})"#,
        options: []
    )

    /// The attributed statements in a block of text, in order. Capped to guard
    /// against a pathological input flooding the ledger.
    public func statements(in text: String, limit: Int = 20) -> [Statement] {
        guard let rx = Self.regex else { return [] }
        let ns = text as NSString
        var out: [Statement] = []
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 4 {
            let speaker = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let verb = ns.substring(with: m.range(at: 2)).lowercased()
            let claim = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip attributions whose "speaker" is a sentence-start common word
            // (e.g. "He", "She", "They", "It") — those aren't named sources.
            guard !Self.pronouns.contains(speaker.lowercased()), claim.count >= 8 else { continue }
            out.append(Statement(speaker: speaker, verb: verb, claim: claim))
            if out.count >= limit { break }
        }
        return out
    }

    private static let pronouns: Set<String> = ["he", "she", "they", "it", "we", "i", "you", "the", "this", "that", "there"]
}
