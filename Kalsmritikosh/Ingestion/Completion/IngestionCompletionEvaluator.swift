//
//  IngestionCompletionEvaluator.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-008) — PURE derivation of an IngestionCompletionSnapshot. The completion state + the
//  three readiness booleans come ONLY from the durable SourceReadinessSnapshot; the upgrade-kind sets +
//  container status are informational overlays that never alter the state. No percentage, no new
//  vocabulary.
//

import Foundation

public enum IngestionCompletionEvaluator {

    public nonisolated static func evaluate(
        readiness: SourceReadinessSnapshot,
        logicalSourceID: UUID,
        pendingUpgradeKinds: Set<SourceUpgradeKind> = [],
        runningUpgradeKinds: Set<SourceUpgradeKind> = [],
        failedUpgradeKinds: Set<SourceUpgradeKind> = [],
        containerInspectionStatus: ContainerManifestStatus? = nil,
        at evaluatedAt: Date
    ) -> IngestionCompletionSnapshot {
        IngestionCompletionSnapshot(
            logicalSourceID: logicalSourceID,
            sourceVersionID: readiness.sourceVersionID,
            readinessRevision: readiness.aggregateRevision,
            completionState: readiness.completionState,
            isSearchReady: readiness.isSearchReady,
            isEvidenceReady: readiness.isEvidenceReady,
            isAnalyticallyReady: readiness.isAnalyticallyReady,
            limitations: readiness.limitations
                .map { "\(String(describing: $0.dimension)): \(String(describing: $0.state))" }.sorted(),
            blockers: readiness.blockers
                .map { "\(String(describing: $0.dimension)): \(String(describing: $0.condition))" }.sorted(),
            pendingUpgradeKinds: pendingUpgradeKinds,
            runningUpgradeKinds: runningUpgradeKinds,
            failedUpgradeKinds: failedUpgradeKinds,
            containerInspectionStatus: containerInspectionStatus,
            evaluatedAt: evaluatedAt)
    }
}
