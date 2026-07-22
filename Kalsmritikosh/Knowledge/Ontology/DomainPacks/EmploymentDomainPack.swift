//
//  EmploymentDomainPack.swift
//  Kalsmritikosh
//
//  SEM-004 — the employment domain pack. Optional; improves extraction for résumés / CVs /
//  bios by recognizing employer, role/designation and tenure, emitting evidence-linked
//  GenericFacts. Absence never blocks generic search. Deterministic, offline.
//
//  Facts are SOURCE_ASSERTED — a résumé records what the person claims about their history;
//  it does not by itself establish truth.
//

import Foundation

public enum EmploymentDomainPack {

    public nonisolated static var recognizers: [BlockRecognizer] {
        [
            BlockRecognizer(name: "employerLine") { text, _ in
                firstMatch(orgPattern, in: text) != nil
                    ? BlockSemanticTag(role: "employerLine", confidence: 0.7, recognizedBy: "employerLine") : nil
            },
            BlockRecognizer(name: "roleLine") { text, _ in
                firstMatch(rolePattern, in: text) != nil
                    ? BlockSemanticTag(role: "roleLine", confidence: 0.65, recognizedBy: "roleLine") : nil
            }
        ]
    }

    public nonisolated static func registry(base: BlockSemanticsRegistry = .generic) -> BlockSemanticsRegistry {
        recognizers.reduce(base) { $0.registering($1) }
    }

    /// Company-name shapes: a capitalized phrase (allowing "&" connectors) ending in a
    /// company suffix/keyword. "Orchid Chemical & Pharmaceutical Ltd" stays whole.
    nonisolated static let orgPattern =
        #"\b[A-Z][A-Za-z.]+(?:\s+(?:&\s+)?[A-Z][A-Za-z.]+){0,5}\s+(?:Ltd\.?|Limited|Pvt\.?|Private|Inc\.?|LLP|LLC|Corp\.?|Corporation|Industries|Chemicals?|Pharmaceutical(?:s)?|Technologies|Systems|Solutions|India)\b"#

    /// Role/title shapes: a capitalized phrase ending in a role keyword.
    nonisolated static let rolePattern =
        #"\b(?:[A-Z][A-Za-z]+\s+){0,3}(?:Executive|Manager|Engineer|Officer|Chemist|Analyst|Consultant|Director|Coordinator|Co-?ordinator|Developer|Lead|Specialist|Administrator|Associate)\b"#

    /// Extract employment facts (employer, role) from résumé-like text.
    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        var facts: [GenericFact] = []
        // Employers — dedup, keep the first few in document order.
        var seenOrg = Set<String>()
        for org in allMatches(orgPattern, in: text) where seenOrg.insert(org.lowercased()).inserted {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "employer", value: org,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID]))
            if facts.count >= 4 { break }
        }
        if let role = firstMatch(rolePattern, in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "role", value: role,
                                     status: .sourceAsserted, confidence: 0.65, sourceBlockIDs: [blockID]))
        }
        return facts
    }

    // MARK: - Helpers

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        allMatches(pattern, in: s).first
    }

    nonisolated static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
    }
}
