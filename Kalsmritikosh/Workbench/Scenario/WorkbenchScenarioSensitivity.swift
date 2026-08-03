//
//  WorkbenchScenarioSensitivity.swift
//  Kalsmritikosh
//
//  LAB-003 (Stage C) — SensitiveScope propagation for scenarios, composed over the SHARED SensitiveScope
//  authority (OPS-003). A scenario defines NO privacy rules of its own and can NEVER widen visibility:
//  its projection, comparison, transformation-over-scenario, export and promotion path are all gated by
//  the protection labels of the canonical sources the underlying dataset binds. A user annotation on
//  restricted evidence does not make the result unrestricted. Broken lineage fails closed.
//

import Foundation

public nonisolated struct WorkbenchScenarioSensitivity: Sendable {
    private let scenarios: WorkbenchScenarioRepository
    private let scopes: SensitiveScopeRepository

    public nonisolated init(scenarios: WorkbenchScenarioRepository, scopes: SensitiveScopeRepository) {
        self.scenarios = scenarios
        self.scopes = scopes
    }

    /// True only if every canonical source the scenario's base dataset binds is permitted by `access`
    /// under the shared authority. Fail-closed on broken lineage. A scenario never relaxes this.
    public func isPermitted(scenarioID: UUID, under access: SensitiveScope) async throws -> Bool {
        for target in try await scenarios.scopeTargets(scenarioID: scenarioID) {
            switch try await scopes.effectiveLabel(for: target) {
            case .resolved(let label):
                if !access.permits(label) { return false }
            case .brokenLineage:
                return false
            }
        }
        return true
    }

    /// The canonical scope targets behind a scenario — delegates to the repository; never forks the set.
    public func scopeTargets(scenarioID: UUID) async throws -> [SensitiveScopeTarget] {
        try await scenarios.scopeTargets(scenarioID: scenarioID)
    }
}
