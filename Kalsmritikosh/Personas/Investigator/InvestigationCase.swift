//
//  InvestigationCase.swift
//  Kalsmritikosh
//
//  INV-01-A (Investigator persona pack — Case Intake & Scope). The Investigator is a professional LENS
//  over the ONE canonical engine. An InvestigationCase is the persona-specific state for a matter: its
//  purpose, scope, time window, requested outcome, and — crucially — the set of canonical sources
//  authorized for the investigation. It REFERENCES canonical sources / deadlines / evidence by id; it
//  never copies them and never forks a second evidence, task, deadline, workflow or SensitiveScope
//  authority. The in-scope source set is the HARD evidence boundary: a source being present in the
//  workspace does not put it inside the active investigation until it is added in-scope here.
//
//  Truth boundaries this model preserves:
//    available in workspace ≠ authorized for this investigation
//    possible deadline       ≠ confirmed deadline
//    case scope              ≠ canonical evidence
//    recommendation          ≠ decision
//

import Foundation

public nonisolated enum InvestigationCaseStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case open
    case scopeConfirmed
    case closed
}

/// The kind of canonical source identity a scope binding references (soft reference, never a copy).
public nonisolated enum InvestigationSourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case logicalSource
    case sourceVersion
    case workspaceSource
}

public nonisolated enum InvestigationCaseEventAction: String, Codable, Sendable, Equatable, CaseIterable {
    case created
    case scopeSet
    case sourceIncluded
    case sourceExcluded
    case scopeConfirmed
    case deadlineBound
    case reopened
}

/// One case→source disposition: `inScope` authorizes the source for the investigation; a source with
/// `inScope == false` is explicitly excluded. A source not present at all is simply not authorized.
public nonisolated struct InvestigationScopeSource: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sourceRef: String
    public let sourceKind: InvestigationSourceKind
    public let inScope: Bool
    public let note: String?
    public let createdAt: Date

    public nonisolated init(id: UUID, caseID: UUID, sourceRef: String, sourceKind: InvestigationSourceKind,
                            inScope: Bool, note: String?, createdAt: Date) {
        self.id = id; self.caseID = caseID; self.sourceRef = sourceRef; self.sourceKind = sourceKind
        self.inScope = inScope; self.note = note; self.createdAt = createdAt
    }
}

public nonisolated struct InvestigationCaseEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let caseID: UUID
    public let sequence: Int
    public let caseRevision: Int
    public let action: InvestigationCaseEventAction
    public let actor: String
    public let detail: String?
    public let occurredAt: Date

    public nonisolated init(id: UUID, caseID: UUID, sequence: Int, caseRevision: Int,
                            action: InvestigationCaseEventAction, actor: String, detail: String?, occurredAt: Date) {
        self.id = id; self.caseID = caseID; self.sequence = sequence; self.caseRevision = caseRevision
        self.action = action; self.actor = actor; self.detail = detail; self.occurredAt = occurredAt
    }
}

/// The case header, mirroring `investigation_cases`. `confirmedDeadlineID` may reference ONLY a confirmed
/// `deadlines` row; `possibleDeadlineNote` carries an advisory candidate that is never authoritative.
public nonisolated struct InvestigationCase: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let workspaceID: UUID
    public let title: String
    public let purpose: String?
    public let scopeStatement: String?
    public let outOfScopeStatement: String?
    public let timeWindowStart: Date?
    public let timeWindowEnd: Date?
    public let status: InvestigationCaseStatus
    public let confirmedDeadlineID: UUID?
    public let possibleDeadlineNote: String?
    public let revision: Int
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, workspaceID: UUID, title: String, purpose: String?, scopeStatement: String?,
                            outOfScopeStatement: String?, timeWindowStart: Date?, timeWindowEnd: Date?,
                            status: InvestigationCaseStatus, confirmedDeadlineID: UUID?, possibleDeadlineNote: String?,
                            revision: Int, actor: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.workspaceID = workspaceID; self.title = title; self.purpose = purpose
        self.scopeStatement = scopeStatement; self.outOfScopeStatement = outOfScopeStatement
        self.timeWindowStart = timeWindowStart; self.timeWindowEnd = timeWindowEnd; self.status = status
        self.confirmedDeadlineID = confirmedDeadlineID; self.possibleDeadlineNote = possibleDeadlineNote
        self.revision = revision; self.actor = actor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// The durable case as reconstructed from disk (the reopen/resume anchor).
public nonisolated struct InvestigationCaseRecord: Sendable, Equatable {
    public let caseHeader: InvestigationCase
    public let sources: [InvestigationScopeSource]
    public let events: [InvestigationCaseEvent]

    public nonisolated init(caseHeader: InvestigationCase, sources: [InvestigationScopeSource], events: [InvestigationCaseEvent]) {
        self.caseHeader = caseHeader; self.sources = sources; self.events = events
    }

    /// The HARD evidence boundary: the canonical source references authorized for this investigation
    /// (in-scope only), in deterministic order. Downstream Ask / Full Evidence / Methods / DataLab /
    /// exports must intersect with this set — never the whole archive.
    public nonisolated var authorizedSourceRefs: [String] {
        sources.filter { $0.inScope }.map { $0.sourceRef }.sorted()
    }
    /// Sources explicitly excluded from the investigation (recorded, not silently dropped).
    public nonisolated var excludedSourceRefs: [String] {
        sources.filter { !$0.inScope }.map { $0.sourceRef }.sorted()
    }
    public nonisolated func isAuthorized(_ sourceRef: String) -> Bool {
        sources.contains { $0.sourceRef == sourceRef && $0.inScope }
    }
}

public nonisolated enum InvestigationCaseError: Error, Sendable, Equatable {
    case blankTitle
    case blankActor
    case workspaceNotFound(UUID)
    case caseNotFound(UUID)
    case caseClosed(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case blankSourceRef
    case deadlineNotConfirmed(UUID)   // a candidate can never bind as the authoritative deadline
}
