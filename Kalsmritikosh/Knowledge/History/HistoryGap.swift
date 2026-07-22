//
//  HistoryGap.swift
//  Kalsmritikosh
//
//  HIST-044 (Universal History program, Phase 6). A gap is not merely "no event for
//  90 days" — it is a TYPED, actionable statement of what is missing and what
//  evidence would fill it. Deterministic inference over the outline. Never
//  accusatory; a gap is a request for evidence, not a claim of wrongdoing.
//

import Foundation

public enum HistoryGapKind: String, Codable, Sendable, CaseIterable {
    case missingStartDate
    case missingEndDate
    case missingIntermediary
    case missingSupportingSource
    case missingCorroboration
    case missingReason
    case missingActor
    case missingResult
    case unexplainedStatusChange
    case silentPeriod
    case coverageGapUnsupportedFormat
    case possibleMissingAttachment
    case possibleMissingEmailInThread
}

public struct HistoryGap: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: HistoryGapKind
    public let subject: HistorySubject
    public let description: String
    public let affectedPeriod: TemporalValue?
    public let expectedEvidenceTypes: [String]
    public let inferenceBasis: [EvidenceReference]
    public let confidence: Double
    public let status: HistoryReviewStatus

    public nonisolated init(
        id: UUID = UUID(), kind: HistoryGapKind, subject: HistorySubject, description: String,
        affectedPeriod: TemporalValue? = nil, expectedEvidenceTypes: [String] = [],
        inferenceBasis: [EvidenceReference] = [], confidence: Double, status: HistoryReviewStatus = .unreviewed
    ) {
        self.id = id; self.kind = kind; self.subject = subject; self.description = description
        self.affectedPeriod = affectedPeriod; self.expectedEvidenceTypes = expectedEvidenceTypes
        self.inferenceBasis = inferenceBasis; self.confidence = confidence; self.status = status
    }
}

/// Deterministic gap inference over a HistoryOutline. Conservative: only gaps that
/// follow directly from the item shape (no speculation). Suggested evidence types
/// help the Missing-Chapter action turn a gap into a focused search.
public struct HistoryGapEngine: Sendable {
    /// A silent period longer than this (seconds) between consecutive dated items
    /// is flagged. Default 2 years.
    public let silentPeriodThreshold: TimeInterval
    public init(silentPeriodThreshold: TimeInterval = 2 * 365 * 24 * 3600) {
        self.silentPeriodThreshold = silentPeriodThreshold
    }

    public func infer(outline: HistoryOutline) -> [HistoryGap] {
        let subject = outline.subject.subject
        var gaps: [HistoryGap] = []

        // Per-item date gaps.
        for item in outline.items {
            let periodKinds: Set<HistoryItemKind> = [.period, .stateStart, .relationshipStart]
            if periodKinds.contains(item.kind), item.start?.start != nil, item.end?.end == nil {
                gaps.append(HistoryGap(
                    kind: .missingEndDate, subject: subject,
                    description: "No end date established for “\(item.title)”.",
                    affectedPeriod: item.start,
                    expectedEvidenceTypes: ["relieving letter", "final statement", "closing record", "termination notice"],
                    inferenceBasis: item.evidence, confidence: 0.7))
            }
            if item.start?.start == nil, item.end?.end != nil {
                gaps.append(HistoryGap(
                    kind: .missingStartDate, subject: subject,
                    description: "No start date established for “\(item.title)”.",
                    affectedPeriod: item.end,
                    expectedEvidenceTypes: ["joining record", "opening document", "commencement notice"],
                    inferenceBasis: item.evidence, confidence: 0.7))
            }
        }

        // Silent periods between consecutive dated items.
        let dated = outline.items.compactMap { item -> (Date, HistoryItem)? in
            item.start?.start.map { ($0, item) }
        }.sorted { $0.0 < $1.0 }
        for i in 1..<max(dated.count, 1) where dated.count > 1 {
            let prev = dated[i - 1], cur = dated[i]
            let gap = cur.0.timeIntervalSince(prev.0)
            if gap > silentPeriodThreshold {
                let period = TemporalValue(start: prev.0, end: cur.0, precision: .day,
                                           originalText: nil, confidence: 0.6)
                gaps.append(HistoryGap(
                    kind: .silentPeriod, subject: subject,
                    description: "A silent period with no recorded activity between “\(prev.1.title)” and “\(cur.1.title)”.",
                    affectedPeriod: period,
                    expectedEvidenceTypes: ["correspondence", "records", "statements from this period"],
                    inferenceBasis: prev.1.evidence + cur.1.evidence, confidence: 0.6))
            }
        }
        // Deterministic order.
        return gaps.sorted { ($0.kind.rawValue, $0.description) < ($1.kind.rawValue, $1.description) }
    }
}
