//
//  WorkflowAutomationExecution.swift
//  Kalsmritikosh
//
//  PJE-010 — the automation execution ledger model. An idempotent, tamper-
//  evident AUDIT RECEIPT for one runtime automation firing. It is NOT a task,
//  deadline, evidence or attention store: proposal OUTPUTS live in their
//  existing canonical tables. This record only proves a version-pinned
//  automation ran, what proposal it produced, and its idempotency identity.
//

import Foundation

public enum WorkflowAutomationExecutionStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case started
    case succeeded
    case failed
    case skippedDuplicate
}

/// The kind of proposal-layer object an execution produced. Deliberately a
/// closed set of PROPOSAL outputs — never a confirmed Claim, Deadline, approval,
/// privilege decision, or workflow completion.
public enum WorkflowAutomationOutputKind: String, Codable, Sendable, CaseIterable, Equatable {
    case attentionItem
    case candidateTask
    case candidateDeadline
}

public nonisolated struct WorkflowAutomationExecution: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let workspaceID: UUID
    public let workflowRunID: UUID?
    public let stepRunID: UUID?
    public let applicationDefinitionID: String
    public let automationDefinitionID: String
    public let automationDefinitionVersion: Int
    public let triggerKind: PersonaAutomationTriggerKind
    public let triggerEventKey: String
    public let actionKind: PersonaAutomationActionKind
    public let idempotencyKey: String
    public let requestJSON: String
    public let requestSHA256: String
    public let status: WorkflowAutomationExecutionStatus
    public let outputKind: WorkflowAutomationOutputKind?
    public let outputID: UUID?
    public let resultJSON: String?
    public let resultSHA256: String?
    public let startedAt: Date
    public let completedAt: Date?
    public let failureReason: String?

    public nonisolated init(
        id: UUID,
        workspaceID: UUID,
        workflowRunID: UUID?,
        stepRunID: UUID?,
        applicationDefinitionID: String,
        automationDefinitionID: String,
        automationDefinitionVersion: Int,
        triggerKind: PersonaAutomationTriggerKind,
        triggerEventKey: String,
        actionKind: PersonaAutomationActionKind,
        idempotencyKey: String,
        requestJSON: String,
        requestSHA256: String,
        status: WorkflowAutomationExecutionStatus,
        outputKind: WorkflowAutomationOutputKind?,
        outputID: UUID?,
        resultJSON: String?,
        resultSHA256: String?,
        startedAt: Date,
        completedAt: Date?,
        failureReason: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workflowRunID = workflowRunID
        self.stepRunID = stepRunID
        self.applicationDefinitionID = applicationDefinitionID
        self.automationDefinitionID = automationDefinitionID
        self.automationDefinitionVersion = automationDefinitionVersion
        self.triggerKind = triggerKind
        self.triggerEventKey = triggerEventKey
        self.actionKind = actionKind
        self.idempotencyKey = idempotencyKey
        self.requestJSON = requestJSON
        self.requestSHA256 = requestSHA256
        self.status = status
        self.outputKind = outputKind
        self.outputID = outputID
        self.resultJSON = resultJSON
        self.resultSHA256 = resultSHA256
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.failureReason = failureReason
    }
}

public enum WorkflowAutomationExecutionError: Error, Equatable, Sendable {
    case executionNotFound(UUID)
    case requestHashMismatch(UUID)
    case resultHashMismatch(UUID)
}
