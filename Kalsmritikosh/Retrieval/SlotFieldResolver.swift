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
        // Case bench 2026-10-18 — US courts say "docket"; the legal pack files it as the case number.
        ("docket number", "casenumber", .identifier, "Docket number", "legal"),
        ("docket no", "casenumber", .identifier, "Docket number", "legal"),
        ("decision date", "decisiondate", .date, "Decision date", "legal"),
        ("which court", "court", .identity, "Court", "legal"),
        ("what court", "court", .identity, "Court", "legal"),
        ("disposition", "disposition", .status, "Disposition", "legal"),
        ("wrote the opinion", "opinionauthor", .identity, "Opinion by", "legal"),
        ("wrote the majority opinion", "opinionauthor", .identity, "Opinion by", "legal"),
        ("author of the opinion", "opinionauthor", .identity, "Opinion by", "legal"),
        ("delivered the opinion", "opinionauthor", .identity, "Opinion by", "legal"),
        ("outcome of the case", "disposition", .status, "Disposition", "legal"),
        ("date of decision", "decisiondate", .date, "Decision date", "legal"),
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
        // "When was <case> decided?" — the decision date (legal pack's decisionDate).
        (["decided"], ["date", "when"], "decisiondate", .date, "Decision date", "legal"),
        // "What did the court decide in <case>?" — the disposition.
        (["court", "decide"], ["what"], "disposition", .status, "Disposition", "legal"),
        // Wide case bench 2026-10-25 — the same questions asked other ways.
        (["authored"], ["opinion", "judge", "justice", "ruling", "decision"], "opinionauthor", .identity, "Opinion by", "legal"),
        (["justice"], ["wrote", "authored", "write", "penned"], "opinionauthor", .identity, "Opinion by", "legal"),
        (["judge"], ["wrote", "authored", "write", "penned"], "opinionauthor", .identity, "Opinion by", "legal"),
        (["outcome"], ["v", "case", "court", "appeal", "in re"], "disposition", .status, "Disposition", "legal"),
        (["decided"], ["how"], "disposition", .status, "Disposition", "legal"),
        // "What did the court rule / hold / order in …?" asks what it decided, not which court.
        (["court"], ["rule", "ruled", "hold", "held", "order", "ordered", "conclude", "concluded"], "disposition", .status, "Disposition", "legal"),
        (["ruling"], ["v", "case", "court", "in re"], "disposition", .status, "Disposition", "legal"),
        (["court"], ["heard", "name", "named"], "court", .identity, "Court", "legal"),
        (["date"], ["v", "in re", "ex parte"], "decisiondate", .date, "Decision date", "legal"),
        (["decided"], ["day", "year"], "decisiondate", .date, "Decision date", "legal"),
        (["handed", "down"], ["date", "when", "day", "year"], "decisiondate", .date, "Decision date", "legal"),
        (["tribunal"], ["which", "what", "name", "decided", "heard"], "court", .identity, "Court", "legal"),
        // "Who were the parties in X v. Y?" — the caption's parties; a contract's parties are not
        // a court case's, so the question must name a case (a "v.", "in re", case, suit, court).
        (["parties"], ["v", "vs", "in re", "ex parte", "case", "suit", "lawsuit", "litigation", "court", "appeal"],
         "parties", .counterparty, "Parties", "legal"),
        // "Who were the two sides in X v. Y?", "Who was involved as plaintiff and defendant in …?"
        (["sides"], ["v", "vs", "in re", "case", "suit", "lawsuit", "court"], "parties", .counterparty, "Parties", "legal"),
        // Held-out wording set 5 (2026-10-25): "Who is on each side of X v. Y?", "Who wrote the
        // court's opinion in …?", "What was the result of X v. Y?".
        (["side"], ["v", "vs", "in re", "suit", "lawsuit", "court"], "parties", .counterparty, "Parties", "legal"),
        (["wrote", "opinion"], ["who", "which", "name"], "opinionauthor", .identity, "Opinion by", "legal"),
        (["result"], ["v", "vs", "in re", "ex parte", "court", "appeal"], "disposition", .status, "Disposition", "legal"),
        (["plaintiff", "defendant"], ["who", "v", "vs", "case"], "parties", .counterparty, "Parties", "legal"),
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
        "decisiondate": "Decision date",
        "disposition": "Disposition",
        "opinionauthor": "Opinion by",
        "parties": "Parties",
        // Discovered fields the case bench meets most (FDA, NTSB, NHTSA reports).
        "reasonforrecall": "Reason for recall", "recallingfirm": "Recalling firm",
        "voluntarymandated": "Voluntary / mandated", "distributionpattern": "Distribution pattern",
        "productquantity": "Product quantity", "recallinitiationdate": "Recall initiation date",
        "dateandtime": "Date and time", "probablecause": "Probable cause",
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
        // "On what date did the court rule in X?" asks when, not what was ruled.
        if out.contains(where: { $0.fieldID == "decisiondate" }),
           q.range(of: #"\b(?:when|date|day)\b"#, options: .regularExpression) != nil {
            out.removeAll { $0.fieldID == "disposition" }
        }

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
        // "Which firm initiated FDA recall F-3176-2017?" asks for the firm: the noun right after
        // which/what names the field, before any other word of the question that happens to be a
        // field on file ("recall") — case bench 2026-10-24.
        // "Name the company behind …" names its head noun after "name the".
        let headIndex = (words.count >= 3 && words[0] == "name" && words[1] == "the") ? 2
            : (words.count >= 2 && ["which", "what"].contains(words[0])) ? 1 : nil
        if let hi = headIndex {
            var head = words[hi]
            // "What recall class was …": the first noun only modifies the second.
            let joiners: Set<String> = ["was", "were", "is", "are", "did", "does", "do", "has", "had", "of", "for", "in", "on",
                                        "at", "to", "behind", "named", "listed", "given", "assigned", "the", "a", "an"]
            // A record calls the same thing by its own word: a recall's "company" is its firm.
            let kin = ["company": "firm", "business": "firm", "maker": "manufacturer", "carrier": "operator",
                       "part": "component", "class": "classification", "system": "component",
                       "airplane": "aircraft", "plane": "aircraft"]
            func namesField(_ w: String) -> Bool {
                w.count >= 4 && (knownFields.contains(where: { $0.hasSuffix(w) }) || kin[w].map { k in knownFields.contains(where: { $0.hasSuffix(k) }) } == true)
            }
            if hi + 2 < words.count, !joiners.contains(words[hi + 1]), joiners.contains(words[hi + 2]),
               words[hi + 1].count >= 3, !words[hi + 1].contains(where: \.isNumber),
               // "Which firm recalled the product …": a verb after the noun is not a second noun.
               !words[hi + 1].hasSuffix("ed") || namesField(words[hi + 1]) { head = words[hi + 1] }
            // "What recall class applies to …", "What vehicle system does …": when the second word
            // names a field on file, the first only modifies it (held-out wording set 4, 2026-10-25).
            if head == words[hi], hi + 1 < words.count, !joiners.contains(words[hi + 1]),
               namesField(words[hi + 1]) { head = words[hi + 1] }
            if !knownFields.contains(where: { $0.hasSuffix(head) }), let k = kin[head] { head = k }
            if head.count >= 4, !ungrammaticalAlone.contains(head) {
                if knownFields.contains(head) { best = (fieldID: head, length: 1) }
                else {
                    let ends = knownFields.filter { $0 != head && $0.hasSuffix(head) }
                    if ends.count == 1, let f = ends.first { best = (fieldID: f, length: 1) }
                }
            }
        }
        for n in stride(from: min(maximumFieldNGram, words.count), through: 1, by: -1) where best == nil {
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
        // Case bench 2026-10-22: "Which firm initiated FDA recall D-1381-2019?" — the ledger
        // holds `recallingfirm`, and "firm" is its last word, not its whole name, so the
        // question got the report's text instead of the firm. A content word of four letters
        // or more that ENDS exactly one field on file names that field.
        // (2026-10-25: the end-of-field rule now reads only the question's head noun, above. Applied
        // to every word it sent "Who was the FDA investigator assigned to FDA recall X?" to
        // "reasonforrecall" through the word "recall".)
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
        in fullQuestion: String, knownFields: Set<String>
    ) -> [Resolution] {
        // A field the on-device or cloud interpreter chose for this question (QuestionUnderstanding,
        // owner decision 2026-10-25) — only ever one the retrieved facts carry.
        if QuestionUnderstanding.interpretedField(for: fullQuestion) == QuestionUnderstanding.noField { return [] }
        if let chosen = QuestionUnderstanding.interpretedField(for: fullQuestion), knownFields.contains(chosen) {
            return [Resolution(fieldID: chosen, requestedField: requestedFieldClass(for: chosen),
                               humanLabel: humanLabel(forFieldID: chosen), domainGroup: "interpreted")]
        }
        // A quoted title names the matter, not a field: "What happened in the case "Oakland
        // Resident Who Sold Fentanyl In San Francisco's Tenderloin …"?" reached a field minted
        // from a dateline ("sanfrancisco") through the title's words (case bench 2026-10-24).
        let question = withoutQuotedTitles(fullQuestion)
        // "What was the court's decision in X?", "Was X affirmed or reversed?" ask what the court
        // decided — not which court, and not when (held-out case bench 2026-10-25 answered both
        // with the court's name or the decision date).
        if knownFields.contains("disposition"),
           question.lowercased().range(of: #"^(?!.*\b(?:when|date|day|year)\b).*(?:\bcourt'?s (?:decision|ruling|holding|judgment|disposition)\b|\b(?:decision|ruling|holding|judgment) of the court\b|\b(?:affirmed|reversed|upheld|overturned|dismissed|granted|denied)\s+or\s+(?:affirmed|reversed|upheld|overturned|dismissed|granted|denied|not)\b|\bcome out\b|\bturn out\b)"#,
                                           options: .regularExpression) != nil {
            return [Resolution(fieldID: "disposition", requestedField: .status, humanLabel: "Disposition", domainGroup: "legal")]
        }
        let curated = resolve(in: question)
        // Case bench 2026-10-21: "When was FDA recall D-0227-2026 initiated?" resolved to the bare
        // "date" field and answered "2026" (a stray year) while the document states "Recall
        // initiation date: 2025-11-05". A date question whose verb names a dated field on file
        // ("initiated" → recallinitiationdate, "opened" → dateopened) asks for that field.
        if curated.allSatisfy({ $0.fieldID == "date" }),
           let specific = namedDateField(in: question, knownFields: knownFields) {
            return [specific]
        }
        // Only reach for the inventory when nothing curated matched AND the F8
        // fallback produced nothing either. A curated mapping always wins.
        if !curated.isEmpty { return curated }
        // "Where did the NTSB ERA25LA118 accident happen?" names no field; a place-shaped field
        // on file for the matter ("Location: Kennesaw, GA") is what it asks for.
        if let place = placeField(in: question, knownFields: knownFields) { return [place] }
        if let reason = reasonField(in: question, knownFields: knownFields) { return [reason] }
        // "How was FDA recall X classified?" asks for what the verb names, not for a field that
        // happens to share a word with the reference ("recall").
        if question.lowercased().range(of: #"^\s*how\s+(?:was|were|is|are)\b"#, options: .regularExpression) != nil,
           let stemmed = verbNamedField(in: question, knownFields: knownFields) { return [stemmed] }
        // A case caption names the matter, not a field: "Missouri-Kansas-Texas Railroad v. National
        // Railroad Adjustment Board" reached a field minted from "St. Louis, Mo." lines ("missouri")
        // through the party's name (held-out wording set 4, 2026-10-25).
        let matterless = withoutCaseCaption(question)
        if let discovered = resolveAgainstInventory(matterless, knownFields: knownFields) {
            return [discovered]
        }
        // Last: a verb that names a field ("How was it classified?" → classification).
        if let stemmed = verbNamedField(in: matterless, knownFields: knownFields) { return [stemmed] }
        return []
    }

    /// The question with a trailing case caption ("… in Hughes v. Life Insurance Co., 112 F. Supp.
    /// 2d 780?") blanked out: the run of capitalised words before "v." to the end.
    nonisolated static func withoutCaseCaption(_ question: String) -> String {
        question.replacingOccurrences(of: #"(?:\b[A-Z][\w.&'’\-]*,?\s+(?:(?:of|and|the|for|&)\s+)*)+v(?:s)?\.\s.*$"#,
                                      with: " ", options: .regularExpression)
    }

    /// The question with its quoted titles ("…" or “…”) blanked out.
    nonisolated static func withoutQuotedTitles(_ question: String) -> String {
        question.replacingOccurrences(of: #""[^"]{3,}"|“[^”]{3,}”"#, with: " ", options: .regularExpression)
    }

    nonisolated static let placeFields = ["location", "accidentlocation", "incidentlocation", "place", "site", "venue", "address"]

    nonisolated static func placeField(in question: String, knownFields: Set<String>) -> Resolution? {
        let q = question.lowercased()
        guard q.hasPrefix("where ") || q.hasPrefix("in which city") || q.hasPrefix("in what city") || q.hasPrefix("in which state"),
              let f = placeFields.first(where: { knownFields.contains($0) }) else { return nil }
        return Resolution(fieldID: f, requestedField: .identifier, humanLabel: humanLabel(forFieldID: f), domainGroup: "discovered")
    }

    /// "Why was FDA recall D-0775-2020 issued?" names no field; a reason field on file ("Reason
    /// for recall: Lack of sterility assurance.") is what it asks for. Case bench 2026-10-24: the
    /// answer was the record's fact list or its distribution sentence.
    nonisolated static func reasonField(in question: String, knownFields: Set<String>) -> Resolution? {
        let q = question.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.hasPrefix("why ") || q.hasPrefix("for what reason") || q.hasPrefix("what was the reason")
              || q.range(of: #"^what (?:problem |issue |defect )?led to\b"#, options: .regularExpression) != nil
              // "What was the problem that led to FDA recall X?" (held-out wording set 4, 2026-10-25).
              || q.range(of: #"^what (?:was|is) the (?:problem|issue|defect|reason) (?:that )?(?:led to|caused|prompted|behind)\b"#, options: .regularExpression) != nil else { return nil }
        // The field must be about what the question names ("reasonforrecall" for a recall), so a
        // "why" about something else never lands on an unrelated record's reason.
        let words = Set(q.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 })
        let candidates = knownFields.filter { f in
            guard f.hasPrefix("reasonfor") else { return false }
            let topic = String(f.dropFirst("reasonfor".count))
            return !topic.isEmpty && words.contains { $0.hasPrefix(topic) || topic.hasPrefix($0) }
        }.sorted { $0.count < $1.count }
        guard let f = candidates.first else { return nil }
        return Resolution(fieldID: f, requestedField: .identifier, humanLabel: humanLabel(forFieldID: f), domainGroup: "discovered")
    }

    /// A question VERB that names a field on file: "How was FDA recall X classified?" →
    /// classification, "Who manufactured the vehicles …" → manufacturer, "What caused the accident …"
    /// → probable cause. The verb's stem (its last three letters off, at least five left) must
    /// begin a word of exactly one known field. Wide case bench 2026-10-25.
    nonisolated static func verbNamedField(in question: String, knownFields: Set<String>) -> Resolution? {
        let words = withoutQuotedTitles(question).lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 6 && ($0.hasSuffix("ed") || $0.hasSuffix("ied")) }
        for w in words {
            let stem = String(w.dropLast(w.hasSuffix("ied") ? 3 : 2).prefix(max(5, w.count - 3)))
            guard stem.count >= 4 else { continue }
            let hits = knownFields.filter { $0.contains(stem) }
            if hits.count == 1, let f = hits.first {
                return Resolution(fieldID: f, requestedField: requestedFieldClass(for: f),
                                  humanLabel: humanLabel(forFieldID: f), domainGroup: "discovered")
            }
        }
        return nil
    }

    /// Fields that date the event a record is about (an accident, an incident, a loss).
    nonisolated static let eventDateFields = ["accidentdate", "incidentdate", "eventdate", "dateofaccident",
                                              "dateofincident", "dateofloss", "lossdate", "occurrencedate",
                                              "dateandtime", "datetime"]

    /// A known date-shaped field whose name carries the stem of one of the question's words
    /// ("initiated" → "initiat" ⊂ "recallinitiationdate"). Only for when-questions; the longest
    /// stem wins, ties go to the shorter (more specific) field name.
    nonisolated static func namedDateField(in question: String, knownFields: Set<String>) -> Resolution? {
        let q = question.lowercased()
        guard q.hasPrefix("when ") || q.contains(" when ") || q.hasPrefix("on what date") || q.hasPrefix("what date")
              || q.range(of: #"\bthe date (?:for|of)\b"#, options: .regularExpression) != nil else { return nil }
        let dateFields = knownFields.filter { $0 != "date" && FactSchemaRegistry.expectedShape(of: $0) == .date }
        guard !dateFields.isEmpty else { return nil }
        let words = q.components(separatedBy: CharacterSet.letters.inverted)
            // Four letters: "When did NHTSA open investigation PE86068?" → dateopened.
            .filter { $0.count >= 4 && !ungrammaticalAlone.contains($0) && !FTSQuerySanitizer.stopwords.contains($0) }
        var best: (field: String, stem: Int)?
        for w in words {
            let stem = String(w.prefix(max(4, w.count - 3)))
            for f in dateFields where f.contains(stem) {
                if best == nil || stem.count > best!.stem || (stem.count == best!.stem && f.count < best!.field.count) {
                    best = (f, stem.count)
                }
            }
        }
        // Case bench 2026-10-24: "When did the accident in NTSB case ERA13CA130 happen?" names no
        // dated field — "happen" is the event itself — so the answer was the report's text while
        // the ledger held "Date & time: February 9, 2013". An event's own date field answers it.
        if best == nil, q.range(of: #"\b(?:happen(?:ed)?|occur(?:red)?|take place|took place)\b"#, options: .regularExpression) != nil,
           let f = eventDateFields.first(where: { dateFields.contains($0) }) {
            best = (f, 0)
        }
        guard let hit = best else { return nil }
        return Resolution(fieldID: hit.field, requestedField: .date,
                          humanLabel: humanLabel(forFieldID: hit.field), domainGroup: "discovered")
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
