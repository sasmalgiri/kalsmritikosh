//
//  CaseReasoning.swift
//  Kalsmritikosh
//
//  Smart-map S5 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §11 REASON; schema v181): the scaffolding
//  around disagreement, over the ONE case file repository and its savepoint. Contradiction DETECTION and AI reading are
//  not changed here; this file only records and presents what a person needs to examine them.
//
//  • Attribution (REASON-01): who states what, firsthand or reported, when it applies, from which source. A name merely
//    near the words never becomes the speaker; a speaker needs a basis (a speech verb, "according to", the interview's
//    speaker, the document's author or the investigator's recorded decision).
//  • Evidence relation (REASON-02): supports / challenges / mentions / qualifies / relevance not assessed. Only a verified
//    "supports" row is documentary support.
//  • Comparison (REASON-03) and difference checks (REASON-04): both passages with their surrounding words, subject,
//    values, units and dates, and the version each was read from; cautions for negation/denial, quoted speakers, differing
//    definitions, other times, other currencies and corrections — shown beside the item, never deciding it.
//  • Source dependence (REASON-05): copied and derivative wording between documents, and the person's independence review.
//    Support is counted by evidential origin; dependence is not truth, and independence stays "not assessed" until reviewed.
//  • Follow-up work (REASON-07): a contradiction child action with the exact question, the result needed and both accounts;
//    its outcome may be inconclusive.
//  • Decision inputs (REASON-10): a question's decision frozen with its evidence rows, alternatives and contrary material.
//  • Proposal decisions (REASON-12): rejected or deferred proposals are not offered again unless their content changed.
//  • Alternatives (REASON-08 on the case side): competing explanations side by side with their material for and against,
//    in the order they were recorded — never counted, ranked or voted.
//  Nothing here calls a model or the network.
//

import Foundation
import os

// MARK: - REASON-01 Attribution

public nonisolated enum CaseAttributionMode: String, Sendable, Codable, CaseIterable {
    case firsthand, reported, notStated, documentAuthor, unattributed
    public var label: String {
        switch self {
        case .firsthand: return "Firsthand — the speaker describes what they perceived"
        case .reported: return "Reported — the speaker passes on what someone else said"
        case .notStated: return "Stated — whether firsthand or reported is not said"
        case .documentAuthor: return "The document's author's own statement"
        case .unattributed: return "Not attributed — no speaker can be named on the words alone"
        }
    }
}

public nonisolated enum CaseAttributionBasis: String, Sendable, Codable, CaseIterable {
    case speechVerb, accordingTo, interviewSpeaker, documentAuthor, investigator, none
    public var label: String {
        switch self {
        case .speechVerb: return "a named speaker with a speech verb"
        case .accordingTo: return "“according to” a named person"
        case .interviewSpeaker: return "the interview's recorded speaker"
        case .documentAuthor: return "the document's recorded author"
        case .investigator: return "the investigator's recorded decision"
        case .none: return "no basis"
        }
    }
}

/// What the rule-based reader found in one sentence. No model is used; it never guesses a speaker.
public nonisolated struct CaseAttributionReading: Sendable, Equatable {
    public var quote: String
    public var claim: String
    public var speaker: String?
    public var mode: CaseAttributionMode
    public var reportedFrom: String?
    public var basis: CaseAttributionBasis
    public var basisDetail: String?
    /// The words saying when the statement applies ("on 3 March"), as written; never converted to a date here.
    public var appliesText: String?
}

public nonisolated struct CaseAttribution: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sourceVersionID: UUID?
    public let blockID: UUID?
    public let quote: String
    public let claim: String
    public let speaker: String?
    public let casePersonID: UUID?
    public let mode: CaseAttributionMode
    public let reportedFrom: String?
    public let basis: CaseAttributionBasis
    public let basisDetail: String?
    public let appliesFrom: Date?
    public let appliesTo: Date?
    public let appliesText: String?
    public let byRule: Bool
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }

    /// "Ravi Kumar (reported, from Meena): the van left at nine — basis: a named speaker with a speech verb".
    public var line: String {
        guard let speaker else { return "Not attributed: “\(quote)”. No speaker is named on these words alone." }
        var s = "\(speaker) — \(mode.label)"
        if let r = reportedFrom { s += " (from \(r))" }
        s += ": “\(claim)”"
        if let t = appliesText { s += " — applies: \(t)" }
        s += ". Basis: \(basis.label)" + (basisDetail.map { " (\($0))" } ?? "") + (byRule ? "; read by rule, not reviewed" : "") + "."
        return s
    }
}

