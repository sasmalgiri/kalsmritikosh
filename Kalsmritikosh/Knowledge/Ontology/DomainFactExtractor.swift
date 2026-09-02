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

    /// V2 (C-10) — corroboration-aware merge. Key = (subject, field, CANONICAL
    /// value): spellings of one value collapse into a single fact; genuinely
    /// different canonical values for the same field are PRESERVED, so a true
    /// disagreement survives as two facts (owner binding — never averaged away,
    /// CLM-003 surfaces it). The merged fact keeps the union of evidence blocks,
    /// the max confidence, the stronger (higher-confidence) side's assessment,
    /// and `sourceCount` set to the INVARIANT: distinct source blocks. The value
    /// FORM kept is the first-seen (the extractor emits in a deterministic order,
    /// so this is stable) — but for a v1 identifier the stored value is already
    /// the bare atom, so all spellings agree on the form anyway.
    nonisolated static func merge(_ facts: [GenericFact]) -> [GenericFact] {
        let comparator = CanonicalFactComparator()
        var byKey: [String: GenericFact] = [:]
        var order: [String] = []
        for f in facts {
            let shape = FactSchemaRegistry.expectedShape(of: f.field)
            let canon = comparator.canonical(f.value, shape)
            let key = "\(f.subjectLabel.lowercased())|\(f.field)|\(canon)"
            if let existing = byKey[key] {
                let blocks = Array(Set(existing.sourceBlockIDs + f.sourceBlockIDs))
                let strongerIsF = f.confidence > existing.confidence
                byKey[key] = GenericFact(id: existing.id, subjectID: existing.subjectID ?? f.subjectID,
                                         subjectLabel: existing.subjectLabel, field: existing.field,
                                         value: existing.value, unit: existing.unit ?? f.unit,
                                         assessment: strongerIsF ? f.assessment : existing.assessment,
                                         confidence: max(existing.confidence, f.confidence),
                                         sourceBlockIDs: blocks,
                                         producerVersion: existing.producerVersion ?? f.producerVersion,
                                         rawMatch: existing.rawMatch ?? f.rawMatch,
                                         sourceCount: Set(blocks).count)
            } else {
                byKey[key] = GenericFact(id: f.id, subjectID: f.subjectID,
                                         subjectLabel: f.subjectLabel, field: f.field,
                                         value: f.value, unit: f.unit,
                                         assessment: f.assessment, confidence: f.confidence,
                                         sourceBlockIDs: f.sourceBlockIDs,
                                         producerVersion: f.producerVersion,
                                         rawMatch: f.rawMatch,
                                         sourceCount: Set(f.sourceBlockIDs).count)
                order.append(key)
            }
        }
        return resolveIdentifierCollisions(order.compactMap { byKey[$0] })
    }

    /// V2 (C-10) — cross-field mislabel resolution at the SOURCE. A canonical
    /// identifier value claimed by MORE THAN ONE identifier field is a
    /// collision (the owner ground-truth case: an application number captured
    /// under "Patent No." in one block while it is the applicationNumber
    /// everywhere else). When exactly one claiming field holds that value as
    /// its SOLE value (its true home) and another claiming field also holds a
    /// DIFFERENT value (so the collision is an intruder there), the value is
    /// REASSIGNED to its home — its evidence blocks merge in as corroboration,
    /// nothing is deleted (the no-delete directive) — and dropped from the
    /// intruded field. A genuine disagreement (two values under one field,
    /// neither colliding across fields) is left untouched: it survives as a
    /// conflict for the evidence gate to surface. The write-time twin of the
    /// composer's query-time cross-field guard: this kills a SAME-block
    /// mislabel at ingest; the query-time guard still covers cross-block cases.
    nonisolated static func resolveIdentifierCollisions(_ facts: [GenericFact]) -> [GenericFact] {
        let cmp = CanonicalFactComparator()
        func canon(_ f: GenericFact) -> String { cmp.canonical(f.value, .identifier) }
        let idIndexed = facts.enumerated().filter {
            FactSchemaRegistry.expectedShape(of: $0.element.field) == .identifier
        }
        guard idIndexed.count >= 2 else { return facts }

        var fieldsByValue: [String: Set<String>] = [:]     // canonical value → claiming fields
        var valuesByField: [String: Set<String>] = [:]     // field → distinct canonical values
        for (_, f) in idIndexed {
            fieldsByValue[canon(f), default: []].insert(f.field)
            valuesByField[f.field, default: []].insert(canon(f))
        }

        var dropIndices = Set<Int>()
        var extraBlocks: [String: [UUID]] = [:]             // "field|canon" (home) → reassigned blocks
        for (idx, f) in idIndexed {
            let v = canon(f)
            guard (fieldsByValue[v]?.count ?? 0) >= 2 else { continue }       // collision only
            guard (valuesByField[f.field]?.count ?? 0) > 1 else { continue }  // this field is intruded
            let homes = (fieldsByValue[v] ?? []).filter { (valuesByField[$0]?.count ?? 0) == 1 }
            guard homes.count == 1, let home = homes.first, home != f.field else { continue }
            dropIndices.insert(idx)
            extraBlocks["\(home)|\(v)", default: []].append(contentsOf: f.sourceBlockIDs)
        }
        guard !dropIndices.isEmpty else { return facts }

        var out: [GenericFact] = []
        for (i, f) in facts.enumerated() {
            if dropIndices.contains(i) { continue }
            if FactSchemaRegistry.expectedShape(of: f.field) == .identifier,
               let extra = extraBlocks["\(f.field)|\(canon(f))"], !extra.isEmpty {
                let blocks = Array(Set(f.sourceBlockIDs + extra))
                out.append(GenericFact(id: f.id, subjectID: f.subjectID, subjectLabel: f.subjectLabel,
                                       field: f.field, value: f.value, unit: f.unit,
                                       assessment: f.assessment, confidence: f.confidence,
                                       sourceBlockIDs: blocks,
                                       producerVersion: f.producerVersion, rawMatch: f.rawMatch,
                                       sourceCount: Set(blocks).count))
            } else {
                out.append(f)
            }
        }
        return out
    }
}
