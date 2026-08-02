//
//  IngestionCompletionTypes.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-008) — the canonical ingestion completion contract. It does NOT introduce a new
//  completion-state vocabulary: the state IS `SourceCompletionState`, derived only by the readiness
//  authority. The snapshot is a PROJECTION reconstructed from durable state (source_versions +
//  source_readiness_* + container_manifests + the upgrade-job ledger) — never a stored column, never a
//  percentage. The upgrade ledger informs the snapshot ("evidence upgrade pending / OCR running /
//  analytical failed") but never changes the completion state.
//

import Foundation

public nonisolated struct IngestionCompletionSnapshot: Sendable, Hashable {
    public let logicalSourceID: UUID
    public let sourceVersionID: UUID
    public let readinessRevision: Int
    public let completionState: SourceCompletionState
    public let isSearchReady: Bool
    public let isEvidenceReady: Bool
    public let isAnalyticallyReady: Bool
    public let limitations: [String]
    public let blockers: [String]
    public let pendingUpgradeKinds: Set<SourceUpgradeKind>
    public let runningUpgradeKinds: Set<SourceUpgradeKind>
    public let failedUpgradeKinds: Set<SourceUpgradeKind>
    /// The container inspection status when this source version is a container; nil otherwise.
    public let containerInspectionStatus: ContainerManifestStatus?
    public let evaluatedAt: Date

    public nonisolated init(logicalSourceID: UUID, sourceVersionID: UUID, readinessRevision: Int,
                            completionState: SourceCompletionState, isSearchReady: Bool, isEvidenceReady: Bool,
                            isAnalyticallyReady: Bool, limitations: [String], blockers: [String],
                            pendingUpgradeKinds: Set<SourceUpgradeKind>, runningUpgradeKinds: Set<SourceUpgradeKind>,
                            failedUpgradeKinds: Set<SourceUpgradeKind>, containerInspectionStatus: ContainerManifestStatus?,
                            evaluatedAt: Date) {
        self.logicalSourceID = logicalSourceID
        self.sourceVersionID = sourceVersionID
        self.readinessRevision = readinessRevision
        self.completionState = completionState
        self.isSearchReady = isSearchReady
        self.isEvidenceReady = isEvidenceReady
        self.isAnalyticallyReady = isAnalyticallyReady
        self.limitations = limitations
        self.blockers = blockers
        self.pendingUpgradeKinds = pendingUpgradeKinds
        self.runningUpgradeKinds = runningUpgradeKinds
        self.failedUpgradeKinds = failedUpgradeKinds
        self.containerInspectionStatus = containerInspectionStatus
        self.evaluatedAt = evaluatedAt
    }

    /// The upgrade kinds pending or running (work still owed toward completeness).
    public var scheduledUpgradeKinds: Set<SourceUpgradeKind> { pendingUpgradeKinds.union(runningUpgradeKinds) }

    /// An honest one-line status — never a percentage.
    public var headline: String {
        var s = "\(completionState.rawValue)"
        if !scheduledUpgradeKinds.isEmpty { s += "; upgrade pending" }
        if !failedUpgradeKinds.isEmpty { s += "; upgrade failed" }
        return s
    }
}