public nonisolated enum CaseAttributionReader {
    public static let ruleVersion = 1
    private static let name = #"([A-Z][A-Za-z.'-]+(?:\s+[A-Z][A-Za-z.'-]+){0,3})"#
    private static let accordingTo = try? NSRegularExpression(pattern: #"^\s*According to "# + name + #",\s*(.{8,})$"#, options: [])
    private static let reportedFromRx = try? NSRegularExpression(
        pattern: name + #"\s+(?:told|informed)\s+(?:him|her|them|me|us)\b|\b(?:heard from|was told by|were told by|learned from)\s+"# + name, options: [])
    private static let reportedWords = try? NSRegularExpression(pattern: #"\b(told (?:him|her|them|me|us)|was told|were told|heard from|heard that|learned from|according to|informed (?:him|her|them|me|us))\b"#, options: [.caseInsensitive])
    private static let perception = try? NSRegularExpression(pattern: #"\b(?:I|he|she|they|we)\s+(?:personally\s+)?(?:saw|heard|watched|witnessed|noticed|observed|counted|was present|were present|signed|paid|received)\b"#, options: [.caseInsensitive])
    private static let when = try? NSRegularExpression(
        pattern: #"\b(?:on|at|in|during|before|after|since|until|by)\s+(?:the\s+)?(?:\d{1,2}(?:st|nd|rd|th)?\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)(?:\s+\d{4})?|(?:January|February|March|April|May|June|July|August|September|October|November|December)(?:\s+\d{1,2}(?:,\s*\d{4})?|\s+\d{4})?|\d{4}|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|\d{1,2}(?::\d{2})?\s*(?:am|pm)|(?:morning|afternoon|evening|night)(?:\s+of\s+[^,.;]{3,30})?)"#,
        options: [])

    /// Read one sentence. A speaker is named only by an explicit attribution in the sentence itself; capitalised names
    /// elsewhere in it, or in nearby sentences, never become the speaker.
    public static func read(_ sentence: String) -> CaseAttributionReading {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = s as NSString
        var r = CaseAttributionReading(quote: s, claim: s, speaker: nil, mode: .unattributed, reportedFrom: nil, basis: .none, basisDetail: nil, appliesText: nil)
        if let rx = accordingTo, let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 3 {
            r.speaker = ns.substring(with: m.range(at: 1))
            r.claim = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: " .")).trimmingCharacters(in: .whitespaces)
            r.basis = .accordingTo
            r.basisDetail = "“According to \(r.speaker ?? "")”"
        } else if let st = StatementExtractor().statements(in: s, limit: 1).first {
            r.speaker = st.speaker
            r.claim = st.claim
            r.basis = .speechVerb
            r.basisDetail = "“\(st.speaker) \(st.verb)”"
        }
        guard r.speaker != nil else { return r }
        r.mode = mode(of: r.claim)
        if r.mode == .reported { r.reportedFrom = reportedFrom(r.claim) }
        r.appliesText = appliesText(r.claim)
        return r
    }

    static func mode(of claim: String) -> CaseAttributionMode {
        let range = NSRange(location: 0, length: (claim as NSString).length)
        if reportedWords?.firstMatch(in: claim, range: range) != nil { return .reported }
        if StatementExtractor().statements(in: claim, limit: 1).first != nil { return .reported }
        if perception?.firstMatch(in: claim, range: range) != nil { return .firsthand }
        return .notStated
    }

    static func reportedFrom(_ claim: String) -> String? {
        let ns = claim as NSString
        guard let m = reportedFromRx?.firstMatch(in: claim, range: NSRange(location: 0, length: ns.length)) else {
            return StatementExtractor().statements(in: claim, limit: 1).first?.speaker
        }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound { return ns.substring(with: m.range(at: i)) }
        return nil
    }

    static func appliesText(_ claim: String) -> String? {
        let ns = claim as NSString
        guard let m = when?.firstMatch(in: claim, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    /// The sentences of a passage (the reader works sentence by sentence, so a name in one sentence never attaches to
    /// another).
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 8 { out.append(t) }
        }
        return out
    }
}

public nonisolated enum CaseReasoningError: Error, Equatable, LocalizedError {
    case speakerNeedsBasis
    case investigatorBasisNeedsReason
    case notADecidedState
    case followUpDecided
    case outcomeNeedsNote
    case badPeriod
    public var errorDescription: String? {
        switch self {
        case .speakerNeedsBasis: return "A speaker is recorded only with the basis that attributes the words to them. A name near the words is not enough."
        case .investigatorBasisNeedsReason: return "Say why you attribute these words to this speaker."
        case .notADecidedState: return "Record the follow-up's outcome as one of the listed results."
        case .followUpDecided: return "This follow-up's outcome is already recorded and is not changed."
        case .outcomeNeedsNote: return "Say what the follow-up found, even when it was inconclusive or not obtained."
        case .badPeriod: return "The period ends before it starts."
        }
    }
}

// MARK: - REASON-02 Evidence relation

/// How an evidence-grid row relates to its question. The stored stance stays as it was; the relation adds the
/// distinctions a stance cannot hold.
public nonisolated enum CaseEvidenceRelation: String, Sendable, Codable, CaseIterable, Identifiable {
    case supports, challenges, mentions, qualifies, unassessed
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .supports: return "Supports"
        case .challenges: return "Challenges"
        case .mentions: return "Mentions — no stance for or against"
        case .qualifies: return "Qualifies — limits or conditions it"
        case .unassessed: return "Linked — relevance not assessed"
        }
    }
    /// The stance column a relation is stored with (only supports and challenges carry one).
    public var stance: GridStance {
        switch self {
        case .supports: return .supports
        case .challenges: return .contradicts
        case .mentions, .qualifies, .unassessed: return .neutral
        }
    }
    /// Only a supporting row can be support at all — and only a verified one is documentary (CaseFileRepository.decide).
    public var canSupport: Bool { self == .supports }
    /// Contrary material: what challenges or limits the point it is linked to.
    public var isContrary: Bool { self == .challenges || self == .qualifies }

    /// The relation of a stored row: its recorded relation, or (rows before v181) the one its stance implies — a neutral
    /// row did not say whether it mentions the question or was never assessed, so it is "relevance not assessed".
    public static func of(stance: GridStance, stored: String?) -> CaseEvidenceRelation {
        if let s = stored, let r = CaseEvidenceRelation(rawValue: s) { return r }
        switch stance {
        case .supports: return .supports
        case .contradicts: return .challenges
        case .neutral: return .unassessed
        }
    }
}

// MARK: - REASON-03 / REASON-04 Comparison and difference checks

/// Why an apparent contradiction may be a difference. Shown beside the pair; it never changes or hides the item.
public nonisolated enum CaseConflictCaution: String, Sendable, Codable, CaseIterable {
    case negation, quotedSpeaker, definition, otherTime, otherCurrency, correction, sameNameOnly
    public var label: String {
        switch self {
        case .negation: return "One account denies or negates — a disagreement between accounts, not two values"
        case .quotedSpeaker: return "Words of a quoted speaker, not the document's own statement"
        case .definition: return "The two may use different definitions (gross/net, including/excluding, “defined as”)"
        case .otherTime: return "The accounts carry different dates — possibly a change over time"
        case .otherCurrency: return "Different currencies — the amounts are not compared"
        case .correction: return "One account states a correction or amendment"
        case .sameNameOnly: return "The accounts share only a surname or first name — possibly different people"
        }
    }
}

