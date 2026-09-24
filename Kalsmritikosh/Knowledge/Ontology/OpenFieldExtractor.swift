//
//  OpenFieldExtractor.swift
//  Kalsmritikosh
//
//  P3.1 — THE UNIVERSALITY UNIT. Facts from documents nobody anticipated.
//
//  THE PROBLEM IT SOLVES. Every `GenericFact` in the ledger came from one of
//  eleven hard-coded domain packs: employment, transaction, contract, patent,
//  research, medical, legal case, vital records, financial statement, property,
//  identity document. A shipping manifest, a car service record, a school
//  report, a lab instrument log, an insurance claim, a building permit — each
//  produced chunks and ZERO facts. The answer then fell back to quoting
//  passages instead of answering from structure, so the
//  database-in-the-middle — the actual moat — was empty for any domain nobody
//  had written a pack for.
//
//  The STORAGE model was never the limitation. `GenericFact` is domain-neutral
//  and `FactSchemaRegistry` states outright: "Open — an unknown field is
//  `.text`, never dropped". Only the PRODUCERS were closed. This is a producer.
//
//  THE INSIGHT IT RESTS ON. Documents state facts the same way in every domain:
//
//      Registration No: MH-12-AB-1234          ← a vehicle record
//      Policy Number   : 4471-99812            ← an insurance page
//      Container ID — MSCU4416782              ← a shipping manifest
//      Roll No:        21BCE1043               ← a school report
//
//  `Label <separator> value`. The domain changes; the shape does not. Capturing
//  that shape generally removes the need for eleven packs to become fifty.
//
//  WHY THE GATES ARE THE REAL WORK. An ungated version of this floods the
//  ledger: every colon in every sentence becomes a "fact", and a ledger of
//  noise is worse than an empty one because noise gets cited. So the extractor
//  refuses far more than it accepts, and each gate below exists because of a
//  specific way prose imitates a label. The ordering matters too — cheap
//  structural rejections run before expensive ones.
//
//  WHAT IT WILL NOT DO. It never emits a field an existing domain pack can
//  emit (`reservedFields`). That is the "ADD, NEVER PERTURB" guarantee: the
//  eleven packs keep exclusive ownership of their fields, so every existing
//  fixture must produce byte-identical output with this pass enabled. A
//  universality feature that silently changed patent extraction would not be
//  worth having.
//
//  Deterministic, offline, no model. Gated by `.openFieldExtraction`.
//

import Foundation

public enum OpenFieldExtractor {

    // MARK: - Tunables, each with the failure it prevents

    /// Separators that introduce a value. `:` dominates; the dashes appear in
    /// manifests and forms. A bare space is NOT a separator — "Total 500" is
    /// indistinguishable from ordinary prose, and admitting it was the single
    /// largest noise source when this was prototyped mentally.
    static let separators: [Character] = [":", "：", "=", "—", "–"]

    /// A label is at most this many words. Real labels are short ("Policy
    /// Number", "Date of Manufacture"); a ten-word run before a colon is a
    /// sentence introducing a quote or a list.
    static let maximumLabelWords = 5

    /// And at least this many characters, so "A:" or "x=" cannot mint a field.
    static let minimumLabelCharacters = 3

    /// Value bounds. Below 1 there is nothing; above this it is prose that
    /// happens to follow a colon — a summary, a quotation, a paragraph.
    static let maximumValueCharacters = 120

    /// Per-document cap. One malformed page — a table of contents, an OCR'd
    /// form grid, a CSV pasted into a document — can present hundreds of
    /// label-like lines. A cap keeps a single bad document from dominating the
    /// ledger, and hitting it is itself a signal worth recording.
    static let maximumFieldsPerDocument = 60

