//
//  PatentDomainPack.swift
//  Kalsmritikosh
//
//  SEM-007 — the patent domain pack. Optional; recognizes patent filings and extracts the
//  patent number, applicant/assignee and OFFICIAL STATUS (filed / published / granted /
//  rejected / abandoned). Official status is authoritative for status questions (a grant
//  certificate outranks correspondence about the application). Deterministic, offline.
//
//  Status facts are SOURCE_ASSERTED (the document records the office's stated status); the
//  pack does not itself adjudicate validity.
//

import Foundation

public enum PatentDomainPack {

    public nonisolated static var recognizers: [BlockRecognizer] {
        [
            BlockRecognizer(name: "patentNumberLine") { text, _ in
                firstMatch(numberPattern, in: text) != nil
                    ? BlockSemanticTag(role: "patentNumber", confidence: 0.8, recognizedBy: "patentNumberLine") : nil
            },
            BlockRecognizer(name: "patentStatusLine") { text, _ in
                status(in: text) != nil
                    ? BlockSemanticTag(role: "patentStatus", confidence: 0.75, recognizedBy: "patentStatusLine") : nil
            }
        ]
    }

    public nonisolated static func registry(base: BlockSemanticsRegistry = .generic) -> BlockSemanticsRegistry {
        recognizers.reduce(base) { $0.registering($1) }
    }

    /// Patent number shapes: "Patent No. 1234567", "Application No 202411001234", "US1234567B2".
    nonisolated static let numberPattern =
        #"(?:patent|application|publication)\s*(?:no\.?|number|#)?\s*[:\-]?\s*[A-Z]{0,2}\s?[\d,\/]{5,}[A-Z0-9]*"#

    /// Ordered by authority: granted/rejected are terminal official states.
    nonisolated static let statusKeywords: [(String, String)] = [
        ("granted", "granted"), ("grant of patent", "granted"),
        ("rejected", "rejected"), ("refused", "rejected"),
        ("abandoned", "abandoned"), ("withdrawn", "abandoned"),
        ("published", "published"),
        ("filed", "filed"), ("application filed", "filed"), ("pending", "pending")
    ]

    public nonisolated static func status(in text: String) -> String? {
        let t = text.lowercased()
        for (needle, canonical) in statusKeywords where t.contains(needle) { return canonical }
        return nil
    }

    /// Extract patent facts (number, status) as evidence-linked SOURCE_ASSERTED facts.
    public nonisolated static func extractFacts(
        fromText text: String,
        subjectLabel: String,
        blockID: UUID
    ) -> [GenericFact] {
        var facts: [GenericFact] = []
        if let number = firstMatch(numberPattern, in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "patentNumber",
                                     value: number.trimmingCharacters(in: .whitespaces),
                                     status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blockID]))
        }
        if let st = status(in: text) {
            facts.append(GenericFact(subjectLabel: subjectLabel, field: "status", value: st,
                                     status: .sourceAsserted, confidence: 0.75, sourceBlockIDs: [blockID]))
        }
        return facts
    }

    // MARK: - Helpers

    nonisolated static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }
}
