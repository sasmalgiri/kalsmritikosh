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
    /// LLM claims dropped at parse time because their cited evidence
    /// failed to resolve against the retrieval set. Surfaced for the UI.
    public let droppedUnverifiable: Int
    /// T10 — Newest event date among supporting evidence (nil when no
    /// events flowed through).
    public let newestEvidenceDate: Date?
    /// T10 — Freshness factor in [0,1]: exp(-ageDays/tau). nil for
    /// historical / reconstruction intents where staleness is the point.
    public let freshness: Double?
    /// T10 — Fraction of intent-window buckets covered by ≥1 event.
    /// `nil` when no meaningful window exists (e.g. the question carried
    /// no `intent.timeframe`) so the UI doesn't surface "covers 100%" as
    /// a misleading default — UPDATE_06 Item 1.
    public let coverage: Double?
    /// T10 — Contiguous empty windows reported as ranges.
    public let coverageGaps: [DateInterval]
    /// T10 — Fraction of files past Tier 1 ingest, in [0,1].
    public let ingestCoverage: Double

    public init(
        combined: Confidence,
        sourceCount: Int,
        distinctSourceObjectIDs: Int,
        agreementScore: Double,
        contradictions: [VerifiedAnswer.Contradiction],
        droppedUnverifiable: Int = 0,
        newestEvidenceDate: Date? = nil,
        freshness: Double? = nil,
        coverage: Double? = nil,
        coverageGaps: [DateInterval] = [],
        ingestCoverage: Double = 1.0
    ) {
        self.combined = combined
        self.sourceCount = sourceCount
        self.distinctSourceObjectIDs = distinctSourceObjectIDs
        self.agreementScore = agreementScore
        self.contradictions = contradictions
        self.droppedUnverifiable = droppedUnverifiable
        self.newestEvidenceDate = newestEvidenceDate
        self.freshness = freshness
        self.coverage = coverage
        self.coverageGaps = coverageGaps
        self.ingestCoverage = ingestCoverage
    }

    private enum CodingKeys: String, CodingKey {
        case combined, sourceCount, distinctSourceObjectIDs,
             agreementScore, contradictions, droppedUnverifiable,
             newestEvidenceDate, freshness, coverage, coverageGaps,
             ingestCoverage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.combined = try c.decode(Confidence.self, forKey: .combined)
        self.sourceCount = try c.decode(Int.self, forKey: .sourceCount)
        self.distinctSourceObjectIDs = try c.decode(Int.self, forKey: .distinctSourceObjectIDs)
        self.agreementScore = try c.decode(Double.self, forKey: .agreementScore)
        self.contradictions = try c.decode([VerifiedAnswer.Contradiction].self, forKey: .contradictions)
        self.droppedUnverifiable = try c.decodeIfPresent(Int.self, forKey: .droppedUnverifiable) ?? 0
        self.newestEvidenceDate = try c.decodeIfPresent(Date.self, forKey: .newestEvidenceDate)
        self.freshness = try c.decodeIfPresent(Double.self, forKey: .freshness)
        self.coverage = try c.decodeIfPresent(Double.self, forKey: .coverage)
        self.coverageGaps = try c.decodeIfPresent([DateInterval].self, forKey: .coverageGaps) ?? []
        self.ingestCoverage = try c.decodeIfPresent(Double.self, forKey: .ingestCoverage) ?? 1.0
    }
}

public protocol ConfidenceEngine: Sendable {
    func evaluate(
        claims: [ExpertFindings.Claim],
        droppedUnverifiable: Int,
        events: [Event],
        intentKind: UserIntent.Kind?,
        intentWindow: DateInterval?,
        ingestCoverage: Double,
        now: Date
    ) async -> ConfidenceReport
}

extension ConfidenceEngine {
    /// Convenience for callers that don't yet compute T10 inputs.
    public func evaluate(
        claims: [ExpertFindings.Claim],
        droppedUnverifiable: Int
    ) async -> ConfidenceReport {
        await evaluate(
            claims: claims,
            droppedUnverifiable: droppedUnverifiable,
            events: [],
            intentKind: nil,
            intentWindow: nil,
            ingestCoverage: 1.0,
            now: .init()
        )
    }
}

