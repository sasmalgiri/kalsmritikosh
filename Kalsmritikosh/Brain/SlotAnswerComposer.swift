//
//  SlotAnswerComposer.swift
//  Kalsmritikosh
//
//  D-12 + D-15 (P0 answer-quality pack). When the question names a
//  registered fact field (QueryPlan.slotFieldIDs, D-11), the primary answer
//  is ONE composed sentence — the requested value with its citations — or an
//  explicit two-value conflict, or an honest not-found that NAMES the
//  missing field and the related evidence that does exist. Never the old
//  every-assertion dump ("Reported: Applicationnumber: … ×3").
//
//  Deterministic, pure — the verifier feeds it retrieval-surfaced facts and
//  their carried ClaimEvaluations (S0.5: produced once, never re-derived).
//

import Foundation

public struct SlotAnswerComposition: Sendable {
    /// The primary answer sentence(s) — replaces the claims dump.
    public let primaryText: String
    /// Objects the primary sentence's facts are grounded in (for citation
    /// coverage — the claim–evidence contract).
    public let supportingObjectIDs: [UUID]
    /// Two different canonical values for the requested field.
    public let isConflict: Bool
    /// The requested field has no surfaced value (D-15 honest not-found).
    public let isNotFound: Bool
    /// D-14 slot-confidence profile inputs, logged by the caller.
    public let singleCanonicalValue: Bool
    public let structuredSource: Bool
    /// Compact "also on file" line for the detail footer (never the primary).
    public let alsoOnFile: String?
    /// Human label of the (first) requested field.
    public let requestedLabel: String
    /// W-5.5 — how many distinct values are in conflict (0 when none);
    /// the disagreement note reads "both values" only when it is two.
    public var conflictValueCount: Int = 0
    /// P2.3 — the single value the slot law cites (the stored value — never
    /// `rawMatch`, which is extraction provenance); the viewer finds it
    /// case-insensitively in the source.
    public var citedValue: String?
}

public enum SlotAnswerComposer {

    /// A surfaceable fact with the signals ranking needs.
    struct Candidate {
        let fact: GenericFact
        let objectID: UUID
        let presentation: ClaimPresentation
        let isAuthority: Bool
        /// S2-U1 — mean structural salience of the source object's retrieved
        /// chunks; a TIEBREAK after rank (tier + source-class), never before.
        var salience: Double = SalienceTable.neutral
    }

    /// Compose the slot answer for `slotFieldIDs` from the retrieval-surfaced
    /// facts. Returns nil when the plan carries no slot fields.
    /// "a grant date", "an invoice number", "the parties" — the field named as the sentence needs it.
    nonisolated static func withArticle(_ label: String) -> String {
        let l = label.lowercased()
        if l.hasSuffix("ies") || (l.hasSuffix("s") && !l.hasSuffix("ss") && !l.hasSuffix("us")) { return "the " + l }
        return (l.first.map { "aeiou".contains($0) } ?? false ? "an " : "a ") + l
    }

