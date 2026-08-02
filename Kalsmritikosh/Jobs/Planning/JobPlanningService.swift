//
//  JobPlanningService.swift
//  Kalsmritikosh
//
//  TBJ-FINAL. The deterministic planner. Given a durable JobRecord and the LIVE task / deadline /
//  workflow authorities, it derives — never persists — the current answers to the job questions:
//  how much confirmed time remains, what is complete, what is missing, what is blocking, which item
//  matters most, and the minimum safe deliverable. Two hard rules:
//
//    1. No fabricated certainty. Progress is honest counts of resolved reference states; there is no
//       "% complete" and no confidence number. A time budget carries a real countdown ONLY when a
//       CONFIRMED bound resolves — an unconfirmed candidate deadline is surfaced as an advisory
//       ("Possible deadline — needs confirmation"), never a countdown.
//    2. Deterministic priority. An item's urgency band is a fixed function of its resolved state,
//       role and the confirmed deadline risk — NEVER a function of evidence confidence. TBJ never
//       marks the underlying job complete; closing a job is a human act (JobRepository.close).
//

import Foundation

public struct JobPlanningService: Sendable {

    /// Items within this window of a confirmed bound are `.atRisk`; past it, `.overdue`. A fixed,
    /// deterministic threshold (not a heuristic that varies per call).
    public static let atRiskWindow: TimeInterval = 24 * 60 * 60

    private let tasks: ProfessionalTaskRepository
    private let deadlines: DeadlineRepository
    private let workflows: WorkflowRunRepository

    public init(tasks: ProfessionalTaskRepository, deadlines: DeadlineRepository,
                workflows: WorkflowRunRepository) {
        self.tasks = tasks
        self.deadlines = deadlines
        self.workflows = workflows
    }

    // MARK: - Public entry

    /// The full honest outcome for a job at `now`.
    public func outcome(for record: JobRecord, now: Date) async throws -> TimeBoundedOutcome {
        let budget = try await budgetStatus(for: record, now: now)
        let statuses = try await resolveStates(record.references)
        let progress = JobProgressSnapshot(items: statuses)

        // Deterministic priority over the INCOMPLETE items only.
        let prioritized = statuses
            .filter { $0.state != .complete }
            .map { PrioritizedJobItem(reference: $0.reference, state: $0.state,
                                      rationale: rationale(for: $0, budgetRisk: budget.risk)) }
            .sorted(by: Self.moreUrgent)

        let completedNow = statuses.filter { $0.state == .complete }
        let remainingWork = statuses.filter { $0.state != .complete }
        let missingEvidence = statuses.filter { $0.state == .missingEvidence }.map(\.reference)
        let blockedActions = statuses.filter { $0.state == .blocked }.map(\.reference)

        return TimeBoundedOutcome(
            budget: budget,
            progress: progress,
            minimumDeliverable: minimumDeliverableStatus(record.plan, statuses: statuses),
            prioritizedItems: prioritized,
            completedNow: completedNow,
            remainingWork: remainingWork,
            missingEvidence: missingEvidence,
            blockedActions: blockedActions,
            deadlineRisk: budget.risk,
            recommendedNextAction: prioritized.first)
    }

    // MARK: - Time budget (confirmed-only; candidate => advisory)

