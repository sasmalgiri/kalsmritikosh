//
//  QueryMission.swift
//  Kalsmritikosh
//
//  AEE-M1 — the Query Mission. ONE mission per user request. It does NOT re-analyse
//  the question: it COMPOSES the already-computed authorities (UserIntent,
//  QueryCategory, LLMQueryClass, QueryPlan) into a single, inspectable statement of
//  what the request is FOR (objective/deliverable), how much evidence risk it carries,
//  which adaptive lane will serve it, and the bounded budget it may spend.
//
//  Boundaries (AEE-M1):
//  • This is orchestration/domain code only — NO schema, NO persistence in M1.
//  • It is NOT a second query-analysis system. Objective/deliverable/lane/risk are
//    DERIVED from the existing signals by QueryMissionCompiler; the mission never
//    re-runs intent detection or re-classifies the question.
//  • The generative-call ceiling remains LLMQueryClass.callLimit — `allowedLLMCalls`
//    can only be EQUAL or STRICTER (never larger). The focused lane tightens it to ≤1.
//

import Foundation

/// The five canonical AEE execution lanes. This is the whole lane vocabulary — no
/// `simple`/`normal`/`advanced`/`smart`/`agentic`/`deepAI` competing tiers exist.
public nonisolated enum AEELane: String, Sendable, Codable, CaseIterable, Hashable {
    case deterministic        // proven exact/durable handler — 0 generative calls
    case focused              // the fast default: grounded lookup/explanation/search — ≤1 call
    case analytical           // root-cause / comparison / compliance / risk / counterfactual / investigation
    case reconstruction       // narrative/history reconstruction (reuses the existing composer)
    case professionalWorkflow // adapter to an EXPLICIT Stage-3 workflow/job invocation only

    /// The lane-specific hard ceiling on generative LLM calls, intersected with
    /// LLMQueryClass.callLimit by the compiler. `nil` means "defer to the class limit".
    public var laneCallCeiling: Int? {
        switch self {
        case .deterministic:      return 0
        case .focused:            return 1
        case .analytical, .reconstruction, .professionalWorkflow: return nil
        }
    }
}

/// The user's OBJECTIVE — what they are trying to achieve. Closed vocabulary.
/// This is the request's purpose, NOT an evidence-status value.
public nonisolated enum MissionObjective: String, Sendable, Codable, CaseIterable, Hashable {
    case locateEvidence
    case answerFact
    case explain
    case compare
    case reconstruct
    case assessRisk
    case identifyGaps
    case executeProfessionalJob
}

/// The concrete DELIVERABLE the answer should produce. Closed vocabulary, kept
/// separate from the objective (e.g. objective `.reconstruct` may deliver a
/// `.timeline` OR a `.reconstructedNarrative`).
public nonisolated enum MissionDeliverable: String, Sendable, Codable, CaseIterable, Hashable {
    case sourceSet
    case directAnswer
    case explanation
    case comparison
    case timeline
    case reconstructedNarrative
    case riskAssessment
    case gapAssessment
    case workflowArtifact
}

/// How much evidentiary risk a wrong/under-supported answer carries. Drives the
/// mission's minimum-readiness obligation (a high-risk claim needs evidence-ready
/// decisive sources; a low-risk lookup may answer from search-ready material with
/// disclosure).
public nonisolated enum MissionEvidenceRisk: String, Sendable, Codable, CaseIterable, Hashable {
    case low
    case medium
    case high
}

/// A purely DESCRIPTIVE effort tier, derived from the class's call limit. It is not a
/// budget authority (LLMQueryClass.callLimit remains the authority) — it exists only
/// so the trace/telemetry can label how heavy a request is at a glance.
public nonisolated enum MissionEffortClass: String, Sendable, Codable, CaseIterable, Hashable {
    case instant     // 0 generative calls
    case light       // 1
    case moderate    // 2
    case heavy       // 3+

    /// Derive the effort tier from the query class's hard call limit.
    public static func from(callLimit: Int) -> MissionEffortClass {
        switch callLimit {
        case ..<1:  return .instant
        case 1:     return .light
        case 2:     return .moderate
        default:    return .heavy
        }
    }
}

/// ONE mission per user request. Composed, never re-analysed.
public nonisolated struct QueryMission: Sendable, Codable, Hashable {
    public let requestID: UUID

    // The existing authorities, composed verbatim (not recomputed).
    public let intent: UserIntent
    public let category: QueryCategory
    public let queryClass: LLMQueryClass
    public let queryPlan: QueryPlan

    // Derived mission framing.
    public let objective: MissionObjective
    public let deliverable: MissionDeliverable
    public let evidenceRisk: MissionEvidenceRisk
    public let effortClass: MissionEffortClass

    public let primaryLane: AEELane
    public let evidenceObligations: MissionEvidenceObligations

    // Bounded budget. `allowedLLMCalls` is the lane ceiling ∩ class limit — never larger
    // than LLMQueryClass.callLimit. `allowedCorrectivePasses` never exceeds the
    // CorrectiveRetrievalPlanner cap.
    public let allowedLLMCalls: Int
    public let allowedCorrectivePasses: Int

    public init(
        requestID: UUID,
        intent: UserIntent,
        category: QueryCategory,
        queryClass: LLMQueryClass,
        queryPlan: QueryPlan,
        objective: MissionObjective,
        deliverable: MissionDeliverable,
        evidenceRisk: MissionEvidenceRisk,
        effortClass: MissionEffortClass,
        primaryLane: AEELane,
        evidenceObligations: MissionEvidenceObligations,
        allowedLLMCalls: Int,
        allowedCorrectivePasses: Int
    ) {
        self.requestID = requestID
        self.intent = intent
        self.category = category
        self.queryClass = queryClass
        self.queryPlan = queryPlan
        self.objective = objective
        self.deliverable = deliverable
        self.evidenceRisk = evidenceRisk
        self.effortClass = effortClass
        self.primaryLane = primaryLane
        self.evidenceObligations = evidenceObligations
        self.allowedLLMCalls = allowedLLMCalls
        self.allowedCorrectivePasses = allowedCorrectivePasses
    }
}
