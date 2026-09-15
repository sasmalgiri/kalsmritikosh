//
//  HealthReportTests.swift
//  KalsmritikoshTests
//
//  U-3.3 (W-6) — the health panel goes RED exactly when an invariant is
//  violated. Pure, fast tier — the acceptance ("panel goes red when a
//  fixture is deliberately broken") without booting the app.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("U-3.3 health report invariants")
struct HealthReportTests {

    @Test func cleanLedgerIsAllGreen() {
        let inv = HealthReport.evaluateInvariants(HealthInputs())
        #expect(inv.allSatisfy { $0.status == .pass })
        #expect(HealthReport(coverage: [], invariants: inv).worstStatus == .pass)
    }

    @Test func causalBudgetBreachFails() {
        let inv = HealthReport.evaluateInvariants(
            HealthInputs(maxCausalLinksPerEvent: 9, causalBudget: 3))
        let causal = inv.first { $0.id == "causal-budget" }
        #expect(causal?.status == .fail)
    }

    @Test func ghostAnchorFailsRed() {
        let report = HealthReport.make(coverage: [],
            inputs: HealthInputs(ghostAnchorCount: 1))
        #expect(report.worstStatus == .fail)
        #expect(report.invariants.first { $0.id == "ghost-anchors" }?.status == .fail)
    }

    @Test func openFrontiersWarnNotFail() {
        // Frontiers open mid-drain is a warning, not a hard failure.
        let report = HealthReport.make(coverage: [],
            inputs: HealthInputs(frontierOpenCount: 5))
        #expect(report.worstStatus == .warn)
    }

    @Test func registerJunkAndUnthreadedAnchorsFail() {
        #expect(HealthReport.evaluateInvariants(HealthInputs(gatedRegisterJunkCount: 2))
            .first { $0.id == "register-clean" }?.status == .fail)
        #expect(HealthReport.evaluateInvariants(HealthInputs(anchorsUnthreaded: 3))
            .first { $0.id == "anchors-threaded" }?.status == .fail)
    }

    @Test func coverageRowTotals() {
        let row = HealthCoverageRow(id: "facts", title: "Facts",
            states: [("stored", 700), ("pending", 16)])
        #expect(row.total == 716)
    }
}
