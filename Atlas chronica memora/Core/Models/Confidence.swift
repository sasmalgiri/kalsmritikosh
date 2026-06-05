//
//  Confidence.swift
//  Atlas chronica memora
//
//  Confidence carries through every extraction, link, summary, and
//  retrieval result. The Verifier uses it to refuse low-quality answers.
//

import Foundation

public struct Confidence: Codable, Hashable, Sendable, Comparable {
    public let value: Double  // 0.0 ... 1.0

    public init(_ value: Double) {
        self.value = max(0.0, min(1.0, value))
    }

    public static let zero = Confidence(0.0)
    public static let low = Confidence(0.33)
    public static let medium = Confidence(0.66)
    public static let high = Confidence(0.9)
    public static let certain = Confidence(1.0)

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.value < rhs.value
    }

    /// Combine independent evidence via probabilistic OR
    /// (1 - product of complements). Used when multiple sources
    /// reinforce the same fact.
    public func combined(with other: Confidence) -> Confidence {
        Confidence(1.0 - (1.0 - value) * (1.0 - other.value))
    }
}
