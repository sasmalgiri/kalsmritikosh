//
//  IngestionCompletionService.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-008 §5/§6) — reconstructs an IngestionCompletionSnapshot for an EXACT source version
//  from durable authorities. It stores nothing (no source_completion_state column, no completion table):
//  the completion state comes only from the readiness authority; the container status + upgrade-kind
//  overlays are read live. Every query is exact-version keyed; a superseded version keeps its own
//  historical completion.
//

import Foundation

public struct IngestionCompletionService: Sendable {

    public typealias UpgradeKindsProvider = @Sendable (UUID) async -> (pending: Set<SourceUpgradeKind>, running: Set<SourceUpgradeKind>, failed: Set<SourceUpgradeKind>)

    private let database: Database
    private let readiness: SourceReadinessRepository
    private let container: ContainerInspectionRepository?
    /// Live upgrade-kind overlay from the job ledger (wired once the repository exists). Nil → no overlay.
    private let upgradeKinds: UpgradeKindsProvider?

    public init(database: Database, readiness: SourceReadinessRepository,
                container: ContainerInspectionRepository? = nil, upgradeKinds: UpgradeKindsProvider? = nil) {
        self.database = database
        self.readiness = readiness
        self.container = container
        self.upgradeKinds = upgradeKinds
    }

    /// The canonical completion snapshot for an EXACT source version. Aliases must be resolved to their
    /// canonical exact version by the caller (completion is never URL / filename / occurrence keyed).
    public func snapshot(sourceVersionID: UUID, at now: Date) async throws -> IngestionCompletionSnapshot {
        guard let row = try await database.query(
            "SELECT logical_source_id, detected_type FROM source_versions WHERE id = ? LIMIT 1;", [.uuid(sourceVersionID)]).first,
            let logical = row.uuid(0) else {
            throw IngestionCompletionError.sourceVersionMissing(sourceVersionID)
        }
        let readinessSnap: SourceReadinessSnapshot
        do { readinessSnap = try await readiness.snapshot(sourceVersionID: sourceVersionID) }
        catch { throw IngestionCompletionError.readinessUnavailable(sourceVersionID) }

        var containerStatus: ContainerManifestStatus? = nil
        if let type = SourceType(rawValue: row.string(1) ?? ""), type.category == .archive, let container {
            containerStatus = try await container.manifest(sourceVersionID: sourceVersionID)?.status
        }
        let overlay = await upgradeKinds?(sourceVersionID) ?? (pending: [], running: [], failed: [])
        return IngestionCompletionEvaluator.evaluate(
            readiness: readinessSnap, logicalSourceID: logical,
            pendingUpgradeKinds: overlay.pending, runningUpgradeKinds: overlay.running,
            failedUpgradeKinds: overlay.failed, containerInspectionStatus: containerStatus, at: now)
    }
}
