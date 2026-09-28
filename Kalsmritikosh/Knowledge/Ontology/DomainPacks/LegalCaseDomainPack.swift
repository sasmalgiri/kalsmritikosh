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

    // Live-archive hardening: dropped the loose markers that fire on patent
    // and general correspondence ("hearing", "vs.", " v. ", "tribunal",
    // "adjourned", "court of") — patents have office hearings, and "vs."/
    // "v." appear everywhere. A real litigation document carries a numbered
    // case, named parties, or the court-of formula.
    nonisolated static let markers: [String] = [
        "plaintiff", "defendant", "petitioner", "respondent",
        "case no", "suit no", "in the court of", "hon'ble",
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
        if let raw = DomainPackText.labeledDate(after: ["hearing on", "date of hearing", "listed on", "next hearing", "adjourned to"], in: text),
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