public nonisolated enum CaseDifferenceCheck {
    private static func has(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    static let negation = #"\b(not|never|no|none|nobody|denied|denies|deny|didn't|did not|wasn't|was not|weren't|isn't|hasn't|haven't|refused|refutes|false)\b"#
    static let quoted = #"[“"«]|\b(said|stated|told|claimed|according to|alleged|wrote)\b"#
    static let definition = #"\b(defined as|means|refers to|for the purposes of|as used in|gross|net|including|excluding|exclusive of|inclusive of)\b"#
    static let correction = #"\b(amended|corrected|correction|revised|revision|erratum|supersedes?|replaces?|withdrawn)\b"#
    static let currencies: [(String, String)] = [("₹", "INR"), ("Rs", "INR"), ("INR", "INR"), ("$", "USD"), ("USD", "USD"), ("€", "EUR"), ("EUR", "EUR"), ("£", "GBP"), ("GBP", "GBP")]

    static func currency(_ s: String) -> Set<String> {
        Set(currencies.filter { c in c.0.count == 1 ? s.contains(c.0) : has(#"\b"# + NSRegularExpression.escapedPattern(for: c.0) + #"\.?\b"#, s) }.map(\.1))
    }
    static func dates(_ s: String) -> [String] {
        let rx = #"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?(?:\s+\d{4})?\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(?:,\s*\d{4})?\b|\b\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}\b|\b\d{4}-\d{2}-\d{2}\b"#
        guard let re = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }

    /// The cautions for a pair of accounts. Each applies to the pair as quoted; none decides it.
    public static func cautions(_ a: String, _ b: String, kind: Contradiction.Kind? = nil) -> [CaseConflictCaution] {
        var out: [CaseConflictCaution] = []
        if has(negation, a) != has(negation, b) { out.append(.negation) }
        if has(quoted, a) || has(quoted, b) { out.append(.quotedSpeaker) }
        if has(definition, a) || has(definition, b) { out.append(.definition) }
        if kind != .date, kind != .sequence {
            let da = Set(dates(a)), db = Set(dates(b))
            if !da.isEmpty, !db.isEmpty, da != db { out.append(.otherTime) }
        }
        let ca = currency(a), cb = currency(b)
        if !ca.isEmpty, !cb.isEmpty, ca.isDisjoint(with: cb) { out.append(.otherCurrency) }
        if has(correction, a) || has(correction, b) { out.append(.correction) }
        return out
    }
}

/// One side of a comparison as the investigator examines it: the quoted words in their passage, and what they say.
public nonisolated struct CaseConflictSide: Sendable, Equatable {
    public let objectID: UUID?
    public let sourceVersionID: UUID?
    public let documentName: String?
    public let quote: String
    /// The words before and after the quote in the version's text (nil: the quote was not found there).
    public let before: String?
    public let after: String?
    public let foundInVersion: Bool
    public let values: [String]
    public let dates: [String]
    public let currencies: [String]
    /// "version 3F2A…, the current version" / "version …, not the current version (current is …)" / "no version".
    public let versionLabel: String
}

public nonisolated struct CaseConflictComparison: Sendable, Equatable {
    public let contradictionID: UUID
    public let kind: Contradiction.Kind
    public let subject: String
    public let a: CaseConflictSide
    public let b: CaseConflictSide
    public let cautions: [CaseConflictCaution]
    /// Both sides as plain lines, for the inspector, the report and a copy.
    public var lines: [String] {
        func side(_ n: String, _ s: CaseConflictSide) -> String {
            var l = "\(n): \(s.documentName ?? "a document"), \(s.versionLabel) — "
            l += s.foundInVersion ? "…\(s.before ?? "")[\(s.quote)]\(s.after ?? "")…" : "“\(s.quote)” (these words were not found in that version's text)"
            if !s.values.isEmpty { l += " · values: " + s.values.joined(separator: ", ") }
            if !s.dates.isEmpty { l += " · dates: " + s.dates.joined(separator: ", ") }
            return l
        }
        var out = ["\(kind.displayName) — \(subject)", side("Account A", a), side("Account B", b)]
        out += cautions.map { "Check: \($0.label)." }
        out.append("Both accounts are kept as they are; a decision records what you concluded and why.")
        return out
    }
}

public nonisolated enum CaseConflictComparer {
    static let contextLength = 220

    static func normalized(_ s: String) -> String {
        s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The words around `quote` in `text` (whitespace-insensitive), or nil when the quote is not there.
    static func context(of quote: String, in text: String) -> (before: String, after: String)? {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let q = quote.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !q.isEmpty, words.count >= q.count else { return nil }
        let lw = words.map { $0.lowercased() }, lq = q.map { $0.lowercased() }
        for i in 0...(words.count - q.count) where Array(lw[i..<(i + q.count)]) == lq {
            let before = words[..<i].joined(separator: " "), after = words[(i + q.count)...].joined(separator: " ")
            return (before.count > contextLength ? String(before.suffix(contextLength)) + " " : (before.isEmpty ? "" : before + " "),
                    after.count > contextLength ? " " + String(after.prefix(contextLength)) : (after.isEmpty ? "" : " " + after))
        }
        return nil
    }

    static func values(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(?:[₹$€£]\s?|\b(?:Rs\.?|INR|USD|EUR|GBP)\s?)?\d[\d,]*(?:\.\d+)?(?:\s?(?:%|kg|g|km|m|cm|mm|l|ml|days?|hours?|minutes?|years?|months?|weeks?|dollars|rupees|euros|pounds|lakh|crore))?"#,
                                             options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
            .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
    }

    /// The subject a stored contradiction names ("Amount — The invoice, total: …" → "The invoice, total").
    static func subject(_ c: Contradiction) -> String {
        let d = c.description
        let afterKind = d.range(of: " — ").map { String(d[$0.upperBound...]) } ?? d
        return afterKind.components(separatedBy: ": ").first?.trimmingCharacters(in: .whitespaces) ?? afterKind
    }

    public static func side(quote: String, objectID: UUID?, version: UUID?, current: UUID?, name: String?, text: String?) -> CaseConflictSide {
        let ctx = text.flatMap { context(of: quote, in: $0) }
        let label: String
        if let v = version {
            let short = String(v.uuidString.prefix(8))
            if let current, current != v { label = "version \(short), not the current version (current: \(current.uuidString.prefix(8)))" }
            else if current == nil { label = "version \(short); no current version resolves" }
            else { label = "version \(short), the current version" }
        } else { label = "no recorded version" }
        return CaseConflictSide(objectID: objectID, sourceVersionID: version, documentName: name, quote: quote, before: ctx?.before, after: ctx?.after,
                                foundInVersion: ctx != nil, values: values(quote), dates: CaseDifferenceCheck.dates(quote),
                                currencies: CaseDifferenceCheck.currency(quote).sorted(), versionLabel: label)
    }

    public static func compare(_ c: Contradiction, a: CaseConflictSide, b: CaseConflictSide) -> CaseConflictComparison {
        CaseConflictComparison(contradictionID: c.id, kind: c.kind, subject: subject(c), a: a, b: b,
                               cautions: CaseDifferenceCheck.cautions(c.claimA, c.claimB, kind: c.kind))
    }
}

// MARK: - REASON-05 Copied and derivative wording; independence review

public nonisolated struct CaseDerivedTextPair: Sendable, Equatable, Hashable {
    /// The two logical sources (sorted).
    public let a: UUID
    public let b: UUID
    /// Share of the shorter document's six-word sequences found in the other (0…1).
    public let shared: Double
    public var basis: String {
        shared >= 0.9 ? "copied text (\(Int((shared * 100).rounded()))% of the shorter document's wording)"
                      : "shared wording — one may derive from the other or both from one origin (\(Int((shared * 100).rounded()))%)"
    }
}

public nonisolated enum CaseDependenceJudgment: String, Sendable, Codable, CaseIterable {
    case dependent, independent, unassessed
    public var label: String {
        switch self {
        case .dependent: return "Dependent — one origin (reviewed)"
        case .independent: return "Independent (reviewed)"
        case .unassessed: return "Independence not assessed"
        }
    }
}

public nonisolated struct CaseDependenceReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sourceA: UUID
    public let sourceB: UUID
    public let judgment: CaseDependenceJudgment
    public let detectedBasis: String?
    public let rationale: String
    public let reviewedBy: String
    public let reviewedAt: Date
}

public nonisolated enum CaseDerivativeText {
    public static let gram = 6
    public static let threshold = 0.5

    static func shingles(_ text: String) -> Set<Int> {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard words.count >= gram else { return words.isEmpty ? [] : [words.joined(separator: " ").hashValue] }
        var out = Set<Int>()
        for i in 0...(words.count - gram) { out.insert(words[i..<(i + gram)].joined(separator: " ").hashValue) }
        return out
    }

    /// Pairs of documents sharing much of their wording. The comparison is by wording only: it says nothing about which
    /// is right, and a pair below the threshold is not thereby independent.
    public static func detect(_ docs: [(source: UUID, text: String)], threshold: Double = threshold) -> [CaseDerivedTextPair] {
        let sh = docs.map { ($0.source, shingles($0.text)) }
        var out: [CaseDerivedTextPair] = []
        for i in 0..<sh.count {
            for j in (i + 1)..<max(i + 1, sh.count) where sh[i].0 != sh[j].0 {
                let x = sh[i].1, y = sh[j].1
                let smaller = min(x.count, y.count)
                guard smaller > 0 else { continue }
                let shared = Double(x.intersection(y).count) / Double(smaller)
                if shared >= threshold {
                    let (a, b) = sh[i].0.uuidString < sh[j].0.uuidString ? (sh[i].0, sh[j].0) : (sh[j].0, sh[i].0)
                    out.append(CaseDerivedTextPair(a: a, b: b, shared: shared))
                }
            }
        }
        return out
    }
}

/// How much separate support a question's supporting rows carry once copies and derivatives are joined.
public nonisolated struct CaseSupportOrigins: Sendable, Equatable {
    public let supportingRows: Int
    public let documents: Int
    public let origins: Int
    /// Pairs joined because their wording is shared and no person reviewed them as independent.
    public let joinedUnreviewed: [CaseDerivedTextPair]
    /// Pairs a person reviewed as independent (kept apart) or dependent (joined).
    public let reviewedIndependent: Int
    public let reviewedDependent: Int
    public var line: String {
        var s = "\(supportingRows) supporting row\(supportingRows == 1 ? "" : "s") from \(documents) document\(documents == 1 ? "" : "s") rest\(supportingRows == 1 ? "s" : "") on \(origins) evidential origin\(origins == 1 ? "" : "s")"
        if !joinedUnreviewed.isEmpty { s += "; \(joinedUnreviewed.count) pair\(joinedUnreviewed.count == 1 ? "" : "s") share wording and are counted as one origin until reviewed (independence not assessed)" }
        if reviewedIndependent > 0 { s += "; \(reviewedIndependent) pair\(reviewedIndependent == 1 ? "" : "s") reviewed as independent" }
        if reviewedDependent > 0 { s += "; \(reviewedDependent) reviewed as dependent" }
        return s + ". Origins say how many separate sources there are — not whether any of them is true or reliable."
    }

    public static func compute(rows: [(row: UUID, source: UUID, text: String)], reviews: [CaseDependenceReview]) -> CaseSupportOrigins {
        let sources = Array(Set(rows.map(\.source))).sorted { $0.uuidString < $1.uuidString }
        var textBySource: [UUID: String] = [:]
        for r in rows where (textBySource[r.source]?.count ?? 0) < r.text.count { textBySource[r.source] = r.text }
        let pairs = CaseDerivativeText.detect(sources.map { ($0, textBySource[$0] ?? "") })
        var latest: [String: CaseDependenceReview] = [:]
        for r in reviews.sorted(by: { $0.reviewedAt < $1.reviewedAt }) { latest["\(r.sourceA.uuidString)|\(r.sourceB.uuidString)"] = r }
        var parent: [UUID: UUID] = [:]
        func find(_ x: UUID) -> UUID { var r = x; while let p = parent[r], p != r { r = p }; return r }
        func union(_ a: UUID, _ b: UUID) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }
        for s in sources { parent[s] = s }
        var joined: [CaseDerivedTextPair] = []
        var indep = 0, dep = 0
        for p in pairs {
            switch latest["\(p.a.uuidString)|\(p.b.uuidString)"]?.judgment {
            case .independent?: indep += 1
            case .dependent?: dep += 1; union(p.a, p.b)
            default: joined.append(p); union(p.a, p.b)
            }
        }
        for (key, r) in latest where r.judgment == .dependent && !pairs.contains(where: { "\($0.a.uuidString)|\($0.b.uuidString)" == key }) {
            if parent[r.sourceA] != nil, parent[r.sourceB] != nil { dep += 1; union(r.sourceA, r.sourceB) }
        }
        return CaseSupportOrigins(supportingRows: rows.count, documents: sources.count, origins: Set(sources.map(find)).count,
                                  joinedUnreviewed: joined, reviewedIndependent: indep, reviewedDependent: dep)
    }
}

// MARK: - REASON-07 Follow-up work from a contradiction

public nonisolated enum CaseFollowUpOutcome: String, Sendable, Codable, CaseIterable {
    case pending, accountAConfirmed, accountBConfirmed, bothExplained, inconclusive, notObtained
    public var label: String {
        switch self {
        case .pending: return "Waiting for the result"
        case .accountAConfirmed: return "The result supports account A"
        case .accountBConfirmed: return "The result supports account B"
        case .bothExplained: return "Both accounts explained (a real difference)"
        case .inconclusive: return "Inconclusive — the result does not settle it"
        case .notObtained: return "The result could not be obtained"
        }
    }
}

public nonisolated struct CaseConflictFollowUp: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let contradictionID: UUID
    public let taskID: UUID
    public let question: String
    public let neededResult: String
    public let sideA: (object: UUID?, version: UUID?, quote: String)
    public let sideB: (object: UUID?, version: UUID?, quote: String)
    public let outcome: CaseFollowUpOutcome
    public let outcomeNote: String?
    public let outcomeBy: String?
    public let outcomeAt: Date?
    public let createdBy: String
    public let createdAt: Date

    public static func == (l: CaseConflictFollowUp, r: CaseConflictFollowUp) -> Bool {
        l.id == r.id && l.outcome == r.outcome && l.outcomeNote == r.outcomeNote && l.question == r.question
    }
}

// MARK: - REASON-10 Decision inputs

public nonisolated struct CaseDecisionInputs: Identifiable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        public let id: String
        public let relation: String
        public let verification: String?
        public let reference: String
        public let quote: String?
        public let label: String?
    }
    public struct Alternative: Codable, Sendable, Equatable {
        public let id: String
        public let statement: String
        public let status: String
        public let revision: Int
        public let forCount: Int
        public let againstCount: Int
    }
    public let id: UUID
    public let caseID: UUID
    public let allegationID: UUID
    public let disposition: String
    public let rationale: String?
    public let exceptionNote: String?
    public let rows: [Row]
    public let alternatives: [Alternative]
    public let contrary: [Row]
    public let digest: String
    public let decidedBy: String
    public let decidedAt: Date

    /// What another investigator reads to reconstruct the decision at that revision.
    public var lines: [String] {
        var out = ["Decided “\(disposition)” by \(decidedBy) on \(decidedAt.formatted(date: .abbreviated, time: .shortened))" + (rationale.map { ": \($0)" } ?? "") + "."]
        if let e = exceptionNote { out.append("Exception recorded: \(e).") }
        out.append("Evidence rows at the time (\(rows.count)): " + (rows.isEmpty ? "none." : rows.map { "\($0.label ?? $0.reference) — \($0.relation)\($0.verification.map { ", \($0)" } ?? "")" }.joined(separator: "; ") + "."))
        out.append("Contrary or limiting material considered (\(contrary.count)): " + (contrary.isEmpty ? "none linked — absence of contrary material is not proof." : contrary.map { $0.label ?? $0.reference }.joined(separator: "; ") + "."))
        out.append("Alternative explanations on record (\(alternatives.count)): " + (alternatives.isEmpty ? "none recorded." : alternatives.map { "“\($0.statement)” (\($0.status), revision \($0.revision))" }.joined(separator: "; ") + "."))
        out.append("Input digest \(digest.prefix(12)) — a later change to these inputs shows as a different digest.")
        return out
    }
}

