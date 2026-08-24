//
//  WorkflowRun.swift
//  Kalsmritikosh
//
//  PJE-003 — Persistent workflow run models.
//  All run, step, decision, artifact, attention, checkpoint, and event types.
//  No lifecycle transition policy — PJE-004 owns that.
//  No executors, no requirement evaluation, no AppState wiring.
//

import Foundation

// MARK: - Run status vocabulary

public enum WorkflowRunStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case active
    case paused
    case waitingForHuman
    case blocked
    case completed
    case cancelled
    case superseded
}

// MARK: - Step-run status vocabulary

public enum WorkflowStepRunStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case active
    case waiting
    case blocked
    case completed
    case skipped
    case cancelled
    case superseded
}

// MARK: - WorkflowRun

public nonisolated struct WorkflowRun: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workspaceID: Workspace.ID

    public let applicationDefinitionID: ApplicationDefinitionID
    public let applicationDefinitionVersion: Int

    public let workflowDefinitionID: WorkflowDefinitionID
    public let workflowDefinitionVersion: Int

    public let title: String?
    public let status: WorkflowRunStatus

    public let currentStepDefinitionID: StepDefinitionID?
    public let currentStepRunID: UUID?

    public let contractSnapshotJSON: String
    public let contractSnapshotSHA256: String
    public let snapshotSchemaVersion: Int

    public let revision: Int

    public let parentRunID: UUID?
    public let supersededByRunID: UUID?

    public let createdAt: Date
    public let updatedAt: Date
    public let startedAt: Date?
    public let pausedAt: Date?
    public let completedAt: Date?
    public let cancelledAt: Date?
    public let cancellationReason: String?

    public nonisolated init(
        id: UUID,
        workspaceID: Workspace.ID,
        applicationDefinitionID: ApplicationDefinitionID,
        applicationDefinitionVersion: Int,
        workflowDefinitionID: WorkflowDefinitionID,
        workflowDefinitionVersion: Int,
        title: String?,
        status: WorkflowRunStatus,
        currentStepDefinitionID: StepDefinitionID?,
        currentStepRunID: UUID?,
        contractSnapshotJSON: String,
        contractSnapshotSHA256: String,
        snapshotSchemaVersion: Int,
        revision: Int,
        parentRunID: UUID?,
        supersededByRunID: UUID?,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        pausedAt: Date?,
        completedAt: Date?,
        cancelledAt: Date?,
        cancellationReason: String?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.applicationDefinitionID = applicationDefinitionID
        self.applicationDefinitionVersion = applicationDefinitionVersion
        self.workflowDefinitionID = workflowDefinitionID
        self.workflowDefinitionVersion = workflowDefinitionVersion
        self.title = title
        self.status = status
        self.currentStepDefinitionID = currentStepDefinitionID
        self.currentStepRunID = currentStepRunID
        self.contractSnapshotJSON = contractSnapshotJSON
        self.contractSnapshotSHA256 = contractSnapshotSHA256
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.revision = revision
        self.parentRunID = parentRunID
        self.supersededByRunID = supersededByRunID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.completedAt = completedAt
        self.cancelledAt = cancelledAt
        self.cancellationReason = cancellationReason
    }
}

// MARK: - WorkflowStepRun

public struct WorkflowStepRun: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID

    public let stepDefinitionID: StepDefinitionID
    public let stepKind: WorkflowStepKind

    public let attempt: Int
    public let sequence: Int

    public let status: WorkflowStepRunStatus

    public let executorID: String?
    public let executorVersion: String?

    public let inputJSON: String
    public let stateJSON: String
    public let outputJSON: String?

    public let stateSHA256: String

    public let enteredAt: Date
    public let updatedAt: Date
    public let completedAt: Date?

    public nonisolated init(
        id: UUID,
        workflowRunID: UUID,
        stepDefinitionID: StepDefinitionID,
        stepKind: WorkflowStepKind,
        attempt: Int,
        sequence: Int,
        status: WorkflowStepRunStatus,
        executorID: String?,
        executorVersion: String?,
        inputJSON: String,
        stateJSON: String,
        outputJSON: String?,
        stateSHA256: String,
        enteredAt: Date,
        updatedAt: Date,
        completedAt: Date?
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.stepDefinitionID = stepDefinitionID
        self.stepKind = stepKind
        self.attempt = attempt
        self.sequence = sequence
        self.status = status
        self.executorID = executorID
        self.executorVersion = executorVersion
        self.inputJSON = inputJSON
        self.stateJSON = stateJSON
        self.outputJSON = outputJSON
        self.stateSHA256 = stateSHA256
        self.enteredAt = enteredAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

// MARK: - Decision vocabulary

public enum WorkflowDecisionKind: String, Codable, CaseIterable, Sendable {
    case branchSelection
    case humanDecision
    case humanApproval
}

public enum WorkflowDecisionActorKind: String, Codable, CaseIterable, Sendable {
    case human
    case deterministicRule
    case system
}

// MARK: - WorkflowDecision

public struct WorkflowDecision: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let stepRunID: UUID

    public let decisionKey: String
    public let kind: WorkflowDecisionKind
    public let selectedOption: String

    public let rationale: String?

    public let actorKind: WorkflowDecisionActorKind
    public let actorIdentifier: String?

    public let supersedesDecisionID: UUID?

    public let metadataJSON: String
    public let decidedAt: Date

    public nonisolated init(
        id: UUID,
        workflowRunID: UUID,
        stepRunID: UUID,
        decisionKey: String,
        kind: WorkflowDecisionKind,
        selectedOption: String,
        rationale: String?,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        supersedesDecisionID: UUID?,
        metadataJSON: String,
        decidedAt: Date
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.stepRunID = stepRunID
        self.decisionKey = decisionKey
        self.kind = kind
        self.selectedOption = selectedOption
        self.rationale = rationale
        self.actorKind = actorKind
        self.actorIdentifier = actorIdentifier
        self.supersedesDecisionID = supersedesDecisionID
        self.metadataJSON = metadataJSON
        self.decidedAt = decidedAt
    }
}

