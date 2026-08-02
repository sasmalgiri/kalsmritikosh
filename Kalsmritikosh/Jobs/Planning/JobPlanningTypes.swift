//
//  JobPlanningTypes.swift
//  Kalsmritikosh
//
//  TBJ-FINAL. The DERIVED planning value types. Nothing here is persisted: JobPlanningService
//  computes these fresh from the durable JobRecord plus the LIVE task / deadline / workflow
//  authorities each time, so they always reflect current canonical truth and never a stale snapshot.
//
//  Two invariants are baked into these shapes:
//    1. No fabricated epistemic percentage. Progress is reported as honest counts of resolved
//       reference states, never as a "% complete" or a confidence number.
//    2. Deterministic priority. An item's urgency band is a fixed function of its resolved state and
//       role — never a function of evidence confidence.
//

import Foundation

/// How a plan reference stands right now, resolved against its live authority object.
public nonisolated enum JobReferenceState: String, Sendable, Codable, CaseIterable {
    /// The referenced work is finished (task completed, requirement satisfied, artifact present).
    case complete
    /// Work is underway but not finished.
    case inProgress
    /// A hard blocker prevents progress (blocked task / blocking attention item / incomplete blocking dependency).
    case blocked
    /// Finished the work but a required human review / approval is outstanding.
    case waitingReview
    /// The item cannot advance until decisive evidence is supplied.
    case missingEvidence
    /// Not yet started.
    case notStarted
    /// The referenced object could not be resolved (deleted or never existed). Surfaced honestly,
    /// never treated as complete.
    case unresolved

    /// True when this reference contributes nothing further to do.
    public nonisolated var isDone: Bool { self == .complete }
}

