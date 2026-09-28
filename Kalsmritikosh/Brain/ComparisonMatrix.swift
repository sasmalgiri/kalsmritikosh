//
//  ComparisonMatrix.swift
//  Kalsmritikosh
//
//  G3 Workflow C — the deterministic core of the comparison brief: a matrix
//  of PROPOSITIONS (fields) × SOURCES, each cell classified honestly. It
//  makes the distinctions the directive requires:
//   · a real DISAGREEMENT vs merely DIFFERENT UNITS/CURRENCY (same magnitude,
//     different unit → not a contradiction);
//   · ABSENT EVIDENCE (a source is silent) vs EVIDENCE OF ABSENCE (a source
//     explicitly states there is none).
//  Pure and deterministic; the free-form brief prose is composed on top of
//  this, never instead of it.
//

import Foundation

/// One source's account of a field.
public struct SourceValue: Sendable, Equatable {
    public enum Presence: Sendable, Equatable {
        case stated(String)      // the source asserts this value
        case explicitlyNone      // the source states there is none (evidence of absence)
        case silent              // the source does not mention it (absent evidence)
    }
    public let sourceID: String
    public let presence: Presence
    public init(sourceID: String, presence: Presence) {
        self.sourceID = sourceID
        self.presence = presence
    }
}

public struct ComparisonCell: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        case agree               // all stated values agree
        case disagree            // stated values genuinely differ
        case differentUnit       // same magnitude, different currency/unit — not a conflict
        case singleSource        // only one source states it
        case unattested          // no source states it (all silent / explicitly none)
    }
    public let field: String
    public let verdict: Verdict
    public let values: [SourceValue]
    /// Sources that are silent (absent evidence) — distinct from those that
    /// explicitly state there is none.
    public let silentSourceIDs: [String]
    public let explicitNoneSourceIDs: [String]

    public var stated: [(sourceID: String, value: String)] {
        values.compactMap { v in
            if case let .stated(s) = v.presence { return (v.sourceID, s) } else { return nil }
        }
    }
}

public enum ComparisonMatrix {

    /// Build the cells for a set of fields over a set of sources. `values`
    /// maps field → the per-source accounts (missing entries default to
    /// silent). Deterministic in source order.
    public nonisolated static func build(
        fields: [String],
        sourceIDs: [String],
        values: [String: [SourceValue]]
    ) -> [ComparisonCell] {
        fields.map { field in
            // Fill in silent for any source with no explicit account.
            let given = values[field] ?? []
            let bySource = Dictionary(given.map { ($0.sourceID, $0) }, uniquingKeysWith: { a, _ in a })
            let full: [SourceValue] = sourceIDs.map { sid in
                bySource[sid] ?? SourceValue(sourceID: sid, presence: .silent)
            }
            let stated = full.compactMap { v -> (String, String)? in
                if case let .stated(s) = v.presence { return (v.sourceID, s) } else { return nil }
            }
            let silent = full.filter { $0.presence == .silent }.map(\.sourceID)
            let none = full.filter { $0.presence == .explicitlyNone }.map(\.sourceID)

            let verdict: ComparisonCell.Verdict
            switch stated.count {
            case 0:  verdict = .unattested
            case 1:  verdict = .singleSource
            default:
                let vals = stated.map(\.1)
                // Different-units FIRST: identical numeric magnitude but the
                // currency/unit framing differs — not a contradiction. (Checked
                // before agreement because the canonical compare strips currency
                // symbols and would otherwise read "₹500" == "$500".)
                if onlyUnitDiffers(vals) {
                    verdict = .differentUnit
                } else if allCanonicallyEqual(vals) {
                    verdict = .agree
                } else {
                    verdict = .disagree
                }
            }
            return ComparisonCell(field: field, verdict: verdict, values: full,
                                  silentSourceIDs: silent, explicitNoneSourceIDs: none)
        }
    }

    // MARK: - Value comparison

    nonisolated static func canon(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated static func allCanonicallyEqual(_ vals: [String]) -> Bool {
        guard let first = vals.first.map(canon) else { return true }
        return vals.allSatisfy { canon($0) == first }
    }

    /// True when the values share the same numeric magnitude but their
    /// currency/unit framing differs — a different-units cell, not a
    /// disagreement. Requires: identical non-empty digit tokens across all
    /// values AND more than one distinct currency marker set.
    nonisolated static func onlyUnitDiffers(_ vals: [String]) -> Bool {
        let digitSets = vals.map { StoryProseRephraser.digitTokens($0) }
        guard let firstDigits = digitSets.first, !firstDigits.isEmpty,
              digitSets.allSatisfy({ $0 == firstDigits }) else { return false }
        let currencies = Set(vals.map { ToolGroundedComposer.currencyMarkers(in: $0) })
        return currencies.count > 1
    }
}
