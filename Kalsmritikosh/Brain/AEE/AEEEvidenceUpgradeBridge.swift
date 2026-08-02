//
//  AEEEvidenceUpgradeBridge.swift
//  Kalsmritikosh
//
//  AEE-M1 — the concrete bridge from AEE to the USF exact-version upgrade subsystem.
//  It is a thin adapter over IngestCoordinator: it reads a version's DERIVED completion
//  state and requests an upgrade of ONLY that exact SourceVersion. It adds no policy —
//  the decision of WHICH versions to upgrade belongs to AdaptiveEvidencePlanner, and the
//  exact-byte protection (a changed old version is never mutated) lives in USF.
//

import Foundation

public struct IngestCoordinatorEvidenceUpgradeBridge: AEEEvidenceUpgrading {
    private let ingest: IngestCoordinator

    public init(ingest: IngestCoordinator) {
        self.ingest = ingest
    }

    public func completionState(sourceVersionID: UUID) async -> SourceCompletionState? {
        (try? await ingest.completion(sourceVersionID: sourceVersionID))?.completionState
    }

    public func ensureReady(sourceVersionID: UUID, goal: SourceUpgradeGoal) async throws {
        // Foreground so the readiness postcondition is met (or the job terminally fails)
        // before we re-read — the planner never asks for more than the decisive versions.
        _ = try await ingest.ensureUpgrade(
            sourceVersionID: sourceVersionID,
            goal: goal,
            priority: .userRequested,
            execution: .foreground)
    }
}