    public nonisolated static func compose(
        slotFieldIDs: [String],
        facts: [GenericFact],
        evaluations: [ClaimEvaluation],
        authorityObjectIDs: [UUID],
        documentsSearched: Int,
        archivePassages: Int? = nil,
        scoreByObject: [KnowledgeObject.ID: Double] = [:],
        salienceByObject: [KnowledgeObject.ID: Double] = [:],
        question: String? = nil
    ) -> SlotAnswerComposition? {
        guard let requestedField = slotFieldIDs.first else { return nil }
        let label = SlotFieldResolver.humanLabel(forFieldID: requestedField)
        let evalByID = Dictionary(evaluations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Surfaceable facts only — the carried evaluation decides (never
        // re-derived). The citation anchor is chosen by the CRITERION-
        // REPRESENTATIVE RULE (owner 2026-09-02, positional-read audit): a
        // single-slot read from an order-independent evidence set selects by
        // criterion (highest retrieval score, stable-key tiebreak), never by
        // position. `eval.evidence.first` was the SlotAnswerComposer:65 sibling
        // of the ReasoningExpert bug — stable-by-luck on the rung-1 witness.
        let surfaceable: [Candidate] = facts.compactMap { f in
            guard let eval = evalByID[f.id], eval.decision.maySurface,
                  let presentation = eval.presentation,
                  let obj = ReasoningExpert.stableRepresentative(eval.evidence, scoreByObject: scoreByObject)
            else { return nil }
            // Post-fix diagnostic (env-gated): raw `.first` vs the chosen
            // criterion anchor — a DIFFER marks where the disease was masked.
            if ProcessInfo.processInfo.environment["KALSMRITIKOSH_DUMP_ANCHOR_PROBE"] == "1",
               eval.evidence.count > 1 {
                let firstRaw = eval.evidence.first?.objectID
                print("ANCHORPROBE site=composer reqField=\(requestedField) field=\(f.field) n=\(eval.evidence.count) first=\(firstRaw.map { String($0.uuidString.prefix(8)) } ?? "nil") criterion=\(String(obj.uuidString.prefix(8))) \(firstRaw == obj ? "MATCH" : "DIFFER")")
            }
            return Candidate(fact: f, objectID: obj, presentation: presentation,
                             isAuthority: authorityObjectIDs.contains(obj),
                             salience: salienceByObject[obj] ?? SalienceTable.neutral)
        }

        var requested = surfaceable.filter { $0.fact.field == requestedField }

        if FactSchemaRegistry.expectedShape(of: requestedField) == .identifier {
            // Query-time date guard (owner live-witness, rc13): a calendar date
            // captured under an identifier field ("Patent : 22/03/2023") must
            // never be offered as a reference-number value — it surfaced as a
            // false conflict against the real patent number. The write-time
            // twin (PatentDomainPack.isDateShapedNumber) stops NEW ingests;
            // this defends LEGACY rows already in the ledger without a
            // re-ingest. Generic across identifier slots (invoice/case/PAN…).
            requested = requested.filter { !Self.isDateShapedIdentifier($0.fact.value) }
        }

        // Cross-field mislabel guard (owner real-data case): a reference
        // number that is more strongly attested under a DIFFERENT identifier
        // field is a mis-extraction — the application number 202331019665 was
        // captured under "Patent No." in a couple of blocks while appearing
        // as applicationNumber everywhere else. Drop a candidate whose
        // canonical identifier is carried MORE OFTEN by another field. Scoped
        // to identifier slots; conservative (strict domination only).
        if FactSchemaRegistry.expectedShape(of: requestedField) == .identifier {
            let cmp = CanonicalFactComparator()
            var countByCanonField: [String: [String: Int]] = [:]
            for f in facts where FactSchemaRegistry.expectedShape(of: f.field) == .identifier {
                let canon = cmp.canonical(f.value, .identifier)
                countByCanonField[canon, default: [:]][f.field, default: 0] += 1
            }
            requested = requested.filter { cand in
                let canon = cmp.canonical(cand.fact.value, .identifier)
                let counts = countByCanonField[canon] ?? [:]
                let mine = counts[requestedField] ?? 0
                let other = counts.filter { $0.key != requestedField }.map(\.value).max() ?? 0
                return other <= mine
            }
        }

        // P2 — values about different records are not a conflict (real-case evaluation 2026-11-03:
        // seven separate recall events pooled into "conflicting values for classification: Class I •
        // Class II • Class III"). A question that names one record (its event, case or reference number)
        // or one subject in full reads only that record's values.
        let recordKeys = Self.recordKeys(of: surfaceable, requestedField: requestedField)
        if let question, !requested.isEmpty {
            requested = Self.focused(requested, question: question, recordKeys: recordKeys)
        }

        guard !requested.isEmpty else {
            // D-15 — the honest not-found NAMES the missing field, and
            // mentions the strongest related fact (same document family)
            // that DOES exist: "shows the grant (Patent number 555489), but
            // none of the N documents searched carries a grant date."
            let group = SlotFieldResolver.vocabulary.first { $0.fieldID == requestedField }?.group
            let groupFields = Set(SlotFieldResolver.vocabulary
                .filter { $0.group == group }.map(\.fieldID))
            let related = surfaceable
                .filter { groupFields.contains($0.fact.field) && $0.fact.field != requestedField }
                .sorted(by: strongerFirst)
                .first
            var sentence: String
            if let related {
                sentence = "Your archive shows \(labeledValue(related.fact)), "
                    + "but none of the \(documentsSearched) document(s) searched carries \(Self.withArticle(label))."
            } else {
                sentence = "None of the \(documentsSearched) document(s) searched carries \(Self.withArticle(label))."
            }
            // F8 (NF-1/NF-2) — the abstention carries its RECEIPT: what was
            // exhausted, and — for a field no extractor even emits — the honest
            // scope statement plus the nearest known field. The receipt persists
            // with the answer via the durable answer commit (AEE-M2), so the
            // abstention is auditable, not just polite.
            if !FieldRegistry.isKnown(requestedField) {
                sentence += " A \(label.lowercased()) is not among the fields this archive's documents contain"
                if let nearest = FieldRegistry.nearestKnown(toLabel: label) {
                    sentence += " (nearest on file: \(nearest.lowercased()))"
                }
                sentence += "."
            }
            let scope = archivePassages.map { "\(documentsSearched) documents and \($0) passages" }
                ?? "\(documentsSearched) document(s)"
            sentence += " (Receipt: \(scope) exhausted across the keyword, entity, timeline and semantic layers; no model was consulted.)"
            return SlotAnswerComposition(
                primaryText: sentence,
                supportingObjectIDs: related.map { [$0.objectID] } ?? [],
                isConflict: false, isNotFound: true,
                singleCanonicalValue: false, structuredSource: false,
                alsoOnFile: nil, requestedLabel: label)
        }

        // Dedupe identical canonical values (grain-aware for dates via the
        // comparator, which parses RAW values), keeping the strongest-ranked
        // carrier of each value.
        let comparator = CanonicalFactComparator()
        var groups: [(canonical: String, best: Candidate)] = []
        for cand in requested.sorted(by: strongerFirst) {
            let canon = canonicalValue(cand.fact, comparator: comparator)
            if !groups.contains(where: { sameValue($0.best, cand, comparator: comparator) }) { groups.append((canon, cand)) }
        }

        let also = alsoOnFileLine(surfaceable: surfaceable, excludingField: requestedField)

        if groups.count == 1 {
            let best = groups[0].best
            // Values keep their full matched text ("Patent No. 900123") —
            // suppress the label when the value already carries it, so the
            // sentence reads "Patent No. 900123." not "Patent number:
            // Patent No. 900123."
            // A value that ends a sentence itself ("Cardinal Health Inc.") takes no second period.
            let stated = labeledValue(best.fact, label: label)
            let sentence = stated.hasSuffix(".") ? stated : stated + "."
            var single = SlotAnswerComposition(
                primaryText: sentence,
                supportingObjectIDs: [best.objectID],
                isConflict: false, isNotFound: false,
                singleCanonicalValue: true,
                structuredSource: best.isAuthority || best.presentation == .fact || best.presentation == .corroborated,
                alsoOnFile: also, requestedLabel: label)
            single.citedValue = best.fact.value
            return single
        }

        // Multiple DIFFERENT canonical values. They conflict only when the SAME record (or subject) carries
        // them in different documents; otherwise each record states its own value, said per record, and
        // values with no record to tell them apart (one release's several amounts, three victims' payments)
        // are no conflict and no single answer — the passages answer instead (nil).
        let conflicting = Self.conflictingRecords(requested, recordKeys: recordKeys, comparator: comparator)
        if conflicting.isEmpty {
            guard let perRecord = Self.perRecord(requested, recordKeys: recordKeys, label: label, comparator: comparator, also: also) else {
                return nil
            }
            return perRecord
        }
        // Only the values of the records in conflict: another record's value is not one of the readings.
        groups = groups.filter { g in requested.contains { c in
            conflicting.contains(Self.recordKey(of: c, recordKeys: recordKeys)) && Self.sameValue(c, g.best, comparator: comparator)
        } }
        if groups.count == 1 {
            let best = groups[0].best
            let stated = labeledValue(best.fact, label: label)
            var single = SlotAnswerComposition(
                primaryText: stated.hasSuffix(".") ? stated : stated + ".",
                supportingObjectIDs: [best.objectID],
                isConflict: false, isNotFound: false, singleCanonicalValue: true,
                structuredSource: best.isAuthority || best.presentation == .fact || best.presentation == .corroborated,
                alsoOnFile: also, requestedLabel: label)
            single.citedValue = best.fact.value
            return single
        }
        // An explicit conflict, both values with their sources — never a list dump, never averaged.
        let lines = groups.prefix(4).map { "• \(renderValue($0.best.fact))" }
        let sentence = "Your archive carries conflicting values for \(label.lowercased()):\n"
            + lines.joined(separator: "\n")
        var composition = SlotAnswerComposition(
            primaryText: sentence,
            supportingObjectIDs: groups.map(\.best.objectID),
            isConflict: true, isNotFound: false,
            singleCanonicalValue: false, structuredSource: false,
            alsoOnFile: also, requestedLabel: label)
        composition.conflictValueCount = min(groups.count, 4)
        return composition
    }

    // MARK: - Ranking (D-12 step 3)

    /// Deterministic strongest-first ordering: rank, then field, then value —
    /// equal-rank candidates never reorder between runs.
    nonisolated static func strongerFirst(_ a: Candidate, _ b: Candidate) -> Bool {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra > rb }
        // S2-U1 consumer 2 — structural salience breaks rank ties: a value
        // from a table row beats the same value restated in a signature
        // block. Strictly AFTER tier + source-class (both live in rank).
        if a.salience != b.salience { return a.salience > b.salience }
        if a.fact.field != b.fact.field { return a.fact.field > b.fact.field }
        return a.fact.value < b.fact.value
    }

    /// "⟨Label⟩ ⟨value⟩" unless the value already opens with the label's
    /// leading word ("Patent No. 900123" needs no "Patent number" prefix).
    nonisolated static func labeledValue(_ fact: GenericFact, label: String? = nil) -> String {
        var l = label ?? SlotFieldResolver.humanLabel(forFieldID: fact.field)
        // A field read from a labelled line keeps the document's own label ("Recalling firm"),
        // not the joined field id ("Recallingfirm") — case bench 2026-10-22.
        if let documentLabel = Self.documentLabel(fact), l.replacingOccurrences(of: " ", with: "").lowercased() == fact.field {
            l = documentLabel
        }
        let rendered = renderValue(fact)
        if let first = l.split(separator: " ").first,
           rendered.lowercased().hasPrefix(first.lowercased()) {
            return rendered
        }
        return label != nil ? "\(l): \(rendered)" : "\(l) \(rendered)"
    }

    /// A readable label for a joined field id ("recallingfirm" → "Recalling firm", "decisiondate" →
    /// "Decision date"), split into known field words. Built from the field id alone — never from
    /// the extraction's raw match (RawMatchBoundaryTests) — and nil unless every part is a known word.
    nonisolated static func documentLabel(_ fact: GenericFact) -> String? {
        let id = fact.field.lowercased()
        guard id.count >= 6, id.allSatisfy({ $0.isLetter }) else { return nil }
        let chars = Array(id)
        // best[i] = the fewest-words split of chars[0..<i]
        var best: [[String]?] = Array(repeating: nil, count: chars.count + 1)
        best[0] = []
        for i in 0..<chars.count where best[i] != nil {
            // Words are 2–14 letters; near the end of the id the range can be empty — never form a
            // closed range whose lower bound exceeds its upper (that traps).
            let upper = min(chars.count, i + 14)
            guard i + 2 <= upper else { continue }
            for j in (i + 2)...upper {
                let w = String(chars[i..<j])
                guard Self.fieldWords.contains(w), let prev = best[i] else { continue }
                if best[j] == nil || (best[j]?.count ?? .max) > prev.count + 1 { best[j] = prev + [w] }
            }
        }
        guard let words = best[chars.count], words.count >= 2 else { return nil }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Words that make up field names on forms, filings, recalls, reports and records.
    nonisolated static let fieldWords: Set<String> = [
        "account", "action", "address", "agency", "amount", "applicant", "application", "approval", "approved",
        "arrival", "arrest", "author", "award", "balance", "bank", "birth", "brand", "case", "cause", "charge",
        "city", "claim", "claimant", "class", "code", "company", "complaint", "contact", "contract", "country",
        "county", "court", "date", "death", "decision", "defect", "defendant", "department", "description",
        "device", "disposition", "distribution", "district", "docket", "due", "effective", "email", "employee",
        "employer", "end", "entry", "event", "expiry", "expiration", "file", "filing", "firm", "first", "grant",
        "hearing", "id", "incident", "initiation", "injury", "inspection", "insured", "invoice", "issue", "judge",
        "last", "license", "location", "loss", "lot", "make", "manufacturer", "model", "name", "notice", "number",
        "office", "officer", "opinion", "order", "owner", "party", "patent", "payment", "phone", "place", "plaintiff",
        "policy", "posting", "product", "publication", "quantity", "reason", "recall", "recalling", "received",
        "recipient", "reference", "registration", "release", "report", "reported", "respondent", "review", "serial",
        "sentence", "severity", "start", "state", "status", "street", "subject", "submission", "supplier", "tax",
        "termination", "title", "total", "type", "unit", "value", "vehicle", "vendor", "victim", "witness", "year", "zip",
    ]

    /// Higher = stronger. An authoritative structural document (DocumentFitness
    /// RET-009) outranks email prose; presentation strength then confidence
    /// break ties.
    nonisolated static func rank(_ c: Candidate) -> Double {
        var score = c.fact.confidence
        if c.isAuthority { score += 2.0 }
        switch c.presentation {
        case .fact:           score += 1.0
        case .corroborated:   score += 0.8
        case .userAttributed: score += 0.6
        case .attributed:     score += 0.3
        case .derivation:     score += 0.2
        case .inference, .conflict: break
        }
        return score
    }

    // MARK: - Value rendering (D-12 label/money rules)

    /// Monetary values render canonically ("Rs20,000 INR" → "₹20,000"), other
    /// values keep their extracted text with the unit appended once.
    public nonisolated static func renderValue(_ fact: GenericFact) -> String {
        if FactSchemaRegistry.expectedShape(of: fact.field) == .money {
            return renderMoney(value: fact.value, unit: fact.unit)
        }
        // VERSION-AWARE RENDERING (V2 commit 2a→2b): `value` is the display
        // form for v0 (fused, "Patent No. 555489") but the normalized ATOM for
        // v1 (bare "555489"). 2a rendered v1 from `rawMatch` — but after C-10
        // merges six spellings into one fact, `rawMatch` is WHICHEVER form the
        // merge stored (first-seen), so the witness would flip with ingestion
        // order at the drain: arbitrary order given authority, at presentation.
        // 2b fixes it: v1 identifier fields render from a per-field DISPLAY
        // LABEL CONSTANT (set equal to today's witnessed surface), so the
        // surface is safe BY CONSTANT, immune to source OCR noise and merge
        // internals. `rawMatch` retires to provenance-for-the-receipt only.
        // v0 / nil (the entire live ledger pre-drain) renders value as-is.
        let isV1 = (fact.producerVersion ?? 0) >= 1
        // V2 (C-7 writer) — a v1 DATE stores precision-aware ISO ("2025-06-17",
        // "2024-11", "2024"); render the seal-anchored canon (day = DD/MM/YYYY
        // per seal #3c, month = "November 2024", year = "2024"), NEVER the
        // source form. A v0 date row keeps its raw text (renders as-is below).
        if isV1, FactSchemaRegistry.expectedShape(of: fact.field) == .date {
            let unit = fact.displayUnit.map { " \($0)" } ?? ""
            return renderCanonicalDate(iso: fact.value) + unit
        }
        let display: String
        // A value that carries its own designation ("Civ. No. 3730", "Patent Appeals No. 4043")
        // is shown as written — "Case No. Civ. No. 3730" says the label twice.
        if isV1, let dl = Self.displayLabel(forFieldID: fact.field),
           fact.value.range(of: #"\b(?:No|Nos)\.|^[A-Za-z]+\.\s"#, options: .regularExpression) == nil {
            display = "\(dl) \(fact.value)"
        } else {
            display = fact.value
        }
        let unit = fact.displayUnit.map { " \($0)" } ?? ""
        return display + unit
    }

    /// V2 (C-7) — the seal-anchored date canon, reconstructed from precision-
    /// aware ISO. Day precision (yyyy-MM-dd) → "DD/MM/YYYY" (the live
    /// "29/11/2024" family per seal #3c); month (yyyy-MM) → "Month YYYY";
    /// year (yyyy) → "YYYY". The display is a CONSTANT of the stored precision,
    /// never derived from the source spelling or rawMatch. Unparseable → as-is.
    nonisolated static func renderCanonicalDate(iso: String) -> String {
        let monthNames = ["January", "February", "March", "April", "May", "June",
                          "July", "August", "September", "October", "November", "December"]
        let parts = iso.split(separator: "-").map(String.init)
        if parts.count >= 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
           (1...12).contains(m) {
            return String(format: "%02d/%02d/%04d", d, m, y)
        }
        if parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) {
            return "\(monthNames[m - 1]) \(y)"
        }
        if parts.count == 1, let y = Int(parts[0]) { return String(y) }
        return iso
    }

    /// V2 2b — per-field display-label constants, set EQUAL to today's
    /// witnessed answer surfaces. v1 rows store the bare atom; the surface is
    /// reconstructed from these constants, NOT from the stored value or the
    /// merge's `rawMatch` — so the witness is byte-identical by construction,
    /// independent of ingestion order and source spelling. A test asserts each
    /// constant equals the current gold prefix for its field. nil → the field
    /// has no v1 rewrite yet (renders v0 value as-is until its pack lands).
    nonisolated static func displayLabel(forFieldID field: String) -> String? {
        switch FactSchemaRegistry.normalizeField(field) {
        case "patentnumber":      return "Patent No."
        case "applicationnumber": return "Application No."
        case "publicationnumber": return "Publication No."
        // Persona-coverage starter-pack identifiers.
        case "casenumber":        return "Case No."
        case "accountnumber":     return "Account No."
        case "idnumber":          return "ID No."
        // HOST-8d — device identifiers. Registered here so an anchor's display
        // name is built from a CONSTANT rather than fusing a source spelling,
        // which is what makes anchor names immune to OCR and spacing noise.
        case "deviceserialnumber": return DeviceIdentity.Field.deviceSerialNumber.label
        case "imei":               return DeviceIdentity.Field.imei.label
        case "meid":               return DeviceIdentity.Field.meid.label
        case "deviceudid":         return DeviceIdentity.Field.deviceUDID.label
        case "devicemacaddress":   return DeviceIdentity.Field.deviceMACAddress.label
        case "computername":       return DeviceIdentity.Field.computerName.label
        case "deviceproducttype":  return DeviceIdentity.Field.deviceProductType.label
        default:                  return nil
        }
    }

    /// Deterministic money rendering: the numeric amount from the matched
    /// text (decimals preserved), grouped, with the currency symbol resolved
    /// from the unit or the raw text. Unparseable → raw + unit unchanged.
    public nonisolated static func renderMoney(value: String, unit: String?) -> String {
        var cleaned = value
            .filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        // "$50k", "$1 million": the scale word is part of the amount (it rendered as "$50", "$1").
        if let scaled = moneyAmount(value), let plain = Double(cleaned), scaled != plain {
            cleaned = scaled == scaled.rounded() ? String(Int(scaled)) : String(scaled)
        }
        guard !cleaned.isEmpty, let amount = Double(cleaned), amount.isFinite else {
            let u = unit.map { " \($0)" } ?? ""
            return value + u
        }
        let symbolByCode: [String: String] = ["INR": "₹", "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"]
        let raw = ((unit ?? "") + " " + value).lowercased()
        var symbol = unit.flatMap { symbolByCode[$0.uppercased()] }
        if symbol == nil {
            if raw.contains("₹") || raw.contains("rs") || raw.contains("inr") { symbol = "₹" }
            else if raw.contains("$") || raw.contains("usd") { symbol = "$" }
            else if raw.contains("€") || raw.contains("eur") { symbol = "€" }
            else if raw.contains("£") || raw.contains("gbp") { symbol = "£" }
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        let fractionDigits = cleaned.contains(".") ? 2 : 0
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let grouped = formatter.string(from: NSNumber(value: amount)) ?? cleaned
        return (symbol ?? "") + grouped
    }

    // MARK: - Helpers

    nonisolated static func canonicalValue(_ fact: GenericFact, comparator: CanonicalFactComparator) -> String {
        let shape = FactSchemaRegistry.expectedShape(of: fact.field)
        // "$50k" and "$50,000" are one amount (the digits alone made them "50" and "50000").
        if shape == .money, let amount = moneyAmount(fact.value) {
            return String(format: "%.2f", amount)
        }
        return comparator.canonical(fact.value, shape)
    }

    /// Same value: grain-aware for dates ("June 2025" = "17 June 2025"), canonical otherwise.
    nonisolated static func sameValue(_ a: Candidate, _ b: Candidate, comparator: CanonicalFactComparator) -> Bool {
        if FactSchemaRegistry.expectedShape(of: b.fact.field) == .date,
           let eq = comparator.dateGrainEquivalent(a.fact.value, b.fact.value) { return eq }
        return canonicalValue(a.fact, comparator: comparator) == canonicalValue(b.fact, comparator: comparator)
    }

    // MARK: - Records (P2: a conflict is about ONE record)

    /// Fields that name the record a document is about: an event, case, docket, recall, incident, claim,
    /// inspection or reference number. The event id first: a recall event carries several recall numbers.
    nonisolated static let recordFieldPattern = #"^(?:event(?:id|number|no)|recallevent(?:id|number)?|(?:case|docket|incident|claim|inspection|investigation|complaint|reference|report|recall|record|file)(?:id|number|no))$"#

    /// One record key per document: the value of its first record field when the document states exactly
    /// one value for it (a document listing several is a list, not one record).
    nonisolated static func recordKeys(of surfaceable: [Candidate], requestedField: String) -> [UUID: (label: String, key: String)] {
        guard requestedField.range(of: recordFieldPattern, options: .regularExpression) == nil else { return [:] }
        let comparator = CanonicalFactComparator()
        var byObject: [UUID: [String: [GenericFact]]] = [:]
        for c in surfaceable where c.fact.field.lowercased().range(of: recordFieldPattern, options: .regularExpression) != nil {
            byObject[c.objectID, default: [:]][c.fact.field.lowercased(), default: []].append(c.fact)
        }
        var out: [UUID: (label: String, key: String)] = [:]
        for (object, fields) in byObject {
            // The event's own number first, then the rest in a stable order.
            for field in fields.keys.sorted(by: { ($0.hasPrefix("event") ? "0" : "1") + $0 < ($1.hasPrefix("event") ? "0" : "1") + $1 }) {
                guard let facts = fields[field] else { continue }
                let keys = Set(facts.map { comparator.canonicalIdentifier($0.value) }).filter { !$0.isEmpty }
                if keys.count == 1, let key = keys.first, let first = facts.first {
                    out[object] = (labeledValue(first), field + ":" + key)
                    break
                }
            }
        }
        return out
    }

    /// The key a value is grouped under: its document's record; else its subject (a canonical entity, or
    /// the subject label shared across documents); else its document.
    nonisolated static func recordKey(of c: Candidate, recordKeys: [UUID: (label: String, key: String)]) -> String {
        if let r = recordKeys[c.objectID] { return "r:" + r.key }
        if let id = c.fact.subjectID { return "s:" + id.uuidString }
        let label = c.fact.subjectLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return label.isEmpty ? "d:" + c.objectID.uuidString : "s:" + label
    }

    /// A question that names one record ("recall event 70738") or one subject in full reads only it.
    nonisolated static func focused(_ requested: [Candidate], question: String,
                                    recordKeys: [UUID: (label: String, key: String)]) -> [Candidate] {
        let lowered = question.lowercased()
        let words = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let squeezed = lowered.filter { $0.isLetter || $0.isNumber }
        let named = Set(recordKeys.values.map(\.key).filter { key in
            let id = String(key.split(separator: ":", maxSplits: 1).last ?? "")
            return !id.isEmpty && (words.contains(id) || (id.count >= 5 && squeezed.contains(id)))
        })
        if !named.isEmpty {
            let kept = requested.filter { recordKeys[$0.objectID].map { named.contains($0.key) } ?? false }
            if !kept.isEmpty { return kept }
        }
        if let subject = ProceedingAnswerer.person(in: question) {
            let kept = requested.filter { ProceedingAnswerer.namesFully($0.fact.subjectLabel, person: subject) }
            if !kept.isEmpty { return kept }
        }
        return requested
    }

    /// The record keys holding two or more different values from different documents — a real
    /// disagreement between sources about one record.
    nonisolated static func conflictingRecords(_ requested: [Candidate], recordKeys: [UUID: (label: String, key: String)],
                                               comparator: CanonicalFactComparator) -> Set<String> {
        var out = Set<String>()
        let byRecord = Dictionary(grouping: requested) { recordKey(of: $0, recordKeys: recordKeys) }
        for (key, cands) in byRecord {
            var distinct: [Candidate] = []
            for c in cands where !distinct.contains(where: { sameValue($0, c, comparator: comparator) }) { distinct.append(c) }
            guard distinct.count >= 2 else { continue }
            // Two values a single document states are two statements of that document (a release's
            // several amounts), not two sources disagreeing: a conflict needs one document saying one
            // value and ANOTHER document saying another.
            let documents = distinct.map { d in Set(cands.filter { sameValue($0, d, comparator: comparator) }.map(\.objectID)) }
            var disagree = false
            for i in documents.indices { for j in documents.indices where i != j {
                if documents[i].contains(where: { a in documents[j].contains { $0 != a } }) { disagree = true }
            } }
            if disagree { out.insert(key) }
        }
        return out
    }

    /// "Event id 70738: Class I" per record, when every value belongs to a named record; nil otherwise.
    nonisolated static func perRecord(_ requested: [Candidate], recordKeys: [UUID: (label: String, key: String)], label: String,
                                      comparator: CanonicalFactComparator, also: String?) -> SlotAnswerComposition? {
        guard !requested.isEmpty, requested.allSatisfy({ recordKeys[$0.objectID] != nil }) else { return nil }
        var rows: [(record: String, value: String, objectID: UUID)] = []
        for c in requested.sorted(by: strongerFirst) {
            guard let r = recordKeys[c.objectID] else { continue }
            let value = renderValue(c.fact)
            if rows.contains(where: { $0.record == r.label && $0.value == value }) { continue }
            rows.append((r.label, value, c.objectID))
        }
        rows.sort { $0.record.localizedStandardCompare($1.record) == .orderedAscending }
        let shown = rows.prefix(8)
        var text = "The \(label.lowercased()) differs by record — each record states its own (these are separate records, not a disagreement between sources):\n"
            + shown.map { "• \($0.record): \($0.value)" }.joined(separator: "\n")
        if rows.count > shown.count { text += "\n(and \(rows.count - shown.count) more)" }
        return SlotAnswerComposition(
            primaryText: text, supportingObjectIDs: Array(NSOrderedSet(array: shown.map(\.objectID)).compactMap { $0 as? UUID }),
            isConflict: false, isNotFound: false, singleCanonicalValue: false, structuredSource: false,
            alsoOnFile: also, requestedLabel: label)
    }

    /// The amount a money value states, with its scale: "$50k" = 50,000, "$1 million" = 1,000,000,
    /// "$1.8 million" = 1,800,000. Nil when no figure is found.
    nonisolated static func moneyAmount(_ value: String) -> Double? {
        guard let r = value.range(of: #"\d[\d,]*(?:\.\d+)?"#, options: .regularExpression),
              let n = Double(value[r].replacingOccurrences(of: ",", with: "")), n.isFinite else { return nil }
        let rest = value[r.upperBound...].lowercased().trimmingCharacters(in: .whitespaces)
        let scales: [(String, Double)] = [("billion", 1e9), ("bn", 1e9), ("million", 1e6), ("mn", 1e6), ("thousand", 1e3), ("m", 1e6), ("k", 1e3), ("b", 1e9)]
        for (word, factor) in scales where rest.range(of: "^" + word + #"(?![a-z])"#, options: .regularExpression) != nil {
            return n * factor
        }
        return n
    }

    /// A value whose digits form a calendar date (dd/mm/yyyy, dd-mm-yyyy,
    /// yyyy-mm-dd) — never a reference number. Query-time twin of
    /// PatentDomainPack.isDateShapedNumber; kept identical so a legacy row and
    /// a freshly-extracted one are judged the same way.
    nonisolated static func isDateShapedIdentifier(_ value: String) -> Bool {
        let patterns = [
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,
            #"\b\d{4}[/-]\d{1,2}[/-]\d{1,2}\b"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    /// One compact detail line for the footer: the strongest OTHER fields on
    /// file, deduped, capped — context, never the primary answer.
    nonisolated static func alsoOnFileLine(
        surfaceable: [Candidate], excludingField: String
    ) -> String? {
        var seenFields = Set<String>()
        var parts: [String] = []
        for c in surfaceable.sorted(by: strongerFirst) {
            guard c.fact.field != excludingField, seenFields.insert(c.fact.field).inserted else { continue }
            parts.append(labeledValue(c.fact))
            if parts.count == 3 { break }
        }
        return parts.isEmpty ? nil : "Also on file: " + parts.joined(separator: " · ")
    }
}
