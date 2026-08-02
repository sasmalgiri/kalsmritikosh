//
//  AdaptiveEvidencePlanner.swift
//  Kalsmritikosh
//
//  AEE-M1 — a PLANNER, not a second MasterBrain. Given a mission and the DERIVED
//  completion state of each decisive exact source version, it computes the minimal set
//  of exact-version upgrades needed to meet the mission's readiness floor. It executes
//  nothing itself; MasterBrain runs the upgrades through the AEEEvidenceUpgrading
//  bridge (backed by the USF exact-version upgrade queue).
//
//  Invariants:
//  • Only decisive versions that are BELOW the floor AND upgradable get an action.
//  • It never plans a whole-archive/whole-source upgrade — it only sees the decisive
//    versions it is handed.
//  • For an analytical mission the floor is `evidenceReady` for the DECISIVE sources —
//    it never demands the whole source be analytically-ready.
//

import Foundation

/// The bridge MasterBrain uses to reach the USF exact-version upgrade subsystem. A
/// concrete adapter wraps IngestCoordinator; tests inject a fake. When no bridge is
/// wired, AEE simply answers from what is already retrieved (disclosing limitations).
public protocol AEEEvidenceUpgrading: Sendable {
    /// The current DERIVED completion state of an exact source version (nil if unknown).
    func completionState(sourceVersionID: UUID) async -> SourceCompletionState?
    /// Ensure ONLY this exact source version reaches the goal via the USF upgrade queue.
    /// Throws when the source's bytes changed / are unavailable — the USF exact-byte
    /// protection is preserved and a changed old version is never mutated.
    func ensureReady(sourceVersionID: UUID, goal: SourceUpgradeGoal) async throws
}

public nonisolated struct AdaptiveEvidencePlanner: Sendable {
    public init() {}

    /// Plan the minimal upgrades for a mission from the decisive versions' readiness.
    public func plan(
        mission: QueryMission,
        decisiveReadiness: [UUID: SourceCompletionState]
    ) -> AEEExecutionPlan {
        let floor = mission.evidenceObligations.minimumSourceReadiness
        var actions: [AEEUpgradeAction] = []
        for id in decisiveReadiness.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let state = decisiveReadiness[id] else { continue }
            if !floor.isMet(by: state) && floor.isUpgradable(from: state) {
                actions.append(AEEUpgradeAction(sourceVersionID: id, goal: floor.upgradeGoal))
            }
        }
        return AEEExecutionPlan(
            mission: mission,
            upgradeActions: actions,
            requiresCorrectiveRetrieval: !actions.isEmpty)
    }
}
