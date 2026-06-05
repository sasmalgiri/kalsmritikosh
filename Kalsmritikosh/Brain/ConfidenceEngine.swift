//
//  ConfidenceEngine.swift
//  Kalsmritikosh
//
//  Dedicated subsystem that scores a set of expert claims and produces a
//  ConfidenceReport. EvidenceVerifier consults this engine before it
//  decides whether to ship an answer, refuse, or downgrade.
//
//  Inputs are pure data — no IO — so the engine is deterministic, fast,
//  and trivially testable.
//

import Foundation

public struct ConfidenceReport: Codable, Sendable, Hashable {
    public let combined: Confidence
    public let sourceCount: Int
    public let distinctSourceObjectIDs: Int
    public let agreementScore: Double         // 0...1, fraction of claims that agree
    public let contradictions: [VerifiedAnswer.Contradiction]

    public init(
        combined: Confidence,
        sourceCount: Int,
        distinctSourceObjectIDs: Int,
        agreementScore: Double,
        contradictions: [VerifiedAnswer.Contradiction]
    ) {
        self.combined = combined
        self.sourceCount = sourceCount
        self.distinctSourceObjectIDs = distinctSourceObjectIDs
        self.agreementScore = agreementScore
        self.contradictions = contradictions
    }
}

public protocol ConfidenceEngine: Sendable {
    func evaluate(claims: [ExpertFindings.Claim]) async -> ConfidenceReport
}

public struct DefaultConfidenceEngine: ConfidenceEngine {
    public init() {}

    public func evaluate(claims: [ExpertFindings.Claim]) async -> ConfidenceReport {
        guard !claims.isEmpty else {
            return ConfidenceReport(
                combined: .zero,
                sourceCount: 0,
                distinctSourceObjectIDs: 0,
                agreementScore: 0,
                contradictions: []
            )
        }

        let sourceCount = claims.reduce(0) { $0 + $1.supportingObjectIDs.count }
        let distinctSources = Set(claims.flatMap(\.supportingObjectIDs)).count

        let agreement = computeAgreement(claims)
        let contradictions = detectContradictions(claims)
        let diversity = sourceCount > 0
            ? Double(distinctSources) / Double(sourceCount)
            : 0.0
        let contradictionPenalty = min(
            1.0,
            Double(contradictions.count) / Double(claims.count)
        )

        let combined = Confidence.aggregate(
            claims.map(\.confidence),
            agreement: agreement,
            diversity: diversity,
            contradictionPenalty: contradictionPenalty
        )

        return ConfidenceReport(
            combined: combined,
            sourceCount: sourceCount,
            distinctSourceObjectIDs: distinctSources,
            agreementScore: agreement,
            contradictions: contradictions
        )
    }

    // Cheap n-gram overlap as an agreement proxy. Pairs of claims that
    // share at least one significant token count as agreeing. Good enough
    // for v1 — model-based agreement scoring lands once the .reasoning
    // capability is fully wired.
    private func computeAgreement(_ claims: [ExpertFindings.Claim]) -> Double {
        guard claims.count >= 2 else { return 1.0 }
        let tokenized = claims.map { tokens($0.statement) }
        var agreeing = 0
        var pairs = 0
        for i in 0..<tokenized.count {
            for j in (i + 1)..<tokenized.count {
                pairs += 1
                let overlap = tokenized[i].intersection(tokenized[j]).count
                if overlap >= 2 { agreeing += 1 }
            }
        }
        return pairs > 0 ? Double(agreeing) / Double(pairs) : 0
    }

    private func tokens(_ s: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the","a","an","and","or","of","to","in","on","for","with","by",
            "is","are","was","were","be","been","at","this","that"
        ]
        return Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stopwords.contains($0) }
        )
    }

    /// Detects claims that share evidence but use opposite-polarity
    /// vocabulary. Cheap; can be extended later.
    private func detectContradictions(
        _ claims: [ExpertFindings.Claim]
    ) -> [VerifiedAnswer.Contradiction] {
        var out: [VerifiedAnswer.Contradiction] = []
        let oppositePairs: [(String, String)] = [
            ("completed", "delayed"),
            ("paid", "unpaid"),
            ("signed", "unsigned"),
            ("delivered", "missing"),
            ("approved", "rejected")
        ]

        for (i, a) in claims.enumerated() {
            for b in claims.dropFirst(i + 1) {
                let sharesEvidence = !Set(a.supportingObjectIDs).isDisjoint(with: b.supportingObjectIDs)
                guard sharesEvidence else { continue }
                for (left, right) in oppositePairs {
                    let aHasLeft = a.statement.localizedCaseInsensitiveContains(left)
                    let aHasRight = a.statement.localizedCaseInsensitiveContains(right)
                    let bHasLeft = b.statement.localizedCaseInsensitiveContains(left)
                    let bHasRight = b.statement.localizedCaseInsensitiveContains(right)
                    if (aHasLeft && bHasRight) || (aHasRight && bHasLeft) {
                        out.append(.init(
                            description: "Same source reports both '\(left)' and '\(right)'.",
                            claimA: a.statement,
                            claimB: b.statement
                        ))
                        break
                    }
                }
            }
        }
        return out
    }
}
