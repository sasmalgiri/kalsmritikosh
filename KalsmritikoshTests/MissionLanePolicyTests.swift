//
//  MissionLanePolicyTests.swift
//  KalsmritikoshTests
//
//  AEE-M1 — the locked lane precedence:
//    workflow > reconstruction > analytical > deterministic-handler > focused.
//  A natural-language phrase alone can NEVER reach professionalWorkflow. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("AEE-M1 — MissionLanePolicy")
struct MissionLanePolicyTests {

    private let policy = MissionLanePolicy()
    private func intent(_ kind: UserIntent.Kind, _ q: String = "q?") -> UserIntent {
        UserIntent(kind: kind, scope: .global, rawQuestion: q)
    }
    private func lane(
        _ kind: UserIntent.Kind, _ c: QueryCategory, _ k: LLMQueryClass,
        workflow: Bool = false, deterministic: Bool = false
    ) -> AEELane {
        policy.selectLane(intent: intent(kind), category: c, queryClass: k,
                          workflowInvocationPresent: workflow, deterministicHandlerAvailable: deterministic)
    }

    @Test("An ordinary fact with no special signal → focused")
    func ordinaryFactFocused() {
        #expect(lane(.factualLookup, .fact, .ordinary) == .focused)
    }

    @Test("A proven deterministic handler → deterministic")
    func deterministic() {
        #expect(lane(.factualLookup, .fact, .ordinary, deterministic: true) == .deterministic)
    }

    @Test("A comparison → analytical")
    func comparisonAnalytical() {
        #expect(lane(.factualLookup, .comparison, .complex) == .analytical)
    }

    @Test("A root-cause → analytical")
    func rootCauseAnalytical() {
        #expect(lane(.factualLookup, .rootCause, .complex) == .analytical)
    }

    @Test("A risk → analytical")
    func riskAnalytical() {
        #expect(lane(.factualLookup, .risk, .complex) == .analytical)
    }

    @Test("An explicit reconstruct-timeline intent → reconstruction")
    func reconstructIntent() {
        #expect(lane(.reconstructTimeline, .timeline, .reconstruction) == .reconstruction)
    }

    @Test("A narrative category → reconstruction")
    func narrativeReconstruction() {
        #expect(lane(.factualLookup, .narrative, .complex) == .reconstruction)
    }

    @Test("An explicit workflow invocation → professionalWorkflow")
    func workflowLane() {
        #expect(lane(.factualLookup, .fact, .moderate, workflow: true) == .professionalWorkflow)
    }

    @Test("Text alone never reaches professionalWorkflow, across every category/class")
    func textAloneNeverWorkflow() {
        for kind in UserIntent.Kind.allCases {
            for c in QueryCategory.allCases {
                for k in LLMQueryClass.allCases {
                    let l = policy.selectLane(intent: intent(kind), category: c, queryClass: k,
                                              workflowInvocationPresent: false,
                                              deterministicHandlerAvailable: false)
                    #expect(l != .professionalWorkflow, "\(kind)/\(c)/\(k) leaked to professionalWorkflow")
                }
            }
        }
    }

    @Test("Precedence: workflow outranks a reconstruction intent; investigation class → analytical")
    func precedenceAndInvestigation() {
        // Workflow present on a reconstruction-shaped request still wins the workflow lane.
        #expect(lane(.reconstructTimeline, .narrative, .reconstruction, workflow: true) == .professionalWorkflow)
        // An investigation class (not a reconstruct category) routes analytical.
        #expect(lane(.factualLookup, .compliance, .investigation) == .analytical)
    }
}
