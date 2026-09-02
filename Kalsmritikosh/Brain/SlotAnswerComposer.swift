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
}

public enum SlotAnswerComposer {

    /// A surfaceable fact with the signals ranking needs.
    struct Candidate {
        let fact: GenericFact
        let objectID: UUID
        let presentation: ClaimPresentation
        let isAuthority: Bool
    }

    /// Compose the slot answer for `slotFieldIDs` from the retrieval-surfaced
    /// facts. Returns nil when the plan carries no slot fields.
    public nonisolated static func compose(
        slotFieldIDs: [String],
        facts: [GenericFact],
        evaluations: [ClaimEvaluation],
        authorityObjectIDs: [UUID],
        documentsSearched: Int,
        scoreByObject: [KnowledgeObject.ID: Double] = [:]
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
                             isAuthority: authorityObjectIDs.contains(obj))
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
            let sentence: String
            if let related {
                sentence = "Your archive shows \(labeledValue(related.fact)), "
                    + "but none of the \(documentsSearched) document(s) searched carries a \(label.lowercased())."
            } else {
                sentence = "None of the \(documentsSearched) document(s) searched carries a \(label.lowercased())."
            }
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
            let isDate = FactSchemaRegistry.expectedShape(of: cand.fact.field) == .date
            let existing = groups.contains { g in
                if isDate, let eq = comparator.dateGrainEquivalent(g.best.fact.value, cand.fact.value) {
                    return eq
                }
                return g.canonical == canon
            }
            if !existing { groups.append((canon, cand)) }
        }

        let also = alsoOnFileLine(surfaceable: surfaceable, excludingField: requestedField)

        if groups.count == 1 {
            let best = groups[0].best
            // Values keep their full matched text ("Patent No. 900123") —
            // suppress the label when the value already carries it, so the
            // sentence reads "Patent No. 900123." not "Patent number:
            // Patent No. 900123."
            let sentence = "\(labeledValue(best.fact, label: label))."
            return SlotAnswerComposition(
                primaryText: sentence,
                supportingObjectIDs: [best.objectID],
                isConflict: false, isNotFound: false,
                singleCanonicalValue: true,
                structuredSource: best.isAuthority || best.presentation == .fact || best.presentation == .corroborated,
                alsoOnFile: also, requestedLabel: label)
        }

        // Multiple DIFFERENT canonical values → an explicit conflict, both
        // values with their sources — never a list dump, never averaged.
        let lines = groups.prefix(4).map { "• \(renderValue($0.best.fact))" }
        let sentence = "Your archive carries conflicting values for \(label.lowercased()):\n"
            + lines.joined(separator: "\n")
        return SlotAnswerComposition(
            primaryText: sentence,
            supportingObjectIDs: groups.map(\.best.objectID),
            isConflict: true, isNotFound: false,
            singleCanonicalValue: false, structuredSource: false,
            alsoOnFile: also, requestedLabel: label)
    }

    // MARK: - Ranking (D-12 step 3)

    /// Deterministic strongest-first ordering: rank, then field, then value —
    /// equal-rank candidates never reorder between runs.
    nonisolated static func strongerFirst(_ a: Candidate, _ b: Candidate) -> Bool {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra > rb }
        if a.fact.field != b.fact.field { return a.fact.field > b.fact.field }
        return a.fact.value < b.fact.value
    }

    /// "⟨Label⟩ ⟨value⟩" unless the value already opens with the label's
    /// leading word ("Patent No. 900123" needs no "Patent number" prefix).
    nonisolated static func labeledValue(_ fact: GenericFact, label: String? = nil) -> String {
        let l = label ?? SlotFieldResolver.humanLabel(forFieldID: fact.field)
        let rendered = renderValue(fact)
        if let first = l.split(separator: " ").first,
           rendered.lowercased().hasPrefix(first.lowercased()) {
            return rendered
        }
        return label != nil ? "\(l): \(rendered)" : "\(l) \(rendered)"
    }

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
            let unit = fact.unit.map { " \($0)" } ?? ""
            return renderCanonicalDate(iso: fact.value) + unit
        }
        let display: String
        if isV1, let dl = Self.displayLabel(forFieldID: fact.field) {
            display = "\(dl) \(fact.value)"
        } else {
            display = fact.value
        }
        let unit = fact.unit.map { " \($0)" } ?? ""
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
        default:                  return nil
        }
    }

    /// Deterministic money rendering: the numeric amount from the matched
    /// text (decimals preserved), grouped, with the currency symbol resolved
    /// from the unit or the raw text. Unparseable → raw + unit unchanged.
    public nonisolated static func renderMoney(value: String, unit: String?) -> String {
        let cleaned = value
            .filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
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
        comparator.canonical(fact.value, FactSchemaRegistry.expectedShape(of: fact.field))
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
