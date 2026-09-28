//
//  VitalRecordsDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the GENEALOGY / vital-records domain (the family
//  historian persona). Reads birth / marriage / death certificates and
//  census-style records: the person, the dated life events, the place,
//  and the family relationships (father / mother / spouse). Optional,
//  additive, marker-gated. Deterministic, offline.
//

import Foundation

public enum VitalRecordsDomainPack {

    nonisolated static let markers: [String] = [
        "date of birth", "date of death", "date of marriage", "born on",
        "died on", "certificate of birth", "certificate of death",
        "certificate of marriage", "father's name", "mother's name",
        "spouse", "husband", "wife", "deceased", "registration of birth",
    ]

    nonisolated static func isVital(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// All text/date — no identifier display constant required.
    public nonisolated static let emittedFields: [String] =
        ["person", "birthDate", "deathDate", "marriageDate", "birthPlace", "father", "mother", "spouse"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        guard isVital(lower) else { return [] }
        var facts: [GenericFact] = []

        if let v = DomainPackText.labeledValue(after: ["name of deceased", "name of the child", "full name", "name"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "person", v, blockID, 0.7))
        }
        addDate(&facts, subjectLabel, "birthDate", ["date of birth", "born on"], text, blockID)
        addDate(&facts, subjectLabel, "deathDate", ["date of death", "died on"], text, blockID)
        addDate(&facts, subjectLabel, "marriageDate", ["date of marriage", "married on"], text, blockID)
        if let v = DomainPackText.labeledValue(after: ["place of birth", "born at", "birthplace"], in: text) {
            facts.append(fact(subjectLabel, "birthPlace", v, blockID, 0.65))
        }
        if let v = DomainPackText.labeledValue(after: ["father's name", "father", "s/o", "son of"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "father", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["mother's name", "mother", "d/o", "daughter of"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "mother", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["spouse", "husband", "wife", "w/o", "married to"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "spouse", v, blockID, 0.65))
        }
        return facts
    }

    nonisolated static func addDate(_ facts: inout [GenericFact], _ subject: String, _ field: String,
                                    _ markers: [String], _ text: String, _ block: UUID) {
        // Prefer a date that follows the specific label; fall back to none
        // (never a bare archive date — that belongs to the generic layer).
        guard let after = DomainPackText.labeledValue(after: markers, in: text),
              let raw = DomainPackText.firstDate(in: after) ?? DomainPackText.firstDate(in: text),
              markers.contains(where: { text.lowercased().contains($0) }),
              let iso = PatentDomainPack.normalizeDate(raw) else { return }
        facts.append(GenericFact(subjectLabel: subject, field: field, value: iso,
                                 status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [block],
                                 producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}
