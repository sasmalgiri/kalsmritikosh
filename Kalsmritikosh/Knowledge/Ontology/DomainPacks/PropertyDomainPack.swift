//
//  PropertyDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the PROPERTY / real-estate domain (the homeowner /
//  conveyancer persona). Reads deeds, sale agreements, and leases: the
//  property, the parties (seller/buyer or lessor/lessee), the
//  consideration, and the deed date. Optional, additive, marker-gated.
//  Deterministic, offline.
//

import Foundation

public enum PropertyDomainPack {

    nonisolated static let markers: [String] = [
        "sale deed", "deed of", "conveyance", "lease agreement", "lessor",
        "lessee", "vendor", "vendee", "property situated", "schedule of property",
        "sq. ft", "sq ft", "khata", "survey no", "plot no", "consideration",
    ]

    nonisolated static func isProperty(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// consideration is money; deedDate is date; the rest text — no
    /// identifier display constant required.
    public nonisolated static let emittedFields: [String] =
        ["propertyAddress", "seller", "buyer", "consideration", "deedDate"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        guard isProperty(lower) else { return [] }
        var facts: [GenericFact] = []

        if let v = DomainPackText.labeledValue(after: ["property situated at", "property at", "premises at", "address"], in: text) {
            facts.append(fact(subjectLabel, "propertyAddress", v, blockID, 0.65, unit: nil))
        }
        if let v = DomainPackText.labeledValue(after: ["seller", "vendor", "lessor", "transferor"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "seller", v, blockID, 0.7, unit: nil))
        }
        if let v = DomainPackText.labeledValue(after: ["buyer", "purchaser", "vendee", "lessee", "transferee"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "buyer", v, blockID, 0.7, unit: nil))
        }
        if lower.contains("consideration"), let money = DomainPackText.firstMoney(in: text) {
            facts.append(fact(subjectLabel, "consideration", money.replacingOccurrences(of: " ", with: ""),
                              blockID, 0.7, unit: DomainPackText.currencyUnit(money)))
        }
        if let raw = DomainPackText.firstDate(in: text), let iso = PatentDomainPack.normalizeDate(raw) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "deedDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.6, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        return facts
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double, unit: String?) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value, unit: unit,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}
