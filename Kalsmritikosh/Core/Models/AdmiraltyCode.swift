//
//  AdmiraltyCode.swift
//  Kalsmritikosh
//
//  INV-08 gap fix — a PUBLISHED source-evaluation rubric (the Admiralty / NATO
//  System). A coarse high/medium/low rating is subjective; the Admiralty code
//  rates two independent axes on a recognized scale:
//    • reliability of the SOURCE   — A…F
//    • credibility of the INFORMATION — 1…6
//  so a rating like "B2" is auditable and means the same thing to any reader.
//
//  This is a pure value. The reliability service maps its letter grade down to
//  the canonical ReliabilityRating for the shared assessment, and stamps the
//  full code (e.g. "Admiralty rating: B2 — Usually reliable / Probably true.")
//  into the assessment rationale — so the exact grade is preserved and audited
//  without changing the shared schema.
//

import Foundation

/// Reliability of the source (Admiralty letter grade).
public nonisolated enum SourceReliabilityGrade: String, Codable, Sendable, CaseIterable, Equatable {
    case a, b, c, d, e, f

    public var letter: String { rawValue.uppercased() }
    public var label: String {
        switch self {
        case .a: return "Completely reliable"
        case .b: return "Usually reliable"
        case .c: return "Fairly reliable"
        case .d: return "Not usually reliable"
        case .e: return "Unreliable"
        case .f: return "Reliability cannot be judged"
        }
    }

    /// Down-map to the shared canonical rating actually stored (schema v74).
    public var coarseRating: ReliabilityRating {
        switch self {
        case .a, .b: return .high
        case .c, .d: return .medium
        case .e:     return .low
        case .f:     return .unknown
        }
    }
}

/// Credibility of the information (Admiralty numeric grade).
public nonisolated enum InformationCredibilityGrade: String, Codable, Sendable, CaseIterable, Equatable {
    case one, two, three, four, five, six

    public var number: Int {
        switch self {
        case .one: return 1; case .two: return 2; case .three: return 3
        case .four: return 4; case .five: return 5; case .six: return 6
        }
    }
    public var label: String {
        switch self {
        case .one:   return "Confirmed by other sources"
        case .two:   return "Probably true"
        case .three: return "Possibly true"
        case .four:  return "Doubtful"
        case .five:  return "Improbable"
        case .six:   return "Truth cannot be judged"
        }
    }
}

/// A full Admiralty rating: source reliability × information credibility.
public nonisolated struct AdmiraltyCode: Codable, Sendable, Equatable, Hashable {
    public let reliability: SourceReliabilityGrade
    public let credibility: InformationCredibilityGrade

    public init(reliability: SourceReliabilityGrade, credibility: InformationCredibilityGrade) {
        self.reliability = reliability; self.credibility = credibility
    }

    /// The compact code, e.g. "B2".
    public var code: String { "\(reliability.letter)\(credibility.number)" }

    /// The stored canonical rating this code maps to.
    public var coarseRating: ReliabilityRating { reliability.coarseRating }

    /// Stamped into the assessment rationale so the exact grade is preserved.
    public var rationaleLine: String { "Admiralty rating: \(code) — \(reliability.label) / \(credibility.label)." }
}
