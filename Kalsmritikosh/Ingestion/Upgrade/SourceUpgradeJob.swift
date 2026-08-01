//
//  SourceUpgradeJob.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009) — one exact-SourceVersion progressive-upgrade job (a row of the v88 ledger). A job
//  describes WORK; it never asserts readiness.
//

import Foundation

public nonisolated struct SourceUpgradeJob: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let scope: SourceUpgradeScope
    public let subjectID: UUID?
    public let sourceVersionID: UUID?
    public let kind: SourceUpgradeKind
    public let targetDimension: SourceReadinessDimension?
    public let requestedGoal: SourceUpgradeGoal?
    public let priority: SourceUpgradePriority
    public let origin: SourceUpgradeOrigin
    public let state: SourceUpgradeJobState
    public let attempts: Int
    public let maxAttempts: Int
    public let lastError: String?
    public let producerID: String
    public let producerVersion: String
    public let notBefore: Date
    public let leaseToken: String?
    public let leaseExpiresAt: Date?

    public nonisolated init(id: UUID, scope: SourceUpgradeScope, subjectID: UUID?, sourceVersionID: UUID?,
                            kind: SourceUpgradeKind, targetDimension: SourceReadinessDimension?,
                            requestedGoal: SourceUpgradeGoal?, priority: SourceUpgradePriority,
                            origin: SourceUpgradeOrigin, state: SourceUpgradeJobState, attempts: Int,
                            maxAttempts: Int, lastError: String?, producerID: String, producerVersion: String,
                            notBefore: Date, leaseToken: String?, leaseExpiresAt: Date?) {
        self.id = id
        self.scope = scope
        self.subjectID = subjectID
        self.sourceVersionID = sourceVersionID
        self.kind = kind
        self.targetDimension = targetDimension
        self.requestedGoal = requestedGoal
        self.priority = priority
        self.origin = origin
        self.state = state
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.lastError = lastError
        self.producerID = producerID
        self.producerVersion = producerVersion
        self.notBefore = notBefore
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
    }
}
