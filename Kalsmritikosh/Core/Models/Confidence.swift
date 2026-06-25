//
//  Confidence.swift
//  Kalsmritikosh
//
//  Confidence carries through every extraction, link, summary, and
//  retrieval result. The Verifier uses it to refuse low-quality answers.
//

import Foundation

public nonisolated struct Confidence: Codable, Hashable, Sendable, Comparable {
    public let value: Double  // 0.0 ... 1.0

    // G2-SWIFT6 — nonisolated so any actor / nonisolated repository can
    // construct Confidence in synchronous context. Value type.
    public nonisolated init(_ value: Double) {
        self.value = max(0.0, min(1.0, value))
    }

    // G2-SWIFT6 — nonisolated so any actor context can reference these.
    public nonisolated static let zero = Confidence(0.0)
    public nonisolated static let low = Confidence(0.33)
    public nonisolated static let medium = Confidence(0.66)
    public nonisolated static let high = Confidence(0.9)
    public nonisolated static let certain = Confidence(1.0)

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.value < rhs.value
    }

    /// Combine independent evidence via probabilistic OR
    /// (1 - product of complements). Used when multiple sources
    /// reinforce the same fact.
    // noisy-OR: P(at least one). Never use across claims.
    // G2-SWIFT6 — nonisolated so callers in actor / nonisolated contexts
    // can combine confidences directly.
    public nonisolated func combined(with other: Confidence) -> Confidence {
        Confidence(1.0 - (1.0 - value) * (1.0 - other.value))
    }

    // MARK: - Calibrated aggregation across claims

    public static let agreementFloor: Double = 0.6
    public static let agreementGain: Double = 0.4
    public static let diversityFloor: Double = 0.7
    public static let diversityGain: Double = 0.3
    public static let contradictionWeight: Double = 0.15
    public static let clampLo: Double = 0.05
    public static let clampHi: Double = 0.98

    /// Calibrated aggregation across many claim-level confidences.
    /// Use this — not `combined(with:)` — whenever collapsing a set of
    /// claims to a single confidence. The formula is:
    ///   mean × (agreementFloor + agreementGain·agreement)
    ///        × (diversityFloor + diversityGain·diversity)
    ///        − contradictionWeight·contradictionPenalty
    /// clamped to [clampLo, clampHi]. Agreement, diversity, and
    /// contradictionPenalty are expected in [0, 1].
    public static func aggregate(
        _ claims: [Confidence],
        agreement: Double,
        diversity: Double,
        contradictionPenalty: Double
    ) -> Confidence {
        guard !claims.isEmpty else { return .zero }
        let mean = claims.map(\.value).reduce(0.0, +) / Double(claims.count)
        let agreementFactor = agreementFloor + agreementGain * clamp01(agreement)
        let diversityFactor = diversityFloor + diversityGain * clamp01(diversity)
        let penalty = contradictionWeight * max(0.0, contradictionPenalty)
        let raw = mean * agreementFactor * diversityFactor - penalty
        return Confidence(max(clampLo, min(clampHi, raw)))
    }

    private static func clamp01(_ x: Double) -> Double {
        max(0.0, min(1.0, x))
    }
}
