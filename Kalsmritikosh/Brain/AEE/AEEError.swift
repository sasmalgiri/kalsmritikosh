//
//  AEEError.swift
//  Kalsmritikosh
//
//  AEE-M1 — the closed error vocabulary for mission compilation and adaptive planning.
//

import Foundation

public nonisolated enum AEEError: Error, Sendable, Equatable, Hashable {
    /// The professionalWorkflow lane was requested without an actual workflow invocation.
    case missingWorkflowContext
    /// The mission's objective cannot be served (e.g. an unsupported query class).
    case unsupportedObjective(MissionObjective)
    /// A decisive source cannot reach the mission's required readiness floor.
    case unsatisfiableReadiness(sourceVersionID: UUID)
    /// The adaptive planner was asked to upgrade with no decisive sources identified.
    case noDecisiveSources
}
