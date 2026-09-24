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
import os

public struct DomainFactExtractor: Sendable {
    public nonisolated init() {}

    /// The packs as callable roots, in the DEFAULT order (the historical
    /// sequence first — first-seen value form wins in merge, so order is
    /// semantic — then the persona-coverage starter packs, each marker-gated
    /// so it stays silent outside its domain).
    private nonisolated static let defaultOrder: [PackRoot] = [
        .employment, .transaction, .contract, .patent, .research,
        .medical, .legalCase, .vitalRecords, .financialStatement, .property, .identityDocument
    ]

    nonisolated enum PackRoot: CaseIterable, Sendable {
        case employment, transaction, contract, patent, research
        case medical, legalCase, vitalRecords, financialStatement, property, identityDocument
        nonisolated func extractFacts(fromText t: String, subjectLabel s: String, blockID b: UUID) -> [GenericFact] {
            switch self {
            case .employment:  return EmploymentDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .transaction: return TransactionDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .contract:    return ContractDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .patent:      return PatentDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .research:    return ResearchDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .medical:            return MedicalDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .legalCase:          return LegalCaseDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .vitalRecords:       return VitalRecordsDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .financialStatement: return FinancialStatementDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .property:           return PropertyDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            case .identityDocument:   return IdentityDocumentDomainPack.extractFacts(fromText: t, subjectLabel: s, blockID: b)
            }
        }
    }

    /// D-17 Step 4 — class-ordered roots as DATA: the class's own root is
    /// tried FIRST (a certificate-classed file meets the patent root before
    /// the employment one), then the remaining packs in the default order.
    /// EVERY pack still runs on every block (the guardrail: classification
    /// errors degrade gracefully — an `other`-classed document uses the
    /// default order and is never excluded).
    nonisolated static let preferredRootByClass: [DocumentClass: PackRoot] = [
        .legalDocument: .patent,
        .certificate:   .patent,
        .invoice:       .transaction,
        .receipt:       .transaction,
        .contract:      .contract,
        .resume:        .employment,
        .email:         .employment,
        .researchPaper: .research,
    ]

    nonisolated static func packOrder(for docClass: DocumentClass?) -> [PackRoot] {
        guard let docClass, let preferred = preferredRootByClass[docClass] else { return defaultOrder }
        return [preferred] + defaultOrder.filter { $0 != preferred }
    }

    /// Run all packs over `text` for `subjectLabel`, linking facts to `blockID`.
    /// `documentClass` orders the roots (class's own first); nil keeps the
    /// historical order, so existing callers are byte-identical.
    public nonisolated func extract(fromText text: String, subjectLabel: String, blockID: UUID,
                                    documentClass: DocumentClass? = nil) -> [GenericFact] {
        var facts: [GenericFact] = []
        for root in Self.packOrder(for: documentClass) {
            facts += root.extractFacts(fromText: text, subjectLabel: subjectLabel, blockID: blockID)
        }
        return Self.merge(facts)
    }