// MARK: - Artifact vocabulary

public enum WorkflowArtifactKind: String, Codable, CaseIterable, Sendable {
    case attachment
    case generatedProduct
    case workProductRun
    case methodResult
}

// MARK: - WorkflowArtifact

public nonisolated struct WorkflowArtifact: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let stepRunID: UUID?

    public let artifactDefinitionID: String
    public let kind: WorkflowArtifactKind
    public let label: String

    public let workProductRunID: UUID?

    public let targetKind: String?
    public let targetID: String?
    public let referenceURI: String?

    public let mediaType: String?
    public let contentSHA256: String?
    public let metadataJSON: String

    public let supersedesArtifactID: UUID?
    public let createdAt: Date

    public nonisolated init(
        id: UUID,
        workflowRunID: UUID,
        stepRunID: UUID?,
        artifactDefinitionID: String,
        kind: WorkflowArtifactKind,
        label: String,
        workProductRunID: UUID?,
        targetKind: String?,
        targetID: String?,
        referenceURI: String?,
        mediaType: String?,
        contentSHA256: String?,
        metadataJSON: String,
        supersedesArtifactID: UUID?,
        createdAt: Date
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.stepRunID = stepRunID
        self.artifactDefinitionID = artifactDefinitionID
        self.kind = kind
        self.label = label
        self.workProductRunID = workProductRunID
        self.targetKind = targetKind
        self.targetID = targetID
        self.referenceURI = referenceURI
        self.mediaType = mediaType
        self.contentSHA256 = contentSHA256
        self.metadataJSON = metadataJSON
        self.supersedesArtifactID = supersedesArtifactID
        self.createdAt = createdAt
    }
}

// MARK: - Attention vocabulary

public enum WorkflowAttentionSeverity: String, Codable, CaseIterable, Sendable {
    case informational
    case advisory
    case blocking
}

public enum WorkflowAttentionStatus: String, Codable, CaseIterable, Sendable {
    case open
    case resolved
    case dismissed
}

public enum WorkflowAttentionSourceKind: String, Codable, CaseIterable, Sendable {
    case requirement
    case validation
    case system
    case user
    case automation
}

// MARK: - WorkflowAttentionItem

public struct WorkflowAttentionItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let stepRunID: UUID?

    public let sourceKind: WorkflowAttentionSourceKind
    public let sourceID: String?

    public let severity: WorkflowAttentionSeverity
    public let status: WorkflowAttentionStatus

    public let title: String
    public let detail: String?

    public let createdAt: Date
    public let resolvedAt: Date?
    public let resolvedBy: String?
    public let resolutionNote: String?

    public nonisolated init(
        id: UUID,
        workflowRunID: UUID,
        stepRunID: UUID?,
        sourceKind: WorkflowAttentionSourceKind,
        sourceID: String?,
        severity: WorkflowAttentionSeverity,
        status: WorkflowAttentionStatus,
        title: String,
        detail: String?,
        createdAt: Date,
        resolvedAt: Date?,
        resolvedBy: String?,
        resolutionNote: String?
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.stepRunID = stepRunID
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.severity = severity
        self.status = status
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.resolutionNote = resolutionNote
    }
}

// MARK: - Checkpoint vocabulary

public enum WorkflowCheckpointReason: String, Codable, CaseIterable, Sendable {
    case explicitSave
    case pause
    case beforeDecision
    case afterDecision
    case beforeArtifactBuild
    case completion
    case recovery
}

// MARK: - WorkflowCheckpoint

