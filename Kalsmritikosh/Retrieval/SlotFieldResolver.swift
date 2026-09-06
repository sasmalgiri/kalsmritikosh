//
//  SlotFieldResolver.swift
//  Kalsmritikosh
//
//  D-11 (P0 answer-quality pack) — identifier-class field routing. "What is
//  the granted patent number" is a SLOT question about a registered fact
//  field, not a request for a definition; the doc-side role detector mapped
//  every "what is the ⟨X⟩" to `.definition`, so the sufficiency footer
//  reported "Not found …: definition" while the value sat in the ledger.
//
//  This resolver tests the question against the registered fact-field
//  vocabulary — FactSchemaRegistry names, the DomainPack field ids (distinct
//  since 80ac42d), and a synonym table — BEFORE the definition mapping.
//  It also owns the lowercase-field → human label table (D-12: the ledger
//  stores "applicationnumber"; rendering must say "Application number").
//
//  Deterministic, offline, pure.
//

import Foundation

public enum SlotFieldResolver {

    /// One resolved slot: the ledger field id (normalized lowercase), the
    /// RequestedField class it rides, and the label the UI prints.
    public struct Resolution: Sendable, Hashable {
        public let fieldID: String
        public let requestedField: RequestedField
        public let humanLabel: String
        /// Fields that belong to the same document family — used by the
        /// honest not-found sentence to mention the evidence that DOES exist
        /// ("shows the grant (Patent No. …) but no grant date").
        public let domainGroup: String
    }

    /// Synonym table: phrase (matched on word boundaries, lowercased) →
    /// resolution. Longest phrase wins so "granted patent number" beats
    /// "patent number" in ordering but both resolve identically.
    nonisolated static let vocabulary: [(phrase: String, fieldID: String, class_: RequestedField, label: String, group: String)] = [
        ("granted patent number", "patentnumber", .identifier, "Patent number", "patent"),
        ("patent number", "patentnumber", .identifier, "Patent number", "patent"),
        ("patent no", "patentnumber", .identifier, "Patent number", "patent"),
        ("application number", "applicationnumber", .identifier, "Application number", "patent"),
        ("application no", "applicationnumber", .identifier, "Application number", "patent"),
        ("publication number", "publicationnumber", .identifier, "Publication number", "patent"),
        ("publication no", "publicationnumber", .identifier, "Publication number", "patent"),
        ("grant date", "grantdate", .date, "Grant date", "patent"),
        ("date of grant", "grantdate", .date, "Grant date", "patent"),
        ("filing date", "filingdate", .date, "Filing date", "patent"),
        ("date of filing", "filingdate", .date, "Filing date", "patent"),
        ("invoice number", "invoicenumber", .identifier, "Invoice number", "transaction"),
        ("invoice no", "invoicenumber", .identifier, "Invoice number", "transaction"),
        ("case number", "casenumber", .identifier, "Case number", "legal"),
        ("case no", "casenumber", .identifier, "Case number", "legal"),
        ("pan number", "pan", .identifier, "PAN", "identity"),
        ("pan", "pan", .identifier, "PAN", "identity"),
        ("gstin number", "gstin", .identifier, "GSTIN", "identity"),
        ("gstin", "gstin", .identifier, "GSTIN", "identity"),
        ("doi", "doi", .identifier, "DOI", "research"),
        ("amount", "amount", .monetaryAmount, "Amount", "transaction"),
        ("fee", "amount", .monetaryAmount, "Amount", "transaction"),
        ("amount paid", "amount", .monetaryAmount, "Amount", "transaction"),
        // A1.1 — the role table's ask-side names ("who is the owner of this
        // patent" resolves to the applicant field; proprietor/holder too).
        ("applicant", "applicant", .counterparty, "Applicant", "patent"),
        ("inventor", "inventor", .counterparty, "Inventor", "patent"),
        ("proprietor", "applicant", .counterparty, "Applicant", "patent"),
        ("patent holder", "applicant", .counterparty, "Applicant", "patent"),
    ]

    /// Combined-cue rules for phrasings that name the field indirectly:
    /// "on which date was the patent granted" carries no "grant date"
    /// bigram, but ⟨patent⟩ + ⟨granted⟩ + ⟨date/when⟩ names it exactly.
    /// Scoped to questions that mention the document family, so a generic
    /// "when was it granted" never resolves.
    nonisolated static let comboRules: [(required: [String], anyOf: [String], fieldID: String, class_: RequestedField, label: String, group: String)] = [
        (["patent", "granted"], ["date", "when"], "grantdate", .date, "Grant date", "patent"),
        (["patent", "grant"], ["date", "when"], "grantdate", .date, "Grant date", "patent"),
        (["patent", "filed"], ["date", "when"], "filingdate", .date, "Filing date", "patent"),
        (["patent", "filing"], ["date", "when"], "filingdate", .date, "Filing date", "patent"),
        // A1.1 — "who is the owner/holder of this patent" (no field bigram).
        (["patent"], ["owner", "owns", "proprietor", "holder", "belongs"], "applicant", .counterparty, "Applicant", "patent"),
    ]

