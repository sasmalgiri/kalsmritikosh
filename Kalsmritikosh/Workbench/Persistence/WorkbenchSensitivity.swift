//
//  WorkbenchSensitivity.swift
//  Kalsmritikosh
//
//  LAB-001 (Stage C) — SensitiveScope propagation for Workbench datasets, composed over the SHARED
//  SensitiveScope authority (OPS-003). The Workbench defines NO privacy rules of its own: a dataset's
//  visibility / export eligibility is derived from the protection labels of the canonical sources it
//  binds. A dataset surface, saved view or export is permitted under an access scope only if EVERY
//  bound canonical target is permitted; broken lineage fails closed.
//

import Foundation

public nonisolated struct WorkbenchSensitivity: Sendable {
    private let datasets: WorkbenchDatasetRepository
    private let scopes: SensitiveScopeRepository

    public nonisolated init(datasets: WorkbenchDatasetRepository, scopes: SensitiveScopeRepository) {
        self.datasets = datasets
        self.scopes = scopes
    }

    /// True only if every canonical source the dataset binds is permitted by `access` under the shared
    /// SensitiveScope authority. A restricted bound source restricts the dataset surface, its saved
    /// views and any export/work-product bridge alike. Fail-closed on broken lineage.
    public func isPermitted(datasetID: UUID, under access: SensitiveScope) async throws -> Bool {
        for target in try await datasets.boundScopeTargets(datasetID: datasetID) {
            switch try await scopes.effectiveLabel(for: target) {
            case .resolved(let label):
                if !access.permits(label) { return false }
            case .brokenLineage:
                return false
            }
        }
        return true
    }

    /// The canonical scope targets a dataset binds — for callers that need to render or audit the
    /// exact protected sources behind a dataset. Delegates to the repository; never forks the target set.
    public func scopeTargets(datasetID: UUID) async throws -> [SensitiveScopeTarget] {
        try await datasets.boundScopeTargets(datasetID: datasetID)
    }
}