    /// Resolve the job's budget against the current instant. A CONFIRMED deadline yields a real
    /// countdown; an explicit duration counts down from job start; a workflow constraint is bounded
    /// but dateless; `.none` is unbounded UNLESS a pending candidate deadline exists on a referenced
    /// task — in which case the honest advisory "possible deadline — needs confirmation" is surfaced,
    /// never a countdown.
    public func budgetStatus(for record: JobRecord, now: Date) async throws -> TimeBudgetStatus {
        let budget = record.objective.budget
        switch budget.basis {
        case .confirmedDeadline:
            guard let id = budget.deadlineID, let d = try await deadlines.deadline(id: id) else {
                return TimeBudgetStatus(basis: .confirmedDeadline, isConfirmed: false, deadlineDate: nil,
                                        precision: nil, remaining: nil, risk: .unknown,
                                        advisory: "The deadline for this job could not be found.")
            }
            guard d.status == .active else {
                return TimeBudgetStatus(basis: .confirmedDeadline, isConfirmed: false,
                                        deadlineDate: d.value.date, precision: d.value.precision,
                                        remaining: nil, risk: .unknown,
                                        advisory: "The deadline is no longer active.")
            }
            let remaining = d.value.date.timeIntervalSince(now)
            return TimeBudgetStatus(basis: .confirmedDeadline, isConfirmed: true, deadlineDate: d.value.date,
                                    precision: d.value.precision, remaining: remaining,
                                    risk: Self.risk(remaining: remaining), advisory: nil)

        case .explicitDuration:
            let total = budget.explicitDuration ?? 0
            let remaining = total - now.timeIntervalSince(record.objective.createdAt)
            return TimeBudgetStatus(basis: .explicitDuration, isConfirmed: true, deadlineDate: nil,
                                    precision: nil, remaining: remaining,
                                    risk: Self.risk(remaining: remaining), advisory: nil)

        case .workflowConstraint:
            // A real constraint exists but carries no concrete instant here — bounded, dateless.
            return TimeBudgetStatus(basis: .workflowConstraint, isConfirmed: true, deadlineDate: nil,
                                    precision: nil, remaining: nil, risk: .unknown, advisory: nil)

        case .none:
            if try await hasPendingCandidateDeadline(record.references) {
                return TimeBudgetStatus(basis: .none, isConfirmed: false, deadlineDate: nil, precision: nil,
                                        remaining: nil, risk: .unknown,
                                        advisory: "Possible deadline — needs confirmation.")
            }
            return .unbounded
        }
    }

    private static func risk(remaining: TimeInterval) -> DeadlineRisk {
        if remaining < 0 { return .overdue }
        if remaining <= atRiskWindow { return .atRisk }
        return .onTrack
    }

    private func hasPendingCandidateDeadline(_ references: [JobPlanReference]) async throws -> Bool {
        for ref in references where ref.kind == .professionalTask {
            guard let taskID = ref.referenceUUID else { continue }
            if try await !deadlines.candidates(taskID: taskID, statuses: [.pending]).isEmpty { return true }
        }
        return false
    }

    // MARK: - Reference state resolution

    /// Resolve every plan reference to its current state against its live authority. Distinct workflow
    /// runs are fetched once and reused for their step / requirement / artifact references.
    public func resolveStates(_ references: [JobPlanReference]) async throws -> [JobReferenceStatus] {
        var runCache: [UUID: ReopenedWorkflowRun?] = [:]
        var out: [JobReferenceStatus] = []
        for ref in references {
            let state = try await resolveState(ref, runCache: &runCache)
            out.append(JobReferenceStatus(reference: ref, state: state))
        }
        return out
    }

    private func resolveState(_ ref: JobPlanReference,
                              runCache: inout [UUID: ReopenedWorkflowRun?]) async throws -> JobReferenceState {
        switch ref.kind {
        case .professionalTask:
            guard let id = ref.referenceUUID, let task = try await tasks.task(id: id) else { return .unresolved }
            return try await taskState(task)

        case .workflowRun:
            guard let id = ref.referenceUUID, let run = await cachedRun(id, cache: &runCache) else { return .unresolved }
            return Self.runState(run.run.status)

        case .workflowStep:
            guard let stepID = ref.referenceUUID, let runID = ref.workflowRunID,
                  let run = await cachedRun(runID, cache: &runCache),
                  let step = run.stepRuns.first(where: { $0.id == stepID }) else { return .unresolved }
            return Self.stepState(step.status)

        case .workflowRequirement:
            guard let runID = ref.workflowRunID, let run = await cachedRun(runID, cache: &runCache) else { return .unresolved }
            // A blocking, still-open attention item for this requirement means it is blocked.
            if run.attentionItems.contains(where: {
                $0.sourceKind == .requirement && $0.sourceID == ref.referenceID
                    && $0.status == .open && $0.severity == .blocking }) {
                return .blocked
            }
            return run.run.status == .completed ? .complete : .inProgress

        case .evidenceRequirement:
            // Decisive evidence: complete once its context run has finished, otherwise the evidence is
            // still outstanding. Reported honestly as missing rather than guessed complete.
            guard let runID = ref.workflowRunID, let run = await cachedRun(runID, cache: &runCache) else { return .unresolved }
            return run.run.status == .completed ? .complete : .missingEvidence

        case .expectedArtifact:
            guard let runID = ref.workflowRunID, let run = await cachedRun(runID, cache: &runCache) else { return .unresolved }
            return run.artifacts.contains(where: { $0.artifactDefinitionID == ref.referenceID })
                ? .complete : .notStarted
        }
    }