    /// Lowercase ledger field id → human label, for every field the packs
    /// and registry emit. Fallback: first letter uppercased, rest unchanged
    /// (the pre-D-12 behavior, correct for single-word fields).
    nonisolated static let humanLabels: [String: String] = [
        "applicationnumber": "Application number",
        "publicationnumber": "Publication number",
        "patentnumber": "Patent number",
        "grantdate": "Grant date",
        "filingdate": "Filing date",
        "invoicenumber": "Invoice number",
        "casenumber": "Case number",
        "pan": "PAN", "gstin": "GSTIN", "doi": "DOI",
        "amount": "Amount", "counterparty": "Counterparty",
        "employer": "Employer", "role": "Role", "status": "Status",
        "date": "Date", "email": "Email", "phone": "Phone", "location": "Location",
    ]

    public nonisolated static func humanLabel(forFieldID fieldID: String) -> String {
        let key = fieldID.lowercased()
        if let label = humanLabels[key] { return label }
        // F8 — synthetic field-shaped ids ("trademarknumber") render with the
        // suffix split back out ("Trademark number"), so the abstention names
        // the field the way the user asked it.
        for suffix in ["number", "date", "id"] where key.hasSuffix(suffix) && key.count > suffix.count {
            let stem = String(key.dropLast(suffix.count))
            return stem.prefix(1).uppercased() + stem.dropFirst() + " " + suffix
        }
        return fieldID.prefix(1).uppercased() + fieldID.dropFirst()
    }

    /// Resolve every registered fact field the question names, ordered by
    /// where the naming phrase appears. Empty when the question names none —
    /// the caller then applies the ordinary field mapping (incl. definition).
    public nonisolated static func resolve(in question: String) -> [Resolution] {
        let q = question.lowercased()
        var out: [Resolution] = []
        var seenFields = Set<String>()

        // Longest-phrase-first so "granted patent number" claims its span
        // before "patent number" re-reports the same field.
        var positioned: [(position: Int, r: Resolution)] = []
        for entry in vocabulary.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            guard let range = wordBoundedRange(of: entry.phrase, in: q) else { continue }
            guard !seenFields.contains(entry.fieldID) else { continue }
            seenFields.insert(entry.fieldID)
            positioned.append((q.distance(from: q.startIndex, to: range.lowerBound),
                               Resolution(fieldID: entry.fieldID, requestedField: entry.class_,
                                          humanLabel: entry.label, domainGroup: entry.group)))
        }
        for rule in comboRules {
            guard !seenFields.contains(rule.fieldID) else { continue }
            let hasRequired = rule.required.allSatisfy { wordBoundedRange(of: $0, in: q) != nil }
            let hasCue = rule.anyOf.contains { wordBoundedRange(of: $0, in: q) != nil }
            if hasRequired && hasCue {
                seenFields.insert(rule.fieldID)
                positioned.append((q.count,
                                   Resolution(fieldID: rule.fieldID, requestedField: rule.class_,
                                              humanLabel: rule.label, domainGroup: rule.group)))
            }
        }
        out = positioned.sorted { $0.position < $1.position }.map(\.r)

        // F8 (rung 1n) — FIELD-SHAPED FALLBACK, only when the vocabulary named
        // nothing: "what is the trademark number" is unmistakably a field
        // request even though no pack emits trademark numbers. Recognizing it
        // routes the ask onto the slot path, whose honest not-found (D-15)
        // then NAMES the field with a receipt — instead of the general path's
        // fact-spam. Conservative: "<word> number|id" (identifier) or
        // "<word> date" (date), word ≥3 chars and never a stopword, so
        // "a number of things" and "any number" never resolve.
        if out.isEmpty {
            out = fieldShapedFallback(in: q)
        }
        return out
    }

    /// The F8 fallback recognizer. Deterministic; first match wins.
    nonisolated static func fieldShapedFallback(in q: String) -> [Resolution] {
        let suffixes: [(suffix: String, class_: RequestedField)] = [
            ("number", .identifier), ("id", .identifier), ("date", .date)
        ]
        let words = q.split { !$0.isLetter }.map(String.init)
        for (i, word) in words.enumerated() where i + 1 < words.count {
            for (suffix, class_) in suffixes where words[i + 1] == suffix {
                guard word.count >= 3, !FTSQuerySanitizer.stopwords.contains(word) else { continue }
                let fieldID = FactSchemaRegistry.normalizeField(word + suffix)
                let label = word.prefix(1).uppercased() + word.dropFirst() + " " + suffix
                return [Resolution(fieldID: fieldID, requestedField: class_,
                                   humanLabel: label, domainGroup: "unknown")]
            }
        }
        return []
    }

    /// `phrase` present in `text` with word boundaries on both sides — so
    /// "pan" never matches inside "company" or "panel".
    nonisolated static func wordBoundedRange(of phrase: String, in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let r = text.range(of: phrase, range: search..<text.endIndex) {
            let beforeOK = r.lowerBound == text.startIndex
                || !isWordChar(text[text.index(before: r.lowerBound)])
            let afterOK = r.upperBound == text.endIndex
                || !isWordChar(text[r.upperBound])
            if beforeOK && afterOK { return r }
            search = r.upperBound
        }
        return nil
    }

    private nonisolated static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}
