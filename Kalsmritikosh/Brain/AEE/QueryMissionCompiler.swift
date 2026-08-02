//
//  QueryMissionCompiler.swift
//  Kalsmritikosh
//
//  AEE-M1 — compiles ONE QueryMission from the already-computed signals. Deterministic
//  and offline: NO generative model call is allowed here. It does not re-detect intent
//  or re-classify the question — it receives UserIntent, QueryCategory, LLMQueryClass
//  and the compiled QueryPlan and derives the mission's framing, lane, obligations and
//  bounded budget on top of them.
//

import Foundation

public nonisolated struct QueryMissionCompiler: Sendable {
    private let lanePolicy: MissionLanePolicy

    public init(lanePolicy: MissionLanePolicy = MissionLanePolicy()) {
        self.lanePolicy = lanePolicy
    }

    public func compile(
        intent: UserIntent,
        category: QueryCategory,
        queryClass: LLMQueryClass,
        plan: QueryPlan,
        context: AEERequestContext
    ) -> QueryMission {
        let objective = Self.objective(
            intent: intent, category: category,
            workflowInvocationPresent: context.workflowInvocationPresent)
        let deliverable = Self.deliverable(objective: objective, category: category)

        let lane = lanePolicy.selectLane(
            intent: intent, category: category, queryClass: queryClass,
            workflowInvocationPresent: context.workflowInvocationPresent,
            deterministicHandlerAvailable: context.deterministicHandlerAvailable)

        let risk = Self.evidenceRisk(lane: lane, plan: plan)
        let effort = MissionEffortClass.from(callLimit: queryClass.callLimit)
        let obligations = MissionEvidenceObligations.forLane(lane, plan: plan)

        // Budget: the lane ceiling INTERSECTED with the class limit. Never larger than
        // LLMQueryClass.callLimit (the existing hard ceiling); focused tightens to ≤1.
        let laneCeiling = lane.laneCallCeiling ?? queryClass.callLimit
        let allowedLLMCalls = min(queryClass.callLimit, laneCeiling)
        let allowedCorrectivePasses = obligations.maxCorrectivePasses

        return QueryMission(
            requestID: context.requestID,
            intent: intent,
            category: category,
            queryClass: queryClass,
            queryPlan: plan,
            objective: objective,
            deliverable: deliverable,
            evidenceRisk: risk,
            effortClass: effort,
            primaryLane: lane,
            evidenceObligations: obligations,
            allowedLLMCalls: allowedLLMCalls,
            allowedCorrectivePasses: allowedCorrectivePasses)
    }

    // MARK: - Objective / deliverable derivation

    static func objective(intent: UserIntent, category: QueryCategory, workflowInvocationPresent: Bool) -> MissionObjective {
        if workflowInvocationPresent { return .executeProfessionalJob }
        switch intent.kind {
        case .missingInformation:                       return .identifyGaps
        case .semanticSearch:                           return .locateEvidence
        case .reconstructTimeline, .reconstructProject, .reconstructRelationship:
            return .reconstruct
        case .riskDetection:                            return .assessRisk
        case .factualLookup, .executiveBriefing, .unknown:
            break
        }
        switch category {
        case .fact:                                     return .answerFact
        case .comparison:                               return .compare
        case .rootCause, .trend:                        return .explain
        case .risk, .compliance, .counterfactual:       return .assessRisk
        case .narrative, .timeline:                     return .reconstruct
        }
    }

    static func deliverable(objective: MissionObjective, category: QueryCategory) -> MissionDeliverable {
        switch objective {
        case .locateEvidence:        return .sourceSet
        case .answerFact:            return .directAnswer
        case .explain:               return .explanation
        case .compare:               return .comparison
        case .reconstruct:           return category == .timeline ? .timeline : .reconstructedNarrative
        case .assessRisk:            return .riskAssessment
        case .identifyGaps:          return .gapAssessment
        case .executeProfessionalJob: return .workflowArtifact
        }
    }

    // MARK: - Evidence risk

    static func evidenceRisk(lane: AEELane, plan: QueryPlan) -> MissionEvidenceRisk {
        switch lane {
        case .deterministic:
            return .low
        case .focused:
            return plan.evidencePolicy.requiresCorroboration ? .medium : .low
        case .analytical, .reconstruction, .professionalWorkflow:
            return .high
        }
    }
}
