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

    @Test func noMeasurementsIsNotAPass() {
        // The defect this replaces: `HealthInputs()` means "nothing was
        // measured", but every field defaulted to a PASSING value, so an
        // unpopulated report showed eight green ticks and the panel said "All
        // checks passing." A self-check panel claiming a clean bill of health
        // from no data is the worst thing it can do.
        let inv = HealthReport.evaluateInvariants(HealthInputs())
        #expect(inv.allSatisfy { $0.status == .notMeasured })
        #expect(inv.allSatisfy { $0.detail == "not measured" })
        let report = HealthReport(coverage: [], invariants: inv)
        #expect(report.worstStatus == .notMeasured)
        #expect(report.measuredCount == 0)
    }

    @Test func aMeasuredCleanLedgerIsGreen() {
        // The genuine clean-ledger case: values PRESENT and good.
        let inv = HealthReport.evaluateInvariants(HealthInputs(
            maxCausalLinksPerEvent: 2, ghostAnchorCount: 0, staleRowsBehindEra: 0,
            gatedRegisterJunkCount: 0, anchorsUnthreaded: 0, frontierOpenCount: 0,
            backfillPending: 0, embeddingConsistent: true))
        #expect(inv.allSatisfy { $0.status == .pass })
        let report = HealthReport(coverage: [], invariants: inv)
        #expect(report.worstStatus == .pass)
        #expect(report.measuredCount == inv.count)
    }

    @Test func oneMeasuredFailureStillOutranksUnmeasuredSiblings() {
        // A real failure must not be diluted by its unmeasured neighbours.
        let report = HealthReport.make(coverage: [], inputs: HealthInputs(ghostAnchorCount: 4))
        #expect(report.worstStatus == .fail)
        #expect(report.measuredCount == 1)
        #expect(report.invariants.filter { $0.status == .notMeasured }.count
                == report.invariants.count - 1)
    }

    @Test func aSinglePassDoesNotClaimTheOthersWereChecked() {
        // Green overall, but the summary count says how many were measured, so
        // "all passing" can never mean "all eight verified" on one datum.
        let report = HealthReport.make(coverage: [], inputs: HealthInputs(ghostAnchorCount: 0))
        #expect(report.worstStatus == .pass)
        #expect(report.measuredCount == 1)
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

    // MARK: - The three live-path false greens

    @Test func anEmptyLedgerReportsNotMeasuredNotPassing() {
        // All three of these read GREEN on an empty ledger before this fix, so
        // a fresh install — or the state right after an erase — said "All
        // checks passing" having verified nothing.
        let embedding = HealthReport.embeddingInvariant(EmbeddingCoverage(total: 0, embedded: 0))
        #expect(embedding.status == .notMeasured)
        #expect(embedding.detail == "no chunks to check yet")

        // MAX over zero groups is 0, which is "within budget 3".
        let causal = HealthReport.causalBudgetInvariant(maxPerEvent: 0, totalLinks: 0)
        #expect(causal.status == .notMeasured)
        #expect(causal.detail.contains("no grounded causal links"))

        // Nothing queued reads as "done".
        let backfill = HealthReport.backfillInvariant(
            id: "b", title: "Backfill", pending: 0, hasWork: false)
        #expect(backfill.status == .notMeasured)

        // And the panel as a whole must not go green off the back of them.
        let report = HealthReport(coverage: [], invariants: [embedding, causal, backfill])
        #expect(report.worstStatus == .notMeasured)
        #expect(report.measuredCount == 0)
    }

    @Test func aPopulatedLedgerStillPassesProperly() {
        // The fix must not turn real passes into "not measured".
        let embedding = HealthReport.embeddingInvariant(
            EmbeddingCoverage(total: 100, embedded: 100))
        #expect(embedding.status == .pass)
        let causal = HealthReport.causalBudgetInvariant(maxPerEvent: 2, totalLinks: 40)
        #expect(causal.status == .pass)
        let backfill = HealthReport.backfillInvariant(
            id: "b", title: "Backfill", pending: 0, hasWork: true)
        #expect(backfill.status == .pass)
        #expect(backfill.detail == "done")

        let report = HealthReport(coverage: [], invariants: [embedding, causal, backfill])
        #expect(report.worstStatus == .pass)
        #expect(report.measuredCount == 3)
    }

    @Test func realViolationsStillGoRedAndAmber() {
        // A populated ledger that breaches the budget is still a hard failure,
        // and inconsistent embedding counts still fail.
        #expect(HealthReport.causalBudgetInvariant(maxPerEvent: 9, totalLinks: 40).status == .fail)
        #expect(HealthReport.embeddingInvariant(
            EmbeddingCoverage(total: 10, embedded: 20)).status == .fail)
        // Pending work is amber whether or not the ledger is otherwise empty:
        // work in the queue IS a measurement.
        #expect(HealthReport.backfillInvariant(
            id: "b", title: "B", pending: 7, hasWork: false).status == .warn)
    }

    @Test func coverageRowTotals() {
        let row = HealthCoverageRow(id: "facts", title: "Facts",
            states: [("stored", 700), ("pending", 16)])
        #expect(row.total == 716)
    }
}