    /// Words that end a label but prove it is prose, not a field name. Each was
    /// chosen because it introduces a clause: "The reason is: ...",
    /// "Note that: ...". A label ending in one of these is a sentence.
    static let proseLabelTails: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "that", "which",
        "who", "whom", "because", "since", "however", "therefore", "thus",
        "note", "notes", "example", "examples", "following", "follows",
        "says", "said", "states", "stated", "reads", "means", "includes",
        "including", "namely", "viz", "eg", "ie", "etc",
    ]

    /// Words that cannot START a label. A label is a noun phrase; these open
    /// clauses and questions.
    static let proseLabelHeads: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "it", "he", "she",
        "they", "we", "i", "you", "if", "when", "while", "although", "though",
        "but", "and", "or", "so", "because", "however", "please", "kindly",
        "what", "why", "how", "where", "who", "whether", "in", "on", "at",
        "to", "for", "with", "by", "from", "of", "as", "per",
    ]

    /// Values that are placeholders, not data. A form's empty field says
    /// "N/A"; storing that as a fact asserts a value the document denies.
    static let placeholderValues: Set<String> = [
        "n/a", "na", "nil", "none", "null", "-", "--", "---", "tbd", "tba",
        "not applicable", "not available", "unknown", "blank", "x", "xx",
        "xxx", "pending", "see below", "see above", "as above", "same",
        "do", "ditto", "________", "____", "...", "n.a.",
    ]

    // MARK: - The reserved set — the ADD-NEVER-PERTURB guarantee

    /// Every field the eleven domain packs can emit, normalized. The open
    /// extractor NEVER emits one of these, so pack-owned fields keep exactly
    /// the extraction they have today and every existing fixture is unaffected.
    ///
    /// Built from each pack's own `emittedFields` where declared, plus the two
    /// `ResearchDomainPack` emits inline (it declares no list — recorded here
    /// rather than silently missed).
    public nonisolated static let reservedFields: Set<String> = {
        var raw: [String] = []
        raw += PatentDomainPack.emittedFields
        raw += EmploymentDomainPack.emittedFields
        raw += TransactionDomainPack.emittedFields
        raw += ContractDomainPack.emittedFields
        raw += MedicalDomainPack.emittedFields
        raw += LegalCaseDomainPack.emittedFields
        raw += VitalRecordsDomainPack.emittedFields
        raw += FinancialStatementDomainPack.emittedFields
        raw += PropertyDomainPack.emittedFields
        raw += IdentityDocumentDomainPack.emittedFields
        // ResearchDomainPack declares no emittedFields; these are what it writes.
        raw += ["doi", "date"]
        // Structural fields the ledger owns for its own purposes.
        raw += ["status", "applicant", "inventor", "counterparty", "employer",
                "role", "amount", "location", "email", "phone"]
        return Set(raw.map { FactSchemaRegistry.normalizeField($0) })
    }()

    // MARK: - Extraction

    /// One captured pair, before it becomes a fact.
    public struct OpenField: Sendable, Equatable {
        public let fieldID: String
        public let label: String
        public let value: String
        /// Confidence, set by the block kind the pair was found in — a table
        /// cell is structurally a field; a paragraph merely looks like one.
        public let confidence: Double
    }

    /// Confidence by block kind. The block's STRUCTURE is real evidence about
    /// whether a colon means "field" — a key/value or table row was laid out as
    /// data by whoever wrote the document, while a paragraph was laid out as
    /// prose and only resembles data.
    nonisolated static func confidence(for kind: EvidenceBlockKind) -> Double? {
        switch kind {
        case .tableRow, .tableCell, .table:
            return 0.75
        case .listItem, .documentHeader, .sectionHeading, .slideBody:
            return 0.65
        case .paragraph, .documentTitle, .slideTitle, .emailBody:
            return 0.55
        // Never: boilerplate and furniture. A page footer's "Page 3 of 9: ..."
        // or a signature block's "Sent from: ..." is not a document fact, and a
        // disclaimer's colons are the densest false-label source there is.
        case .pageHeader, .pageFooter, .footnote, .endnote, .emailSignature,
             .emailDisclaimer, .quotedEmail, .codeBlock, .image, .figureCaption,
             .attachment, .emailHeader:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Extract open fields from one block's text.
    ///
    /// Returns `[]` for every block kind that cannot carry a field, so the
    /// caller does not need to know the policy.
    public nonisolated static func fields(in text: String, kind: EvidenceBlockKind) -> [OpenField] {
        guard let blockConfidence = confidence(for: kind) else { return [] }
        var out: [OpenField] = []
        var seenFieldIDs = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= minimumLabelCharacters + 2 else { continue }
            guard let pair = split(line) else { continue }
            guard isLabelLike(pair.label), isValueLike(pair.value) else { continue }

            let fieldID = FactSchemaRegistry.normalizeField(normalizeLabel(pair.label))
            guard !fieldID.isEmpty else { continue }
            // THE GUARANTEE: never touch a pack-owned field.
            guard !reservedFields.contains(fieldID) else { continue }
            // The ledger's own junk gate, reused rather than reimplemented.
            guard FactValuePlausibility.isAcceptable(field: fieldID, value: pair.value) else { continue }
            guard seenFieldIDs.insert(fieldID).inserted else { continue }

            out.append(OpenField(fieldID: fieldID, label: pair.label,
                                 value: pair.value, confidence: blockConfidence))
        }
        return out
    }

    /// Split at the FIRST separator only. A line like
    /// "Address: 12 Main St, Pune: 411001" has one label and one value; taking
    /// the last separator would make "411001" the value of a label containing a
    /// street address.
    nonisolated static func split(_ line: String) -> (label: String, value: String)? {
        guard let idx = line.firstIndex(where: { separators.contains($0) }) else { return nil }
        let label = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":=—–")))
        guard !label.isEmpty, !value.isEmpty else { return nil }
        return (label, value)
    }

    /// Is this a FIELD NAME, or the start of a sentence that happens to contain
    /// a colon?
    nonisolated static func isLabelLike(_ label: String) -> Bool {
        guard label.count >= minimumLabelCharacters, label.count <= 48 else { return false }
        let words = label.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= maximumLabelWords else { return false }

        // A label is a noun phrase: letters, spaces, and the punctuation forms
        // real labels use. Digits are allowed ("Line 2 Address") but a label
        // that is MOSTLY digits is a line number or a citation, not a name.
        let letters = label.filter(\.isLetter).count
        guard letters >= 2, Double(letters) / Double(label.count) >= 0.5 else { return false }
        for ch in label where !(ch.isLetter || ch.isNumber || ch == " " || ch == "." ||
                                ch == "_" || ch == "-" || ch == "/" || ch == "(" || ch == ")" ||
                                ch == "'" || ch == "&" || ch == "#") {
            return false
        }
        // Clause markers — the two gates that kill most prose.
        if let first = words.first?.lowercased().trimmingCharacters(in: .punctuationCharacters),
           proseLabelHeads.contains(first) { return false }
        if let last = words.last?.lowercased().trimmingCharacters(in: .punctuationCharacters),
           proseLabelTails.contains(last) { return false }
        // A sentence ending in terminal punctuation before the colon is prose.
        if label.hasSuffix(".") && words.count > 1 { return false }
        if label.contains("?") || label.contains("!") { return false }
        return true
    }

    /// Is this a VALUE, or prose that follows a colon?
    nonisolated static func isValueLike(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumValueCharacters else { return false }
        let lower = value.lowercased().trimmingCharacters(in: .whitespaces)
        // A placeholder asserts absence. Storing it would state a value the
        // document explicitly declines to give.
        guard !placeholderValues.contains(lower) else { return false }
        // A value is not a sentence. Multiple sentence-ending periods, or a
        // long word count, means the colon introduced prose.
        let words = value.split(separator: " ")
        guard words.count <= 14 else { return false }
        if value.filter({ $0 == "." }).count >= 3, words.count > 6 { return false }
        // Must carry at least one letter or digit — not only punctuation.
        guard value.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return true
    }

    /// "Date of Manufacture" → "dateofmanufacture"; "Roll No." → "rollno".
    /// Normalization is what lets the same field from two documents merge, so
    /// it must be stable and lossless enough to stay readable in the UI, where
    /// `SlotFieldResolver.humanLabel` re-splits it.
    nonisolated static func normalizeLabel(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    // MARK: - Facts

    /// Open fields for a whole document, as evidence-linked facts.
    ///
    /// `blocks` must be in document order. The cap applies across the document,
    /// not per block, because the flood this guards against is a whole page of
    /// label-like lines.
    public nonisolated static func extractFacts(
        blocks: [(id: UUID, text: String, kind: EvidenceBlockKind)],
        subjectLabel: String
    ) -> (facts: [GenericFact], cappedAt: Int?) {
        guard KnowledgeModuleFlags.isEnabled(.openFieldExtraction) else { return ([], nil) }
        var facts: [GenericFact] = []
        var seen = Set<String>()
        var capped: Int?

        for block in blocks {
            for field in fields(in: block.text, kind: block.kind) {
                guard facts.count < maximumFieldsPerDocument else {
                    capped = maximumFieldsPerDocument
                    return (facts, capped)
                }
                // Document-wide dedup: the same field repeated on every page of
                // a form is ONE fact with more evidence, not many facts. The
                // merge downstream unions the blocks.
                let key = field.fieldID + "|" + field.value.lowercased()
                guard seen.insert(key).inserted else { continue }
                facts.append(GenericFact(
                    subjectLabel: subjectLabel,
                    field: field.fieldID,
                    value: field.value,
                    status: .sourceAsserted,
                    confidence: field.confidence,
                    sourceBlockIDs: [block.id],
                    producerVersion: DerivedProducerVersions.facts,
                    // The receipt keeps the label AS WRITTEN, so a reader can
                    // see that "rollno" came from "Roll No." and judge the
                    // normalization themselves.
                    rawMatch: "\(field.label): \(field.value)",
                    sourceCount: 1))
            }
        }
        return (facts, capped)
    }
}
