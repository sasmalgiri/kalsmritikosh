//
//  ComplexityAnalyzer.swift
//  Kalsmritikosh
//
//  Scores a UserIntent on a 1-5 complexity scale. The DeterministicRouter
//  uses the score to widen / narrow the CapabilitySpec it builds —
//  trivial lookups ask for `.classification + .routerSmall`, multi-source
//  reconstructions ask for `.reasoning + .longContext + .expertLarge`.
//
//  Heuristic for v1 (per locked decision). A model-based analyzer can
//  swap in later once the .complexityAnalysis capability resolves; this
//  protocol leaves room for that.
//

import Foundation

public struct ComplexityScore: Codable, Sendable, Hashable {
    public let value: Int     // 1...5
    public let contributors: [String]

    public init(value: Int, contributors: [String]) {
        self.value = max(1, min(5, value))
        self.contributors = contributors
    }
}

public protocol ComplexityAnalyzer: Sendable {
    func score(_ intent: UserIntent) async -> ComplexityScore
}

public struct HeuristicComplexityAnalyzer: ComplexityAnalyzer {
    public nonisolated init() {}

    public func score(_ intent: UserIntent) async -> ComplexityScore {
        var score = 1
        var contributors: [String] = []

        switch intent.kind {
        case .factualLookup, .semanticSearch:
            score += 0
            contributors.append("kind=lookup")
        case .reconstructRelationship:
            score += 2
            contributors.append("kind=reconstructRelationship")
        case .reconstructProject, .reconstructTimeline:
            score += 3
            contributors.append("kind=reconstruct")
        case .executiveBriefing, .riskDetection, .missingInformation:
            score += 3
            contributors.append("kind=executive/risk/missing")
        case .unknown:
            score += 1
            contributors.append("kind=unknown")
        }

        let hints = intent.entityHints.count
        switch hints {
        case 0...1: break
        case 2...4: score += 1; contributors.append("entityHints=\(hints)")
        default: score += 2; contributors.append("entityHints=\(hints)")
        }

        if let timeframe = intent.timeframe {
            let start = timeframe.start ?? .distantPast
            let end = timeframe.end ?? .distantFuture
            let days = end.timeIntervalSince(start) / 86_400
            if days > 365 {
                score += 1
                contributors.append("timeframe>1y")
            }
        }

        return ComplexityScore(value: score, contributors: contributors)
    }
}
