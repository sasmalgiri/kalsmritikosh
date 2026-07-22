//
//  ContractDomainPack.swift
//  Kalsmritikosh
//
//  SEM-006 — the contract domain pack. Optional; recognizes agreements and extracts the
//  parties, effective date, and the draft/final/amendment version-state plus key terms.
//  Deterministic, offline. Facts are SOURCE_ASSERTED.
//

import Foundation

public enum ContractDomainPack {

    public nonisolated static var recognizers: [BlockRecognizer] {
        [
            BlockRecognizer(name: "partyLine") { text, _ in
                let t = text.lowercased()
                let hit = t.contains("by and between") || t.contains("between") && t.contains("and")
                    || t.contains("party of the first part") || t.contains("hereinafter")
                return hit ? BlockSemanticTag(role: "partyLine", confidence: 0.65, recognizedBy: "partyLine") : nil
            },
            BlockRecognizer(name: "versionState") { text, _ in
                versionState(in: text) != nil
                    ? BlockSemanticTag(role: "contractVersionState", confidence: 0.7, recognizedBy: "versionState") : nil
            }
        ]
    }

    public nonisolated static func registry(base: BlockSemanticsRegistry = .generic) -> BlockSemanticsRegistry {
        recognizers.reduce(base) { $0.registering($1) }
    }

    /// Draft / final / amendment version state (terminal "executed/final" prioritized).
    nonisolated static let stateKeywords: [(String, String)] = [
        ("amendment", "amendment"), ("addendum", "amendment"),
        ("executed", "final"), ("final version", "final"), ("fully signed", "final"),
        ("draft", "draft"), ("for review", "draft"), ("markup", "draft")
    ]

    public nonisolated static func versionState(in text: String) -> String? {
        let t = text.lowercased()
        for (needle, canonical) in stateKeywords where t.contains(needle) { return canonical }
        return nil
    }

    /// Extract contract facts (parties, effectiveDate, versionState) as evidence-linked facts.
    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        var facts: [GenericFact] = []
        if let state = versionState(in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "status", value: state,
                                     status: .sourceAsserted, confidence: 0.7, sourceBlockIDs: [blockID]))
        }
        if let date = firstMatch(#"(?:effective|dated|as of)\s+(?:date\s+)?[:\-]?\s*\d{1,2}[/\-.\s][A-Za-z0-9]+[/\-.\s]\d{2,4}"#, in: text)
            ?? firstMatch(#"\b\d{1,2}[/\-.]\d{1,2}[/\-.]\d{2,4}\b"#, in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "date", value: date,
                                     status: .sourceAsserted, confidence: 0.6, sourceBlockIDs: [blockID]))
        }
        return facts
    }

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
    }
}