    /// C-4 — the DOCUMENT-level entry point: every pack over every block, PLUS
    /// the label/value pairs a page break separated (see
    /// `CrossBlockLabelAssembler`). Callers that hold the whole block list
    /// should use this; `extract(fromText:)` remains for single-block callers
    /// and is unchanged.
    ///
    /// Without this pass a field label at the foot of a page and its value at
    /// the head of the next produced NO fact — each extractor sees one block, so
    /// neither half was ever a fact. That is ordinary paginated-document
    /// behaviour, not an exotic case.
    ///
    /// `perBlockMinimumLength` applies only to the per-block pass, matching the
    /// existing call sites. The assembler deliberately sees blocks of EVERY
    /// length: a page whose first line is a bare "700321" is a six-character
    /// block, and it is exactly the block that carries the value.
    /// P3.1 — an overload carrying each block's KIND, so the open-field
    /// extractor can weight a table cell above a paragraph and refuse
    /// furniture outright. The kind-less overload below forwards with
    /// `.paragraph`, which is the conservative assumption.
    public nonisolated func extract(
        fromKindedBlocks blocks: [(id: UUID, text: String, kind: EvidenceBlockKind)],
        subjectLabel: String,
        documentClass: DocumentClass? = nil,
        perBlockMinimumLength: Int = 8
    ) -> [GenericFact] {
        var facts = extract(
            fromBlocks: blocks.map { .init(id: $0.id, text: $0.text) },
            subjectLabel: subjectLabel,
            documentClass: documentClass,
            perBlockMinimumLength: perBlockMinimumLength)
        // P3.1 — THE UNIVERSALITY PASS, and it runs LAST on purpose.
        //
        // It never emits a field the eleven packs own (see
        // OpenFieldExtractor.reservedFields), so it cannot perturb their
        // output; running it after them also means `merge` sees pack facts
        // first, and merge keeps the FIRST-SEEN value form. Order therefore
        // preserves today's behaviour exactly while adding the fields no pack
        // was ever written for.
        let open = OpenFieldExtractor.extractFacts(blocks: blocks, subjectLabel: subjectLabel)
        if let cap = open.cappedAt {
            // Hitting the cap is itself a finding: one document presented more
            // label-like lines than any real form has, which usually means a
            // table of contents, a pasted spreadsheet, or an OCR grid.
            KalsmritikoshLog.knowledge.info(
                "OpenFieldExtractor: capped at \(cap, privacy: .public) fields for subject \(subjectLabel, privacy: .private)")
        }
        facts += open.facts
        return Self.merge(facts)
    }

    public nonisolated func extract(
        fromBlocks blocks: [CrossBlockLabelAssembler.Block],
        subjectLabel: String,
        documentClass: DocumentClass? = nil,
        perBlockMinimumLength: Int = 8
    ) -> [GenericFact] {
        var facts: [GenericFact] = []
        for block in blocks {
            guard block.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= perBlockMinimumLength
            else { continue }
            // PER-BLOCK merge, exactly as `extract(fromText:)` does it. This is
            // not redundant with the merge below: `resolveIdentifierCollisions`
            // runs inside `merge`, and its documented scope (owner binding gate
            // 4) is collisions whose fields CO-OCCUR IN ONE BLOCK. Accumulating
            // raw facts and merging only once at the end would silently widen
            // that resolver from per-block to per-document, which is a
            // different rule than the one that was agreed.
            facts += extract(fromText: block.text, subjectLabel: subjectLabel,
                             blockID: block.id, documentClass: documentClass)
        }
        facts += Self.crossBlockFacts(in: blocks, subjectLabel: subjectLabel,
                                      documentClass: documentClass)
        // The document-level merge the call sites already performed on the
        // accumulated per-block output, kept here so this entry point's
        // contract matches `extract(fromText:)`: callers receive merged facts.
        return Self.merge(facts)
    }