// MARK: - REASON-12 Proposal decisions

public nonisolated enum CaseProposalKind: String, Sendable, Codable, CaseIterable {
    case fact, link, gap, reportPoint, followUp, other
}

public nonisolated enum CaseProposalDecision: String, Sendable, Codable, CaseIterable {
    case accepted, rejected, deferred
}

public nonisolated struct CaseProposalVerdict: Sendable, Equatable {
    /// Offer the proposal to the person now.
    public let offer: Bool
    /// Why (always said): never decided; unchanged since rejected/deferred/accepted; changed since, with what changed.
    public let reason: String
}

public nonisolated enum CaseProposalMemory {
    /// Whether to offer a proposal again, from the latest decision on its key and its content now.
    public static func verdict(latest: (decision: CaseProposalDecision, digest: String, text: String?, reason: String?, actor: String, at: Date)?,
                               content: String) -> CaseProposalVerdict {
        guard let latest else { return CaseProposalVerdict(offer: true, reason: "Not decided before.") }
        let day = latest.at.formatted(date: .abbreviated, time: .omitted)
        if latest.digest == CaseFileHash.sha256(content) {
            switch latest.decision {
            case .accepted: return CaseProposalVerdict(offer: false, reason: "Accepted by \(latest.actor) on \(day); unchanged.")
            case .rejected: return CaseProposalVerdict(offer: false, reason: "Rejected by \(latest.actor) on \(day) (\(latest.reason ?? "no reason")); the material is unchanged, so it is not offered again.")
            case .deferred: return CaseProposalVerdict(offer: false, reason: "Deferred by \(latest.actor) on \(day) (\(latest.reason ?? "no reason")); unchanged — it waits where you deferred it.")
            }
        }
        let diff = latest.text.map { CaseReportVersionComparison.wordDiff($0, content) }
        var what = "its content changed since it was \(latest.decision.rawValue) on \(day)"
        if let d = diff {
            if !d.removed.isEmpty { what += "; removed: “\(d.removed.prefix(8).joined(separator: " "))”" }
            if !d.added.isEmpty { what += "; added: “\(d.added.prefix(8).joined(separator: " "))”" }
        }
        return CaseProposalVerdict(offer: true, reason: "Offered again because " + what + ".")
    }
}

