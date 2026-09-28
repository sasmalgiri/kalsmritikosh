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

    /// INTERROGATIVE SHAPE CUES — phrases that name a field's VALUE SHAPE
    /// rather than its name. "how much did I pay?" asks for money without ever
    /// saying "amount"; "when was it sent?" asks for a date without saying
    /// "date". The relevance gates that decide which ledger facts may be shown
    /// compare question words against a fact's field NAME and value, so
    /// without this they drop the `amount` fact for "how much?" — the field is
    /// named by the question's GRAMMAR, not its vocabulary, and no amount of
    /// synonym listing reaches it.
    ///
    /// Deliberately limited to MONEY and DATE — the only two shapes an
    /// interrogative names unambiguously and that are narrow enough to be safe.
    /// "who", "what" and "where" are excluded on purpose: the fields they range
    /// over (applicant, employer, counterparty, location, role …) are all
    /// `.text`, so a cue for them would admit EVERY text-shaped fact riding the
    /// retrieval — which is precisely the dump these gates exist to stop.
    nonisolated static let shapeCues: [(phrases: [String], shapes: Set<FactSchemaRegistry.ValueShape>)] = [
        (["how much", "how many", "what amount", "total cost", "cost of", "price",
          "how expensive", "payable"], [.money, .number]),
        (["when", "what date", "which date", "on what day", "how long ago"], [.date]),
    ]

    /// The value shapes this question asks for, via `shapeCues`. Empty when the
    /// question names no shape — which is the common case and means the callers'
    /// ordinary term-overlap rules decide alone.
    public nonisolated static func requestedValueShapes(
        in question: String
    ) -> Set<FactSchemaRegistry.ValueShape> {
        let q = question.lowercased()
        var out: Set<FactSchemaRegistry.ValueShape> = []
        for cue in shapeCues where cue.phrases.contains(where: { wordBoundedRange(of: $0, in: q) != nil }) {
            out.formUnion(cue.shapes)
        }
        return out
    }

    /// Whether `question` asks for the shape `field` holds — the cheap check
    /// the relevance gates call. False when the question names no shape, so it
    /// only ever ADMITS a fact, never excludes one.
    public nonisolated static func questionRequestsShape(
        ofField field: String, in question: String
    ) -> Bool {
        let shapes = requestedValueShapes(in: question)
        guard !shapes.isEmpty else { return false }
        return shapes.contains(FactSchemaRegistry.expectedShape(of: field))
    }

    /// A2.3 — REGISTRY-ALIAS EXPANSION: when the question carries one alias
    /// of a field ("patent no"), the canonical phrase joins the keyword
    /// query ("patent number") so FTS recall never depends on which spelling
    /// the document used. Deterministic; appends, never rewrites.
    public nonisolated static func expandAliases(_ question: String) -> String {
        let q = question.lowercased()
        var additions: [String] = []
        var seen = Set<String>()
        for entry in vocabulary where q.contains(entry.phrase) {
            let canonical = entry.label.lowercased()
            if canonical != entry.phrase, !q.contains(canonical), seen.insert(canonical).inserted {
                additions.append(canonical)
            }
        }
        return additions.isEmpty ? question : question + " " + additions.joined(separator: " ")
    }

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

    // MARK: - P3.4 · resolve against the LEDGER'S OWN FIELDS
    //
    // `vocabulary` holds ~25 hand-written phrases. That was sufficient while
    // every fact came from eleven domain packs whose fields were known in
    // advance. With P3.1's open-field extractor the ledger can now hold
    // `chassisnumber`, `policynumber`, `attendingphysician`, `containerid` —
    // fields nobody enumerated — and a fixed phrase list can never name them.
    // Open extraction without open ASKING just fills a ledger nobody can query.
    //
    // THE TRICK IS THAT IT IS THE EXACT INVERSE OF THE EXTRACTOR.
    // `OpenFieldExtractor.normalizeLabel` turns "Chassis Number" into
    // "chassisnumber" by lowercasing and dropping non-alphanumerics. So to go
    // back, take consecutive words from the question, normalize them the same
    // way, and test membership in the field inventory:
    //
    //      "what is the chassis number"
    //        → n-grams: "what", "whatis", "chassis", "chassisnumber", ...
    //        → "chassisnumber" ∈ knownFields  ✓
    //
    // No synonym table, no model, no new vocabulary — and it cannot invent a
    // field, because a match must be a field the ledger ACTUALLY HOLDS. That
    // last property is what makes it safe: the worst case is no match, which
    // falls through to the honest field-named not-found.

    /// Longest n-gram first: "grant date" must beat "date" when the ledger has
    /// both, or the more specific question resolves to the vaguer field.
    nonisolated static let maximumFieldNGram = 4

    /// Question words that must never form part of a field name on their own.
    /// Without this, "what is the date" resolves "date" from the word "date"
    /// in a question about something else entirely — and more importantly
    /// "number"/"name" alone are far too generic to answer with.
    nonisolated static let ungrammaticalAlone: Set<String> = [
        "what", "which", "who", "whom", "when", "where", "why", "how",
        "is", "was", "are", "were", "the", "a", "an", "of", "in", "on",
        "for", "to", "my", "our", "his", "her", "their", "its", "this",
        "that", "did", "does", "do", "any", "all", "some", "show", "list",
        "tell", "give", "find", "get", "number", "name", "date", "value",
        "id", "no", "total", "amount", "type", "kind", "detail", "details",
    ]

    /// Resolve the question against the ledger's ACTUAL field inventory.
    ///
    /// Runs only after `vocabulary`, `comboRules` and the F8 field-shaped
    /// fallback have all declined — so it never overrides a curated mapping,
    /// it only reaches fields nobody curated. Returns at most one resolution:
    /// the longest n-gram match, which is the most specific reading.
    public nonisolated static func resolveAgainstInventory(
        _ question: String, knownFields: Set<String>
    ) -> Resolution? {
        guard KnowledgeModuleFlags.isEnabled(.openFieldAsking) else { return nil }
        guard !knownFields.isEmpty else { return nil }
        let words = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var best: (fieldID: String, length: Int)?
        for n in stride(from: min(maximumFieldNGram, words.count), through: 1, by: -1) {
            for start in 0...(words.count - n) {
                let gram = Array(words[start..<(start + n)])
                // A single word that is a question word or a bare generic
                // ("number", "date") is not a field name. Two or more words
                // are specific enough that the inventory match carries the
                // weight — "grant date" is a real field, "date" is not a
                // question.
                if n == 1, ungrammaticalAlone.contains(gram[0]) { continue }
                let candidate = gram.joined()
                guard knownFields.contains(candidate) else { continue }
                if best == nil || n > best!.length {
                    best = (fieldID: candidate, length: n)
                }
            }
            // Longest wins; once a length matches there is no better one below.
            if best != nil { break }
        }
        guard let hit = best else { return nil }
        return Resolution(
            fieldID: hit.fieldID,
            // The SHAPE comes from the registry, which is open by design — an
            // unknown field is `.text`. So a discovered field is typed the same
            // way a curated one is.
            requestedField: requestedFieldClass(for: hit.fieldID),
            humanLabel: humanLabel(forFieldID: hit.fieldID),
            domainGroup: "discovered")
    }

    /// Map a value shape onto the `RequestedField` class the planner uses, so a
    /// discovered field routes exactly like a curated one of the same shape.
    nonisolated static func requestedFieldClass(for fieldID: String) -> RequestedField {
        switch FactSchemaRegistry.expectedShape(of: fieldID) {
        case .identifier:                return .identifier
        case .date:                      return .date
        case .money:                     return .monetaryAmount
        case .email, .phone, .url, .text, .number, .duration, .boolean:
            return .identifier
        }
    }

    /// `resolve` plus the inventory fallback, in one call. This is the entry
    /// point callers that HAVE the inventory should use; `resolve(in:)` stays
    /// unchanged for callers that do not, so nothing existing shifts.
    public nonisolated static func resolve(
        in question: String, knownFields: Set<String>
    ) -> [Resolution] {
        let curated = resolve(in: question)
        // Only reach for the inventory when nothing curated matched AND the F8
        // fallback produced nothing either. A curated mapping always wins.
        if !curated.isEmpty { return curated }
        if let discovered = resolveAgainstInventory(question, knownFields: knownFields) {
            return [discovered]
        }
        return []
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
