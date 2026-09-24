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
import os

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
    /// W-4 (owner witness, 2026-09-06): two laws hardened after live junk.
    ///   - "patent(?!\s+application)" — "Patent Application-N" is an
    ///     APPLICATION reference; the patent label may never claim it.
    ///   - the country-code prefix is case-SENSITIVE and ATTACHED
    ///     ((?-i:[A-Z]{2})? with no space): under case-insensitive matching,
    ///     the tail of "granted 202331019665" minted the junk canon
    ///     "ed202331019665" — two prose letters posing as a country code.
    ///   - W-5.6: the value TAIL is case-sensitive too ((?-i:[A-Z0-9]*)) —
    ///     under case-insensitive matching it swallowed a following word
    ///     ("202331019665Applicant" ×82 on the live archive). A real
    ///     kind-code suffix (B2) is uppercase; prose is not.
    nonisolated static let numberCapturePattern =
        #"(?<label>patent(?!\s+application)|application|publication)\s*(?:no\.?|number|#)?\s*[:\-]?\s*(?<value>(?-i:[A-Z]{2})?\d[\d,]{4,}(?:(?-i:[A-Z][A-Z0-9]{0,3})(?![a-z]))?)"#

    /// The OCR-tolerant twin of `numberCapturePattern`, for SCANNED pages where
    /// the digits were read as letters ("Patent No. 7OO321"). Identical up to
    /// the value group, which admits the confusable letters as well as digits —
    /// and is CASE-SENSITIVE (`(?-i:)`) because only some cases are genuine
    /// confusions: `B` collides with 8, plain `b` does not. Every match is then
    /// put through `OCRDigitRecovery`, which refuses far more than it repairs;
    /// this pattern only decides what is worth ASKING about.
    ///
    /// The character class is built from the recovery table so the two cannot
    /// drift: a letter matched here but unknown there would never be repaired,
    /// and a letter known there but unmatched here would never be reached.
    nonisolated static let ocrNumberCapturePattern: String =
        #"(?<label>patent(?!\s+application)|application|publication)\s*(?:no\.?|number|#)?\s*[:\-]?\s*(?<value>"#
        + "(?-i:" + OCRDigitRecovery.candidateCharacterClass
        + "{\(OCRDigitRecovery.lengthRange.lowerBound),\(OCRDigitRecovery.lengthRange.upperBound)})"
        + ")"

    /// Confidence for a value whose digits were restored from an OCR misread.
    /// Deliberately below the verbatim tier (0.8): the reading is a candidate
    /// supported by the glyph shapes, not a value the page states plainly.
    nonisolated static let ocrRecoveredConfidence = 0.55

    /// Confidence for a value rejoined to its label across a page break. Below
    /// verbatim because the JOIN is an inference about layout — the page does
    /// assert both halves, but not their adjacency.
    nonisolated static let crossBlockAssembledConfidence = 0.7

    /// The fields this pack can emit under producer_version=1 — the authority
    /// the completeness invariant (SlotAnswerComposer display contracts) checks
    /// against, so a new emittable field cannot ship without a display contract.
    public nonisolated static let emittedFields: [String] =
        ["patentNumber", "applicationNumber", "publicationNumber", "status", "grantDate", "filingDate",
         "applicant", "inventor"]

    /// A1.1 — role capture patterns (field → regex with a ‹name› group). Data.
    /// W-5.1 — the POA continuation set is the full formula (having / of /
    /// son of / daughter of / residing / nationality); what a pattern
    /// captures must STILL pass `isPlausibleRoleValue` at write.
    nonisolated static let rolePatterns: [(String, String)] = [
        ("applicant", #"applicant[s]?\s*(?:name)?\s*[:\-]\s*(?<name>[A-Za-z][A-Za-z .]{3,58}?)(?=[,;\n\(]|$)"#),
        // P2.7 — THE POA FORMULA, with the bare `of` REMOVED.
        //
        // Owner ruling: keep the grantor's name. But W-5.1 refused it for a real
        // reason — the live archive produced "acknowledge receipt" x82 and
        // "need patent agent" x82 through this very pattern, and
        // `roleStopwords` does NOT catch either (measured). So the casing rule
        // in isPlausibleRoleValue was load-bearing and could not simply be
        // relaxed.
        //
        // The weak link was never the casing: it was the bare `of`. "I
        // acknowledge receipt OF the letter" matches `\bI …\s+of`, and so does
        // half of English correspondence. The remaining alternatives are a
        // document FORMULA that prose does not imitate — a power of attorney
        // says "I, <name> having …" / "son of" / "residing" / "nationality".
        // Removing `of` alone refuses the witnessed junk AT THE PATTERN, which
        // is stronger than refusing it at the gate: a value that never matches
        // cannot be mis-scored later.
        //
        // "son of" and "daughter of" are kept as COMPOUNDS — they are formula
        // terms, and losing them would drop the Indian POA phrasing this
        // archive actually uses.
        ("applicant", #"\bI,?\s+(?<name>[A-Za-z][A-Za-z .]{3,58}?)\s*,?\s+(?:having|son of|daughter of|wife of|resid|nationality|aged)"#),
        ("applicant", #"granted to\s+(?<name>[A-Za-z][A-Za-z .]{3,58}?)(?=[,;\n\(]|$)"#),
        ("inventor",  #"inventor[s]?\s*(?:name)?\s*[:\-]\s*(?<name>[A-Za-z][A-Za-z .]{3,58}?)(?=[,;\n\(]|$)"#),
    ]

    /// W-5.1 — THE ROLE-VALUE GATE: a captured role value must be a NAME,
    /// not a clause. The witnessed junk ("am writing to state…", "wish to
    /// bring to your…") is prose the `\bI\b` pattern swallowed. A value
    /// passes only when every token is name-shaped and none is a function
    /// word; the register's junk classifiers (mail-infra, title-shaped,
    /// automated-sender, nil-family, filename) apply on top. Per the doc's
    /// law, every token must START uppercase (Title-Case or ALL-CAPS) —
    /// the live junk ("acknowledge receipt" ×82, "need patent agent" ×82)
    /// is lowercase prose no stoplist can enumerate. The person's name
    /// reaches the register through the labeled certificate lines, which
    /// write it cased; a lowercase POA capture is counted, not stored.
    nonisolated static let roleStopwords: Set<String> = [
        "am", "is", "are", "was", "were", "be", "been", "being",
        "the", "a", "an", "to", "that", "this", "these", "those",
        "of", "and", "or", "in", "on", "at", "for", "with", "by",
        "have", "has", "had", "will", "would", "shall", "should",
        "can", "could", "may", "might", "do", "does", "did", "not",
        "hereby", "herewith", "writing", "write", "state", "submit",
        "request", "wish", "like", "pleased", "inform", "bring",
        "attach", "attached", "enclose", "enclosed", "declare",
        "you", "your", "yours", "my", "our", "us", "we", "it",
        "undersigned", "applicant", "inventor", "sir", "madam",
    ]

    nonisolated static func isPlausibleRoleValue(_ name: String) -> Bool {
        let tokens = name.split(separator: " ").map(String.init)
        guard (2...5).contains(tokens.count) else { return false }
        for token in tokens {
            let bare = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard bare.count >= 2 || (token.count == 2 && token.hasSuffix(".")) else { return false }
            guard bare.allSatisfy({ $0.isLetter }) else { return false }
            guard bare.first?.isUppercase == true else { return false }
            if roleStopwords.contains(bare.lowercased()) { return false }
        }
        let lower = name.lowercased()
        if EntityQualityGate.isMailInfraName(name) { return false }
        if EntityQualityGate.isTitleShaped(name) { return false }
        if EntityQualityGate.isAutomatedSender(lower) { return false }
        if EntityQualityGate.isNilFamily(lower) { return false }
        if EntityQualityGate.isFilenameShaped(lower) { return false }
        return true
    }

    /// P2.7 — a lowercase name captured by the POA FORMULA only.
    ///
    /// Everything `isPlausibleRoleValue` checks EXCEPT the uppercase-initial
    /// rule: 2-5 tokens, each alphabetic and >=2 chars, none a function word,
    /// and none of the register's junk classifiers. The casing rule is what the
    /// formula pattern has already earned the right to skip; nothing else is
    /// loosened, so a clause that somehow reached here is still refused.
    nonisolated static func isPlausibleLowercaseFormulaName(_ name: String) -> Bool {
        let tokens = name.split(separator: " ").map(String.init)
        guard (2...5).contains(tokens.count) else { return false }
        for token in tokens {
            let bare = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard bare.count >= 2 || (token.count == 2 && token.hasSuffix(".")) else { return false }
            guard bare.allSatisfy({ $0.isLetter }) else { return false }
            if roleStopwords.contains(bare.lowercased()) { return false }
        }
        let lower = name.lowercased()
        if EntityQualityGate.isMailInfraName(name) { return false }
        if EntityQualityGate.isTitleShaped(name) { return false }
        if EntityQualityGate.isAutomatedSender(lower) { return false }
        if EntityQualityGate.isNilFamily(lower) { return false }
        if EntityQualityGate.isFilenameShaped(lower) { return false }
        return true
    }

    nonisolated static func cleanRoleName(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["mr. ", "mrs. ", "ms. ", "dr. ", "shri ", "smt. "] where t.lowercased().hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
        }
        return t.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

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
        // OCR RECOVERY (V0 noise class 4). On a scanned page the digits arrive
        // as letters — "Patent No. 7OO321" — and the strict pattern above,
        // which requires digits, matches nothing. Before this pass that meant
        // the value was not merely read wrongly: it was never recorded, and
        // nothing said a labeled identifier had been seen and abandoned. So a
        // scanned grant letter held no patent number at all.
        //
        // This runs SECOND on purpose. `seen` already holds everything the
        // strict reader captured, so a value read cleanly anywhere in the block
        // wins and is never re-minted as a repair. What lands here is only what
        // the clean reader could not see.
        var unrecoverableOCRCandidates = 0
        for (full, label, rawValue) in captureGroups(ocrNumberCapturePattern, in: text) {
            guard let recovered = OCRDigitRecovery.recover(rawValue) else {
                // Refused by the recovery gates — a word, or too little of it
                // left to restore. Counted so a page full of unreadable
                // identifiers is visible in the log rather than being a silent
                // nothing; never stored, because a guessed identifier can be
                // cited and a missing one cannot.
                if rawValue.contains(where: { !$0.isNumber }) { unrecoverableOCRCandidates += 1 }
                continue
            }
            let value = normalizeIdentifier(recovered)
            guard !value.isEmpty, !isDateShapedNumber(value) else { continue }
            let field: String
            switch label.lowercased() {
            case "application": field = "applicationNumber"
            case "publication": field = "publicationNumber"
            default:            field = "patentNumber"
            }
            guard seen.insert(field + "|" + value.lowercased()).inserted else { continue }
            facts.append(GenericFact(subjectLabel: subjectLabel, field: field, value: value,
                                     status: .sourceAsserted, confidence: ocrRecoveredConfidence,
                                     sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts,
                                     // The receipt keeps the SCANNED form, so a
                                     // reader sees "700321" against
                                     // "Patent No. 7OO321" and judges the repair.
                                     rawMatch: full.trimmingCharacters(in: .whitespaces),
                                     sourceCount: 1,
                                     derivation: .ocrCorrected))
        }
        if unrecoverableOCRCandidates > 0 {
            KalsmritikoshLog.knowledge.info("PatentDomainPack: \(unrecoverableOCRCandidates) labeled identifier(s) too mangled to recover")
        }

        // A1.1 (W-4c) — THE ROLE TABLE, as data: who stands in which role,
        // read from certificate fields, POA parties, and labeled lines. The
        // owner's witnessed gap: the POA plainly says "I, shirshendu sasmal…"
        // while the answer said "Not found: identity". Names are captured
        // conservatively (2–5 capitalized-or-lowercase word tokens before a
        // delimiter); the validity trim strips titles and trailing clauses.
        var rejectedRoleValues = 0
        for (field, pattern) in Self.rolePatterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(withName: "name")
                guard r.location != NSNotFound else { continue }
                let name = Self.cleanRoleName(ns.substring(with: r))
                guard name.split(separator: " ").count >= 2, name.count <= 60 else { continue }
                // W-5.1 — the role-value gate at write: clause-shaped values
                // are rejected and counted, never stored.
                // P2.7 — the POA formula's capture may be lowercase; every
                // other pattern still requires Title Case. `poaFormula` is true
                // only for the `\bI, <name> having/son of/...` pattern, whose
                // junk was removed at the pattern above, so this relaxation
                // cannot readmit "acknowledge receipt".
                let poaFormula = pattern.contains("\\bI,?")
                let plausible = Self.isPlausibleRoleValue(name)
                    || (poaFormula
                        && KnowledgeModuleFlags.isEnabled(.poaGrantorRecovery)
                        && Self.isPlausibleLowercaseFormulaName(name))
                guard plausible else { rejectedRoleValues += 1; continue }
                let key = field + "|" + name.lowercased()
                guard seen.insert(key).inserted else { continue }
                facts.append(GenericFact(subjectLabel: subjectLabel, field: field, value: name,
                                         status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID],
                                         producerVersion: DerivedProducerVersions.facts,
                                         rawMatch: String(ns.substring(with: m.range).prefix(160)), sourceCount: 1))
            }
        }

        if rejectedRoleValues > 0 {
            // Counted, never stored — the health panel's junk-in-register
            // invariant reads zero because of this gate.
            KalsmritikoshLog.knowledge.info("PatentDomainPack: role-value gate rejected \(rejectedRoleValues) clause-shaped candidate(s)")
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
        let atom = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        // W-4 validity gate: an identifier atom starts with a digit, or with
        // a REAL country code — exactly two UPPERCASE letters attached to a
        // digit. Anything else ("ed202331019665") is prose shrapnel: empty
        // out, and the caller's empty-guard drops it.
        if let first = atom.first, first.isNumber { return atom }
        let prefix = atom.prefix(2)
        if prefix.count == 2, prefix.allSatisfy({ $0.isLetter && $0.isUppercase }),
           atom.dropFirst(2).first?.isNumber == true {
            return atom
        }
        return ""
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
