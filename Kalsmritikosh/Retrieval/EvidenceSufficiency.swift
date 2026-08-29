//
//  EvidenceSufficiency.swift
//  Kalsmritikosh
//
//  RET-006 — evidence sufficiency. A QueryPlan states which FIELDS the answer must
//  supply (amount, payee, employer, date…). After retrieval, this checks whether the
//  retrieved evidence actually CONTAINS each requested field, and reports what is
//  covered vs missing. The answer layer uses this to honestly disclose gaps
//  ("amount: not found in the retrieved evidence") instead of fabricating a value or
//  emitting a vague "not specified".
//
//  Deterministic, offline. Reuses the doc-side field detector so "what the question
//  asked for" and "what the evidence provides" are measured on the same vocabulary.
//
//  This does NOT invent missing values and NEVER treats absence as proof of anything
//  (pack: "a missing item is never presented as proof of wrongdoing"). It only states
//  the searched scope and what was not found.
//

import Foundation

public struct EvidenceSufficiency: Sendable, Hashable {
    /// Requested fields the retrieved evidence actually contains.
    public let covered: [RequestedField]
    /// Requested fields the retrieved evidence does NOT contain.
    public let missing: [RequestedField]
    /// How many distinct evidence documents were searched (for honest scope disclosure).
    public let documentsSearched: Int

    public var isComplete: Bool { missing.isEmpty }
    public var coverageRatio: Double {
        let total = covered.count + missing.count
        return total == 0 ? 1.0 : Double(covered.count) / Double(total)
    }

    /// A neutral, non-accusatory disclosure line for the answer footer.
    public nonisolated func disclosure() -> String {
        guard !missing.isEmpty else { return "" }
        let names = missing.map(Self.label).joined(separator: ", ")
        return "Not found in the \(documentsSearched) document(s) searched: \(names)."
    }

    nonisolated static func label(_ f: RequestedField) -> String {
        switch f {
        case .monetaryAmount: return "amount"
        case .counterparty:   return "counterparty/payee"
        case .date:           return "date"
        case .employment:     return "employment/employer"
        case .location:       return "location"
        case .definition:     return "definition"
        case .status:         return "status"
        case .quantity:       return "quantity"
        case .contactInfo:    return "contact info"
        case .terms:          return "terms"
        case .identity:       return "identity"
        case .cause:          return "cause/reason"
        case .identifier:     return "reference number"
        case .other:          return "requested detail"
        }
    }
}

public struct EvidenceSufficiencyAssessor: Sendable {
    public nonisolated init() {}

    /// Assess whether the retrieved evidence covers the plan's requested fields.
    /// `evidenceTexts` are the text bodies of the retrieved chunks/blocks.
    public nonisolated func assess(plan: QueryPlan, evidenceTexts: [String]) -> EvidenceSufficiency {
        let requested = plan.requestedFields.filter { $0 != .other }
        // What fields does the union of retrieved evidence expose?
        var present: Set<RequestedField> = []
        for text in evidenceTexts {
            present.formUnion(DocumentRoleInference.presentFields(inText: text))
            // Date/location/quantity/contact aren't in the doc-side detector's core set;
            // detect them here on the same text so sufficiency covers all requested fields.
            present.formUnion(Self.auxiliaryFields(in: text))
        }
        let covered = requested.filter { present.contains($0) }
        let missing = requested.filter { !present.contains($0) }
        return EvidenceSufficiency(covered: covered, missing: missing, documentsSearched: evidenceTexts.count)
    }

    /// Fields the doc-side role detector doesn't cover, detected here for sufficiency.
    nonisolated static func auxiliaryFields(in text: String) -> Set<RequestedField> {
        let t = text.lowercased()
        var f: Set<RequestedField> = []
        // date: month names or dd/mm/yyyy-ish or a 20xx year
        let months = ["jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"]
        if months.contains(where: { t.contains($0) }) || t.contains("20") && t.contains(where: \.isNumber) {
            if t.range(of: #"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"#, options: .regularExpression) != nil
                || months.contains(where: { t.contains($0) }) {
                f.insert(.date)
            }
        }
        if t.contains(where: \.isNumber) && (t.contains("phone") || t.contains("mobile") || t.contains("@")) {
            f.insert(.contactInfo)
        }
        if t.range(of: #"\b\d+\b"#, options: .regularExpression) != nil { f.insert(.quantity) }
        if t.contains(" at ") || t.contains("located") || t.contains("address") || t.contains("city") {
            f.insert(.location)
        }
        return f
    }
}