public struct WorkflowCheckpoint: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID
    public let runRevision: Int

    public let reason: WorkflowCheckpointReason

    public let snapshotJSON: String
    public let snapshotSHA256: String

    public let createdAt: Date

    public nonisolated init(
        id: UUID,
        workflowRunID: UUID,
        runRevision: Int,
        reason: WorkflowCheckpointReason,
        snapshotJSON: String,
        snapshotSHA256: String,
        createdAt: Date
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.runRevision = runRevision
        self.reason = reason
        self.snapshotJSON = snapshotJSON
        self.snapshotSHA256 = snapshotSHA256
        self.createdAt = createdAt
    }
}

// MARK: - WorkflowCheckpointPayload

/// Canonical snapshot of the full mutable run state at checkpoint time.
/// Excludes prior checkpoints, registry objects, DB handles, and UI state.
public nonisolated struct WorkflowCheckpointPayload: Codable, Hashable, Sendable {
    public let run: WorkflowRun
    public let stepRuns: [WorkflowStepRun]
    public let decisions: [WorkflowDecision]
    public let artifacts: [WorkflowArtifact]
    public let attentionItems: [WorkflowAttentionItem]
    public let events: [WorkflowRunEvent]
    public let lastEventSequence: Int
    public let runRevision: Int

    public nonisolated init(
        run: WorkflowRun,
        stepRuns: [WorkflowStepRun],
        decisions: [WorkflowDecision],
        artifacts: [WorkflowArtifact],
        attentionItems: [WorkflowAttentionItem],
        events: [WorkflowRunEvent],
        lastEventSequence: Int,
        runRevision: Int
    ) {
        self.run = run
        self.stepRuns = stepRuns
        self.decisions = decisions
        self.artifacts = artifacts
        self.attentionItems = attentionItems
        self.events = events
        self.lastEventSequence = lastEventSequence
        self.runRevision = runRevision
    }
}

// MARK: - Event vocabulary

public enum WorkflowRunEventType: String, Codable, CaseIterable, Sendable {
    case runCreated
    case runStateChanged
    case stepRunInserted
    case stepRunUpdated
    case decisionRecorded
    case artifactRecorded
    case attentionCreated
    case attentionUpdated
    case checkpointCreated
    case runSupersessionLinked
}

// MARK: - WorkflowRunEvent

public nonisolated struct WorkflowRunEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let workflowRunID: UUID

    public let sequence: Int
    public let runRevision: Int

    public let type: WorkflowRunEventType

    public let actorKind: WorkflowDecisionActorKind
    public let actorIdentifier: String?

    public let payloadJSON: String
    public let occurredAt: Date

    public nonisolated init(
        id: UUID,
        workflowRunID: UUID,
        sequence: Int,
        runRevision: Int,
        type: WorkflowRunEventType,
        actorKind: WorkflowDecisionActorKind,
        actorIdentifier: String?,
        payloadJSON: String,
        occurredAt: Date
    ) {
        self.id = id
        self.workflowRunID = workflowRunID
        self.sequence = sequence
        self.runRevision = runRevision
        self.type = type
        self.actorKind = actorKind
        self.actorIdentifier = actorIdentifier
        self.payloadJSON = payloadJSON
        self.occurredAt = occurredAt
    }
}

// MARK: - WorkflowRunTimestampPatch

/// Carries optional timestamp overrides applied by updateRunState.
/// nil means "set to NULL". To keep an existing value, pass the current value.
public struct WorkflowRunTimestampPatch: Sendable {
    public let startedAt: Date?
    public let pausedAt: Date?
    public let completedAt: Date?
    public let cancelledAt: Date?

    public nonisolated init(
        startedAt: Date? = nil,
        pausedAt: Date? = nil,
        completedAt: Date? = nil,
        cancelledAt: Date? = nil
    ) {
        self.startedAt = startedAt
        self.pausedAt = pausedAt
        self.completedAt = completedAt
        self.cancelledAt = cancelledAt
    }
}

// MARK: - ReopenedWorkflowRun

/// The fully verified aggregate reopened from storage.
/// All hashes verified; event sequence and revision agreement confirmed.
public struct ReopenedWorkflowRun: Sendable, Hashable {
    public let run: WorkflowRun
    public let contract: WorkflowRunContractSnapshot
    public let stepRuns: [WorkflowStepRun]
    public let decisions: [WorkflowDecision]
    public let artifacts: [WorkflowArtifact]
    public let checkpoints: [WorkflowCheckpoint]
    public let attentionItems: [WorkflowAttentionItem]
    public let events: [WorkflowRunEvent]

    public nonisolated init(
        run: WorkflowRun,
        contract: WorkflowRunContractSnapshot,
        stepRuns: [WorkflowStepRun],
        decisions: [WorkflowDecision],
        artifacts: [WorkflowArtifact],
        checkpoints: [WorkflowCheckpoint],
        attentionItems: [WorkflowAttentionItem],
        events: [WorkflowRunEvent]
    ) {
        self.run = run
        self.contract = contract
        self.stepRuns = stepRuns
        self.decisions = decisions
        self.artifacts = artifacts
        self.checkpoints = checkpoints
        self.attentionItems = attentionItems
        self.events = events
    }
}
