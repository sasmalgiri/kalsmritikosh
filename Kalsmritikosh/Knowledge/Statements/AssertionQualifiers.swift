//
//  AssertionQualifiers.swift
//  Kalsmritikosh
//
//  Smart-map S2 / SRC-03 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05) — the qualifications that
//  decide what a sentence actually asserts: who says it (speaker, reported speech), whether it is negated, how
//  certain it is, whether it is proposed or future rather than done, whether it is conditional, and its date as
//  written. Deterministic word rules over the text — no model.
//
//  `check(quote:in:)` answers the truncation question: when quoted words are cut from a longer source sentence,
//  which of the sentence's qualifiers did the cut leave out? "intact on arrival" cut from "The courier said that the
//  seal was not intact on arrival" drops both the negation and the attribution; the full sentence and the dropped
//  qualifiers then travel with the quote, so the truncated words never read as the opposite of the source.
//

import Foundation
import os

/// A qualifier a sentence can carry.
public nonisolated enum AssertionQualifierKind: String, Codable, Sendable, CaseIterable, Hashable {
    case negation, attribution, uncertainty, proposed, condition, date

    public var label: String {
        switch self {
        case .negation: return "Negation"
        case .attribution: return "Reported speech"
        case .uncertainty: return "Uncertainty"
        case .proposed: return "Proposed or future"
        case .condition: return "Condition"
        case .date: return "Date"
        }
    }

    /// A qualifier whose loss can reverse or change what the words assert (not merely drop a detail).
    public var changesMeaning: Bool { self != .date }
}

/// The qualifiers found in one piece of text.
public nonisolated struct AssertionQualifiers: Codable, Sendable, Hashable {
    /// Who the text says said it ("the courier"), when an attribution names someone.
    public var speaker: String?
    /// The words are reported ("said that", "according to", "claims").
    public var reportedSpeech: Bool = false
    /// The negation words found ("not", "never", "didn't").
    public var negations: [String] = []
    /// The hedge words found ("may", "possibly", "allegedly").
    public var uncertainty: [String] = []
    /// The words marking a proposal, plan or future event ("will", "plans to", "proposed").
    public var proposed: [String] = []
    /// The words marking a condition ("if", "unless", "only if").
    public var conditions: [String] = []
    /// The date as the text writes it.
    public var dateText: String?

    public init(speaker: String? = nil, reportedSpeech: Bool = false, negations: [String] = [], uncertainty: [String] = [],
                proposed: [String] = [], conditions: [String] = [], dateText: String? = nil) {
        self.speaker = speaker; self.reportedSpeech = reportedSpeech; self.negations = negations; self.uncertainty = uncertainty
        self.proposed = proposed; self.conditions = conditions; self.dateText = dateText
    }

    public var kinds: Set<AssertionQualifierKind> {
        var out = Set<AssertionQualifierKind>()
        if !negations.isEmpty { out.insert(.negation) }
        if reportedSpeech { out.insert(.attribution) }
        if !uncertainty.isEmpty { out.insert(.uncertainty) }
        if !proposed.isEmpty { out.insert(.proposed) }
        if !conditions.isEmpty { out.insert(.condition) }
        if dateText != nil { out.insert(.date) }
        return out
    }
    public var isEmpty: Bool { kinds.isEmpty }

    /// The words that mark `kind` in this text, for a plain line.
    public func words(_ kind: AssertionQualifierKind) -> [String] {
        switch kind {
        case .negation: return negations
        case .attribution: return speaker.map { [$0] } ?? (reportedSpeech ? ["reported speech"] : [])
        case .uncertainty: return uncertainty
        case .proposed: return proposed
        case .condition: return conditions
        case .date: return dateText.map { [$0] } ?? []
        }
    }
}

