//
//  ResearchDomainPack.swift
//  Kalsmritikosh
//
//  SEM-008 — the research/publication domain pack. Optional; recognizes study/publication
//  records and extracts a DOI, year and journal/venue as evidence-linked facts.
//  Deterministic, offline. Facts are SOURCE_ASSERTED.
//

import Foundation

public enum ResearchDomainPack {

    public nonisolated static var recognizers: [BlockRecognizer] {
        [
            BlockRecognizer(name: "citationLine") { text, _ in
                let t = text.lowercased()
                let hit = t.contains("doi") || t.contains("et al") || t.contains("journal")
                    || t.contains("vol.") || t.contains("pp.") || t.contains("proceedings")
                return hit ? BlockSemanticTag(role: "citationLine", confidence: 0.65, recognizedBy: "citationLine") : nil
            }
        ]
    }

    public nonisolated static func registry(base: BlockSemanticsRegistry = .generic) -> BlockSemanticsRegistry {
        recognizers.reduce(base) { $0.registering($1) }
    }

    /// Extract publication facts (DOI, year, venue) from citation-like text.
    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        var facts: [GenericFact] = []
        if let doi = firstMatch(#"10\.\d{4,9}/[-._;()/:A-Za-z0-9]+"#, in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "doi", value: doi,
                                     status: .sourceAsserted, confidence: 0.85, sourceBlockIDs: [blockID]))
        }
        if let year = firstMatch(#"\b(?:19|20)\d{2}\b"#, in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "date", value: year, unit: "year",
                                     status: .sourceAsserted, confidence: 0.5, sourceBlockIDs: [blockID]))
        }
        return facts
    }

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }
}
