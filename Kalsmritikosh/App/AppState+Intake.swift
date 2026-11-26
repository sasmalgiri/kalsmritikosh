//
//  AppState+Intake.swift
//  Kalsmritikosh
//
//  Smart-map S2 (IN-05 / IN-06 / IN-12) — what happens after an intake batch has been read:
//  • every version the batch received gets its text digest, so a content-equivalent source (same text, different bytes)
//    is recognised as such (SourceSamenessRepository; nothing is merged);
//  • every case's channel-arrival policy is applied, so an item arriving through a channel a person trusted for a case is
//    included in that case, naming the policy (InvestigationWorkspaceIntake.applyArrivalPolicies).
//  Failures are logged; they never undo or fail the batch itself.
//

import Foundation
import os

extension AppState {
    /// Follow-ups of one finished batch (ingest run).
    func afterIntakeBatch(run: UUID) async {
        guard let db = database else { return }
        let receipts = IntakeReceiptRepository(database: db)
        do {
            if let receipt = try await receipts.receipt(run: run) {
                let sameness = SourceSamenessRepository(database: db)
                for line in receipt.lines where line.outcome == .received {
                    guard let version = line.sourceVersionID else { continue }
                    do {
                        try await sameness.recordTextDigest(sourceVersionID: version, at: Date())
                    } catch {
                        KalsmritikoshLog.ingestion.error("Text digest not recorded: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        } catch {
            KalsmritikoshLog.ingestion.error("Intake receipt unreadable after the batch: \(error.localizedDescription, privacy: .public)")
        }
        if let intake = investigationWorkspaceIntake {
            let included = await intake.applyArrivalPolicies(at: Date())
            if included > 0 {
                KalsmritikoshLog.app.notice("Trusted-source policies included \(included) source(s) in their cases")
            }
        }
    }
}
