//
//  ComparisonLedgerResolver.swift
//  Kalsmritikosh
//
//  G3 Workflow C (T-G3.3b) — the seam that binds the pure ComparisonService
//  to the real ledger. It answers, for one field and one source document,
//  what that source says: a stated value, an explicit "none" (evidence of
//  absence), or silence (absent evidence). It never touches SQLite itself —
//  it composes two INJECTED reads (facts-for-field, block→document), so it
//  stays deterministic and testable while running on live data in the app.
//
//  Honesty rules encoded here:
//   · A source is `.stated` only when a fact whose evidence blocks belong to
//     that document carries a real value. The unit/currency qualifier is
//     folded into the value string so the matrix can tell "same magnitude,
//     different unit" from a genuine disagreement.
//   · A source is `.explicitlyNone` only when its fact's value is a recognized
//     none-token ("none", "n/a", …) — evidence of absence, not our inference.
//   · Otherwise the source is `.silent`. We never manufacture a value or a
//     "none" a source did not record.
//

import Foundation

public struct ComparisonLedgerResolver: Sendable {
    /// All facts on file for a (raw) field name, across every source.
    public let factsForField: @Sendable (_ field: String) async -> [GenericFact]
    /// The owning source-document id for an evidence block, when resolvable.
    public let documentOfBlock: @Sendable (_ blockID: UUID) async -> UUID?

    public init(
        factsForField: @escaping @Sendable (_ field: String) async -> [GenericFact],
        documentOfBlock: @escaping @Sendable (_ blockID: UUID) async -> UUID?
    ) {
        self.factsForField = factsForField
        self.documentOfBlock = documentOfBlock
    }

    /// Recognized evidence-of-absence tokens. Conservative on purpose: only a
    /// source that literally records one of these counts as `.explicitlyNone`.
    static let noneTokens: Set<String> = [
        "none", "n/a", "na", "nil", "not applicable", "not stated",
        "no", "not available", "not found", "absent"
    ]

    /// What `sourceID` (a document id's uuidString) says about `field`.
    public func presence(field: String, sourceID: String) async -> SourceValue.Presence {
        let canon = FactSchemaRegistry.normalizeField(field)
        guard FieldRegistry.isKnown(canon) else { return .silent }
        let rows = await factsForField(canon)

        // Keep only facts whose evidence blocks belong to this source document.
        var mine: [GenericFact] = []
        for f in rows {
            var belongs = false
            for b in f.sourceBlockIDs {
                if let doc = await documentOfBlock(b), doc.uuidString == sourceID {
                    belongs = true
                    break
                }
            }
            if belongs { mine.append(f) }
        }
        guard !mine.isEmpty else { return .silent }

        // Prefer a real stated value; fall back to explicit-none only when
        // every fact this source recorded is a none-token.
        let stated = mine.filter { !Self.isNoneToken($0.value) }
        if let best = pickStated(stated) {
            return .stated(foldUnit(best))
        }
        return .explicitlyNone
    }

    /// Bind this resolver to the ComparisonService's per-cell reader.
    public func fieldValue() -> @Sendable (_ field: String, _ sourceID: String) async -> SourceValue.Presence {
        { field, sourceID in await self.presence(field: field, sourceID: sourceID) }
    }

    // MARK: - Deterministic selection

    /// Highest-confidence stated fact; ties broken by value string so the
    /// result is stable across runs.
    private func pickStated(_ facts: [GenericFact]) -> GenericFact? {
        facts.max { a, b in
            a.confidence != b.confidence ? a.confidence < b.confidence : a.value > b.value
        }
    }

    /// Fold a unit/currency qualifier into the value so the matrix's
    /// unit-vs-conflict detection sees it (e.g. value "500000" + unit "INR" →
    /// "500000 INR"). Skip when the value already carries the unit.
    private func foldUnit(_ f: GenericFact) -> String {
        guard let unit = f.unit?.trimmingCharacters(in: .whitespaces), !unit.isEmpty else { return f.value }
        if f.value.range(of: unit, options: .caseInsensitive) != nil { return f.value }
        return "\(f.value) \(unit)"
    }

    static func isNoneToken(_ value: String) -> Bool {
        noneTokens.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

public extension ComparisonService {
    /// Build a ComparisonService that reads live ledger facts through a resolver.
    init(resolver: ComparisonLedgerResolver) {
        self.init(fieldValue: resolver.fieldValue())
    }
}
