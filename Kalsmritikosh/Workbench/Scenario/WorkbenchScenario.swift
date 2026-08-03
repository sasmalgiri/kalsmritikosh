//
//  WorkbenchScenario.swift
//  Kalsmritikosh
//
//  LAB-003 (Stage C) — a scenario is a NON-DESTRUCTIVE analytical overlay on a LAB-001 WorkbenchDataset.
//  It records what a user proposes to change (value overrides, proposed corrections, classifications,
//  annotations, experimental derived values, row inclusion/exclusion) WITHOUT ever mutating canonical
//  evidence, the source cells, or the LAB-002 derivations. The overlay is a durable, append-only
//  OPERATION LOG plus an undo/redo pointer — the current scenario state is always REPLAYED from the log
//  (never a stored final mutated blob), so the full history is reconstructable and undo/redo is a
//  deterministic move of the pointer, not a rewrite of history.
//
//  Permanent truth boundaries this model preserves:
//    scenario value      ≠ canonical evidence
//    proposed correction ≠ confirmed correction
//    classification      ≠ established fact
//    annotation          ≠ Claim
//    experiment          ≠ canonical mutation
//    undo/redo           ≠ evidence-history rewrite
//    promotion           ≠ automatic truth upgrade
//
//  Promotion of scenario content into canonical/professional truth happens ONLY through an explicit
//  human-reviewed action recorded here, routed to an EXISTING authority (user correction / working
//  finding / method run / claim review / work product) — there is no makeCanonical() shortcut, and a
//  rejected promotion leaves canonical state untouched.
//

import Foundation

/// A scenario's lifecycle. `active` accepts operations; `promoted`/`discarded` are terminal for editing
/// but never erase the audit trail.
public nonisolated enum WorkbenchScenarioStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case active
    case discarded
    case promoted
}

/// The closed set of non-destructive overlay operations a scenario supports.
public nonisolated enum WorkbenchScenarioOpKind: String, Codable, Sendable, Equatable, CaseIterable {
    case valueOverride              // a what-if value at a cell
    case proposedCorrection         // a proposed fix (a promotion candidate), carries a reason
    case classification             // a label on a row/cell (never changes the underlying data value)
    case annotation                 // a free-text note on a row/cell
    case derivedExperimentalValue   // a deterministic value recomputed over the scenario projection
    case rowInclusion               // re-include a previously excluded row
    case rowExclusion               // exclude a row from the scenario projection
}

/// An operation is on the LIVE branch or has been ABANDONED (its redo branch was truncated by a new
/// operation after an undo). Abandoned operations are retained for audit but are never re-applied.
public nonisolated enum WorkbenchScenarioOpStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case live
    case abandoned
}

/// What an operation targets. A cell op carries a field; a row op does not.
public nonisolated enum WorkbenchScenarioTargetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case cell
    case row
}

/// The reviewed decision on a promotion attempt.
public nonisolated enum WorkbenchScenarioReviewDecision: String, Codable, Sendable, Equatable, CaseIterable {
    case accepted
    case rejected
}

/// The EXISTING authority a promotion routes into. LAB-003 records the reviewed routing + the resulting
/// object reference; the canonical write itself is performed by that authority — never here.
public nonisolated enum WorkbenchScenarioPromotionDestination: String, Codable, Sendable, Equatable, CaseIterable {
    case userCorrection
    case workingFinding
    case methodRunInput
    case claimReview
    case workProductInput
}

/// Append-only scenario audit vocabulary.
public nonisolated enum WorkbenchScenarioEventAction: String, Codable, Sendable, Equatable, CaseIterable {
    case created
    case operationApplied
    case undone
    case redone
    case reset
    case discarded
    case duplicated
    case promotionAccepted
    case promotionRejected
}

/// One overlay operation in the durable log. `sequence` is monotone and never reused; `beforeValue`
/// captures the projected value at the target immediately before this op (for audit + comparison).
public nonisolated struct WorkbenchScenarioOperation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scenarioID: UUID
    public let sequence: Int
    public let kind: WorkbenchScenarioOpKind
    public let targetKind: WorkbenchScenarioTargetKind
    public let rowID: UUID
    public let fieldID: UUID?
    public let beforeValue: String?
    public let afterValue: String?
    public let reason: String?
    public let status: WorkbenchScenarioOpStatus
    public let actor: String
    public let createdAt: Date

    public nonisolated init(id: UUID, scenarioID: UUID, sequence: Int, kind: WorkbenchScenarioOpKind,
                            targetKind: WorkbenchScenarioTargetKind, rowID: UUID, fieldID: UUID?,
                            beforeValue: String?, afterValue: String?, reason: String?,
                            status: WorkbenchScenarioOpStatus, actor: String, createdAt: Date) {
        self.id = id; self.scenarioID = scenarioID; self.sequence = sequence; self.kind = kind
        self.targetKind = targetKind; self.rowID = rowID; self.fieldID = fieldID
        self.beforeValue = beforeValue; self.afterValue = afterValue; self.reason = reason
        self.status = status; self.actor = actor; self.createdAt = createdAt
    }
}

