//
//  DomainFactExtractor.swift
//  Kalsmritikosh
//
//  SEM-004…008 unification — the single entry point that runs every optional domain pack
//  over a block's text and returns the evidence-linked GenericFacts they produce, deduped.
//  This is what the ingest/enrichment pipeline calls: packs are additive and domain-neutral,
//  so an unfamiliar domain simply yields fewer facts — never a failure.
//
//  Deterministic, offline. No pack "wins"; all contribute, and duplicate (field,value) pairs
//  from overlapping packs (e.g. a receipt that is also correspondence) are merged, keeping the
//  union of evidence blocks.
//

import Foundation

public struct DomainFactExtractor: Sendable {
    public nonisolated init() {}

    /// Run all packs over `text` for `subjectLabel`, linking facts to `blockID`.
    public nonisolated func extract(fromText text: String, subjectLabel: String, blockID: UUID) -> [GenericFact] {
        var facts: [GenericFact] = []
        facts += EmploymentDomainPack.extractFacts(fromText: text, subjectLabel: subjectLabel, blockID: blockID)
        facts += TransactionDomainPack.extractFacts(fromText: text, subjectLabel: subjectLabel, blockID: blockID)
        facts += ContractDomainPack.extractFacts(fromText: text, subjectLabel: subjectLabel, blockID: blockID)
        facts += PatentDomainPack.extractFacts(fromText: text, subjectLabel: subjectLabel, blockID: blockID)
        facts += ResearchDomainPack.extractFacts(fromText: text, subjectLabel: subjectLabel, blockID: blockID)
        return Self.merge(facts)
    }

    /// Merge facts with the same (field, value): keep one, union its evidence blocks. Different
    /// values for the same field are preserved (that's a contradiction for CLM-003 to surface).
    nonisolated static func merge(_ facts: [GenericFact]) -> [GenericFact] {
        var byKey: [String: GenericFact] = [:]
        var order: [String] = []
        for f in facts {
            let key = "\(f.field)|\(f.value.lowercased())"
            if let existing = byKey[key] {
                let blocks = Array(Set(existing.sourceBlockIDs + f.sourceBlockIDs))
                byKey[key] = GenericFact(id: existing.id, subjectID: existing.subjectID,
                                         subjectLabel: existing.subjectLabel, field: existing.field,
                                         value: existing.value, unit: existing.unit ?? f.unit,
                                         assessment: existing.assessment, confidence: max(existing.confidence, f.confidence),
                                         sourceBlockIDs: blocks)
            } else {
                byKey[key] = f
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}