    /// Facts built from rejoined label/value pairs, each marked
    /// `.crossBlockAssembled` and citing every block it was assembled from.
    ///
    /// RESTRICTED TO IDENTIFIER-SHAPED FIELDS. The assembly is a two-token
    /// synthetic string ("Patent No. 700321") built for one purpose: to let an
    /// identifier label reach its number. Running the full pack surface over it
    /// and keeping whatever else came out would let a synthetic string mint
    /// statuses, dates or names that no block actually states in that form.
    /// So only the field kind the assembly was made to recover survives it.
    nonisolated static func crossBlockFacts(
        in blocks: [CrossBlockLabelAssembler.Block],
        subjectLabel: String,
        documentClass: DocumentClass?
    ) -> [GenericFact] {
        let assemblies = CrossBlockLabelAssembler().assemblies(in: blocks)
        guard !assemblies.isEmpty else { return [] }
        var out: [GenericFact] = []
        for assembly in assemblies {
            // The label block's id is the nominal home; `assembled(from:)` then
            // re-grounds the fact on the full block set.
            guard let home = assembly.blockIDs.first else { continue }
            for root in packOrder(for: documentClass) {
                let produced = root.extractFacts(fromText: assembly.text,
                                                 subjectLabel: subjectLabel, blockID: home)
                for fact in produced
                where FactSchemaRegistry.expectedShape(of: fact.field) == .identifier {
                    out.append(fact.assembled(
                        from: assembly.blockIDs,
                        derivation: .crossBlockAssembled,
                        confidence: PatentDomainPack.crossBlockAssembledConfidence))
                }
            }
        }
        return out
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
                let blocks = stableBlocks(existing.sourceBlockIDs + f.sourceBlockIDs)
                let strongerIsF = f.confidence > existing.confidence
                byKey[key] = GenericFact(id: existing.id, subjectID: existing.subjectID ?? f.subjectID,
                                         subjectLabel: existing.subjectLabel, field: existing.field,
                                         value: existing.value, unit: existing.unit ?? f.unit,
                                         assessment: strongerIsF ? f.assessment : existing.assessment,
                                         confidence: max(existing.confidence, f.confidence),
                                         sourceBlockIDs: blocks,
                                         producerVersion: existing.producerVersion ?? f.producerVersion,
                                         rawMatch: existing.rawMatch ?? f.rawMatch,
                                         sourceCount: blocks.count,
                                         // VERBATIM WINS: a value read cleanly
                                         // ANYWHERE is a clean value, so a
                                         // repaired occurrence must not flag it.
                                         // The nil here is an assertion, not an
                                         // absence, so `??` would be wrong.
                                         derivation: GenericFact.mergedDerivation(
                                            existing.derivation, f.derivation))
            } else {
                byKey[key] = GenericFact(id: f.id, subjectID: f.subjectID,
                                         subjectLabel: f.subjectLabel, field: f.field,
                                         value: f.value, unit: f.unit,
                                         assessment: f.assessment, confidence: f.confidence,
                                         sourceBlockIDs: stableBlocks(f.sourceBlockIDs),
                                         producerVersion: f.producerVersion,
                                         rawMatch: f.rawMatch,
                                         sourceCount: Set(f.sourceBlockIDs).count,
                                         derivation: f.derivation)
                order.append(key)
            }
        }
        return resolveIdentifierCollisions(order.compactMap { byKey[$0] })
    }

    /// ORIGIN-FIX (owner 2026-09-02, positional-read audit): dedupe AND SORT
    /// evidence blocks by the unit-A stable key. `Array(Set(...))` alone laundered
    /// a per-process hash order into every downstream `.first` reader (the
    /// sourceBlockIDs.first sub-class); sorting at the write makes those reads
    /// lawful-by-construction — the class dies where it's born (the C-i shape).
    nonisolated static func stableBlocks(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
    }

    /// V2 (C-10) — cross-field mislabel resolution at the SOURCE, CAGED (owner
    /// binding 2026-09-02, gate 1). A canonical identifier value claimed by MORE
    /// THAN ONE identifier field is a collision (the owner ground-truth case: an
    /// application number captured under "Patent No." in one block while it is
    /// the applicationNumber everywhere else). Reassignment fires ONLY when ALL
    /// hold:
    ///   (a) canonical-VALUE equality across fields — NEVER value shape (no
    ///       "looks application-shaped" homing; that would be hasPrefix sniffing
    ///       reborn at write time). The only signal is `canonical(value)`.
    ///   (b) the intruded field holds a DIFFERENT value too (the collision is
    ///       redundant there — an intruder, not the field's own answer). This is
    ///       what separates a MISLABEL from a COINCIDENCE: two fields that each
    ///       hold the same value as their SOLE value (an invoice number equal to
    ///       a case number) never cross-reassign — value-equality alone is not
    ///       identity of referent (gate 2).
    ///   (c) exactly one claiming field holds the value as its sole value (a
    ///       single unambiguous home).
    ///   (d) CORROBORATION GATE — the home's attestation ≥ the intruded
    ///       attestation. A value can never be moved INTO a field where it is
    ///       LESS attested than where it sits: this stops a well-witnessed
    ///       patent number that appears once, mislabeled, under applicationNumber
    ///       from being dragged out of patentNumber. ("≥" not strict ">": a
    ///       same-block letter attests every field once, so the honest single-
    ///       block corroboration is uniformly 1 — reported to the owner.)
    /// On reassignment the value's evidence blocks ride into the home as
    /// corroboration (nothing deleted — the no-delete directive) and drop from
    /// the intruded field. A genuine disagreement (two values under one field,
    /// neither colliding across fields) is untouched — it survives as a conflict.
    ///
    /// SCOPE (owner binding gate 4): this runs inside merge(), which the
    /// extractor calls PER BLOCK — so the resolver only sees collisions whose
    /// fields co-occur in ONE block. A mislabel whose true-home value lives in a
    /// DIFFERENT document is out of scope here and is caught by the composer's
    /// query-time cross-field guard instead. The V5 drain's predicted-diff must
    /// state this: within-block reassignment only; cross-block collisions on the
    /// 716 sources remain the query-time layer's job.
    nonisolated static func resolveIdentifierCollisions(_ facts: [GenericFact]) -> [GenericFact] {
        let cmp = CanonicalFactComparator()
        func canon(_ f: GenericFact) -> String { cmp.canonical(f.value, .identifier) }
        let idIndexed = facts.enumerated().filter {
            FactSchemaRegistry.expectedShape(of: $0.element.field) == .identifier
        }
        guard idIndexed.count >= 2 else { return facts }

        var fieldsByValue: [String: Set<String>] = [:]     // canonical value → claiming fields
        var valuesByField: [String: Set<String>] = [:]     // field → distinct canonical values
        var attestation: [String: Int] = [:]               // "field|canon" → corroboration (sourceCount)
        for (_, f) in idIndexed {
            let v = canon(f)
            fieldsByValue[v, default: []].insert(f.field)
            valuesByField[f.field, default: []].insert(v)
            attestation["\(f.field)|\(v)"] = f.sourceCount ?? Set(f.sourceBlockIDs).count
        }

        var dropIndices = Set<Int>()
        var extraBlocks: [String: [UUID]] = [:]             // "field|canon" (home) → reassigned blocks
        var reassignOrigin: [String: String] = [:]          // "field|canon" (home) → the intruded field it came from
        for (idx, f) in idIndexed {
            let v = canon(f)
            guard (fieldsByValue[v]?.count ?? 0) >= 2 else { continue }       // (a) collision only
            guard (valuesByField[f.field]?.count ?? 0) > 1 else { continue }  // (b) this field is intruded
            let homes = (fieldsByValue[v] ?? []).filter { (valuesByField[$0]?.count ?? 0) == 1 }
            guard homes.count == 1, let home = homes.first, home != f.field else { continue }  // (c)
            let homeSC = attestation["\(home)|\(v)"] ?? 0
            let intrudedSC = attestation["\(f.field)|\(v)"] ?? 1
            guard homeSC >= intrudedSC else { continue }                     // (d) corroboration gate
            dropIndices.insert(idx)
            extraBlocks["\(home)|\(v)", default: []].append(contentsOf: f.sourceBlockIDs)
            reassignOrigin["\(home)|\(v)"] = f.field                          // gate-3 provenance
        }
        guard !dropIndices.isEmpty else { return facts }

        var out: [GenericFact] = []
        for (i, f) in facts.enumerated() {
            if dropIndices.contains(i) { continue }
            let key = "\(f.field)|\(canon(f))"
            if FactSchemaRegistry.expectedShape(of: f.field) == .identifier,
               let extra = extraBlocks[key], !extra.isEmpty {
                let blocks = stableBlocks(f.sourceBlockIDs + extra)
                out.append(GenericFact(id: f.id, subjectID: f.subjectID, subjectLabel: f.subjectLabel,
                                       field: f.field, value: f.value, unit: f.unit,
                                       assessment: f.assessment, confidence: f.confidence,
                                       sourceBlockIDs: blocks,
                                       producerVersion: f.producerVersion, rawMatch: f.rawMatch,
                                       sourceCount: Set(blocks).count,
                                       reassignedFrom: f.reassignedFrom ?? reassignOrigin[key],  // gate-3 advisory
                                       derivation: f.derivation))
            } else {
                out.append(f)
            }
        }
        return out
    }
}
