//
//  CorrectiveRetrievalPlannerTests.swift
//  KalsmritikoshTests
//
//  RET-007 — at most one budgeted corrective retrieval pass; never loops, never blind-reruns.
//

import Testing
@testable import Kalsmritikosh

@Suite("RET-007 CorrectiveRetrievalPlanner")
struct CorrectiveRetrievalPlannerTests {

    private let planner = CorrectiveRetrievalPlanner()
    private let qc = QueryPlanCompiler()

    private func plan() -> QueryPlan {
        qc.compile(intent: UserIntent(kind: .factualLookup, scope: .global,
                                      rawQuestion: "how much and to whom?"),
                   category: .fact, queryClass: .ordinary)
    }
    private func sufficiency(missing: [RequestedField]) -> EvidenceSufficiency {
        EvidenceSufficiency(covered: [], missing: missing, documentsSearched: 3)
    }

    @Test("Retries once when fields are missing and budget remains")
    func retriesOnce() {
        let d = planner.decide(plan: plan(), sufficiency: sufficiency(missing: [.monetaryAmount]),
                               correctivePassesUsed: 0, retrievalBudgetRemaining: 1)
        #expect(d.shouldRetry)
        #expect(d.targetFields.contains(.monetaryAmount))
    }

    @Test("Never exceeds one corrective pass")
    func capped() {
        let d = planner.decide(plan: plan(), sufficiency: sufficiency(missing: [.monetaryAmount]),
                               correctivePassesUsed: 1, retrievalBudgetRemaining: 5)
        #expect(!d.shouldRetry)
    }

    @Test("No retry without budget")
    func noBudget() {
        let d = planner.decide(plan: plan(), sufficiency: sufficiency(missing: [.monetaryAmount]),
                               correctivePassesUsed: 0, retrievalBudgetRemaining: 0)
        #expect(!d.shouldRetry)
    }

    @Test("No retry when already complete")
    func complete() {
        let d = planner.decide(plan: plan(), sufficiency: EvidenceSufficiency(covered: [.monetaryAmount], missing: [], documentsSearched: 3),
                               correctivePassesUsed: 0, retrievalBudgetRemaining: 5)
        #expect(!d.shouldRetry)
    }
}
