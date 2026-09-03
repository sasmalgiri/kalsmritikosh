//
//  FieldRegistry.swift
//  Kalsmritikosh
//
//  F8 (II.0) — the single registry of every field this system KNOWS: the four
//  domain packs' emittedFields plus the slot vocabulary. The abstention layer
//  reads it to say the honest, specific thing:
//    · a KNOWN field with no facts → "none of the N documents carries a …"
//    · an UNKNOWN field-shaped ask → "… is not among the fields this archive's
//      documents contain" (+ the nearest known field as the NF-2 nearest-miss).
//  Deterministic, assembled from the same constants the extractors publish —
//  a new emittable field joins the registry by existing, never by registration
//  ceremony (the C-ii completeness pattern).
//

import Foundation

public enum FieldRegistry {

    /// Every field the extraction layer can emit, normalized. Assembled from
    /// the packs' own declarations — the registry cannot drift from the packs.
    public nonisolated static let knownFields: Set<String> = {
        var out = Set<String>()
        for f in PatentDomainPack.emittedFields { out.insert(FactSchemaRegistry.normalizeField(f)) }
        for f in ContractDomainPack.emittedFields { out.insert(FactSchemaRegistry.normalizeField(f)) }
        for f in TransactionDomainPack.emittedFields { out.insert(FactSchemaRegistry.normalizeField(f)) }
        for f in EmploymentDomainPack.emittedFields { out.insert(FactSchemaRegistry.normalizeField(f)) }
        for entry in SlotFieldResolver.vocabulary { out.insert(FactSchemaRegistry.normalizeField(entry.fieldID)) }
        return out
    }()

    public nonisolated static func isKnown(_ fieldID: String) -> Bool {
        knownFields.contains(FactSchemaRegistry.normalizeField(fieldID))
    }

    /// NF-2 nearest-miss: the known field sharing the longest token with the
    /// asked one ("trademark number" → "patent number" via "number"), rendered
    /// as a human label. nil when nothing meaningfully relates.
    public nonisolated static func nearestKnown(toLabel label: String) -> String? {
        let askedTokens = Set(label.lowercased().split(separator: " ").map(String.init))
        var best: (field: String, overlap: Int)?
        for field in knownFields.sorted() {   // sorted → deterministic tie-break
            let human = SlotFieldResolver.humanLabel(forFieldID: field).lowercased()
            let overlap = Set(human.split(separator: " ").map(String.init)).intersection(askedTokens).count
            if overlap > (best?.overlap ?? 0) { best = (field, overlap) }
        }
        guard let best, best.overlap >= 1 else { return nil }
        return SlotFieldResolver.humanLabel(forFieldID: best.field)
    }
}
