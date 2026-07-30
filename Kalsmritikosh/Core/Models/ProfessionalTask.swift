//
//  ProfessionalTask.swift
//  Kalsmritikosh
//
//  OPS-002 — the shared Task and Deadline Engine models.
//
//  NON-NEGOTIABLE TRUTH RULE: `DeadlineCandidate ≠ Deadline`. A candidate is a PROPOSAL-layer
//  object (extracted / rule-derived / model-proposed / user-proposed date). Confirmation creates a
//  NEW `Deadline` row and preserves the candidate with its origin, evidence and review history —
//  a candidate row is never reused as a confirmed deadline, and an extracted or model-proposed
//  date is never inserted directly as a Deadline. Task completion is workflow completion, never
//  confirmation of linked evidence; priority is urgency, never evidence strength.
//

import Foundation

// MARK: - Deadline value (reuses the canonical DatePrecision — never a second precision enum)

/// A date + its COARSEST TRUE precision + originating time zone. Precision travels with the
/// timestamp (never pad a month-precision date to midnight and drop the flag).
public nonisolated struct DeadlineValue: Sendable, Equatable, Codable {
    public let date: Date
    public let precision: DatePrecision
    public let timeZoneIdentifier: String

    public nonisolated init(date: Date, precision: DatePrecision, timeZoneIdentifier: String) {
        self.date = date
        self.precision = precision
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Precisions a CANDIDATE may carry. Coarser than .month cannot even be proposed as a
    /// deadline candidate (it isn't an actionable date).
    public nonisolated static let candidatePrecisions: Set<DatePrecision> = [.month, .day, .minute, .instant]

    /// Precisions a CONFIRMED operational deadline requires. A .month candidate must first be
    /// refined through an explicit reviewed correction — never silently converted to the first or
    /// last day of the month.
    public nonisolated static let confirmablePrecisions: Set<DatePrecision> = [.day, .minute, .instant]
}

// MARK: - Task

public enum ProfessionalTaskType: String, Codable, Sendable, CaseIterable {
    case action
    case evidenceRequest
    case review
    case decision
    case followUp
    case correction
    case approval
    case other
}

public enum ProfessionalTaskStatus: String, Codable, Sendable, CaseIterable {
    case candidate
    case open
    case inProgress
    case blocked
    case completed
    case cancelled
    case archived
}

/// Where the task came from. `sourceExtraction` / `modelProposed` / `automationProposed` tasks
/// MUST begin as `.candidate`; only a user or an identified deterministic rule can open them.
public enum ProfessionalTaskOrigin: String, Codable, Sendable, CaseIterable {
    case userCreated
    case deterministicRule
    case sourceExtraction
    case modelProposed
    case automationProposed
    case importedLegacy
}

public enum ProfessionalTaskPriority: String, Codable, Sendable, CaseIterable {
    case low
    case normal
    case high
    case critical
}

public nonisolated struct ProfessionalTask: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let workspaceID: UUID
    public let primaryIssueID: UUID?

    public var title: String
    public var detail: String?
    public var type: ProfessionalTaskType
    public var status: ProfessionalTaskStatus
    public var priority: ProfessionalTaskPriority
    public var owner: String?

    public let origin: ProfessionalTaskOrigin
    public let createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var archivedAt: Date?

    public nonisolated init(id: UUID, workspaceID: UUID, primaryIssueID: UUID?, title: String,
                            detail: String?, type: ProfessionalTaskType, status: ProfessionalTaskStatus,
                            priority: ProfessionalTaskPriority, owner: String?,
                            origin: ProfessionalTaskOrigin, createdAt: Date, updatedAt: Date,
                            completedAt: Date?, archivedAt: Date?) {
        self.id = id; self.workspaceID = workspaceID; self.primaryIssueID = primaryIssueID
        self.title = title; self.detail = detail; self.type = type; self.status = status
        self.priority = priority; self.owner = owner; self.origin = origin
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.completedAt = completedAt; self.archivedAt = archivedAt
    }
}

