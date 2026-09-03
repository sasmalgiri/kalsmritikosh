//
//  IdentifierAnchorReview.swift
//  Kalsmritikosh
//
//  V3 3d (I-5) — the anchor split-suspect detector. Anchors resolve by EXACT
//  normalized equality only (no fuzzy R-4), so an OCR-corrupt identifier becomes
//  a SEPARATE anchor — correct, never silently folded. I-5 is the SECOND pass
//  that NOTICES two anchors are suspiciously alike (differ only by OCR-confusable
//  characters) or internally inconsistent (a grant dated before its filing) and
//  emits a REVERSIBLE PROPOSED-MERGE review event — a suggestion for a human,
//  never an auto-fold. The two anchors stay distinct until someone accepts.
//
//  Pure + deterministic + offline. The proposal is persisted (by the caller) as
//  a FactReview(action: .merge, reviewer: "system") — reusing the existing
//  reversible review vocabulary, so Phase 4's review loop consumes anchor merges
//  unchanged. A split-suspect anchor NEVER threads a milestone chain.
//

import Foundation

public enum IdentifierAnchorReview {

    /// OCR confusion classes (owner-ruled): characters a scanner routinely swaps.
    /// Case-insensitive. Bidirectional within a class.
    static let confusionClasses: [Set<Character>] = [
        ["5", "s"], ["0", "o"], ["1", "l", "i"], ["8", "b"], ["2", "z"]
    ]

    /// Are two characters OCR-confusable (or literally equal)?
    static func confusable(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        let la = Character(a.lowercased()), lb = Character(b.lowercased())
        if la == lb { return true }
        return confusionClasses.contains { $0.contains(la) && $0.contains(lb) }
    }

    /// Two canonical identifier values are OCR-NEAR-DUPLICATES iff: same length,
    /// EVERY differing position is an OCR-confusable pair, and there are between 1
    /// and `maxConfusable` such positions. 0 diffs = identical (already one
    /// anchor); a NON-confusable difference or a length change (e.g. 555489 vs
    /// 555480 — 9↔0 is not a confusion class) = GENUINELY DISTINCT identifiers, no
    /// proposal. Substitution-only by design: OCR corrupts glyphs, it doesn't add
    /// or drop digits.
    public static func isOCRNearDuplicate(_ a: String, _ b: String, maxConfusable: Int = 2) -> Bool {
        let ca = Array(a), cb = Array(b)
        guard ca.count == cb.count, !ca.isEmpty else { return false }
        var diffs = 0
        for i in 0..<ca.count {
            if ca[i] == cb[i] { continue }
            guard confusable(ca[i], cb[i]) else { return false }
            diffs += 1
            if diffs > maxConfusable { return false }
        }
        return diffs >= 1
    }

    /// A physically-impossible date order on ONE anchor — a grant earlier than its
    /// filing — marks the anchor a split-suspect (its identity or a date is
    /// corrupt). Both dates required; a missing date is not a contradiction.
    public static func isDateInconsistent(filing: Date?, grant: Date?) -> Bool {
        guard let filing, let grant else { return false }
        return grant < filing
    }

    /// A reversible proposed merge between two distinct anchors judged OCR-alike.
    /// Direction is deterministic (the lexicographically-smaller canonical value
    /// is the merge TARGET, so the same pair always proposes the same way).
    public struct ProposedMerge: Equatable, Sendable {
        public let fromAnchorID: Entity.ID   // the suspect duplicate
        public let toAnchorID: Entity.ID     // the proposed canonical target
        public let field: String
        public let fromValue: String
        public let toValue: String
        public var evidence: String {
            "OCR-confusable identifiers under \(field): \(fromValue) ~ \(toValue) (proposed merge, reversible)"
        }
    }

    private struct AnchorRef { let id: Entity.ID; let field: String; let canon: String }

    private static func refs(_ anchors: [Entity]) -> [AnchorRef] {
        anchors.compactMap { e in
            guard e.kind == .identifierAnchor, let key = e.normalizedValue else { return nil }
            // A DB-read anchor carries the identityKey "field|canon" in its
            // `normalized` column (attribute-free read); an in-memory makeAnchor()
            // carries the bare canon in normalizedValue with the field in
            // attributes. Handle both — a canonical identifier never contains "|"
            // (punctuation is stripped), so the separator is unambiguous.
            if let sep = key.firstIndex(of: "|") {
                return AnchorRef(id: e.id, field: String(key[..<sep]),
                                 canon: String(key[key.index(after: sep)...]))
            }
            guard let field = IdentifierAnchor.anchorField(of: e) else { return nil }
            return AnchorRef(id: e.id, field: field, canon: key)
        }
    }

    /// Over a set of anchors, propose reversible merges for OCR-near-duplicate
    /// canonical values that share an anchorField. Deterministic (stable ordering,
    /// stable direction). NEVER folds — returns proposals the caller persists as
    /// system FactReviews for human review.
    public static func proposedMerges(among anchors: [Entity]) -> [ProposedMerge] {
        let sorted = refs(anchors).sorted {
            ($0.field, $0.canon, $0.id.uuidString) < ($1.field, $1.canon, $1.id.uuidString)
        }
        var out: [ProposedMerge] = []
        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count where sorted[i].field == sorted[j].field {
                if isOCRNearDuplicate(sorted[i].canon, sorted[j].canon) {
                    // i sorts before j, so i's canon is the target (smaller); j is the suspect.
                    out.append(ProposedMerge(
                        fromAnchorID: sorted[j].id, toAnchorID: sorted[i].id, field: sorted[i].field,
                        fromValue: sorted[j].canon, toValue: sorted[i].canon))
                }
            }
        }
        return out
    }

    /// The anchor ids that are SPLIT-SUSPECTS from OCR near-duplication (the
    /// `from` side of a proposed merge). A split-suspect anchor must never thread
    /// a milestone chain — the milestone builder excludes these ids.
    public static func splitSuspectAnchorIDs(among anchors: [Entity]) -> Set<Entity.ID> {
        Set(proposedMerges(among: anchors).map(\.fromAnchorID))
    }
}
