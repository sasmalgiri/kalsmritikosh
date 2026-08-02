//
//  JobObjective.swift
//  Kalsmritikosh
//
//  TBJ-FINAL. A Job is a DURABLE PLANNING ENVELOPE over the work a user must deliver against a time
//  budget. It is NOT a task and NOT a deadline: it owns no executable state of its own. Every item
//  in its plan (JobPlanReference) points at an object that ALREADY exists in the canonical engine —
//  a ProfessionalTask, a WorkflowRun / step / requirement, an evidence requirement, or an expected
//  artifact. Progress, priority and the time-bounded outcome are DERIVED at plan time from those
//  live authorities (see JobPlanningService) — never stored here as a competing truth, and never as
//  a fabricated completion percentage.
//
//  These are the persisted value shapes, mirroring the v91 tables. Writes go through JobRepository.
//

import Foundation

/// The job-envelope lifecycle. A DISTINCT vocabulary from ProfessionalTaskStatus / WorkflowRunStatus:
/// a user opens a job (active), then explicitly closes or abandons it. Underlying task / workflow
/// completion is a SEPARATE, derived fact and is never inferred from this value.
public nonisolated enum JobLifecycle: String, Codable, Sendable, CaseIterable {
    case active
    case closed
    case abandoned
}

/// What kind of existing authority object a plan item references. TBJ never invents a new executable
/// object — it points at one the canonical engine already owns.
public nonisolated enum JobPlanReferenceKind: String, Codable, Sendable, CaseIterable {
    case professionalTask
    case workflowRun
    case workflowStep
    case workflowRequirement
    case evidenceRequirement
    case expectedArtifact
}

/// How central a plan item is to the job. `required` items gate the job's full completion;
/// items also flagged into the MinimumAcceptableDeliverable gate the minimum safe deliverable.
public nonisolated enum JobPlanReferenceRole: String, Codable, Sendable, CaseIterable {
    case required
    case supporting
    case optional
}

/// One durable item in the JobExecutionPlan: a typed pointer to an existing authority object.
public nonisolated struct JobPlanReference: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let jobID: UUID
    public let kind: JobPlanReferenceKind
    /// The referenced object's identifier — a UUID string for task/run/step, or a stable string id
    /// for a requirement / artifact definition. Stored verbatim; interpreted by kind.
    public let referenceID: String
    /// Context run for a step / requirement / artifact reference (soft reference).
    public let workflowRunID: UUID?
    public let role: JobPlanReferenceRole
    /// True when this item is part of the MinimumAcceptableDeliverable.
    public let isMinimumDeliverable: Bool
    public let ordinal: Int
    public let note: String?
    public let createdAt: Date

    public nonisolated init(id: UUID, jobID: UUID, kind: JobPlanReferenceKind, referenceID: String,
                            workflowRunID: UUID?, role: JobPlanReferenceRole,
                            isMinimumDeliverable: Bool, ordinal: Int, note: String?, createdAt: Date) {
        self.id = id
        self.jobID = jobID
        self.kind = kind
        self.referenceID = referenceID
        self.workflowRunID = workflowRunID
        self.role = role
        self.isMinimumDeliverable = isMinimumDeliverable
        self.ordinal = ordinal
        self.note = note
        self.createdAt = createdAt
    }

    /// The referenced id parsed as a UUID, when the kind uses UUID identity (task/run/step).
    public nonisolated var referenceUUID: UUID? { UUID(uuidString: referenceID) }
}

/// The persisted job envelope, mirroring `job_objectives`.
public nonisolated struct JobObjective: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let workspaceID: UUID
    public let title: String
    public let detail: String?
    public let budget: TimeBudget
    /// The run the job is primarily executed through, when the job is workflow-driven (soft reference).
    public let primaryWorkflowRunID: UUID?
    public let lifecycle: JobLifecycle
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let closureReason: String?

    public nonisolated init(id: UUID, workspaceID: UUID, title: String, detail: String?,
                            budget: TimeBudget, primaryWorkflowRunID: UUID?, lifecycle: JobLifecycle,
                            revision: Int, createdAt: Date, updatedAt: Date,
                            closedAt: Date?, closureReason: String?) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.detail = detail
        self.budget = budget
        self.primaryWorkflowRunID = primaryWorkflowRunID
        self.lifecycle = lifecycle
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.closedAt = closedAt
        self.closureReason = closureReason
    }
}