/// Deterministic urgency bands, highest first. Ordering is by `rawValue` (0 = most urgent). This is
/// the §16 priority algorithm: hard blocker → confirmed-deadline criticality → required-deliverable
/// dependency → decisive evidence → required review → optional enrichment. Evidence CONFIDENCE never
/// enters this ordering.
public nonisolated enum JobPriorityBand: Int, Sendable, Codable, CaseIterable, Comparable {
    case hardBlocker = 0
    case confirmedDeadlineCritical = 1
    case requiredDeliverableDependency = 2
    case decisiveEvidence = 3
    case requiredReview = 4
    case optionalEnrichment = 5

    public nonisolated static func < (lhs: JobPriorityBand, rhs: JobPriorityBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One plan reference resolved to its current state.
public nonisolated struct JobReferenceStatus: Sendable, Equatable {
    public let reference: JobPlanReference
    public let state: JobReferenceState

    public nonisolated init(reference: JobPlanReference, state: JobReferenceState) {
        self.reference = reference
        self.state = state
    }
}

/// Why an item sits where it does in the priority order — a human-readable, deterministic rationale.
public nonisolated struct JobPriorityRationale: Sendable, Equatable {
    public let band: JobPriorityBand
    public let reason: String

    public nonisolated init(band: JobPriorityBand, reason: String) {
        self.band = band
        self.reason = reason
    }
}

/// A prioritised, resolved plan item: what it is, how it stands, and where the deterministic
/// algorithm placed it.
public nonisolated struct PrioritizedJobItem: Sendable, Equatable {
    public let reference: JobPlanReference
    public let state: JobReferenceState
    public let rationale: JobPriorityRationale

    public nonisolated init(reference: JobPlanReference, state: JobReferenceState,
                            rationale: JobPriorityRationale) {
        self.reference = reference
        self.state = state
        self.rationale = rationale
    }

    public nonisolated var band: JobPriorityBand { rationale.band }
}

/// How a confirmed time bound stands against the current instant. `.unknown` covers the honest
/// case where no CONFIRMED bound exists (e.g. only a candidate, or an open-ended job).
public nonisolated enum DeadlineRisk: String, Sendable, Codable, CaseIterable {
    case onTrack
    case atRisk
    case overdue
    case unknown
}

/// The derived, current view of a job's time budget. Carries a real countdown ONLY when a CONFIRMED
/// bound was resolved; otherwise `isConfirmed == false` and `advisory` explains why (e.g. a candidate
/// deadline that still needs confirmation, or a deleted/inactive deadline).
public nonisolated struct TimeBudgetStatus: Sendable, Equatable {
    public let basis: JobBudgetBasis
    /// True when the budget is bounded by a resolved, confirmed authority (not a candidate, not open-ended).
    public let isConfirmed: Bool
    /// The resolved confirmed-deadline instant, when applicable.
    public let deadlineDate: Date?
    /// The confirmed deadline's precision, when applicable (coarse precisions are surfaced honestly).
    public let precision: DatePrecision?
    /// Seconds remaining against a confirmed bound (deadline − now, or explicit allotment − elapsed).
    /// nil when no confirmed bound exists — never a guessed number.
    public let remaining: TimeInterval?
    public let risk: DeadlineRisk
    /// A user-facing note when the budget is NOT an authoritative countdown, e.g.
    /// "Possible deadline — needs confirmation." nil when the budget is confirmed or plainly none.
    public let advisory: String?

    public nonisolated init(basis: JobBudgetBasis, isConfirmed: Bool, deadlineDate: Date?,
                            precision: DatePrecision?, remaining: TimeInterval?, risk: DeadlineRisk,
                            advisory: String?) {
        self.basis = basis
        self.isConfirmed = isConfirmed
        self.deadlineDate = deadlineDate
        self.precision = precision
        self.remaining = remaining
        self.risk = risk
        self.advisory = advisory
    }

    public nonisolated static let unbounded = TimeBudgetStatus(
        basis: .none, isConfirmed: false, deadlineDate: nil, precision: nil,
        remaining: nil, risk: .unknown, advisory: nil)
}

/// Honest progress as COUNTS of resolved reference states. Deliberately carries NO percentage and no
/// completion fraction — those would read as a fabricated certainty. Callers render the counts.
public nonisolated struct JobProgressSnapshot: Sendable, Equatable {
    public let items: [JobReferenceStatus]

    public nonisolated init(items: [JobReferenceStatus]) { self.items = items }

    public nonisolated var total: Int { items.count }
    public nonisolated func count(_ state: JobReferenceState) -> Int {
        items.filter { $0.state == state }.count
    }
    public nonisolated var completeCount: Int { count(.complete) }
    public nonisolated var blockedCount: Int { count(.blocked) }
    public nonisolated var waitingReviewCount: Int { count(.waitingReview) }
    public nonisolated var missingEvidenceCount: Int { count(.missingEvidence) }
    public nonisolated var unresolvedCount: Int { count(.unresolved) }
    /// Items still requiring work (anything not `complete`).
    public nonisolated var remainingCount: Int { items.filter { !$0.state.isDone }.count }
}

/// Whether the MinimumAcceptableDeliverable is satisfied right now.
public nonisolated enum MinimumDeliverableStatus: String, Sendable, Codable, CaseIterable {
    /// Every MAD item is complete — a usable deliverable exists now.
    case met
    /// At least one MAD item is still outstanding.
    case notMet
    /// The job's author defined no minimum deliverable.
    case undefined
}

/// The honest time-bounded outcome for a job at the current instant. It states what is delivered,
/// what remains, what is blocked, what evidence is missing, the deadline risk, and the single
/// recommended next action. It NEVER marks the underlying job complete — closing a job is a human
/// act recorded through JobRepository, not an inference of this service.
public nonisolated struct TimeBoundedOutcome: Sendable, Equatable {
    public let budget: TimeBudgetStatus
    public let progress: JobProgressSnapshot
    public let minimumDeliverable: MinimumDeliverableStatus
    /// The prioritised plan, most urgent first (deterministic ordering).
    public let prioritizedItems: [PrioritizedJobItem]
    /// What could be delivered now (complete items).
    public let completedNow: [JobReferenceStatus]
    /// What still needs work.
    public let remainingWork: [JobReferenceStatus]
    /// Items blocked awaiting decisive evidence.
    public let missingEvidence: [JobPlanReference]
    /// Items blocked by a hard blocker.
    public let blockedActions: [JobPlanReference]
    public let deadlineRisk: DeadlineRisk
    /// The single highest-priority thing to do next, if anything remains.
    public let recommendedNextAction: PrioritizedJobItem?

    public nonisolated init(budget: TimeBudgetStatus, progress: JobProgressSnapshot,
                            minimumDeliverable: MinimumDeliverableStatus,
                            prioritizedItems: [PrioritizedJobItem],
                            completedNow: [JobReferenceStatus], remainingWork: [JobReferenceStatus],
                            missingEvidence: [JobPlanReference], blockedActions: [JobPlanReference],
                            deadlineRisk: DeadlineRisk, recommendedNextAction: PrioritizedJobItem?) {
        self.budget = budget
        self.progress = progress
        self.minimumDeliverable = minimumDeliverable
        self.prioritizedItems = prioritizedItems
        self.completedNow = completedNow
        self.remainingWork = remainingWork
        self.missingEvidence = missingEvidence
        self.blockedActions = blockedActions
        self.deadlineRisk = deadlineRisk
        self.recommendedNextAction = recommendedNextAction
    }

    /// TBJ never completes a job. This is always false and exists to make the contract explicit at
    /// call sites: the job's completion is a separate, human-recorded fact (JobRepository.close).
    public nonisolated var marksJobComplete: Bool { false }
}
