//
//  AppState+LedgerMaintenance.swift
//  Kalsmritikosh
//
//  Topic-Ledger U3 (owner rule 1) — the owner-invoked one-time cleanup that
//  collapses an already-inflated fact ledger to one canonical row per distinct
//  fact and drops extraction junk. Safe and idempotent: facts are derived
//  projections, so rewriting them never touches primary evidence.
//

import Foundation
import os

extension AppState {
    /// Collapse duplicate facts + drop junk in the live ledger. Returns
    /// (before, after) row counts, or nil if the repository isn't ready.
    @discardableResult
    public func cleanUpLedger() async -> (before: Int, after: Int)? {
        guard let genericFacts else { return nil }
        do {
            let result = try await genericFacts.dedupExisting()
            KalsmritikoshLog.app.info("Ledger cleanup: \(result.before, privacy: .public) → \(result.after, privacy: .public) facts")
            return result
        } catch {
            KalsmritikoshLog.app.error("Ledger cleanup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