public struct DefaultConfidenceEngine: ConfidenceEngine {
    /// Freshness time-constant in days for status/current intents.
    public static let statusFreshnessTau: Double = 90

    /// D-14 — the slot-question confidence profile. A uniquely-attested
    /// identifier from a structured source with no conflict on the REQUESTED
    /// field is not a 37% answer: floor it at 0.8 BEFORE the ingest-coverage
    /// multiplier (T11 behavior untouched — the same max(coverage, 0.5)
    /// factor applies to the floor). Returns `base` unchanged when any
    /// profile condition fails.
    public nonisolated static func slotProfileFloor(
        base: Confidence,
        singleCanonicalValue: Bool,
        structuredSource: Bool,
        conflictOnRequestedField: Bool,
        ingestCoverage: Double
    ) -> Confidence {
        guard singleCanonicalValue, structuredSource, !conflictOnRequestedField else { return base }
        let ingestFactor = ingestCoverage < 1.0 ? max(ingestCoverage, 0.5) : 1.0
        return Confidence(max(base.value, 0.8 * ingestFactor))
    }

    public init() {}

    public func evaluate(
        claims: [ExpertFindings.Claim],
        droppedUnverifiable: Int,
        events: [Event],
        intentKind: UserIntent.Kind?,
        intentWindow: DateInterval?,
        ingestCoverage: Double,
        now: Date
    ) async -> ConfidenceReport {
        let timeliness = Self.timeliness(
            events: events,
            intentKind: intentKind,
            intentWindow: intentWindow,
            now: now
        )
        let ingestFactor = ingestCoverage < 1.0 ? max(ingestCoverage, 0.5) : 1.0

        guard !claims.isEmpty else {
            return ConfidenceReport(
                combined: .zero,
                sourceCount: 0,
                distinctSourceObjectIDs: 0,
                agreementScore: 0,
                contradictions: [],
                droppedUnverifiable: droppedUnverifiable,
                newestEvidenceDate: timeliness.newest,
                freshness: timeliness.freshness,
                coverage: timeliness.coverage,
                coverageGaps: timeliness.gaps,
                ingestCoverage: ingestCoverage
            )
        }

        let sourceCount = claims.reduce(0) { $0 + $1.supportingObjectIDs.count }
        let distinctSourceSet = Set(claims.flatMap(\.supportingObjectIDs))
        let distinctSources = distinctSourceSet.count
        // Adjudication instrument (seal-#3 residual): when enabled, dump the
        // full sorted distinct-source set so a ±1 count across runs resolves
        // to the differing object's IDENTITY (exhaust-class → C-i coverage
        // gap; legitimate → between-ask sequence race). Env-gated, inert in
        // production.
        if ProcessInfo.processInfo.environment["KALSMRITIKOSH_DUMP_SOURCES"] == "1" {
            let ids = distinctSourceSet.map(\.uuidString).sorted().joined(separator: ",")
            print("SOURCESET n=\(distinctSources) ids=\(ids)")
        }
        // ORDERED-EVIDENCE PROBE (owner 2026-09-02, Q2 tripwire): measurement
        // only — the FULL ORDERED input as it reaches the distinctSources Set,
        // so a per-ask ±1–2 count resolves to WHICH object enters/leaves, at
        // WHICH index (the upstream assembly's fingerprint), and whether the
        // list carries duplicates (order-sensitive dedupe) vs different
        // membership (assembly wobble). Env-gated, inert in production.
        if ProcessInfo.processInfo.environment["KALSMRITIKOSH_DUMP_EVIDENCE_ORDER"] == "1" {
            func clean(_ s: String) -> String {
                String(s.prefix(28)).replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\n", with: "/")
            }
            for (ci, claim) in claims.enumerated() {
                print("EVORDER CLAIM[\(ci)] conf=\(claim.confidence.value) nobj=\(claim.supportingObjectIDs.count) stmt=\(clean(claim.statement))")
            }
            let seq = claims.flatMap(\.supportingObjectIDs).map(\.uuidString)
            let dupes = seq.count - Set(seq).count
            print("EVORDER SEQ n=\(seq.count) distinct=\(distinctSources) dupes=\(dupes): \(seq.joined(separator: ","))")
        }

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

        // Apply ingest-coverage multiplier per T10: while ingest is
        // incomplete, final confidence is multiplied by max(coverage, 0.5).
        // CANONICAL ROUNDING AT SOURCE (nondeterminism class 5, owner
        // pre-ruling): floating-point accumulation ORDER can shift the
        // scalar by ~1 ULP (~1e-16) run-to-run at identical evidence — the
        // graded probe's last residual. Round to a stated precision, 1e-12:
        // nine orders below any semantic step (slot floors move in 1e-3),
        // four above ULP noise. Representation, not tolerance — comparisons
        // stay exact equality.
        let combinedAdjusted = Confidence(((combined.value * ingestFactor) * 1e12).rounded() / 1e12)

        return ConfidenceReport(
            combined: combinedAdjusted,
            sourceCount: sourceCount,
            distinctSourceObjectIDs: distinctSources,
            agreementScore: agreement,
            contradictions: contradictions,
            droppedUnverifiable: droppedUnverifiable,
            newestEvidenceDate: timeliness.newest,
            freshness: timeliness.freshness,
            coverage: timeliness.coverage,
            coverageGaps: timeliness.gaps,
            ingestCoverage: ingestCoverage
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

    // MARK: - T10 — Timeliness signals

    /// Aggregates the freshness + coverage analysis. Pure function so
    /// the engine method stays linear.
    public struct TimelinessSummary: Sendable {
        public let newest: Date?
        public let freshness: Double?
        /// `nil` when no meaningful intent window was provided — see
        /// `ConfidenceReport.coverage`.
        public let coverage: Double?
        public let gaps: [DateInterval]
    }

    public static func timeliness(
        events: [Event],
        intentKind: UserIntent.Kind?,
        intentWindow: DateInterval?,
        now: Date
    ) -> TimelinessSummary {
        let dates = events.map(\.date).sorted()
        let newest = dates.last

        // Freshness — only meaningful for status/current intents.
        let freshness: Double? = {
            guard let newest else { return nil }
            switch intentKind {
            case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
                return nil  // historical / reconstruction — staleness is the point
            default:
                let ageDays = now.timeIntervalSince(newest) / 86_400
                return Swift.max(0, exp(-Swift.max(0, ageDays) / statusFreshnessTau))
            }
        }()

        // Coverage — bucket events into the intent window's quarters.
        // When the question carries no `intent.timeframe` there's no window
        // to bucket against and we surface `nil` rather than a misleading
        // "covers 100%". UPDATE_06 Item 1.
        guard let window = intentWindow, window.duration > 0 else {
            return TimelinessSummary(
                newest: newest,
                freshness: freshness,
                coverage: nil,
                gaps: []
            )
        }
        let bucketCount = 4
        let bucketWidth = window.duration / Double(bucketCount)
        var bucketHits = Array(repeating: false, count: bucketCount)
        for date in dates {
            guard window.contains(date) else { continue }
            let offset = date.timeIntervalSince(window.start)
            var idx = Int(offset / bucketWidth)
            if idx >= bucketCount { idx = bucketCount - 1 }
            if idx >= 0 { bucketHits[idx] = true }
        }
        let coverage = Double(bucketHits.filter { $0 }.count) / Double(bucketCount)

        var gaps: [DateInterval] = []
        var i = 0
        while i < bucketCount {
            if !bucketHits[i] {
                var j = i
                while j < bucketCount && !bucketHits[j] { j += 1 }
                let gapStart = window.start.addingTimeInterval(Double(i) * bucketWidth)
                let gapEnd = window.start.addingTimeInterval(Double(j) * bucketWidth)
                gaps.append(DateInterval(start: gapStart, end: gapEnd))
                i = j
            } else {
                i += 1
            }
        }
        return TimelinessSummary(
            newest: newest,
            freshness: freshness,
            coverage: coverage,
            gaps: gaps
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
