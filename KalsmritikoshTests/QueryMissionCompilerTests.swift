//
//  QueryMissionCompilerTests.swift
//  KalsmritikoshTests
//
//  AEE-M1 — the mission compiler DERIVES one mission from the existing signals without
//  re-analysing the question or calling a model. It proves objective/deliverable/lane/
//  risk/effort/budget derivation, and that the generative-call ceiling is only ever
//  equal-or-stricter than LLMQueryClass.callLimit. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M1 — QueryMissionCompiler")
struct QueryMissionCompilerTests {

    private func intent(_ kind: UserIntent.Kind, _ q: String, hints: [String] = []) -> UserIntent {
        UserIntent(kind: kind, scope: .global, entityHints: hints, rawQuestion: q)
    }
    private func plan(_ i: UserIntent, _ c: QueryCategory, _ k: LLMQueryClass) -> QueryPlan {
        QueryPlanCompiler().compile(intent: i, category: c, queryClass: k)
    }
    private func compile(
        _ i: UserIntent, _ c: QueryCategory, _ k: LLMQueryClass,
        workflow: Bool = false, deterministic: Bool = false, requestID: UUID = UUID()
    ) -> QueryMission {
        QueryMissionCompiler().compile(
            intent: i, category: c, queryClass: k, plan: plan(i, c, k),
            context: AEERequestContext(requestID: requestID,
                                       workflowInvocationPresent: workflow,
                                       deterministicHandlerAvailable: deterministic))
    }

    @Test("An ordinary fact compiles to answerFact / directAnswer on the focused lane")
    func ordinaryFact() {
        let m = compile(intent(.factualLookup, "what is the balance?"), .fact, .ordinary)
        #expect(m.objective == .answerFact)
        #expect(m.deliverable == .directAnswer)
        #expect(m.primaryLane == .focused)
    }

    @Test("The focused lane tightens the generative ceiling to at most one call")
    func focusedCeiling() {
        // Even if the class allowed more, focused caps at 1.
        let m = compile(intent(.factualLookup, "compare?"), .fact, .moderate)  // callLimit 2
        #expect(m.primaryLane == .focused)
        #expect(m.allowedLLMCalls == 1)
    }

    @Test("The deterministic lane allows zero generative calls")
    func deterministicZero() {
        let m = compile(intent(.factualLookup, "what is the id?"), .fact, .ordinary, deterministic: true)
        #expect(m.primaryLane == .deterministic)
        #expect(m.allowedLLMCalls == 0)
        #expect(m.allowedCorrectivePasses == 0)
    }

    @Test("An analytical mission may use the full class budget")
    func analyticalBudget() {
        let m = compile(intent(.factualLookup, "why did X compare to Y?"), .comparison, .complex) // callLimit 3
        #expect(m.primaryLane == .analytical)
        #expect(m.allowedLLMCalls == 3)
    }

    @Test("allowedLLMCalls never exceeds the class call limit (the existing hard ceiling)")
    func neverExceedsClassLimit() {
        for k in LLMQueryClass.allCases {
            let m = compile(intent(.factualLookup, "why compare?"), .comparison, k)
            #expect(m.allowedLLMCalls <= k.callLimit, "\(k) exceeded its call limit")
        }
    }

    @Test("A workflow invocation compiles to executeProfessionalJob / workflowArtifact")
    func workflowObjective() {
        let m = compile(intent(.factualLookup, "run the intake job"), .fact, .moderate, workflow: true)
        #expect(m.objective == .executeProfessionalJob)
        #expect(m.deliverable == .workflowArtifact)
        #expect(m.primaryLane == .professionalWorkflow)
    }

    @Test("A reconstruct intent delivers a timeline for a timeline category, else a narrative")
    func reconstructDeliverables() {
        let t = compile(intent(.reconstructTimeline, "trace the events"), .timeline, .reconstruction)
        #expect(t.objective == .reconstruct)
        #expect(t.deliverable == .timeline)
        let n = compile(intent(.reconstructProject, "tell the story"), .narrative, .reconstruction)
        #expect(n.objective == .reconstruct)
        #expect(n.deliverable == .reconstructedNarrative)
    }

    @Test("A comparison category compiles to compare / comparison")
    func comparison() {
        let m = compile(intent(.factualLookup, "A versus B?"), .comparison, .complex)
        #expect(m.objective == .compare)
        #expect(m.deliverable == .comparison)
    }

    @Test("A risk category compiles to assessRisk / riskAssessment")
    func risk() {
        let m = compile(intent(.factualLookup, "what is the exposure?"), .risk, .complex)
        #expect(m.objective == .assessRisk)
        #expect(m.deliverable == .riskAssessment)
    }

    @Test("A missing-information intent compiles to identifyGaps / gapAssessment")
    func gaps() {
        let m = compile(intent(.missingInformation, "what is missing?"), .fact, .ordinary)
        #expect(m.objective == .identifyGaps)
        #expect(m.deliverable == .gapAssessment)
    }

    @Test("A semantic-search intent compiles to locateEvidence / sourceSet")
    func locate() {
        let m = compile(intent(.semanticSearch, "find documents about X"), .fact, .ordinary)
        #expect(m.objective == .locateEvidence)
        #expect(m.deliverable == .sourceSet)
    }

    @Test("Effort class derives from the call limit; the requestID threads through")
    func effortAndRequestID() {
        #expect(MissionEffortClass.from(callLimit: 0) == .instant)
        #expect(MissionEffortClass.from(callLimit: 1) == .light)
        #expect(MissionEffortClass.from(callLimit: 2) == .moderate)
        #expect(MissionEffortClass.from(callLimit: 3) == .heavy)
        let id = UUID()
        let m = compile(intent(.factualLookup, "q?"), .fact, .ordinary, requestID: id)
        #expect(m.requestID == id)
        #expect(m.effortClass == .light)   // ordinary → 1 call → light
    }
}