// MARK: - Alternatives presented without a vote

public nonisolated struct CaseAlternativeExplanation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let statement: String
    public let status: String
    public let recordedAt: Date
    /// Material cited for and against it, each with its document and note (never summed into a score).
    public let materialFor: [String]
    public let materialAgainst: [String]
}

public nonisolated struct CaseAlternativesView: Sendable, Equatable {
    public let explanations: [CaseAlternativeExplanation]
    public var notice: String {
        "Competing explanations are listed in the order they were recorded, each with what is cited for and against it. The app does not count, rank or vote between them; reliability rates a source, not whether a claim is true."
    }
}

// MARK: - Persistence

extension CaseFileRepository {

    // MARK: Attributions (REASON-01)

    /// Record who states what. A speaker needs a basis; an investigator's attribution needs its reason.
    @discardableResult
    public func recordAttribution(caseID: UUID, _ r: CaseAttributionReading, sourceVersionID: UUID? = nil, blockID: UUID? = nil, casePersonID: UUID? = nil,
                                  appliesFrom: Date? = nil, appliesTo: Date? = nil, byRule: Bool = false, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        _ = try Self.clean(r.quote, "The quoted words")
        if r.speaker != nil, r.basis == .none { throw CaseReasoningError.speakerNeedsBasis }
        if r.speaker == nil, r.mode != .unattributed { throw CaseReasoningError.speakerNeedsBasis }
        if r.basis == .investigator, Self.blankToNil(r.basisDetail) == nil { throw CaseReasoningError.investigatorBasisNeedsReason }
        if let a = appliesFrom, let b = appliesTo, b < a { throw CaseReasoningError.badPeriod }
        let id = UUID()
        let mode = r.speaker == nil ? CaseAttributionMode.unattributed : r.mode
        let basis = r.speaker == nil ? CaseAttributionBasis.none : r.basis
        try await write("cf_attr", caseID: caseID, actor: who, action: "attributionRecorded",
                        detail: "\(r.speaker ?? "unattributed") (\(mode.rawValue)): \(r.claim.prefix(80))", at: date) { db in
            if let v = sourceVersionID, !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            if let p = casePersonID, try db.query("SELECT 1 FROM case_people WHERE id = ? AND case_id = ? AND removed_at IS NULL;", [.uuid(p), .uuid(caseID)]).isEmpty {
                throw CaseWorkError.notInCase("person")
            }
            try db.exec("""
                INSERT INTO case_assertion_attributions (id, case_id, source_version_id, block_id, quote, claim, speaker, case_person_id, mode, reported_from,
                    basis, basis_detail, applies_from, applies_to, applies_text, origin, rule_version, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), sourceVersionID.map { .uuid($0) } ?? .null, blockID.map { .uuid($0) } ?? .null, .text(r.quote), .text(r.claim),
                      .optionalText(r.speaker), casePersonID.map { .uuid($0) } ?? .null, .text(mode.rawValue), .optionalText(r.reportedFrom),
                      .text(basis.rawValue), .optionalText(Self.blankToNil(r.basisDetail)), .optionalDate(appliesFrom), .optionalDate(appliesTo),
                      .optionalText(r.appliesText), .text(byRule ? "rule" : "investigator"), byRule ? .integer(Int64(CaseAttributionReader.ruleVersion)) : .null,
                      .text(who), .date(date)])
        }
        return id
    }

    /// Read a source version's passages by rule and record each attributed statement (sentences without an explicit
    /// attribution are not recorded: they have no speaker). Returns the ids recorded.
    @discardableResult
    public func readAttributions(caseID: UUID, sourceVersionID: UUID, actor: String, at date: Date = Date()) async throws -> [UUID] {
        try await CaseAccessPolicy.requireChange(database, caseID: caseID, actor: actor, .work)
        var out: [UUID] = []
        for p in try await reportPassages(sourceVersionID: sourceVersionID) {
            for s in CaseAttributionReader.sentences(p.text) {
                let r = CaseAttributionReader.read(s)
                guard r.speaker != nil else { continue }
                let already = try await database.query("SELECT 1 FROM case_assertion_attributions WHERE case_id = ? AND source_version_id = ? AND quote = ? AND withdrawn_at IS NULL;",
                                                       [.uuid(caseID), .uuid(sourceVersionID), .text(r.quote)])
                guard already.isEmpty else { continue }
                out.append(try await recordAttribution(caseID: caseID, r, sourceVersionID: sourceVersionID, blockID: p.block, byRule: true, actor: actor, at: date))
            }
        }
        return out
    }

    public func attributions(caseID: UUID) async throws -> [CaseAttribution] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, source_version_id, block_id, quote, claim, speaker, case_person_id, mode, reported_from, basis, basis_detail,
                   applies_from, applies_to, applies_text, origin, recorded_by, recorded_at, withdrawn_at
            FROM case_assertion_attributions WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let q = r.string(4), let cl = r.string(5),
                  let mode = r.string(8).flatMap(CaseAttributionMode.init(rawValue:)), let basis = r.string(10).flatMap(CaseAttributionBasis.init(rawValue:)),
                  let by = r.string(16), let at = r.date(17) else { return nil }
            return CaseAttribution(id: id, caseID: c, sourceVersionID: r.uuid(2), blockID: r.uuid(3), quote: q, claim: cl, speaker: r.string(6),
                                   casePersonID: r.uuid(7), mode: mode, reportedFrom: r.string(9), basis: basis, basisDetail: r.string(11),
                                   appliesFrom: r.date(12), appliesTo: r.date(13), appliesText: r.string(14), byRule: r.string(15) == "rule",
                                   recordedBy: by, recordedAt: at, withdrawnAt: r.date(18))
        }
    }

    public func withdrawAttribution(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        let why = try Self.clean(reason, "The reason")
        let who = try Self.clean(actor, "Actor")
        try await write("cf_attrw", caseID: caseID, actor: who, action: "attributionWithdrawn", detail: why, at: date) { db in
            guard try !db.query("SELECT 1 FROM case_assertion_attributions WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(id), .uuid(caseID)]).isEmpty else {
                throw CaseWorkError.notInCase("attribution")
            }
            try db.exec("UPDATE case_assertion_attributions SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    // MARK: Evidence relation (REASON-02)

    /// Record how an evidence row relates to its question. The stance follows the relation; verification is untouched,
    /// and the row's before/after copy is kept.
    public func setEvidenceRelation(caseID: UUID, linkID: UUID, relation: CaseEvidenceRelation, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        try await write("cf_rel", caseID: caseID, actor: who, action: "evidenceRelationSet", detail: relation.rawValue, at: date, capture: .gridLink(linkID)) { db in
            guard try !db.query("SELECT 1 FROM case_allegation_evidence e JOIN case_allegations a ON a.id = e.allegation_id WHERE e.id = ? AND a.case_id = ? AND e.removed_at IS NULL;",
                                [.uuid(linkID), .uuid(caseID)]).isEmpty else { throw CaseWorkError.notInCase("evidence link") }
            try db.exec("UPDATE case_allegation_evidence SET relation = ?, stance = ? WHERE id = ?;", [.text(relation.rawValue), .text(relation.stance.rawValue), .uuid(linkID)])
        }
    }

    // MARK: Contrary material per question (REASON-02 / REASON-08)

    /// Everything linked to a question that challenges or limits it, from the grid (challenges, qualifies) — kept beside
    /// the support, never netted against it.
    public func contraryMaterial(caseID: UUID, allegationID: UUID) async throws -> [AllegationEvidence] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await allegationEvidence(caseID: caseID).filter { $0.allegationID == allegationID && $0.relation.isContrary }
    }

    // MARK: Source dependence (REASON-05)

    @discardableResult
    public func reviewDependence(caseID: UUID, sourceA: UUID, sourceB: UUID, judgment: CaseDependenceJudgment, detectedBasis: String? = nil,
                                 rationale: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let why = try Self.clean(rationale, "The reason")
        let who = try Self.clean(actor, "Actor")
        guard sourceA != sourceB else { throw CaseWorkError.notInCase("second source") }
        let (a, b) = sourceA.uuidString.lowercased() < sourceB.uuidString.lowercased() ? (sourceA, sourceB) : (sourceB, sourceA)
        let id = UUID()
        try await write("cf_dep", caseID: caseID, actor: who, action: "dependenceReviewed", detail: "\(judgment.rawValue): \(why)", at: date) { db in
            try db.exec("""
                INSERT INTO case_source_dependence_reviews (id, case_id, source_a, source_b, judgment, detected_basis, rationale, reviewed_by, reviewed_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(a.uuidString.lowercased()), .text(b.uuidString.lowercased()), .text(judgment.rawValue),
                      .optionalText(Self.blankToNil(detectedBasis)), .text(why), .text(who), .date(date)])
        }
        return id
    }

