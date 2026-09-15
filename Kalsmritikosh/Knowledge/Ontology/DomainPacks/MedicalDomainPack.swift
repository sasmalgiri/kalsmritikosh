//
//  MedicalDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the MEDICAL / health domain (the patient / caregiver /
//  personal-health persona). Like every domain pack it is OPTIONAL and
//  ADDITIVE: it improves extraction for health records (discharge
//  summaries, prescriptions, lab reports, consultation notes) and stays
//  SILENT on everything else. A hard domain-marker gate at the top means
//  it emits nothing on a patent letter or an invoice, so it can never
//  perturb another domain's answers. Deterministic, offline.
//
//  Fields: patient · provider · diagnosis · medication · visitDate.
//  No PHI leaves the Mac — this is the same on-device ledger as every
//  other pack.
//

import Foundation

public enum MedicalDomainPack {

    /// The pack fires only when the text carries an unambiguous health
    /// marker. Conservative on purpose: a false medical fact on a
    /// non-medical document is worse than a missed one (the generic layer
    /// still answers). All lower-cased substring checks.
    // Live-archive hardening: dropped the loose markers that fire on noisy
    // email/OCR text ("mg " inside encoded tokens, bare "patient"/"drug"/
    // "rx"). A real health record carries one of these unambiguous phrases.
    nonisolated static let markers: [String] = [
        "diagnosis", "prescription", "prescribed", "dosage",
        "discharge summary", "lab report", "blood pressure",
        "chief complaint", "physician", "medication",
    ]

    nonisolated static func isMedical(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// The fields this pack emits — the display-contract completeness
    /// authority (V1DisplayContractTests). All text/date shapes, so each
    /// renders its own atom; no identifier display constant required.
    public nonisolated static let emittedFields: [String] =
        ["patient", "provider", "diagnosis", "medication", "visitDate"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        guard isMedical(lower) else { return [] }
        var facts: [GenericFact] = []

        if let v = labeledValue(after: ["patient name", "patient", "name of patient"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "patient", v, blockID, 0.75))
        }
        if let v = labeledValue(after: ["doctor", "physician", "consultant", "hospital", "clinic", "attending"], in: text) {
            facts.append(fact(subjectLabel, "provider", v, blockID, 0.7))
        }
        if let v = labeledValue(after: ["diagnosis", "impression", "provisional diagnosis"], in: text) {
            facts.append(fact(subjectLabel, "diagnosis", v, blockID, 0.7))
        }
        if let v = labeledValue(after: ["medication", "prescribed", "medicine"], in: text) {
            facts.append(fact(subjectLabel, "medication", v, blockID, 0.65))
        }
        if let raw = DomainPackText.labeledDate(after: ["date of visit", "visit date", "date of admission", "consulted on", "seen on"], in: text),
           let iso = PatentDomainPack.normalizeDate(raw) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "visitDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.65, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        return facts
    }

    // MARK: - Helpers

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }

    nonisolated static func labeledValue(after markers: [String], in text: String) -> String? {
        DomainPackText.labeledValue(after: markers, in: text)
    }
}