// MARK: - Dependencies

public enum TaskDependencyKind: String, Codable, Sendable, CaseIterable {
    case blocking
    case informational
}

public nonisolated struct TaskDependency: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let dependsOnTaskID: UUID
    public let kind: TaskDependencyKind
    public let createdAt: Date

    public nonisolated init(id: UUID, taskID: UUID, dependsOnTaskID: UUID,
                            kind: TaskDependencyKind, createdAt: Date) {
        self.id = id; self.taskID = taskID; self.dependsOnTaskID = dependsOnTaskID
        self.kind = kind; self.createdAt = createdAt
    }
}

// MARK: - Deadline candidate (proposal layer)

public enum DeadlineCandidateOrigin: String, Codable, Sendable, CaseIterable {
    case sourceExtraction
    case deterministicRule
    case modelProposed
    case userProposed
    /// PJE-010: a runtime automation proposed this candidate date. Like every
    /// other candidate origin it is a PROPOSAL only — never a confirmed Deadline,
    /// and never a deterministic-rule or model classification.
    case automationProposed
    case importedLegacy
}

public enum DeadlineCandidateStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case promoted
    case rejected
    case superseded
    case archived
}

/// A PROPOSED deadline. `confidence` is extraction/proposal confidence ONLY — never legal
/// certainty or evidence strength.
public nonisolated struct DeadlineCandidate: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let value: DeadlineValue
    public let kind: DeadlineKind
    public let origin: DeadlineCandidateOrigin
    public let confidence: Double?
    public let proposedBy: String
    public let ruleID: String?
    public let ruleVersion: String?
    public let status: DeadlineCandidateStatus
    public let createdAt: Date
    public let reviewedAt: Date?

    public nonisolated init(id: UUID, taskID: UUID, value: DeadlineValue, kind: DeadlineKind,
                            origin: DeadlineCandidateOrigin, confidence: Double?, proposedBy: String,
                            ruleID: String?, ruleVersion: String?, status: DeadlineCandidateStatus,
                            createdAt: Date, reviewedAt: Date?) {
        self.id = id; self.taskID = taskID; self.value = value; self.kind = kind
        self.origin = origin; self.confidence = confidence; self.proposedBy = proposedBy
        self.ruleID = ruleID; self.ruleVersion = ruleVersion; self.status = status
        self.createdAt = createdAt; self.reviewedAt = reviewedAt
    }
}

// MARK: - Confirmed deadline

public enum DeadlineKind: String, Codable, Sendable, CaseIterable {
    case due
    case review
    case response
    case filing
    case renewal
    case expiry
    case followUp
    case other
}

/// NOTE: there is deliberately NO `.overdue` status — overdue is CALCULATED from an active
/// deadline and a comparison time, never persisted by an autonomous status change.
public enum DeadlineStatus: String, Codable, Sendable, CaseIterable {
    case active
    case satisfied
    case cancelled
    case superseded
    case archived
}

public enum DeadlineConfirmationKind: String, Codable, Sendable, CaseIterable {
    case user
    case deterministicRule
    // Source extraction and model proposal are NEVER confirmation kinds.
}

/// Who/what confirmed a candidate into a real Deadline. User confirmation requires a non-blank
/// confirmer; rule confirmation requires a non-blank rule id + version AND at least one exact
/// evidence link on the candidate.
public nonisolated struct DeadlineConfirmation: Sendable, Equatable, Codable {
    public let kind: DeadlineConfirmationKind
    public let confirmedBy: String
    public let confirmedAt: Date
    public let reason: String?
    public let ruleID: String?
    public let ruleVersion: String?

    public nonisolated init(kind: DeadlineConfirmationKind, confirmedBy: String, confirmedAt: Date,
                            reason: String?, ruleID: String?, ruleVersion: String?) {
        self.kind = kind; self.confirmedBy = confirmedBy; self.confirmedAt = confirmedAt
        self.reason = reason; self.ruleID = ruleID; self.ruleVersion = ruleVersion
    }
}

