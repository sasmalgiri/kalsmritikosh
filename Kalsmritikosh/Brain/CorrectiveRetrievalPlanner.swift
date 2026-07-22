//
//  CorrectiveRetrievalPlanner.swift
//  Kalsmritikosh
//
//  RET-007 — bounded corrective retrieval. If the first retrieval didn't cover the fields
//  the question asked for (RET-006 sufficiency), ONE targeted second pass may help — but no
//  more than one, and only within the shared request budget. This prevents both silent
//  under-answering and unbounded retrieval loops.
//
//  Deterministic decision component. It does not itself retrieve — it decides whether to,
//  and what to target (the still-missing fields + the subjects), so the caller can run a
//  single focused pass.
//

import Foundation

public struct CorrectiveRetrievalPlanner: Sendable {
    public nonisolated init() {}

    /// Hard cap: at most one corrective pass per question.
    public nonisolated static let maxCorrectivePasses = 1

    public struct Decision: Sendable, Hashable {
        public let shouldRetry: Bool
        public let targetFields: [RequestedField]
        public let targetSubjects: [String]
        public let rationale: String
    }

    /// Decide whether to run a corrective pass.
    /// - correctivePassesUsed: how many corrective passes already ran (0 on the first call).
    /// - retrievalBudgetRemaining: remaining retrieval budget units (>0 required to retry).
    public nonisolated func decide(
        plan: QueryPlan,
        sufficiency: EvidenceSufficiency,
        correctivePassesUsed: Int,
        retrievalBudgetRemaining: Int
    ) -> Decision {
        // Already complete → never retry.
        if sufficiency.isComplete {
            return Decision(shouldRetry: false, targetFields: [], targetSubjects: [],
                            rationale: "evidence already covers all requested fields")
        }
        // Cap reached → stop, disclose the gap instead (RET-006/CLM-004).
        if correctivePassesUsed >= Self.maxCorrectivePasses {
            return Decision(shouldRetry: false, targetFields: sufficiency.missing, targetSubjects: plan.targetSubjects,
                            rationale: "corrective-pass cap reached; disclose remaining gaps")
        }
        // No budget → stop.
        if retrievalBudgetRemaining <= 0 {
            return Decision(shouldRetry: false, targetFields: sufficiency.missing, targetSubjects: plan.targetSubjects,
                            rationale: "no retrieval budget remaining; disclose remaining gaps")
        }
        // Nothing specific to target → stop (avoid a blind re-run).
        if sufficiency.missing.isEmpty {
            return Decision(shouldRetry: false, targetFields: [], targetSubjects: plan.targetSubjects,
                            rationale: "no specific missing field to target")
        }
        // Warranted: one focused pass at the missing fields + subjects.
        return Decision(shouldRetry: true, targetFields: sufficiency.missing, targetSubjects: plan.targetSubjects,
                        rationale: "one corrective pass targeting: \(sufficiency.missing.map(\.rawValue).joined(separator: ", "))")
    }
}