/// What a truncated quote kept and left out of its source sentence.
public nonisolated struct QuoteContextCheck: Codable, Sendable, Hashable {
    /// The full source sentence(s) the quoted words were cut from; nil when the words were not found in the source.
    public let sentence: String?
    /// The qualifiers of the full sentence (of the quote alone when the sentence is unknown).
    public let qualifiers: AssertionQualifiers
    /// Qualifiers the sentence carries that the quoted words leave out, in a fixed order.
    public let dropped: [AssertionQualifierKind]

    public init(sentence: String?, qualifiers: AssertionQualifiers, dropped: [AssertionQualifierKind]) {
        self.sentence = sentence; self.qualifiers = qualifiers; self.dropped = dropped
    }

    /// The cut left out something that changes what the words assert (negation, attribution, uncertainty, a plan, a condition).
    public var changesMeaning: Bool { dropped.contains { $0.changesMeaning } }
    /// The quote is a shorter part of its sentence (the sentence is kept only when it is longer than the quote).
    public var isTruncated: Bool { sentence != nil }

    /// Plain lines that travel with the quote.
    public var lines: [String] {
        var out: [String] = []
        for kind in dropped {
            let words = qualifiers.words(kind).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            switch kind {
            case .negation: out.append("Source sentence is negated (\(words)) — the quoted words leave it out")
            case .attribution: out.append("Source sentence is reported speech" + (qualifiers.speaker.map { " by \($0)" } ?? "") + " — the quoted words leave the attribution out")
            case .uncertainty: out.append("Source sentence is uncertain (\(words)) — the quoted words leave it out")
            case .proposed: out.append("Source sentence is a plan or future event (\(words)) — the quoted words leave it out")
            case .condition: out.append("Source sentence is conditional (\(words)) — the quoted words leave it out")
            case .date: out.append("Source sentence is dated \(words)")
            }
        }
        if !dropped.isEmpty, let sentence { out.append("Full sentence: \u{201C}\(sentence)\u{201D}") }
        return out
    }
}

