//
//  CaseStatementSupport.swift
//  Kalsmritikosh
//
//  Smart-map S2 / SRC-07 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §05) — a citation's existence
//  does not validate an unrelated assertion. The case's one verifier (CaseEvidenceVerifier) decides whether the
//  quoted words are really in the cited version; this file decides whether those words SUPPORT the statement they
//  are attached to, by the kind of field:
//    • quote   — the statement's words are in the passage (after normalising spacing, quotation marks and case);
//    • name    — a person or organisation named in the statement is named in the passage (honorifics, initials,
//                order and accents allowed; a different given name is not the same person);
//    • date    — the same day is stated in the passage;
//    • amount  — the same value, with no conflicting currency (the studios' rule, StudioEvidenceResolver);
//    • summary — a paraphrase: every amount, dated day and name it states must be in the passage, it must not
//                reverse the passage's negation, and it must share subject matter with the passage.
//  Deterministic rules only — nothing here calls a model.
//
//  SRC-03 — `CasePointSourceCheck` is what a point carries about its quoted words: the qualifiers of the source
//  sentence they were cut from (and which the cut left out) and any way the investigator's statement is not supported.
//

import Foundation
import os

/// The kind of source-linked field being checked.
public nonisolated enum CaseStatementField: String, Sendable, CaseIterable, Codable {
    case quote, name, date, amount, summary
}

/// The outcome of checking a statement against its passage.
public nonisolated struct CaseStatementCheck: Sendable, Equatable {
    /// The facets the statement states that were checked (amounts, dates, names, negation, subject matter).
    public let checked: [String]
    /// Why the passage does not support the statement (empty: supported).
    public let failures: [String]
    public var isSupported: Bool { failures.isEmpty }
}

public nonisolated enum CaseStatementSupport {

    /// nil when `quote` supports `value` as a field of `field`; otherwise the reason.
    public static func check(_ value: String, as field: CaseStatementField, against quote: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        switch field {
        case .quote:
            return StudioEvidenceResolver.norm(quote).contains(StudioEvidenceResolver.norm(v)) ? nil : "the passage does not contain these exact words"
        case .amount:
            return StudioEvidenceResolver.supports(v, kind: .amount, quote: quote)
        case .date:
            return StudioEvidenceResolver.supports(v, kind: .date, quote: quote)
        case .name:
            return nameSupported(v, by: quote) ? nil : "the passage does not name \(v)"
        case .summary:
            let c = check(statement: v, against: quote)
            return c.isSupported ? nil : c.failures.joined(separator: "; ")
        }
    }

    /// A paraphrase or summary against its passage: what it states must be in the passage.
    public static func check(statement: String, against quote: String) -> CaseStatementCheck {
        var checked: [String] = []
        var failures: [String] = []
        // Amounts written with a currency.
        for token in StudioEvidenceResolver.amountTokens(in: statement) where !FAMoney.currency(of: token).isEmpty && FAMoney.value(of: token) != nil {
            checked.append("amount \(token)")
            if StudioEvidenceResolver.supports(token, kind: .amount, quote: quote) != nil {
                failures.append("the passage does not state the amount \(token.trimmingCharacters(in: .whitespaces))")
            }
        }
        // Dates written with a year: the same day must be stated in the passage.
        let passageDates = StudioEvidenceResolver.dates(in: quote)
        let calendar = Calendar(identifier: .gregorian)
        for (written, day) in writtenDates(in: statement) {
            checked.append("date \(written)")
            if !passageDates.contains(where: { calendar.isDate($0, inSameDayAs: day) }) {
                failures.append("the passage does not state the date \(written)")
            }
        }
        // Names (people, organisations, places written as proper names of two words or more, or after a title).
        for name in names(in: statement) {
            checked.append("name \(name)")
            if !nameSupported(name, by: quote) { failures.append("the passage does not name \(name)") }
        }
        // Negation: a statement must not say the opposite of its passage.
        let saysNot = !AssertionQualifierDetector.detect(statement).negations.isEmpty
        let passageNot = !AssertionQualifierDetector.detect(quote).negations.isEmpty
        checked.append("negation")
        if saysNot != passageNot {
            failures.append(passageNot ? "the passage is negated and the statement is not — it may say the opposite"
                                       : "the statement is negated and the passage is not — it may say the opposite")
        }
        // Subject matter: a statement of several content words that shares none with the passage is unrelated.
        let words = contentStems(statement)
        if words.count >= 4 {
            checked.append("subject matter")
            if words.isDisjoint(with: contentStems(quote)) { failures.append("the passage does not mention what this states") }
        }
        return CaseStatementCheck(checked: checked, failures: failures)
    }

    // MARK: Names

    static let honorifics: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "prof", "professor", "sir", "dame", "shri", "smt", "sri", "mx", "rev", "hon", "the"]
    static let corporateSuffixes: Set<String> = ["ltd", "limited", "inc", "incorporated", "llc", "llp", "plc", "co", "corp", "corporation", "pvt", "private", "gmbh", "sa", "ag"]
    static let notNames: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
                                        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "the", "a", "an", "this", "that", "on", "in",
                                        "at", "by", "of", "and", "or", "i", "we", "he", "she", "they", "it", "page", "section", "exhibit"]

    /// The name's identifying words: folded (case, accents), punctuation removed, titles and company suffixes dropped.
    static func nameTokens(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !honorifics.contains($0) && !corporateSuffixes.contains($0) }
    }

    /// Whether `text` names `name`: every word of the name is a word of the text, an initial ("J.") matches a word of
    /// the text starting with it, and the last word (the surname or the organisation's main word) is always required.
    public static func nameSupported(_ name: String, by text: String) -> Bool {
        let want = nameTokens(name)
        guard let last = want.last else { return true }
        let have = nameTokens(text)
        let set = Set(have)
        guard last.count == 1 ? have.contains(where: { $0.hasPrefix(last) }) : set.contains(last) else { return false }
        for token in want.dropLast() {
            if token.count == 1 {
                guard have.contains(where: { $0.hasPrefix(token) }) else { return false }
            } else if !set.contains(token) {
                return false
            }
        }
        return true
    }

    /// Proper names written in `text`: runs of two or more capitalised words (initials allowed), or one after a title.
    public static func names(in text: String) -> [String] {
        let pattern = #"\b(?:(?:Mr|Mrs|Ms|Dr|Prof|Shri|Smt)\.?\s+)?[A-Z][A-Za-z'\-]+(?:\s+(?:[A-Z]\.|[A-Z][A-Za-z'\-]+|de|van|von|da|bin|al)){1,4}|\b(?:Mr|Mrs|Ms|Dr|Prof|Shri|Smt)\.?\s+[A-Z][A-Za-z'\-]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            KalsmritikoshLog.app.error("Name pattern did not compile")
            return []
        }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var words = ns.substring(with: m.range).split(separator: " ").map(String.init)
            // Leading words that are not part of a name ("The", "On", a month) are dropped.
            while let first = words.first, notNames.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeFirst() }
            // A title counts as a word here ("Dr Rao"); it is ignored when the name is matched.
            let named = words.filter { !notNames.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            guard named.count >= 2 else { continue }
            let name = named.joined(separator: " ")
            if !out.contains(name) { out.append(name) }
        }
        return out
    }

    // MARK: Dates and words

    /// Dates written with a year ("3 March 2026", "2026-03-03"), as written, with the day they name.
    static func writtenDates(in text: String) -> [(written: String, day: Date)] {
        var out: [(written: String, day: Date)] = []
        let ns = text as NSString
        let iso = DateFormatter(); iso.locale = Locale(identifier: "en_US_POSIX"); iso.dateFormat = "yyyy-MM-dd"; iso.timeZone = .current
        if let re = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let written = ns.substring(with: m.range)
                if let d = iso.date(from: written) { out.append((written, d)) }
            }
        }
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let written = ns.substring(with: m.range)
                // Deep dive batch 3 — "05/03/2026" (either way round) is not read: neither support nor contradiction.
                guard let d = m.date, written.range(of: #"\d{4}"#, options: .regularExpression) != nil, !StudioEvidenceResolver.isAmbiguousNumericDate(written),
                      !out.contains(where: { $0.written.contains(written) || written.contains($0.written) }) else { continue }
                out.append((written.trimmingCharacters(in: .whitespaces), d))
            }
        }
        return out
    }

    static let stopWords: Set<String> = ["this", "that", "with", "from", "were", "have", "been", "they", "them", "their", "there", "which", "what",
                                         "when", "where", "about", "into", "than", "then", "also", "only", "said", "says", "would", "could", "should",
                                         "will", "shall", "does", "did", "done", "being", "after", "before", "under", "over", "very", "some", "such"]

    /// Content words of length ≥ 4, stemmed to their first five letters, lowercased and accent-folded.
    static func contentStems(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
            .map { String($0.prefix(5)) })
    }
}

