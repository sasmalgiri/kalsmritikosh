//
//  MissionLanePolicy.swift
//  Kalsmritikosh
//
//  AEE-M1 — deterministic lane selection. Given the already-computed signals plus two
//  request-scoped facts (is this an EXPLICIT Stage-3 workflow invocation? is a proven
//  deterministic handler available?), pick exactly one of the five canonical lanes.
//
//  Locked precedence (spec §10):
//    1. explicit Stage-3 workflow invocation            → professionalWorkflow
//    2. explicit narrative/history reconstruction        → reconstruction
//    3. rootCause/comparison/compliance/risk/counterfactual/(trend)/investigation
//                                                         → analytical
//    4. proven deterministic handler available           → deterministic
//    5. otherwise (normal grounded lookup/explain/search) → focused
//
//  A natural-language phrase alone can NEVER enter professionalWorkflow — only an
//  actual `workflowInvocationPresent` signal reaches rule 1.
//

import Foundation

public nonisolated struct MissionLanePolicy: Sendable {
    public init() {}

    public func selectLane(
        intent: UserIntent,
        category: QueryCategory,
        queryClass: LLMQueryClass,
        workflowInvocationPresent: Bool,
        deterministicHandlerAvailable: Bool
    ) -> AEELane {
        if workflowInvocationPresent { return .professionalWorkflow }
        if Self.isReconstruction(intent: intent, category: category, queryClass: queryClass) {
            return .reconstruction
        }
        if Self.isAnalytical(category: category, queryClass: queryClass) {
            return .analytical
        }
        if deterministicHandlerAvailable { return .deterministic }
        return .focused
    }

    /// Explicit narrative/history reconstruction: a reconstruct-* intent, a narrative
    /// category, or a (deep)reconstruction class.
    static func isReconstruction(intent: UserIntent, category: QueryCategory, queryClass: LLMQueryClass) -> Bool {
        switch intent.kind {
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            return true
        default:
            break
        }
        if category == .narrative { return true }
        if queryClass == .reconstruction || queryClass == .deepReconstruction { return true }
        return false
    }

    /// Analytical work: the analytical categories or an investigation class.
    static func isAnalytical(category: QueryCategory, queryClass: LLMQueryClass) -> Bool {
        switch category {
        case .rootCause, .comparison, .compliance, .counterfactual, .risk, .trend:
            return true
        case .fact, .timeline, .narrative:
            break
        }
        if queryClass == .investigation { return true }
        return false
    }
}