    private func cachedRun(_ id: UUID, cache: inout [UUID: ReopenedWorkflowRun?]) async -> ReopenedWorkflowRun? {
        if let cached = cache[id] { return cached }
        let run = try? await workflows.fetchRun(id)
        cache[id] = run
        return run
    }

    /// Map a task to a job-reference state, honouring blocking dependencies and task nature.
    private func taskState(_ task: ProfessionalTask) async throws -> JobReferenceState {
        switch task.status {
        case .completed: return .complete
        case .cancelled, .archived: return .unresolved
        case .blocked: return .blocked
        case .candidate, .open, .inProgress:
            // A required blocking predecessor that is not complete makes this a hard blocker.
            if try await hasIncompleteBlockingDependency(task) { return .blocked }
            switch task.type {
            case .evidenceRequest: return .missingEvidence
            case .review, .approval: return .waitingReview
            default: return task.status == .inProgress ? .inProgress : .notStarted
            }
        }
    }

    private func hasIncompleteBlockingDependency(_ task: ProfessionalTask) async throws -> Bool {
        let deps = try await tasks.dependencies(taskID: task.id)
        for dep in deps where dep.kind == .blocking {
            let predecessor = try await tasks.task(id: dep.dependsOnTaskID)
            if predecessor?.status != .completed { return true }
        }
        return false
    }

    static func runState(_ status: WorkflowRunStatus) -> JobReferenceState {
        switch status {
        case .completed: return .complete
        case .cancelled, .superseded: return .unresolved
        case .blocked: return .blocked
        case .waitingForHuman: return .waitingReview
        case .draft: return .notStarted
        case .active, .paused: return .inProgress
        }
    }

    static func stepState(_ status: WorkflowStepRunStatus) -> JobReferenceState {
        switch status {
        case .completed, .skipped: return .complete
        case .cancelled, .superseded: return .unresolved
        case .blocked: return .blocked
        case .waiting: return .waitingReview
        case .ready: return .notStarted
        case .active: return .inProgress
        }
    }

    // MARK: - Priority (deterministic)

    /// Assign an item its urgency band. Fixed function of state, role and confirmed-deadline risk —
    /// never of evidence confidence. Precedence follows §16:
    /// hard blocker → confirmed-deadline criticality → required-deliverable dependency →
    /// decisive evidence → required review → optional enrichment.
    public func rationale(for status: JobReferenceStatus, budgetRisk: DeadlineRisk) -> JobPriorityRationale {
        let ref = status.reference
        let incomplete = status.state != .complete && status.state != .unresolved

        if status.state == .blocked {
            return JobPriorityRationale(band: .hardBlocker, reason: "Blocked — the blocker must be cleared first.")
        }
        if incomplete, ref.role == .required, budgetRisk == .overdue || budgetRisk == .atRisk {
            return JobPriorityRationale(band: .confirmedDeadlineCritical,
                                        reason: "Required for the deliverable and under confirmed deadline pressure.")
        }
        if incomplete, ref.role == .required {
            return JobPriorityRationale(band: .requiredDeliverableDependency,
                                        reason: "A required part of the job's deliverable.")
        }
        if status.state == .missingEvidence {
            return JobPriorityRationale(band: .decisiveEvidence, reason: "Decisive evidence is still needed.")
        }
        if status.state == .waitingReview {
            return JobPriorityRationale(band: .requiredReview, reason: "Awaiting a required human review or approval.")
        }
        return JobPriorityRationale(band: .optionalEnrichment, reason: "Supporting or optional work.")
    }

    /// Total order: by band (most urgent first), then plan ordinal, then id — fully deterministic.
    private static func moreUrgent(_ a: PrioritizedJobItem, _ b: PrioritizedJobItem) -> Bool {
        if a.band != b.band { return a.band < b.band }
        if a.reference.ordinal != b.reference.ordinal { return a.reference.ordinal < b.reference.ordinal }
        return a.reference.id.uuidString < b.reference.id.uuidString
    }

    // MARK: - Minimum acceptable deliverable

    private func minimumDeliverableStatus(_ plan: JobExecutionPlan,
                                          statuses: [JobReferenceStatus]) -> MinimumDeliverableStatus {
        let mad = plan.minimumAcceptableDeliverable
        if mad.isEmpty { return .undefined }
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.reference.id, $0.state) })
        let allComplete = mad.references.allSatisfy { byID[$0.id] == .complete }
        return allComplete ? .met : .notMet
    }
}