/// What a job's plan changed. Append-only per-job audit ledger (`job_events`).
public nonisolated enum JobEventAction: String, Codable, Sendable, CaseIterable {
    case created
    case budgetSet
    case referenceAdded
    case referenceRemoved
    case referenceUpdated
    case closed
    case abandoned
    case reopened
}

/// One durable audit entry for the job envelope.
public nonisolated struct JobEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let jobID: UUID
    public let sequence: Int
    public let jobRevision: Int
    public let action: JobEventAction
    public let actor: String
    public let detail: String?
    public let occurredAt: Date

    public nonisolated init(id: UUID, jobID: UUID, sequence: Int, jobRevision: Int,
                            action: JobEventAction, actor: String, detail: String?, occurredAt: Date) {
        self.id = id
        self.jobID = jobID
        self.sequence = sequence
        self.jobRevision = jobRevision
        self.action = action
        self.actor = actor
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

/// The durable JobExecutionPlan: the objective plus its ordered references. This is exactly what
/// JobRepository.reopen(_:) reconstructs so a job resumes with the same context after relaunch —
/// no LLM memory, no reconstruction from prose.
public nonisolated struct JobExecutionPlan: Sendable, Equatable {
    public let objective: JobObjective
    public let references: [JobPlanReference]

    public nonisolated init(objective: JobObjective, references: [JobPlanReference]) {
        self.objective = objective
        self.references = references
    }

    /// The MinimumAcceptableDeliverable: the subset of references flagged into it (ordered).
    public nonisolated var minimumAcceptableDeliverable: MinimumAcceptableDeliverable {
        MinimumAcceptableDeliverable(references: references.filter(\.isMinimumDeliverable)
            .sorted { $0.ordinal < $1.ordinal })
    }

    /// References that gate FULL job completion (required role), ordered.
    public nonisolated var requiredReferences: [JobPlanReference] {
        references.filter { $0.role == .required }.sorted { $0.ordinal < $1.ordinal }
    }
}

/// The named minimum-safe-deliverable view over a plan: the flagged subset that must be finished for
/// the job to have delivered something usable even if the full objective cannot be met in time.
public nonisolated struct MinimumAcceptableDeliverable: Sendable, Equatable {
    public let references: [JobPlanReference]

    public nonisolated init(references: [JobPlanReference]) { self.references = references }

    /// True when the job's author defined no minimum deliverable (the whole plan is the deliverable).
    public nonisolated var isEmpty: Bool { references.isEmpty }
}

/// The full durable state of a job as reconstructed from disk: objective + plan + audit history.
/// Returned by JobRepository.reopen(_:) — the resume anchor.
public nonisolated struct JobRecord: Sendable, Equatable {
    public let plan: JobExecutionPlan
    public let events: [JobEvent]

    public nonisolated init(plan: JobExecutionPlan, events: [JobEvent]) {
        self.plan = plan
        self.events = events
    }

    public nonisolated var objective: JobObjective { plan.objective }
    public nonisolated var references: [JobPlanReference] { plan.references }
}

/// Errors from the job persistence + planning layer. Fail-closed: an invalid reference or an
/// unconfirmed deadline is rejected, never silently coerced.
public nonisolated enum JobError: Error, Sendable, Equatable {
    case blankTitle
    case blankActor
    case workspaceNotFound(UUID)
    case jobNotFound(UUID)
    case malformedBudget
    /// A budget named a confirmed deadline that does not resolve in `deadlines` (a candidate or a
    /// nonexistent id is refused — a DeadlineCandidate can never become a budget).
    case deadlineNotConfirmed(UUID)
    case workflowRunNotFound(UUID)
    case crossWorkspaceReference(kind: String, id: String)
    case blankReference
    case duplicateReference
    case referenceNotFound(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case invalidLifecycleTransition(from: JobLifecycle, to: JobLifecycle)
    case jobNotActive(JobLifecycle)
}