public nonisolated enum AssertionQualifierDetector {

    static let negationPattern = #"\b(not|never|none|nothing|nobody|neither|nor|without|cannot|no longer)\b|\b[a-z]+n't\b|\bno\b(?!\.?\s*\d)"#
    static let attributionPattern = #"\b(said|says|stated|told|tells|claimed|claims that|alleged|alleges|reported that|according to|asserted|asserts|wrote that|writes that|testified|testifies|denied|denies|insisted|insists|believes|believed|recalled|recalls|admitted|admits)\b"#
    static let uncertaintyPattern = #"\b(may|might|could|possibly|perhaps|probably|likely|unlikely|apparently|appears?|appeared|seems?|seemed|allegedly|reportedly|approximately|roughly|estimated|suspected|unconfirmed|unclear|uncertain|not sure|believed to)\b"#
    static let proposedPattern = #"\b(will|shall|going to|plans? to|planned|planning|intends? to|intended|proposed|proposes|propose|scheduled|expected to|would|to be (?:paid|delivered|signed|sent|made))\b"#
    static let conditionPattern = #"\b(if|unless|only if|provided that|subject to|on condition that|in case|assuming)\b"#

    /// The qualifiers of `text`.
    public static func detect(_ text: String) -> AssertionQualifiers {
        let lower = text.lowercased()
        var q = AssertionQualifiers()
        q.negations = matches(negationPattern, in: lower)
        let attributions = matchRanges(attributionPattern, in: lower)
        q.reportedSpeech = !attributions.isEmpty
        if let first = attributions.first { q.speaker = speaker(in: text, lower: lower, attribution: first) }
        q.uncertainty = matches(uncertaintyPattern, in: lower)
        q.proposed = matches(proposedPattern, in: lower)
        q.conditions = matches(conditionPattern, in: lower)
        q.dateText = dateText(in: text)
        return q
    }

    /// Which qualifiers of the source sentence(s) the quoted words keep. The sentence is found by the quote's place
    /// in `source` (whitespace, quotation marks and dashes normalised, case ignored); a quote not found in `source`
    /// is judged on its own words (no sentence, nothing dropped).
    public static func check(quote: String, in source: String) -> QuoteContextCheck {
        let q = normalise(quote).trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"'"))
        let s = normalise(source)
        guard !q.isEmpty, let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return QuoteContextCheck(sentence: nil, qualifiers: detect(quote), dropped: [])
        }
        let sentence = String(s[sentenceRange(in: s, around: r)]).trimmingCharacters(in: .whitespacesAndNewlines)
        let full = detect(sentence)
        let kept = detect(String(s[r]))
        var dropped = AssertionQualifierKind.allCases.filter { full.kinds.contains($0) && !kept.kinds.contains($0) }
        // A negation inside the quote that the sentence repeats elsewhere is kept; one the sentence has in addition
        // (more negation words than the quote holds) is dropped.
        if !dropped.contains(.negation), full.negations.count > kept.negations.count { dropped.insert(.negation, at: 0) }
        dropped = AssertionQualifierKind.allCases.filter { dropped.contains($0) }
        let edges = CharacterSet(charactersIn: " .,;:!?\"'")
        let whole = sentence.trimmingCharacters(in: edges).caseInsensitiveCompare(String(s[r]).trimmingCharacters(in: edges)) == .orderedSame
        return QuoteContextCheck(sentence: whole ? nil : sentence, qualifiers: full, dropped: whole ? [] : dropped)
    }

    // MARK: Pieces

    static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "[\u{201C}\u{201D}\u{2033}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2018}\u{2019}\u{2032}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2013}\u{2014}]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The sentence(s) around `r`: back to the previous sentence end (or the start), forward to the next (or the end).
    static func sentenceRange(in s: String, around r: Range<String.Index>) -> Range<String.Index> {
        var start = r.lowerBound
        while start > s.startIndex {
            let prev = s.index(before: start)
            if ".!?\n".contains(s[prev]), start < s.endIndex, s[start] == " " || s[start] == "\n" { break }
            start = prev
        }
        var end = r.upperBound
        while end < s.endIndex {
            let c = s[end]
            end = s.index(after: end)
            if ".!?\n".contains(c), end == s.endIndex || s[end] == " " || s[end] == "\n" { break }
        }
        return start..<end
    }

    static func matchRanges(_ pattern: String, in lower: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            KalsmritikoshLog.knowledge.error("Qualifier pattern did not compile")
            return []
        }
        return re.matches(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)).map(\.range)
    }

    static func matches(_ pattern: String, in lower: String) -> [String] {
        let ns = lower as NSString
        var seen = Set<String>()
        return matchRanges(pattern, in: lower).map { ns.substring(with: $0) }.filter { seen.insert($0).inserted }
    }

    /// The words before the first attribution verb (up to six, back to a clause break), or after "according to".
    static func speaker(in text: String, lower: String, attribution: NSRange) -> String? {
        let ns = text as NSString
        let verb = (lower as NSString).substring(with: attribution)
        if verb == "according to" {
            let tail = ns.substring(from: attribution.location + attribution.length)
            let name = tail.split(whereSeparator: { ",;:.".contains($0) }).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            return name.flatMap { $0.isEmpty ? nil : String($0.split(separator: " ").prefix(6).joined(separator: " ")) }
        }
        let head = ns.substring(to: attribution.location)
        let clause = head.split(whereSeparator: { ",;:.!?\n".contains($0) }).last.map(String.init) ?? head
        let words = clause.split(separator: " ").suffix(6)
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !["it", "this", "that", "which"].contains(name.lowercased()) else { return nil }
        return name
    }

    /// The first written date with a year ("3 March 2026", "2026-03-03"), as written.
    static func dateText(in text: String) -> String? {
        let ns = text as NSString
        if let re = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#),
           let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range)
        }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let written = ns.substring(with: m.range)
            if written.range(of: #"\d{4}"#, options: .regularExpression) != nil { return written }
        }
        return nil
    }
}
