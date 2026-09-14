//
//  LegalCaseDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the LITIGATION / legal-case domain (the lawyer /
//  forensic / compliance persona). Distinct from ContractDomainPack:
//  contracts are agreements between parties; this pack reads COURT
//  matters — case numbers, courts, plaintiff/defendant, hearing dates.
//  Optional, additive, marker-gated (silent on non-legal text).
//  Deterministic, offline.
//

import Foundation

public enum LegalCaseDomainPack {

    nonisolated static let markers: [String] = [
        "plaintiff", "defendant", "petitioner", "respondent", "vs.", " v. ",
        "case no", "suit no", "in the court of", "hon'ble", "honourable court",
        "cause list", "hearing", "adjourned", "court of", "tribunal",
    ]

    nonisolated static func isLegalCase(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// caseNumber is an identifier (display constant "Case No."); the rest
    /// are text/date and render their own atom.
    public nonisolated static let emittedFields: [String] =
        ["caseNumber", "court", "plaintiff", "defendant", "hearingDate"]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        guard isLegalCase(lower) else { return [] }
        var facts: [GenericFact] = []

        if let v = DomainPackText.labeledIdentifier(after: ["case no", "suit no", "case number", "c.a. no", "w.p. no"], in: text) {
            facts.append(fact(subjectLabel, "caseNumber", v, blockID, 0.8))
        }
        if let v = DomainPackText.labeledValue(after: ["in the court of", "court of", "before the", "tribunal"], in: text) {
            facts.append(fact(subjectLabel, "court", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["plaintiff", "petitioner", "appellant", "complainant"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "plaintiff", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["defendant", "respondent", "accused"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "defendant", v, blockID, 0.7))
        }
        if let raw = DomainPackText.firstDate(in: text), lower.contains("hearing") || lower.contains("adjourned") || lower.contains("listed"),
           let iso = PatentDomainPack.normalizeDate(raw) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "hearingDate", value: iso,
                                     status: .sourceAsserted, confidence: 0.65, sourceBlockIDs: [blockID],
                                     producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
        }
        return facts
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}
