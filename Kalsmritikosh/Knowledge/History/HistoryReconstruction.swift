//
//  HistoryReconstruction.swift
//  Kalsmritikosh
//
//  HIST-050 (Universal History program, Phase 7). The public contract for the
//  canonical reconstruction engine and its streamed updates. The deterministic
//  outline is always produced; prose (chapterReady) is an optional Phase-8 layer.
//  No generic RAG output is ever labelled Historical (release gate).
//

import Foundation

public struct HistoryRequest: Sendable {
    public let corpusSnapshotID: UUID?
    public let dateRange: ClosedRange<Date>?
    public let includeUndated: Bool
    /// object id → independence key (content hash / message id / lineage) for honest
    /// corroboration during reconciliation.
    public let independenceKeys: [KnowledgeObject.ID: String]
    /// Whether to attempt LLM prose (Phase 8). Deterministic outline is produced
    /// regardless; false keeps reconstruction fully deterministic.
    public let generateProse: Bool

    public nonisolated init(corpusSnapshotID: UUID? = nil, dateRange: ClosedRange<Date>? = nil,
                            includeUndated: Bool = true, independenceKeys: [KnowledgeObject.ID: String] = [:],
                            generateProse: Bool = false) {
        self.corpusSnapshotID = corpusSnapshotID; self.dateRange = dateRange
        self.includeUndated = includeUndated; self.independenceKeys = independenceKeys
        self.generateProse = generateProse
    }
}

/// The in-memory reconstruction result (Phase 9 persists it as a HistoryArtifact).
public struct HistoryReconstructionResult: Sendable {
    public let subject: ResolvedHistorySubject
    public let outline: HistoryOutline
    public let claims: [TemporalClaim]
    public let engineVersion: String
    public let generatedAt: Date
    public nonisolated init(subject: ResolvedHistorySubject, outline: HistoryOutline,
                            claims: [TemporalClaim], engineVersion: String, generatedAt: Date) {
        self.subject = subject; self.outline = outline; self.claims = claims
        self.engineVersion = engineVersion; self.generatedAt = generatedAt
    }
}

public enum HistoryUpdate: Sendable {
    case resolvingSubject
    case collecting(itemsSoFar: Int)
    case temporalising(claims: Int)
    case reconciling
    case outlineReady(HistoryOutline)
    case chapterReady(HistoryChapterPlan)
    case verified(HistoryReconstructionResult)
    case failed(reason: String)
}

public protocol HistoryReconstructing: Sendable {
    func reconstruct(subject: HistorySubject, request: HistoryRequest) -> AsyncStream<HistoryUpdate>
}
