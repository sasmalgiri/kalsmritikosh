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
    /// Detection only (recognizer) — extraction uses `numberCapturePattern` below.
    nonisolated static let numberPattern =
        #"(?:patent|application|publication)\s*(?:no\.?|number|#)?\s*[:\-]?\s*[A-Z]{0,2}\s?[\d,\/]{5,}[A-Z0-9]*"#

    /// V2 (C-1) — capture-group extraction. The `label` group names the field;
    /// the `value` group is the bare identifier, DELIBERATELY excluding `/` so a
    /// calendar date ("Patent : 22/03/2023") can never be captured as a number.
    /// The stored value is the normalized ATOM (no label, no spaces, no commas);
    /// the label lives only as a per-field display constant at render time. This
    /// is the two-layer split: the ledger holds "700321", the surface says
    /// "Patent No. 700321", composed from a constant — never fused into storage.
    nonisolated static let numberCapturePattern =
        #"(?<label>patent|application|publication)\s*(?:no\.?|number|#)?\s*[:\-]?\s*(?<value>[A-Z]{0,2}\s?\d[\d,]{4,}[A-Z0-9]*)"#

    /// The fields this pack can emit under producer_version=1 — the authority
    /// the completeness invariant (SlotAnswerComposer display contracts) checks
    /// against, so a new emittable field cannot ship without a display contract.
    public nonisolated static let emittedFields: [String] =
        ["patentNumber", "applicationNumber", "publicationNumber", "status", "grantDate", "filingDate"]

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
        // V2 (C-1) capture-group extraction. The label group names the field;
        // the value group is the bare identifier. The historical release fix
        // stands — ALL matches extracted, each under the field its own label
        // names — but the value no longer carries the label: it is normalized
        // to the atom (trim, strip spaces + commas). Six label spellings of one
        // number now store ONE value; the C-10 merge collapses them to one fact.
        var seen = Set<String>()
        for (full, label, rawValue) in captureGroups(numberCapturePattern, in: text) {
            let value = normalizeIdentifier(rawValue)
            guard !value.isEmpty else { continue }
            // Defense in depth: the value group already excludes `/`, so a slash
            // date cannot be captured — this guard also stops a bare 8-digit
            // date shape if the source omits separators.
            if isDateShapedNumber(value) { continue }
            let field: String
            switch label.lowercased() {
            case "application": field = "applicationNumber"
            case "publication": field = "publicationNumber"
            default:            field = "patentNumber"
            }
            let key = field + "|" + value.lowercased()
            guard seen.insert(key).inserted else { continue }
            facts.append(GenericFact(subjectLabel: subjectLabel, field: field, value: value,
                                     status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts,
                                     rawMatch: full.trimmingCharacters(in: .whitespaces), sourceCount: 1))
        }
        if let st = status(in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "status", value: st,
                                     status: .sourceAsserted, confidence: 0.75, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: nil, sourceCount: 1))
        }
        // D-16 — the grant/filing DATES are distinct slot fields ("on which
        // date was the patent granted" answers from grantDate, never from a
        // generic date). V2 (C-7): the stored value is precision-aware ISO
        // ("2025-06-17", "2024-11", "2024"); the display canon (day = DD/MM/YYYY
        // per seal #3c, month = "November 2024", year = "2024") is reconstructed
        // at render, NEVER derived from the source form. rawMatch keeps the
        // source spelling as the receipt.
        for (pattern, field) in datePatterns {
            if let raw = firstMatch(pattern, in: text) {
                let rawDate = dateValue(fromLabelMatch: raw)
                if let iso = normalizeDate(rawDate) {
                    facts.append(GenericFact(subjectLabel: subjectLabel, field: field, value: iso,
                                             status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blockID],
                                             producerVersion: DerivedProducerVersions.facts,
                                             rawMatch: rawDate, sourceCount: 1))
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

    /// A captured "number" whose digit portion is actually a calendar date
    /// (dd/mm/yyyy, dd-mm-yyyy, yyyy-mm-dd) — never a patent/application no.
    nonisolated static func isDateShapedNumber(_ value: String) -> Bool {
        let patterns = [
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,   // 22/03/2023, 22-03-23
            #"\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b"#,     // 2023-03-22
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    /// V2 (C-1) — named-group capture. Returns (fullMatch, label, value) for
    /// every match of a pattern carrying `label` and `value` named groups.
    /// Case-insensitive; deterministic left-to-right order.
    nonisolated static func captureGroups(_ pattern: String, in s: String) -> [(full: String, label: String, value: String)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let labelRange = m.range(withName: "label")
            let valueRange = m.range(withName: "value")
            guard labelRange.location != NSNotFound, valueRange.location != NSNotFound else { return nil }
            return (ns.substring(with: m.range),
                    ns.substring(with: labelRange),
                    ns.substring(with: valueRange))
        }
    }

    /// V2 (C-7) — the normalized identifier ATOM: trimmed, spaces and commas
    /// removed. "US 1,234,567 B2" → "US1234567B2"; " 700321 " → "700321". The
    /// stored value is this atom; the label is a display constant, never stored.
    nonisolated static func normalizeIdentifier(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
    }

    /// V2 (C-7) — normalize a labeled date's text to precision-aware ISO:
    /// day → "yyyy-MM-dd", month → "yyyy-MM", year → "yyyy". nil when no year
    /// parses. Token assignment (day before month for bare numbers) matches
    /// CanonicalFactComparator.dateComponents, so the writer and the read-time
    /// comparator never disagree on what "12/01/2024" means.
    nonisolated static func normalizeDate(_ raw: String) -> String? {
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        let lower = raw.lowercased()
        var day: Int?; var month: Int?; var year: Int?
        for (name, num) in months where lower.contains(name) { month = num }
        let nums = lower.split { !$0.isNumber }.compactMap { Int($0) }
        for n in nums {
            if n > 1900 && n < 2100 { year = n }
            else if n <= 31 && day == nil { day = n }
            else if n <= 12 && month == nil { month = n }
        }
        guard let y = year else { return nil }
        if let m = month, let d = day { return String(format: "%04d-%02d-%02d", y, m, d) }
        if let m = month { return String(format: "%04d-%02d", y, m) }
        return String(format: "%04d", y)
    }

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