public nonisolated struct Deadline: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    /// The candidate this deadline was promoted from (UNIQUE — one candidate → at most one
    /// Deadline). Nil only for a direct user-created confirmed deadline.
    public let sourceCandidateID: UUID?
    public let value: DeadlineValue
    public let kind: DeadlineKind
    public let status: DeadlineStatus
    public let confirmation: DeadlineConfirmation
    public let createdAt: Date
    public var updatedAt: Date
    public var satisfiedAt: Date?
    public var archivedAt: Date?

    public nonisolated init(id: UUID, taskID: UUID, sourceCandidateID: UUID?, value: DeadlineValue,
                            kind: DeadlineKind, status: DeadlineStatus,
                            confirmation: DeadlineConfirmation, createdAt: Date, updatedAt: Date,
                            satisfiedAt: Date?, archivedAt: Date?) {
        self.id = id; self.taskID = taskID; self.sourceCandidateID = sourceCandidateID
        self.value = value; self.kind = kind; self.status = status; self.confirmation = confirmation
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.satisfiedAt = satisfiedAt; self.archivedAt = archivedAt
    }

    /// Overdue is a CALCULATION on an active deadline — never a stored, autonomously-mutated status.
    public nonisolated func isOverdue(at date: Date) -> Bool {
        status == .active && date > value.date
    }
}

// MARK: - Evidence links (IDs only — never copied content)

public enum TaskEvidenceLinkScope: Sendable, Equatable, Hashable {
    case task
    case deadlineCandidate(UUID)
    case deadline(UUID)

    public nonisolated var kind: String {
        switch self {
        case .task:              return "task"
        case .deadlineCandidate: return "deadlineCandidate"
        case .deadline:          return "deadline"
        }
    }

    public nonisolated var scopeID: UUID? {
        switch self {
        case .task:                        return nil
        case .deadlineCandidate(let id):   return id
        case .deadline(let id):            return id
        }
    }

    public nonisolated init?(kind: String, scopeID: UUID?) {
        switch (kind, scopeID) {
        case ("task", _):                       self = .task
        case ("deadlineCandidate", let id?):    self = .deadlineCandidate(id)
        case ("deadline", let id?):             self = .deadline(id)
        default:                                return nil
        }
    }
}

/// Same canonical target set as IssueLinkTarget (both validated by the shared
/// WorkflowTargetValidator — identical fail-closed existence + workspace-boundary rules).
public enum TaskEvidenceTarget: Sendable, Equatable, Hashable {
    case claim(UUID)
    case event(UUID)
    case entity(UUID)
    case evidenceBlock(UUID)
    case knowledgeObject(UUID)
    case sourceVersion(UUID)
    case contradiction(UUID)
    case gap(UUID)

    public nonisolated var kind: String {
        switch self {
        case .claim:           return "claim"
        case .event:           return "event"
        case .entity:          return "entity"
        case .evidenceBlock:   return "evidenceBlock"
        case .knowledgeObject: return "knowledgeObject"
        case .sourceVersion:   return "sourceVersion"
        case .contradiction:   return "contradiction"
        case .gap:             return "gap"
        }
    }

    public nonisolated var targetID: UUID {
        switch self {
        case .claim(let id), .event(let id), .entity(let id), .evidenceBlock(let id),
             .knowledgeObject(let id), .sourceVersion(let id), .contradiction(let id), .gap(let id):
            return id
        }
    }

    public nonisolated init?(kind: String, targetID: UUID) {
        switch kind {
        case "claim":           self = .claim(targetID)
        case "event":           self = .event(targetID)
        case "entity":          self = .entity(targetID)
        case "evidenceBlock":   self = .evidenceBlock(targetID)
        case "knowledgeObject": self = .knowledgeObject(targetID)
        case "sourceVersion":   self = .sourceVersion(targetID)
        case "contradiction":   self = .contradiction(targetID)
        case "gap":             self = .gap(targetID)
        default:                return nil
        }
    }
}

