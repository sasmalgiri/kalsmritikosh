//
//  TimeBudget.swift
//  Kalsmritikosh
//
//  TBJ-FINAL. The usable-time model for a time-bounded Job. A TimeBudget is a value description of
//  WHAT defines the job's time pressure — nothing more. The three authoritative sources are an
//  explicit user duration, a CONFIRMED Deadline, or a workflow constraint. A DeadlineCandidate is
//  NEVER a budget: it has no row in the `deadlines` table, so JobRepository cannot bind it, and the
//  planning service surfaces an unconfirmed candidate separately as "possible deadline — needs
//  confirmation" (see TimeBudgetStatus.advisory) rather than as a confirmed countdown.
//
//  This type carries no clock. How much time REMAINS is derived at plan time (TimeBudgetStatus),
//  because it depends on the live deadline date + precision resolved from the confirmed-deadline
//  authority and the current instant — never stored here as a stale number.
//

import Foundation

/// Which authority (if any) defines a job's usable time. Distinct from any deadline/task status.
public nonisolated enum JobBudgetBasis: String, Codable, Sendable, CaseIterable {
    /// The user stated a fixed amount of usable time (e.g. "I have two hours").
    case explicitDuration
    /// A CONFIRMED Deadline (a row in `deadlines`) bounds the job.
    case confirmedDeadline
    /// A workflow run the job executes through imposes the time constraint.
    case workflowConstraint
    /// No time bound is known. The job is open-ended until a bound is confirmed.
    case none
}

/// The stored budget specification. Exactly one source field is populated for its basis; a `.none`
/// budget populates none. Construct via the factories, which keep that invariant.
public nonisolated struct TimeBudget: Sendable, Equatable, Codable {
    public let basis: JobBudgetBasis
    /// Total usable seconds, set iff `basis == .explicitDuration` (always > 0).
    public let explicitDuration: TimeInterval?
    /// A CONFIRMED deadline's id, set iff `basis == .confirmedDeadline`. Resolved against
    /// `deadlines` (never `deadline_candidates`) by JobRepository at bind time.
    public let deadlineID: UUID?
    /// The constraining workflow run's id, set iff `basis == .workflowConstraint`.
    public let workflowRunID: UUID?

    public nonisolated init(basis: JobBudgetBasis, explicitDuration: TimeInterval?,
                            deadlineID: UUID?, workflowRunID: UUID?) {
        self.basis = basis
        self.explicitDuration = explicitDuration
        self.deadlineID = deadlineID
        self.workflowRunID = workflowRunID
    }

    /// An open-ended job with no known time bound.
    public nonisolated static let none = TimeBudget(basis: .none, explicitDuration: nil,
                                                    deadlineID: nil, workflowRunID: nil)

    /// A fixed usable-time allotment. `seconds` must be > 0.
    public nonisolated static func explicit(seconds: TimeInterval) -> TimeBudget {
        TimeBudget(basis: .explicitDuration, explicitDuration: seconds, deadlineID: nil, workflowRunID: nil)
    }

    /// Bound by a CONFIRMED deadline. `deadlineID` must resolve in `deadlines`, enforced by the repository.
    public nonisolated static func confirmedDeadline(_ deadlineID: UUID) -> TimeBudget {
        TimeBudget(basis: .confirmedDeadline, explicitDuration: nil, deadlineID: deadlineID, workflowRunID: nil)
    }

    /// Bound by a workflow run's own constraint.
    public nonisolated static func workflowConstraint(_ workflowRunID: UUID) -> TimeBudget {
        TimeBudget(basis: .workflowConstraint, explicitDuration: nil, deadlineID: nil, workflowRunID: workflowRunID)
    }

    /// True when the basis and its populated field agree and no other field is set. The DB CHECK
    /// enforces the same shape; this lets the repository fail closed before a write.
    public nonisolated var isWellFormed: Bool {
        switch basis {
        case .explicitDuration:
            return (explicitDuration ?? 0) > 0 && deadlineID == nil && workflowRunID == nil
        case .confirmedDeadline:
            return deadlineID != nil && explicitDuration == nil && workflowRunID == nil
        case .workflowConstraint:
            return workflowRunID != nil && explicitDuration == nil && deadlineID == nil
        case .none:
            return explicitDuration == nil && deadlineID == nil && workflowRunID == nil
        }
    }
}
