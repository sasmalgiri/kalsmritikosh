//
//  PatentDomainPack.swift
//  Kalsmritikosh
//
//  SEM-007 — the patent domain pack. Optional; recognizes patent filings and extracts the
//  patent number, applicant/assignee and OFFICIAL STATUS (filed / published / granted /
//  rejected / abandoned). Official status is authoritative for status questions (a grant
//  certificate outranks correspondence about the application). Deterministic, offline.
//
//  Status facts are SOURCE_ASSERTED (the document records the office's stated status); the
//  pack does not itself adjudicate validity.
//

import Foundation

public enum PatentDomainPack {

    public nonisolated static var recognizers: [BlockRecognizer] {
        [
            BlockRecognizer(name: "patentNumberLine") { text, _ in
                firstMatch(numberPattern, in: text) != nil
                    ? BlockSemanticTag(role: "patentNumber", confidence: 0.8, recognizedBy: "patentNumberLine") : nil
            },
            BlockRecognizer(name: "patentStatusLine") { text, _ in
                status(in: text) != nil
                    ? BlockSemanticTag(role: "patentStatus", confidence: 0.75, recognizedBy: "patentStatusLine") : nil
            }
        ]
    }

    public nonisolated static func registry(base: BlockSemanticsRegistry = .generic) -> BlockSemanticsRegistry {
        recognizers.reduce(base) { $0.registering($1) }
    }

    /// Patent number shapes: "Patent No. 1234567", "Application No 202411001234", "US1234567B2".
    nonisolated static let numberPattern =
        #"(?:patent|application|publication)\s*(?:no\.?|number|#)?\s*[:\-]?\s*[A-Z]{0,2}\s?[\d,\/]{5,}[A-Z0-9]*"#

    /// Ordered by authority: granted/rejected are terminal official states.
    nonisolated static let statusKeywords: [(String, String)] = [
        ("granted", "granted"), ("grant of patent", "granted"),
        ("rejected", "rejected"), ("refused", "rejected"),
        ("abandoned", "abandoned"), ("withdrawn", "abandoned"),
        ("published", "published"),
        ("filed", "filed"), ("application filed", "filed"), ("pending", "pending")
    ]

    public nonisolated static func status(in text: String) -> String? {
        let t = text.lowercased()
        for (needle, canonical) in statusKeywords where t.contains(needle) { return canonical }
        return nil
    }

    /// Extract patent facts (number, status) as evidence-linked SOURCE_ASSERTED facts.
    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        var facts: [GenericFact] = []
        // Release-quality fix (2026-08-28, owner ground-truth case): ONE field
        // for application/publication/GRANTED numbers made them conflicting
        // values of a single attribute, so the majority (the application
        // number, quoted in every email) buried the granted patent number —
        // and firstMatch dropped the second number in grant letters that
        // carry both. Extract ALL matches, each under the field its own
        // prefix names; values keep their full matched text unchanged.
        var seen = Set<String>()
        for match in allMatches(numberPattern, in: text) {
            let value = match.trimmingCharacters(in: .whitespaces)
            let lower = value.lowercased()
            let field: String
            if lower.hasPrefix("application") { field = "applicationNumber" }
            else if lower.hasPrefix("publication") { field = "publicationNumber" }
            else { field = "patentNumber" }
            let key = field + "|" + value.lowercased()
            guard seen.insert(key).inserted else { continue }
            facts.append(GenericFact(subjectLabel: subjectLabel, field: field,
                                     value: value,
                                     status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blockID]))
        }
        if let st = status(in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "status", value: st,
                                     status: .sourceAsserted, confidence: 0.75, sourceBlockIDs: [blockID]))
        }
        // D-16 — the grant/filing DATES are distinct slot fields ("on which
        // date was the patent granted" answers from grantDate, never from a
        // generic date). Labels follow the IPO grant-letter forms the story-
        // spine extractor already triggers on ("Date of Grant :", "Date of
        // Filing :", "granted on …").
        for (pattern, field) in datePatterns {
            if let raw = firstMatch(pattern, in: text) {
                let value = dateValue(fromLabelMatch: raw)
                if !value.isEmpty {
                    facts.append(GenericFact(subjectLabel: subjectLabel, field: field, value: value,
                                             status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blockID]))
                }
            }
        }
        return facts
    }

    /// Labeled date lines → slot fields. The capture keeps the full date text
    /// (values keep their matched text unchanged, per pack convention).
    nonisolated static let datePatterns: [(String, String)] = [
        (#"(?:date\s+of\s+grant|granted\s+on)\s*[:\-]?\s*([0-9]{1,2}(?:st|nd|rd|th)?[ \-/]*(?:[A-Za-z]+|[0-9]{1,2})[ ,\-/]*[0-9]{2,4}|[0-9]{4}-[0-9]{2}-[0-9]{2})"#, "grantDate"),
        (#"(?:date\s+of\s+filing|filed\s+on)\s*[:\-]?\s*([0-9]{1,2}(?:st|nd|rd|th)?[ \-/]*(?:[A-Za-z]+|[0-9]{1,2})[ ,\-/]*[0-9]{2,4}|[0-9]{4}-[0-9]{2}-[0-9]{2})"#, "filingDate"),
    ]

    /// The date portion of a labeled match ("Date of Grant : 29 November 2024"
    /// → "29 November 2024"): everything from the first digit, trimmed —
    /// robust to ":", "-", and bare "granted on" forms alike.
    nonisolated static func dateValue(fromLabelMatch raw: String) -> String {
        guard let idx = raw.firstIndex(where: \.isNumber) else { return "" }
        return String(raw[idx...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        allMatches(pattern, in: s).first
    }

    nonisolated static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
