//
//  ChangeDigest.swift
//  Kalsmritikosh
//
//  Proactive change-monitoring: "since you last checked, what's NEW or RESOLVED?"
//  Turns the tool into an agent — as documents arrive, the important shifts
//  (new contradictions, filled/created gaps) are surfaced instead of waiting to
//  be re-discovered. Deterministic: items are keyed by a CONTENT signature
//  (kind + normalized claims/description), stable across re-scans even though the
//  underlying rows get fresh UUIDs each scan. No model.
//

import Foundation

public enum ChangeDigest {

    /// Stable signature for a contradiction — independent of its per-scan UUID.
    /// Claims are sorted so A/B ordering can't change the key.
    public static func signature(_ c: Contradiction) -> String {
        let a = norm(c.claimA), b = norm(c.claimB)
        let pair = [a, b].sorted().joined(separator: "≠")
        return "contradiction|\(c.kind.rawValue)|\(pair)"
    }

    /// Stable signature for a gap.
    public static func signature(_ g: GapNode) -> String {
        "gap|\(g.kind.rawValue)|\(norm(g.description))"
    }

    /// Split current vs previous signature sets into added / removed.
    public static func diff(previous: Set<String>, current: Set<String>) -> (added: Set<String>, removed: Set<String>) {
        (current.subtracting(previous), previous.subtracting(current))
    }

    private static func norm(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// What changed since the last acknowledged snapshot.
public struct ChangeReport: Sendable {
    public let previousDate: Date?
    public let newContradictions: [Contradiction]
    public let resolvedContradictionCount: Int
    public let newGaps: [GapNode]
    public let resolvedGapCount: Int
    /// Current full signature set (for saving a fresh baseline on acknowledge).
    public let currentSignatures: [String]
    public let currentContradictionCount: Int
    public let currentGapCount: Int

    public var hasBaseline: Bool { previousDate != nil }
    public var hasChanges: Bool {
        !newContradictions.isEmpty || !newGaps.isEmpty
            || resolvedContradictionCount > 0 || resolvedGapCount > 0
    }

    public init(
        previousDate: Date?, newContradictions: [Contradiction], resolvedContradictionCount: Int,
        newGaps: [GapNode], resolvedGapCount: Int, currentSignatures: [String],
        currentContradictionCount: Int, currentGapCount: Int
    ) {
        self.previousDate = previousDate
        self.newContradictions = newContradictions
        self.resolvedContradictionCount = resolvedContradictionCount
        self.newGaps = newGaps
        self.resolvedGapCount = resolvedGapCount
        self.currentSignatures = currentSignatures
        self.currentContradictionCount = currentContradictionCount
        self.currentGapCount = currentGapCount
    }
}