public enum TaskEvidenceLinkRole: String, Codable, Sendable, CaseIterable {
    case basis
    case context
    case requiresReview
    case completionEvidence
    case deadlineBasis
}

public nonisolated struct TaskEvidenceLink: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let scope: TaskEvidenceLinkScope
    public let target: TaskEvidenceTarget
    public let role: TaskEvidenceLinkRole
    public let createdAt: Date

    public nonisolated init(id: UUID, taskID: UUID, scope: TaskEvidenceLinkScope,
                            target: TaskEvidenceTarget, role: TaskEvidenceLinkRole, createdAt: Date) {
        self.id = id; self.taskID = taskID; self.scope = scope
        self.target = target; self.role = role; self.createdAt = createdAt
    }
}

// MARK: - Append-only audit ledgers

public enum ProfessionalTaskReviewAction: String, Codable, Sendable, CaseIterable {
    case created
    case candidateConfirmed
    case statusChanged
    case completed
    case reopened
    case cancelled
    case archived
    case corrected
}

/// The kind of authority behind a confirmation review row (v70). Persisted so the ledger can
/// PROVE which authority opened a task — never just the actor's display name.
public enum TaskAuthorityKind: String, Codable, Sendable, CaseIterable {
    case user
    case deterministicRule
}

public nonisolated struct ProfessionalTaskReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let taskID: UUID
    public let action: ProfessionalTaskReviewAction
    public let priorStatus: ProfessionalTaskStatus?
    public let newStatus: ProfessionalTaskStatus?
    public let reviewer: String
    public let reason: String?
    public let reviewedAt: Date
    /// Structured confirmation provenance (v70). Set on `created` (createConfirmed) and
    /// `candidateConfirmed` rows; nil on other actions and on rows predating v70.
    public let authorityKind: TaskAuthorityKind?
    public let ruleID: String?
    public let ruleVersion: String?

    public nonisolated init(id: UUID, taskID: UUID, action: ProfessionalTaskReviewAction,
                            priorStatus: ProfessionalTaskStatus?, newStatus: ProfessionalTaskStatus?,
                            reviewer: String, reason: String?, reviewedAt: Date,
                            authorityKind: TaskAuthorityKind? = nil,
                            ruleID: String? = nil, ruleVersion: String? = nil) {
        self.id = id; self.taskID = taskID; self.action = action
        self.priorStatus = priorStatus; self.newStatus = newStatus
        self.reviewer = reviewer; self.reason = reason; self.reviewedAt = reviewedAt
        self.authorityKind = authorityKind; self.ruleID = ruleID; self.ruleVersion = ruleVersion
    }
}

public enum DeadlineCandidateReviewAction: String, Codable, Sendable, CaseIterable {
    case created
    case corrected
    case promoted
    case rejected
    case superseded
    case archived
}

public nonisolated struct DeadlineCandidateReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let candidateID: UUID
    public let action: DeadlineCandidateReviewAction
    public let reviewer: String
    public let reason: String?
    public let reviewedAt: Date

    public nonisolated init(id: UUID, candidateID: UUID, action: DeadlineCandidateReviewAction,
                            reviewer: String, reason: String?, reviewedAt: Date) {
        self.id = id; self.candidateID = candidateID; self.action = action
        self.reviewer = reviewer; self.reason = reason; self.reviewedAt = reviewedAt
    }
}

public enum DeadlineReviewAction: String, Codable, Sendable, CaseIterable {
    case confirmed
    case satisfied
    case cancelled
    case superseded
    case archived
    case corrected
}

public nonisolated struct DeadlineReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let deadlineID: UUID
    public let action: DeadlineReviewAction
    public let reviewer: String
    public let reason: String?
    public let reviewedAt: Date

    public nonisolated init(id: UUID, deadlineID: UUID, action: DeadlineReviewAction,
                            reviewer: String, reason: String?, reviewedAt: Date) {
        self.id = id; self.deadlineID = deadlineID; self.action = action
        self.reviewer = reviewer; self.reason = reason; self.reviewedAt = reviewedAt
    }
}