/// SRC-03 — what a report point carries about its quoted words (stored as `case_report_points.qualifiers_json`).
public nonisolated struct CasePointSourceCheck: Codable, Sendable, Hashable {
    /// The source sentence's qualifiers, the full sentence when the words were cut from it, and what the cut left out.
    public var context: QuoteContextCheck
    /// How the investigator's statement is not supported by the quoted words (empty: nothing found).
    public var statementIssues: [String]

    public init(context: QuoteContextCheck, statementIssues: [String]) {
        self.context = context; self.statementIssues = statementIssues
    }

    /// The cut changes what the words assert, or the statement is not supported by them.
    public var flagsMeaning: Bool { context.changesMeaning || !statementIssues.isEmpty }

    /// The lines that travel with the point.
    public var lines: [String] { context.lines + statementIssues.map { "Your statement: \($0)" } }

    /// Check the quoted words against the source text they were read from and the statement made of them.
    public static func make(statement: String, quote: String?, sourceText: String?) -> CasePointSourceCheck? {
        guard let quote = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty else { return nil }
        let context = sourceText.map { AssertionQualifierDetector.check(quote: quote, in: $0) }
            ?? QuoteContextCheck(sentence: nil, qualifiers: AssertionQualifierDetector.detect(quote), dropped: [])
        return CasePointSourceCheck(context: context, statementIssues: CaseStatementSupport.check(statement: statement, against: quote).failures)
    }

    public var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return String(decoding: try encoder.encode(self), as: UTF8.self) } catch {
            KalsmritikoshLog.app.error("Point source check not encoded: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public static func decode(_ raw: String?) -> CasePointSourceCheck? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(CasePointSourceCheck.self, from: data) } catch {
            KalsmritikoshLog.app.error("Stored point source check unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