    public func dependenceReviews(caseID: UUID) async throws -> [CaseDependenceReview] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, source_a, source_b, judgment, detected_basis, rationale, reviewed_by, reviewed_at
            FROM case_source_dependence_reviews WHERE case_id = ? ORDER BY reviewed_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let a = r.string(2).flatMap(UUID.init(uuidString:)), let b = r.string(3).flatMap(UUID.init(uuidString:)),
                  let j = r.string(4).flatMap(CaseDependenceJudgment.init(rawValue:)), let why = r.string(6), let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseDependenceReview(id: id, caseID: c, sourceA: a, sourceB: b, judgment: j, detectedBasis: r.string(5), rationale: why, reviewedBy: by, reviewedAt: at)
        }
    }

    /// The separate evidential origins behind a question's supporting rows: versions of one document are one origin, and
    /// documents sharing their wording are joined until a person reviews them as independent.
    public func supportOrigins(caseID: UUID, allegationID: UUID) async throws -> CaseSupportOrigins {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let rows = try await allegationEvidence(caseID: caseID).filter { $0.allegationID == allegationID && $0.relation.canSupport }
        var input: [(row: UUID, source: UUID, text: String)] = []
        for e in rows {
            guard case .sourceVersion(let v) = CaseEvidenceReference.parse(e.evidenceRef),
                  let logical = try await database.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(v)]).first?.uuid(0) else { continue }
            let text = try await reportPassages(sourceVersionID: v).map(\.text).joined(separator: " ")
            input.append((e.id, logical, text))
        }
        return CaseSupportOrigins.compute(rows: input, reviews: try await dependenceReviews(caseID: caseID))
    }

    // MARK: Follow-up outcomes (REASON-07)

    func insertConflictFollowUp(caseID: UUID, contradictionID: UUID, taskID: UUID, question: String, neededResult: String,
                                a: (UUID?, UUID?, String), b: (UUID?, UUID?, String), actor: String, at date: Date) async throws -> UUID {
        let id = UUID()
        try await write("cf_fu", caseID: caseID, actor: actor, action: "conflictFollowUpRaised", detail: question, at: date) { db in
            for v in [a.1, b.1].compactMap({ $0 }) where !(try Self.versionInCase(db, v, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_conflict_followups (id, case_id, contradiction_id, task_id, question, needed_result, side_a_object, side_a_version, side_a_quote,
                    side_b_object, side_b_version, side_b_quote, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(contradictionID), .uuid(taskID), .text(question), .text(neededResult),
                      a.0.map { .uuid($0) } ?? .null, a.1.map { .uuid($0) } ?? .null, .text(a.2),
                      b.0.map { .uuid($0) } ?? .null, b.1.map { .uuid($0) } ?? .null, .text(b.2), .text(actor), .date(date)])
        }
        return id
    }

    public func conflictFollowUps(caseID: UUID) async throws -> [CaseConflictFollowUp] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        return try await database.query("""
            SELECT id, case_id, contradiction_id, task_id, question, needed_result, side_a_object, side_a_version, side_a_quote, side_b_object, side_b_version,
                   side_b_quote, outcome, outcome_note, outcome_by, outcome_at, created_by, created_at
            FROM case_conflict_followups WHERE case_id = ? ORDER BY created_at, rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let k = r.uuid(2), let t = r.uuid(3), let q = r.string(4), let n = r.string(5),
                  let qa = r.string(8), let qb = r.string(11), let o = r.string(12).flatMap(CaseFollowUpOutcome.init(rawValue:)),
                  let by = r.string(16), let at = r.date(17) else { return nil }
            return CaseConflictFollowUp(id: id, caseID: c, contradictionID: k, taskID: t, question: q, neededResult: n,
                                        sideA: (r.uuid(6), r.uuid(7), qa), sideB: (r.uuid(9), r.uuid(10), qb), outcome: o,
                                        outcomeNote: r.string(13), outcomeBy: r.string(14), outcomeAt: r.date(15), createdBy: by, createdAt: at)
        }
    }

    /// Record what the follow-up found — once. Inconclusive and "not obtained" are results, with a note.
    public func recordFollowUpOutcome(caseID: UUID, taskID: UUID, outcome: CaseFollowUpOutcome, note: String, actor: String, at date: Date = Date()) async throws {
        guard outcome != .pending else { throw CaseReasoningError.notADecidedState }
        guard let why = Self.blankToNil(note) else { throw CaseReasoningError.outcomeNeedsNote }
        let who = try Self.clean(actor, "Actor")
        try await write("cf_fuo", caseID: caseID, actor: who, action: "conflictFollowUpOutcome", detail: "\(outcome.rawValue): \(why)", at: date) { db in
            guard let st = try db.query("SELECT outcome FROM case_conflict_followups WHERE task_id = ? AND case_id = ?;", [.uuid(taskID), .uuid(caseID)]).first?.string(0) else {
                throw CaseWorkError.notInCase("follow-up")
            }
            guard st == CaseFollowUpOutcome.pending.rawValue else { throw CaseReasoningError.followUpDecided }
            try db.exec("UPDATE case_conflict_followups SET outcome = ?, outcome_note = ?, outcome_by = ?, outcome_at = ? WHERE task_id = ?;",
                        [.text(outcome.rawValue), .text(why), .text(who), .date(date), .uuid(taskID)])
        }
    }

    // MARK: Decision inputs (REASON-10)

    /// Inside the decision's savepoint: freeze what the decision was made on.
    static func recordDecisionInputs(_ db: isolated Database, caseID: UUID, allegationID: UUID, disposition: String, rationale: String?,
                                     exception: String?, actor: String, at date: Date) throws {
        let rows: [CaseDecisionInputs.Row] = try db.query("""
            SELECT id, coalesce(relation, CASE stance WHEN 'supports' THEN 'supports' WHEN 'contradicts' THEN 'challenges' ELSE 'unassessed' END),
                   verification, evidence_ref, quote, label
            FROM case_allegation_evidence WHERE allegation_id = ? AND removed_at IS NULL ORDER BY created_at, rowid;
            """, [.uuid(allegationID)]).compactMap { r in
            guard let id = r.string(0), let rel = r.string(1), let ref = r.string(3) else { return nil }
            return CaseDecisionInputs.Row(id: id.lowercased(), relation: rel, verification: r.string(2), reference: ref, quote: r.string(4), label: r.string(5))
        }
        let alternatives: [CaseDecisionInputs.Alternative] = try db.query("""
            SELECT h.id, h.statement, h.status, h.revision,
                   (SELECT COUNT(*) FROM investigation_hypothesis_evidence e WHERE e.hypothesis_id = h.id AND e.stance = 'for'),
                   (SELECT COUNT(*) FROM investigation_hypothesis_evidence e WHERE e.hypothesis_id = h.id AND e.stance = 'against')
            FROM investigation_hypotheses h WHERE h.case_id = ? ORDER BY h.created_at, h.rowid;
            """, [.uuid(caseID)]).compactMap { r in
            guard let id = r.string(0), let st = r.string(1), let s = r.string(2) else { return nil }
            return CaseDecisionInputs.Alternative(id: id.lowercased(), statement: st, status: s, revision: Int(r.int(3) ?? 0),
                                                  forCount: Int(r.int(4) ?? 0), againstCount: Int(r.int(5) ?? 0))
        }
        let contrary = rows.filter { CaseEvidenceRelation(rawValue: $0.relation)?.isContrary == true }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let rj = String(decoding: try enc.encode(rows), as: UTF8.self)
        let aj = String(decoding: try enc.encode(alternatives), as: UTF8.self)
        let cj = String(decoding: try enc.encode(contrary), as: UTF8.self)
        let digest = CaseFileHash.sha256([disposition, rationale ?? "", exception ?? "", rj, aj, cj].joined(separator: "\u{1F}"))
        try db.exec("""
            INSERT INTO case_decision_inputs (id, case_id, allegation_id, disposition, rationale, exception_note, inputs_json, alternatives_json, contrary_json,
                inputs_digest, decided_by, decided_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .uuid(allegationID), .text(disposition), .optionalText(rationale), .optionalText(exception),
                  .text(rj), .text(aj), .text(cj), .text(digest), .text(actor), .date(date)])
    }

    public func decisionInputs(caseID: UUID, allegationID: UUID) async throws -> [CaseDecisionInputs] {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let dec = JSONDecoder()
        return try await database.query("""
            SELECT id, case_id, allegation_id, disposition, rationale, exception_note, inputs_json, alternatives_json, contrary_json, inputs_digest, decided_by, decided_at
            FROM case_decision_inputs WHERE case_id = ? AND allegation_id = ? ORDER BY decided_at, rowid;
            """, [.uuid(caseID), .uuid(allegationID)]).compactMap { r in
            guard let id = r.uuid(0), let c = r.uuid(1), let a = r.uuid(2), let d = r.string(3), let dg = r.string(9), let by = r.string(10), let at = r.date(11) else { return nil }
            func rows(_ i: Int) -> [CaseDecisionInputs.Row] { (try? dec.decode([CaseDecisionInputs.Row].self, from: Data((r.string(i) ?? "[]").utf8))) ?? [] }
            let alts = (try? dec.decode([CaseDecisionInputs.Alternative].self, from: Data((r.string(7) ?? "[]").utf8))) ?? []
            return CaseDecisionInputs(id: id, caseID: c, allegationID: a, disposition: d, rationale: r.string(4), exceptionNote: r.string(5),
                                      rows: rows(6), alternatives: alts, contrary: rows(8), digest: dg, decidedBy: by, decidedAt: at)
        }
    }

    // MARK: Proposal decisions (REASON-12)

    @discardableResult
    public func recordProposalDecision(caseID: UUID, kind: CaseProposalKind, key: String, content: String, decision: CaseProposalDecision,
                                       reason: String?, actor: String, at date: Date = Date()) async throws -> UUID {
        let k = try Self.clean(key, "The proposal")
        let who = try Self.clean(actor, "Actor")
        let why = Self.blankToNil(reason)
        if decision != .accepted, why == nil { throw CaseFileError.blank("The reason") }
        let id = UUID()
        try await write("cf_prop", caseID: caseID, actor: who, action: "proposalDecided", detail: "\(kind.rawValue) \(decision.rawValue)" + (why.map { ": \($0)" } ?? ""), at: date) { db in
            try db.exec("""
                INSERT INTO case_proposal_decisions (id, case_id, proposal_kind, proposal_key, content_digest, content_text, decision, reason, actor, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(kind.rawValue), .text(k), .text(CaseFileHash.sha256(content)), .text(String(content.prefix(4000))),
                      .text(decision.rawValue), .optionalText(why), .text(who), .date(date)])
        }
        return id
    }

    /// Whether to offer a proposal now (any kind: a suggested fact, link, gap, point or follow-up).
    public func proposalVerdict(caseID: UUID, kind: CaseProposalKind, key: String, content: String) async throws -> CaseProposalVerdict {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let r = try await database.query("""
            SELECT decision, content_digest, content_text, reason, actor, decided_at FROM case_proposal_decisions
            WHERE case_id = ? AND proposal_kind = ? AND proposal_key = ? ORDER BY decided_at DESC, rowid DESC LIMIT 1;
            """, [.uuid(caseID), .text(kind.rawValue), .text(key.trimmingCharacters(in: .whitespacesAndNewlines))]).first
        let latest = r.flatMap { r -> (CaseProposalDecision, String, String?, String?, String, Date)? in
            guard let d = r.string(0).flatMap(CaseProposalDecision.init(rawValue:)), let dg = r.string(1), let by = r.string(4), let at = r.date(5) else { return nil }
            return (d, dg, r.string(2), r.string(3), by, at)
        }
        return CaseProposalMemory.verdict(latest: latest.map { (decision: $0.0, digest: $0.1, text: $0.2, reason: $0.3, actor: $0.4, at: $0.5) }, content: content)
    }

    // MARK: Alternatives (no vote)

    public func alternatives(caseID: UUID) async throws -> CaseAlternativesView {
        try await CaseAccessPolicy.requireRead(database, caseID: caseID)
        let hyps = try await database.query("SELECT id, statement, status, created_at FROM investigation_hypotheses WHERE case_id = ? AND kind = 'hypothesis' ORDER BY created_at, rowid;",
                                            [.uuid(caseID)])
        var out: [CaseAlternativeExplanation] = []
        for h in hyps {
            guard let id = h.uuid(0), let st = h.string(1), let status = h.string(2), let at = h.date(3) else { continue }
            let ev = try await database.query("SELECT stance, source_version_id, note FROM investigation_hypothesis_evidence WHERE hypothesis_id = ? ORDER BY created_at, rowid;", [.uuid(id)])
            let names = try await sourceLabels(ev.compactMap { $0.uuid(1) })
            func line(_ r: SQLRow) -> String { (r.uuid(1).flatMap { names[$0] } ?? "a source") + (r.string(2).map { " — \($0)" } ?? "") }
            out.append(CaseAlternativeExplanation(id: id, statement: st, status: status, recordedAt: at,
                                                  materialFor: ev.filter { $0.string(0) == "for" }.map(line),
                                                  materialAgainst: ev.filter { $0.string(0) == "against" }.map(line)))
        }
        return CaseAlternativesView(explanations: out)
    }
}

// MARK: - The follow-up action (CaseFileService)

extension CaseFileService {
    /// "Create follow-up" on a contradiction: a case action whose purpose is the exact question and whose expected result is
    /// the result needed, linked to both accounts as quoted (and the versions they were read from). Its outcome is recorded
    /// separately and may be inconclusive; creating it decides nothing about the contradiction.
    @discardableResult
    public func createConflictFollowUp(caseID: UUID, contradiction c: Contradiction, versionA: UUID?, versionB: UUID?, question: String, neededResult: String,
                                       responsible: String? = nil, servesQuestions: [UUID] = [], due: Date? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        try await CaseAccessPolicy.requireChange(file.database, caseID: caseID, actor: actor, .work)
        let q = try CaseFileRepository.clean(question, "The question to answer")
        let n = try CaseFileRepository.clean(neededResult, "The result needed")
        let who = try CaseFileRepository.clean(actor, "Actor")
        let task = try await createAction(caseID: caseID, ChildAction(title: "Resolve: \(q.prefix(80))", purpose: q, deliverable: n, responsible: responsible,
                                                                      servesQuestions: servesQuestions, due: due), actor: who, at: date)
        do {
            _ = try await file.insertConflictFollowUp(caseID: caseID, contradictionID: c.id, taskID: task, question: q, neededResult: n,
                                                      a: (c.evidenceA, versionA, c.claimA), b: (c.evidenceB, versionB, c.claimB), actor: who, at: date)
        } catch {
            KalsmritikoshLog.app.error("Contradiction follow-up not recorded; cancelling its task: \(error.localizedDescription, privacy: .public)")
            do { try await setTaskStatus(caseID: caseID, taskID: task, to: .cancelled, actor: who, at: date) } catch {
                KalsmritikoshLog.app.error("The follow-up task could not be cancelled: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        return task
    }
}

// MARK: - REASON-11 Scoring detection apart from human disposition

/// A scored run of the contradiction check over labelled fixtures, kept apart from what people decided about the
/// items. Detection is scored against a hand-written key; dispositions are only counted.
public nonisolated struct CaseConflictScore: Sendable, Equatable {
    public struct Case: Sendable, Equatable {
        public let name: String
        public let expectedConflict: Bool
        public let detected: Int
        public var outcome: String {
            switch (expectedConflict, detected > 0) {
            case (true, true): return "found (true positive)"
            case (true, false): return "missed (false negative)"
            case (false, true): return "flagged although not a conflict (false positive)"
            case (false, false): return "correctly not flagged"
            }
        }
    }
    public let cases: [Case]
    public let dispositions: [CaseConflictState: Int]
    public var truePositives: Int { cases.filter { $0.expectedConflict && $0.detected > 0 }.count }
    public var falsePositives: Int { cases.filter { !$0.expectedConflict && $0.detected > 0 }.count }
    public var missed: Int { cases.filter { $0.expectedConflict && $0.detected == 0 }.count }
    public var trueNegatives: Int { cases.filter { !$0.expectedConflict && $0.detected == 0 }.count }

    public var lines: [String] {
        var out = ["Detection (the check against a hand-written key): \(truePositives) found, \(missed) missed, \(falsePositives) flagged wrongly, \(trueNegatives) correctly not flagged, of \(cases.count) fixtures."]
        out += cases.map { "- \($0.name): \($0.outcome)" }
        let d = CaseConflictState.allCases.compactMap { s in dispositions[s].map { "\(s.rawValue) \($0)" } }
        out.append("Human disposition (counted separately, not scored): " + (d.isEmpty ? "none recorded." : d.joined(separator: ", ") + "."))
        return out
    }

    public static func score(_ fixtures: [(name: String, expectedConflict: Bool, documents: [CaseContradictionFinder.Document])],
                             dispositions: [CaseConflictState] = []) -> CaseConflictScore {
        var counts: [CaseConflictState: Int] = [:]
        for s in dispositions { counts[s, default: 0] += 1 }
        return CaseConflictScore(cases: fixtures.map { Case(name: $0.name, expectedConflict: $0.expectedConflict, detected: CaseContradictionFinder.ruleFindings($0.documents).count) },
                                 dispositions: counts)
    }
}