/// A reviewed promotion attempt (accepted or rejected) + where it routed + the resulting reference.
public nonisolated struct WorkbenchScenarioReview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scenarioID: UUID
    public let operationID: UUID
    public let destination: WorkbenchScenarioPromotionDestination
    public let decision: WorkbenchScenarioReviewDecision
    public let reviewer: String
    public let reason: String?
    public let resultingReference: String?
    public let decidedAt: Date

    public nonisolated init(id: UUID, scenarioID: UUID, operationID: UUID,
                            destination: WorkbenchScenarioPromotionDestination,
                            decision: WorkbenchScenarioReviewDecision, reviewer: String,
                            reason: String?, resultingReference: String?, decidedAt: Date) {
        self.id = id; self.scenarioID = scenarioID; self.operationID = operationID
        self.destination = destination; self.decision = decision; self.reviewer = reviewer
        self.reason = reason; self.resultingReference = resultingReference; self.decidedAt = decidedAt
    }
}

public nonisolated struct WorkbenchScenarioEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let scenarioID: UUID
    public let sequence: Int
    public let scenarioRevision: Int
    public let action: WorkbenchScenarioEventAction
    public let actor: String
    public let detail: String?
    public let occurredAt: Date

    public nonisolated init(id: UUID, scenarioID: UUID, sequence: Int, scenarioRevision: Int,
                            action: WorkbenchScenarioEventAction, actor: String, detail: String?, occurredAt: Date) {
        self.id = id; self.scenarioID = scenarioID; self.sequence = sequence; self.scenarioRevision = scenarioRevision
        self.action = action; self.actor = actor; self.detail = detail; self.occurredAt = occurredAt
    }
}

/// The scenario header, mirroring `workbench_scenarios`. `currentOpSeq` is the undo/redo pointer: the
/// sequence of the last-applied live operation (0 = scenario origin / before any operation).
public nonisolated struct WorkbenchScenario: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let datasetID: UUID
    public let baseDatasetRevision: Int
    public let title: String
    public let status: WorkbenchScenarioStatus
    public let currentOpSeq: Int
    public let revision: Int
    public let actor: String
    public let createdAt: Date
    public let updatedAt: Date

    public nonisolated init(id: UUID, datasetID: UUID, baseDatasetRevision: Int, title: String,
                            status: WorkbenchScenarioStatus, currentOpSeq: Int, revision: Int,
                            actor: String, createdAt: Date, updatedAt: Date) {
        self.id = id; self.datasetID = datasetID; self.baseDatasetRevision = baseDatasetRevision
        self.title = title; self.status = status; self.currentOpSeq = currentOpSeq; self.revision = revision
        self.actor = actor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// The durable scenario as reconstructed from disk (the close/reopen anchor). Operations are ALL of the
/// log (live + abandoned) in sequence order, so the exact undo/redo position is recoverable.
public nonisolated struct WorkbenchScenarioRecord: Sendable, Equatable {
    public let scenario: WorkbenchScenario
    public let operations: [WorkbenchScenarioOperation]
    public let reviews: [WorkbenchScenarioReview]
    public let events: [WorkbenchScenarioEvent]

    public nonisolated init(scenario: WorkbenchScenario, operations: [WorkbenchScenarioOperation],
                            reviews: [WorkbenchScenarioReview], events: [WorkbenchScenarioEvent]) {
        self.scenario = scenario; self.operations = operations; self.reviews = reviews; self.events = events
    }

    /// The applied operations: live, in sequence order, up to and including the pointer.
    public nonisolated var appliedOperations: [WorkbenchScenarioOperation] {
        operations.filter { $0.status == .live && $0.sequence <= scenario.currentOpSeq }.sorted { $0.sequence < $1.sequence }
    }
    /// The redoable operations: live, above the pointer, in sequence order.
    public nonisolated var redoableOperations: [WorkbenchScenarioOperation] {
        operations.filter { $0.status == .live && $0.sequence > scenario.currentOpSeq }.sorted { $0.sequence < $1.sequence }
    }
    public nonisolated var canUndo: Bool { !appliedOperations.isEmpty }
    public nonisolated var canRedo: Bool { !redoableOperations.isEmpty }
}

public nonisolated enum WorkbenchScenarioError: Error, Sendable, Equatable {
    case blankTitle
    case blankActor
    case datasetNotFound(UUID)
    case scenarioNotFound(UUID)
    case notActive(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case rowNotInDataset(UUID)
    case fieldNotInDataset(UUID)
    case fieldRequiredForCellOp
    case nothingToUndo
    case nothingToRedo
    case operationNotFound(UUID)
    case operationNotPromotable(UUID)
    case blankReason
    case parse(WorkbenchExpressionError)
    case unknownField(String)
}
