//
//  IdentityDocumentDomainPack.swift
//  Kalsmritikosh
//
//  Starter pack — the IDENTITY / government-document domain (the citizen /
//  admin persona). Reads passports, driving licences, national IDs, and
//  similar: the document type, its number, the holder, the issue/expiry
//  dates, and the issuing authority. Optional, additive, marker-gated.
//  Deterministic, offline — an ID number never leaves the Mac.
//

import Foundation

public enum IdentityDocumentDomainPack {

    nonisolated static let markers: [String] = [
        "passport", "driving licence", "driving license", "date of expiry",
        "date of issue", "issuing authority", "identity card", "national id",
        "aadhaar", "pan card", "voter id", "licence no", "license no",
    ]

    nonisolated static func isIdentity(_ lower: String) -> Bool {
        markers.contains { lower.contains($0) }
    }

    /// idNumber is an identifier (display constant "ID No."); issueDate /
    /// expiryDate are dates; the rest text.
    public nonisolated static let emittedFields: [String] =
        ["documentType", "idNumber", "holder", "issueDate", "expiryDate", "issuingAuthority"]

    nonisolated static let typeByMarker: [(String, String)] = [
        ("passport", "Passport"), ("driving licence", "Driving Licence"),
        ("driving license", "Driving License"), ("aadhaar", "Aadhaar"),
        ("pan card", "PAN Card"), ("voter id", "Voter ID"),
        ("national id", "National ID"), ("identity card", "Identity Card"),
    ]

    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        let lower = text.lowercased()
        guard isIdentity(lower) else { return [] }
        var facts: [GenericFact] = []

        if let (_, label) = typeByMarker.first(where: { lower.contains($0.0) }) {
            facts.append(fact(subjectLabel, "documentType", label, blockID, 0.8))
        }
        if let v = DomainPackText.labeledIdentifier(after: ["passport no", "licence no", "license no", "id no", "number", "no"], in: text) {
            facts.append(fact(subjectLabel, "idNumber", v, blockID, 0.8))
        }
        if let v = DomainPackText.labeledValue(after: ["name", "holder", "surname", "given name"], in: text),
           PatentDomainPack.isPlausibleRoleValue(v) {
            facts.append(fact(subjectLabel, "holder", v, blockID, 0.7))
        }
        if let v = DomainPackText.labeledValue(after: ["issuing authority", "authority", "issued by"], in: text) {
            facts.append(fact(subjectLabel, "issuingAuthority", v, blockID, 0.65))
        }
        addDate(&facts, subjectLabel, "issueDate", ["date of issue", "issued on"], text, blockID)
        addDate(&facts, subjectLabel, "expiryDate", ["date of expiry", "valid until", "expires on"], text, blockID)
        return facts
    }

    nonisolated static func addDate(_ facts: inout [GenericFact], _ subject: String, _ field: String,
                                    _ markers: [String], _ text: String, _ block: UUID) {
        guard markers.contains(where: { text.lowercased().contains($0) }),
              let after = DomainPackText.labeledValue(after: markers, in: text),
              let raw = DomainPackText.firstDate(in: after) ?? DomainPackText.firstDate(in: text),
              let iso = PatentDomainPack.normalizeDate(raw) else { return }
        facts.append(GenericFact(subjectLabel: subject, field: field, value: iso,
                                 status: .sourceAsserted, confidence: 0.65, sourceBlockIDs: [block],
                                 producerVersion: DerivedProducerVersions.facts, rawMatch: raw, sourceCount: 1))
    }

    nonisolated static func fact(_ subject: String, _ field: String, _ value: String,
                                 _ block: UUID, _ conf: Double) -> GenericFact {
        GenericFact(subjectLabel: subject, field: field, value: value,
                    status: .sourceAsserted, confidence: conf, sourceBlockIDs: [block],
                    producerVersion: DerivedProducerVersions.facts, rawMatch: value, sourceCount: 1)
    }
}
