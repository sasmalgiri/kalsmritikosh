//
//  LLMBudgetTests.swift
//  KalsmritikoshTests
//
//  Unit tests for the hard request-scoped LLM budget (Minimum-LLM Completion
//  spec §20). Pure logic — no live brain, no provider. The runtime call-count
//  matrix (0 calls at boot, 1 for ordinary, ≤3 complex, …) is exercised
//  separately by RealDataProbe against a live archive.
//
//  NOTE: add this file to the KalsmritikoshTests target in Xcode
//  (File ▸ Add Files…) before running — the project uses buildable folders for
//  the app but the test bundle membership is explicit.
//

import Testing
@testable import Kalsmritikosh

struct LLMBudgetTests {

    // MARK: - LLMQueryClass ceilings

    @Test func classCallLimitsMatchSpec() {
        #expect(LLMQueryClass.deterministic.callLimit == 0)
        #expect(LLMQueryClass.ordinary.callLimit == 1)
        #expect(LLMQueryClass.moderate.callLimit == 2)
        #expect(LLMQueryClass.complex.callLimit == 3)
        #expect(LLMQueryClass.reconstruction.callLimit == 3)
        #expect(LLMQueryClass.deepReconstruction.callLimit == 5)
        #expect(LLMQueryClass.investigation.callLimit == 5)
        #expect(LLMQueryClass.unsupported.callLimit == 0)
    }

    @Test func expertLimitsMatchSpec() {
        #expect(LLMQueryClass.ordinary.expertLimit == 1)
        #expect(LLMQueryClass.moderate.expertLimit == 1)
        #expect(LLMQueryClass.complex.expertLimit == 2)
        #expect(LLMQueryClass.reconstruction.expertLimit == 0)
        #expect(LLMQueryClass.investigation.expertLimit == 2)
        #expect(LLMQueryClass.deterministic.expertLimit == 0)
    }

    @Test func onlyReconstructiveClassesRequireCorroboration() {
        #expect(LLMQueryClass.ordinary.requiresCorroboration == false)
        #expect(LLMQueryClass.moderate.requiresCorroboration == false)
        #expect(LLMQueryClass.complex.requiresCorroboration == true)
        #expect(LLMQueryClass.reconstruction.requiresCorroboration == true)
        #expect(LLMQueryClass.investigation.requiresCorroboration == true)
    }

    // MARK: - LLMCallBudget enforcement

    @Test func budgetRejectsCallBeyondLimit() async throws {
        let budget = LLMCallBudget(limit: 1)
        _ = try await budget.reserve(purpose: "a", providerID: "p")
        await #expect(throws: LLMCallBudgetError.self) {
            _ = try await budget.reserve(purpose: "b", providerID: "p")
        }
    }

    @Test func failedCallStillConsumesBudget() async throws {
        let budget = LLMCallBudget(limit: 2)
        let s1 = try await budget.reserve(purpose: "a", providerID: "p")
        await budget.finish(sequence: s1, status: .failed)
        // The failed call is NOT refunded — only one reservation remains.
        _ = try await budget.reserve(purpose: "b", providerID: "p")
        await #expect(throws: LLMCallBudgetError.self) {
            _ = try await budget.reserve(purpose: "c", providerID: "p")
        }
    }

    @Test func retryConsumesAnotherCall() async throws {
        let budget = LLMCallBudget(limit: 2)
        let s1 = try await budget.reserve(purpose: "try", providerID: "p")
        await budget.finish(sequence: s1, status: .failed)
        // A retry reserves again — visible, not hidden.
        _ = try await budget.reserve(purpose: "try.retry", providerID: "p")
        let snap = await budget.snapshot()
        #expect(snap.used == 2)
        #expect(snap.remaining == 0)
    }

    @Test func canSpendReflectsRemaining() async throws {
        let budget = LLMCallBudget(limit: 3)
        #expect(await budget.canSpend(3) == true)
        _ = try await budget.reserve(purpose: "a", providerID: "p")
        #expect(await budget.canSpend(2) == true)
        #expect(await budget.canSpend(3) == false)
    }

    @Test func childContextSharesParentBudget() async throws {
        let parent = LLMRequestContext(
            budget: LLMCallBudget(limit: 1), queryClass: .investigation
        )
        let child = parent.child(purpose: "step")
        #expect(child.rootRequestID == parent.rootRequestID)
        // Spending through the child exhausts the shared budget.
        _ = try await child.budget.reserve(purpose: "x", providerID: "p")
        #expect(await parent.budget.canSpend() == false)
    }

    // MARK: - Classifier

    @Test func ordinaryLookupClassifiesOrdinary() {
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "Who signed the contract?")
        #expect(LLMQueryClassifier.classify(question: intent.rawQuestion, intent: intent) == .ordinary)
    }

    @Test func explicitInvestigateClassifiesInvestigation() {
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "Investigate the payment delays")
        #expect(LLMQueryClassifier.classify(question: intent.rawQuestion, intent: intent) == .investigation)
    }

    @Test func reconstructWithDeepPhrasingClassifiesDeep() {
        let intent = UserIntent(kind: .reconstructProject, scope: .global, rawQuestion: "Give an in-depth reconstruction of Project Delta")
        #expect(LLMQueryClassifier.classify(question: intent.rawQuestion, intent: intent) == .deepReconstruction)
    }

    // MARK: - Router expert cap

    @Test func ordinaryRoutesExactlyOneExpert() {
        let all = ["expert.reasoning", "expert.email", "expert.legal", "expert.timeline"]
        let picked = DeterministicRouter.minimalExpertSet(from: all, queryClass: .ordinary)
        #expect(picked == ["expert.reasoning"])
    }

    @Test func complexRoutesAtMostTwoExperts() {
        let all = ["expert.reasoning", "expert.email", "expert.legal", "expert.timeline", "expert.financial"]
        let picked = DeterministicRouter.minimalExpertSet(from: all, queryClass: .complex)
        #expect(picked.count <= 2)
        #expect(picked.first == "expert.reasoning")
    }

    @Test func reconstructionDoesNotFanOutExperts() {
        let all = ["expert.reasoning", "expert.timeline", "expert.project"]
        let picked = DeterministicRouter.minimalExpertSet(from: all, queryClass: .reconstruction)
        #expect(picked.isEmpty)
    }
}
