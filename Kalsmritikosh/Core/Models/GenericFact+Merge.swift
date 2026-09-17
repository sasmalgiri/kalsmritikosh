//
//  GenericFact+Merge.swift
//  Kalsmritikosh
//
//  Topic-Ledger Rebuild U1 (owner rule 1, 2026-09-17) — "one-time-consumable per
//  distinct fact". A fact is identified by its NATURAL KEY (subject + field +
//  value + unit), not by a per-extraction UUID. Re-encountering the same fact
//  MERGES into the canonical row — unioning its source blocks and counting the
//  distinct corroborating documents — instead of minting a duplicate. This is
//  the fix for the live finding of 9,266 rows collapsing to 387 distinct facts.
//
//  Pure and deterministic; facts are derived projections, so merging never
//  touches primary evidence.
//

import Foundation

extension GenericFact {
    /// The identity of a fact for dedup/merge: same subject asserting the same
    /// field=value(unit) is the SAME fact, however many documents state it.
    public nonisolated var naturalKey: String {
        let subject = subjectID?.uuidString.lowercased() ?? subjectLabel.lowercased()
        let u = (unit ?? "").lowercased()
        return [subject,
                field.lowercased(),
                value.lowercased(),
                u].joined(separator: "|")
    }

    /// Merge another occurrence of the SAME fact (same naturalKey) into this
    /// canonical one: union the source blocks, recompute the distinct-document
    /// corroboration count, keep the higher confidence, and preserve this row's
    /// id/assessment. Caller guarantees `naturalKey == other.naturalKey`.
    public nonisolated func mergedWith(_ other: GenericFact) -> GenericFact {
        var blocks = sourceBlockIDs
        var seen = Set(sourceBlockIDs)
        for b in other.sourceBlockIDs where seen.insert(b).inserted { blocks.append(b) }
        return GenericFact(
            id: id,                                   // keep the canonical (earliest) id
            subjectID: subjectID ?? other.subjectID,
            subjectLabel: subjectLabel,
            field: field,
            value: value,
            unit: unit ?? other.unit,
            assessment: assessment,                   // canonical row's assessment stands
            confidence: Swift.max(confidence, other.confidence),
            sourceBlockIDs: blocks,
            producerVersion: Swift.max(producerVersion ?? 0, other.producerVersion ?? 0),
            rawMatch: rawMatch ?? other.rawMatch,
            sourceCount: blocks.count,                // distinct corroborating documents/blocks
            reassignedFrom: reassignedFrom ?? other.reassignedFrom)
    }

    /// Collapse a batch of facts to one canonical row per naturalKey (first-seen
    /// wins the id; the rest merge in). Deterministic in input order.
    public nonisolated static func canonicalize(_ facts: [GenericFact]) -> [GenericFact] {
        var order: [String] = []
        var byKey: [String: GenericFact] = [:]
        for f in facts {
            let k = f.naturalKey
            if let existing = byKey[k] {
                byKey[k] = existing.mergedWith(f)
            } else {
                byKey[k] = f
                order.append(k)
            }
        }
        return order.compactMap { byKey[$0] }
    }
}
