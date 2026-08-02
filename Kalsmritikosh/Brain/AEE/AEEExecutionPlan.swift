//
//  AEEExecutionPlan.swift
//  Kalsmritikosh
//
//  AEE-M1 — the bounded, inspectable plan the AdaptiveEvidencePlanner produces for a
//  mission: the lane's mission, the MINIMAL set of exact-version upgrades needed to
//  meet the readiness floor, and whether a single targeted retrieval refresh should
//  follow. It carries no generative decisions and never asks for a whole-archive
//  upgrade.
//

import Foundation

/// A request to raise ONE exact source version to a readiness goal. The sourceVersionID
/// is an exact USF SourceVersion — never a URL, never a whole logical source.
public nonisolated struct AEEUpgradeAction: Sendable, Hashable {
    public let sourceVersionID: UUID
    public let goal: SourceUpgradeGoal

    public init(sourceVersionID: UUID, goal: SourceUpgradeGoal) {
        self.sourceVersionID = sourceVersionID
        self.goal = goal
    }
}

public nonisolated struct AEEExecutionPlan: Sendable, Hashable {
    public let mission: QueryMission
    /// The minimal upgrades — only decisive versions actually below the floor AND able
    /// to reach it. Empty when nothing needs upgrading.
    public let upgradeActions: [AEEUpgradeAction]
    /// Whether a single targeted retrieval refresh should follow the upgrades.
    public let requiresCorrectiveRetrieval: Bool

    public init(mission: QueryMission, upgradeActions: [AEEUpgradeAction], requiresCorrectiveRetrieval: Bool) {
        self.mission = mission
        self.upgradeActions = upgradeActions
        self.requiresCorrectiveRetrieval = requiresCorrectiveRetrieval
    }

    public var hasUpgrades: Bool { !upgradeActions.isEmpty }
}
