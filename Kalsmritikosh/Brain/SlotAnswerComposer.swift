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
        documentsSearched: Int
    ) -> SlotAnswerComposition? {
        guard let requestedField = slotFieldIDs.first else { return nil }
        let label = SlotFieldResolver.humanLabel(forFieldID: requestedField)
        let evalByID = Dictionary(evaluations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Surfaceable facts only — the carried evaluation decides (never
        // re-derived), keyed by first evidence object for citations.
        let surfaceable: [Candidate] = facts.compactMap { f in
            guard let eval = evalByID[f.id], eval.decision.maySurface,
                  let presentation = eval.presentation,
                  let obj = eval.evidence.first?.objectID else { return nil }
            return Candidate(fact: f, objectID: obj, presentation: presentation,
                             isAuthority: authorityObjectIDs.contains(obj))
        }

        let requested = surfaceable.filter { $0.fact.field == requestedField }

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
        let unit = fact.unit.map { " \($0)" } ?? ""
        return fact.value + unit
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
