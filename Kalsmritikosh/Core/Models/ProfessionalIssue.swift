//
//  ProfessionalIssue.swift
//  Kalsmritikosh
//
//  OPS-001 — the shared, persona-neutral professional ISSUE: something that requires attention,
//  review, investigation or resolution (an unresolved question, an evidence concern, a
//  contradiction to examine, a missing-information issue, a risk, a lead, a decision to make, a
//  scope concern). An Issue is WORKFLOW STATE. It is NOT a canonical Claim, contradiction record,
//  gap record, task, confirmed finding, root cause or legal conclusion — it REFERENCES those
//  canonical objects by id (IssueLink) and never copies or mutates them. Resolving/dismissing an
//  Issue never changes any canonical evidence assessment.
//

import Foundation

/// The professional-workflow classification of an Issue. `contradictionReview` /
/// `missingEvidence` describe the WORKFLOW issue; the canonical contradiction or gap itself is
/// linked by id, never embedded.
public enum IssueType: String, Codable, Sendable, CaseIterable {
    case question
    case evidenceConcern
    case contradictionReview
    case missingEvidence
    case lead
    case risk
    case scopeConcern
    case decisionRequired
    case findingCandidate
    case other
}

/// Workflow status. `resolved` means the WORKING issue was addressed — it does NOT confirm a
/// linked Claim, resolve a canonical contradiction, or prove anything about missing evidence.
public enum IssueStatus: String, Codable, Sendable, CaseIterable {
    case open
    case inReview
    case blocked
    case resolved
    case dismissed
    case superseded
    case archived
}

/// Workflow urgency — never evidence strength.
public enum IssuePriority: String, Codable, Sendable, CaseIterable {
    case low
    case normal
    case high
    case critical
}

public struct ProfessionalIssue: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let workspaceID: UUID

    public var title: String
    public var detail: String?
    public var type: IssueType
    public var status: IssueStatus
    public var priority: IssuePriority

    public let createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?

    public nonisolated init(id: UUID, workspaceID: UUID, title: String, detail: String?,
                            type: IssueType, status: IssueStatus, priority: IssuePriority,
                            createdAt: Date, updatedAt: Date, closedAt: Date?) {
        self.id = id; self.workspaceID = workspaceID
        self.title = title; self.detail = detail
        self.type = type; self.status = status; self.priority = priority
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.closedAt = closedAt
    }
}

/// The canonical objects an Issue may reference (by id only). Future targets — workflowRun,
/// methodRun, task, workProductRun — are reserved for later Stage 2–4 units and deliberately NOT
/// modelled yet (no unresolved-FK placeholders for objects that don't exist).
public enum IssueLinkTarget: Sendable, Equatable, Hashable {
    case claim(UUID)
    case event(UUID)
    case entity(UUID)
    case evidenceBlock(UUID)
    case knowledgeObject(UUID)
    case sourceVersion(UUID)
    case contradiction(UUID)
    case gap(UUID)

    /// Stable storage discriminator (professional_issue_links.target_kind).
    public var kind: String {
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

    public var targetID: UUID {
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

/// How the Issue relates to the target — user/workflow organisation ONLY; a link role never
/// alters the canonical evidence assessment.
public enum IssueLinkRole: String, Codable, Sendable, CaseIterable {
    case related
    case triggeredBy
    case supports
    case opposes
    case requiresReview
    case addresses
}

public struct IssueLink: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let issueID: UUID
    public let target: IssueLinkTarget
    public let role: IssueLinkRole
    public let createdAt: Date

    public nonisolated init(id: UUID, issueID: UUID, target: IssueLinkTarget,
                            role: IssueLinkRole, createdAt: Date) {
        self.id = id; self.issueID = issueID; self.target = target
        self.role = role; self.createdAt = createdAt
    }
}

/// Append-only lifecycle ledger action.
public enum IssueReviewAction: String, Codable, Sendable, CaseIterable {
    case created
    case statusChanged
    case corrected
    case resolved
    case reopened
    case dismissed
    case superseded
    case archived
}

/// One append-only lifecycle record. Every status transition MUST add one — a status is never
/// silently updated without its ledger entry.
public struct IssueReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let issueID: UUID
    public let action: IssueReviewAction
    public let priorStatus: IssueStatus?
    public let newStatus: IssueStatus?
    public let reviewer: String
    public let reason: String?
    public let reviewedAt: Date

    public nonisolated init(id: UUID, issueID: UUID, action: IssueReviewAction,
                            priorStatus: IssueStatus?, newStatus: IssueStatus?,
                            reviewer: String, reason: String?, reviewedAt: Date) {
        self.id = id; self.issueID = issueID; self.action = action
        self.priorStatus = priorStatus; self.newStatus = newStatus
        self.reviewer = reviewer; self.reason = reason; self.reviewedAt = reviewedAt
    }
}
