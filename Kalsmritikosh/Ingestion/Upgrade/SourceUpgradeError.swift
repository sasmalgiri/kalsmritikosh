//
//  SourceUpgradeError.swift
//  Kalsmritikosh
//
//  USF-M3 (USF-009) — typed errors for exact-SourceVersion progressive upgrade. Impossible targets are
//  BLOCKERS (never enqueued forever); a changed referenced source can never mutate the old version.
//

import Foundation

public nonisolated enum SourceUpgradeError: Error, Sendable, Equatable {
    // Planner blockers (§25) — a requested goal that cannot currently be reached.
    case unsupportedCapability(SourceUpgradeKind)
    case missingDependency(String)
    case sourceUnavailable(UUID)
    case policyBlocked(String)

    // Byte-resolution outcomes (§18).
    case sourceBytesChanged(UUID)          // referenced bytes differ from the exact version hash
    case vaultBlobMissing(UUID)            // managed version's vault blob is gone
    case hashMismatch(UUID)                // reopened bytes do not hash to the version's hash

    // Ledger.
    case jobNotFound(UUID)
    case sourceVersionMissing(UUID)
    case notAnActiveJob(UUID)
    // A handler returned but the expected durable readiness postcondition was not met (§27).
    case postconditionNotSatisfied(kind: SourceUpgradeKind, sourceVersionID: UUID)
}
