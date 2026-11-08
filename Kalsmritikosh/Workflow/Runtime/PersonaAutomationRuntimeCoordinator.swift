//
//  PersonaAutomationRuntimeCoordinator.swift
//  Kalsmritikosh
//
//  PJE-010 Part B — the automation runtime. Executes a version-pinned automation
//  definition by dispatching its ONE restricted action to a PROPOSAL-LAYER
//  output created through the existing canonical repositories, and records an
//  idempotent, tamper-evident execution receipt.
//
//  Locked rules:
//    * Automation creates PROPOSALS only — advisory attention items, candidate
//      tasks, candidate deadlines, review items, missing-evidence requests.
//    * It never confirms a Claim, promotes a candidate, confirms a Deadline,
//      records human approval, marks privilege, completes a workflow, or
//      finalizes a work product.
//    * Dispatch is on the CLOSED action enum — there is NO persona switch.
//    * Idempotency: the same automation def/version + scope + trigger event
//      produces ONE logical output; replay returns the prior execution.
//    * attentionCreated triggers are recursion-guarded.
//    * Smart-map S8 (AUTO-03 / AUTO-04 / AUTO-09): a task output's identity is DERIVED from its receipt, so a run
//      interrupted between the output and the receipt's completion is resumed (`recovery: .resumeInterrupted`) by
//      finding that output — never by making a second one; a failed receipt can be retried deliberately
//      (`recovery: .retryFailed`) under the same idempotency key, with its attempt count recorded.
//

import Foundation
import CryptoKit
import os

public struct PersonaAutomationTriggerEvent: Sendable, Equatable {
    public let kind: PersonaAutomationTriggerKind
    /// Stable identity of the delivered event (run/step/attention identity, a
    /// scheduled slot, or an explicit manual token). Drives idempotency.
    public let eventKey: String
    public let recursionDepth: Int
    /// True when this trigger was itself caused by an automation-created object.
    public let originIsAutomation: Bool
    /// Explicit opt-in for responding to automation-created attention items.
    public let respondToAutomationOrigin: Bool

    public nonisolated init(
        kind: PersonaAutomationTriggerKind,
        eventKey: String,
        recursionDepth: Int = 0,
        originIsAutomation: Bool = false,
        respondToAutomationOrigin: Bool = false
    ) {
        self.kind = kind
        self.eventKey = eventKey
        self.recursionDepth = recursionDepth
        self.originIsAutomation = originIsAutomation
        self.respondToAutomationOrigin = respondToAutomationOrigin
    }
}

/// Everything an action adapter needs. Fields are optional per action; the
/// coordinator validates the ones its action requires.
public struct PersonaAutomationRequest: Sendable {
    public let workspaceID: UUID
    public let workflowRunID: UUID?
    public let stepRunID: UUID?
    public let title: String
    public let detail: String?
    public let severity: WorkflowAttentionSeverity
    public let taskType: ProfessionalTaskType
    public let priority: ProfessionalTaskPriority
    public let primaryIssueID: UUID?
    public let targetTaskID: UUID?
    public let deadlineValue: DeadlineValue?
    public let deadlineKind: DeadlineKind?
    public let evidenceReferences: [WorkflowProvenanceReference]

    public nonisolated init(
        workspaceID: UUID,
        workflowRunID: UUID? = nil,
        stepRunID: UUID? = nil,
        title: String,
        detail: String? = nil,
        severity: WorkflowAttentionSeverity = .advisory,
        taskType: ProfessionalTaskType = .action,
        priority: ProfessionalTaskPriority = .normal,
        primaryIssueID: UUID? = nil,
        targetTaskID: UUID? = nil,
        deadlineValue: DeadlineValue? = nil,
        deadlineKind: DeadlineKind? = nil,
        evidenceReferences: [WorkflowProvenanceReference] = []
    ) {
        self.workspaceID = workspaceID
        self.workflowRunID = workflowRunID
        self.stepRunID = stepRunID
        self.title = title
        self.detail = detail
        self.severity = severity
        self.taskType = taskType
        self.priority = priority
        self.primaryIssueID = primaryIssueID
        self.targetTaskID = targetTaskID
        self.deadlineValue = deadlineValue
        self.deadlineKind = deadlineKind
        self.evidenceReferences = evidenceReferences
    }
}

/// Smart-map S8 — what a repeated delivery of an already-reserved idempotency key may do.
public enum PersonaAutomationRecovery: Sendable, Equatable {
    /// Default: a repeated delivery returns the prior execution (whatever its state).
    case none
    /// A receipt left `started` by an interrupted run is completed — with the output already made when there is one.
    case resumeInterrupted
    /// …and a `failed` receipt is tried again (its attempt count goes up; it keeps its idempotency key).
    case retryFailed
}

public enum PersonaAutomationOutcome: Sendable, Equatable {
    case produced(WorkflowAutomationExecution)
    case skippedDuplicate(WorkflowAutomationExecution)
    case suppressedRecursion
}

public enum PersonaAutomationRuntimeError: Error, Equatable, Sendable {
    case triggerMismatch(expected: PersonaAutomationTriggerKind, delivered: PersonaAutomationTriggerKind)
    case evidenceReferenceDenied
    case attentionOutputRequiresRun
    case candidateDeadlineRequiresTaskAndValue
    case maxRecursionDepthExceeded
    case outputNotObserved
}

public actor PersonaAutomationRuntimeCoordinator {

    private let executions: WorkflowAutomationExecutionRepository
    private let workflowRuns: WorkflowRunRepository
    private let tasks: ProfessionalTaskRepository
    private let deadlines: DeadlineRepository
    private let validator: WorkflowProvenanceReferenceValidator?
    private let maxRecursionDepth: Int

    public init(
        executions: WorkflowAutomationExecutionRepository,
        workflowRuns: WorkflowRunRepository,
        tasks: ProfessionalTaskRepository,
        deadlines: DeadlineRepository,
        validator: WorkflowProvenanceReferenceValidator? = nil,
        maxRecursionDepth: Int = 1
    ) {
        self.executions = executions
        self.workflowRuns = workflowRuns
        self.tasks = tasks
        self.deadlines = deadlines
        self.validator = validator
        self.maxRecursionDepth = maxRecursionDepth
    }

    /// Execute one version-pinned automation. `definition` must be the resolved
    /// definition frozen in the run's contract (not a latest-lookup).
    public func run(
        definition: PersonaAutomationDefinition,
        applicationID: ApplicationDefinitionID,
        request: PersonaAutomationRequest,
        trigger: PersonaAutomationTriggerEvent,
        now: Date,
        recovery: PersonaAutomationRecovery = .none
    ) async throws -> PersonaAutomationOutcome {
        // 1. The delivered trigger must match the frozen definition's trigger.
        guard trigger.kind == definition.trigger else {
            throw PersonaAutomationRuntimeError.triggerMismatch(
                expected: definition.trigger, delivered: trigger.kind)
        }

        // 2. Recursion guard for automation-created attention items.
        if trigger.kind == .attentionCreated, trigger.originIsAutomation, !trigger.respondToAutomationOrigin {
            return .suppressedRecursion
        }
        guard trigger.recursionDepth <= maxRecursionDepth else {
            throw PersonaAutomationRuntimeError.maxRecursionDepthExceeded
        }

        // 3. Validate any canonical evidence references (fail closed).
        if let validator, !request.evidenceReferences.isEmpty {
            do {
                try await validator.validate(
                    request.evidenceReferences,
                    workflowRunID: request.workflowRunID ?? UUID(),
                    workspaceID: request.workspaceID)
            } catch {
                throw PersonaAutomationRuntimeError.evidenceReferenceDenied
            }
        }

        // 4. Idempotency identity + canonical request JSON.
        let idempotencyKey = Self.idempotencyKey(
            definition: definition, applicationID: applicationID, request: request, trigger: trigger)
        let requestJSON = try Self.requestJSON(
            definition: definition, applicationID: applicationID, request: request, trigger: trigger)

        // 5. Reserve the idempotency key; a replay returns the prior execution.
        let begun = try await executions.begin(
            workspaceID: request.workspaceID,
            workflowRunID: request.workflowRunID,
            stepRunID: request.stepRunID,
            applicationDefinitionID: applicationID.rawValue,
            automationDefinitionID: definition.id.rawValue,
            automationDefinitionVersion: definition.version,
            triggerKind: trigger.kind,
            triggerEventKey: trigger.eventKey,
            actionKind: definition.action,
            idempotencyKey: idempotencyKey,
            requestJSON: requestJSON,
            now: now)

        let execution: WorkflowAutomationExecution
        switch begun {
        case .duplicate(let existing):
            switch (existing.status, recovery) {
            case (.started, .resumeInterrupted), (.started, .retryFailed):
                execution = existing                        // interrupted: finish it (the output is found, not remade)
            case (.failed, .retryFailed):
                execution = try await executions.restart(id: existing.id, now: now)
            default:
                return .skippedDuplicate(existing)
            }
        case .started(let started):
            execution = started
        }

        // 6. Produce exactly ONE proposal output (adapter dispatch on the closed
        // action enum), then complete the receipt. On failure, mark it failed —
        // no proposal output survives.
        do {
            let output = try await produceOutput(
                definition: definition, request: request, outputID: Self.outputID(for: execution.id), now: now)
            let resultJSON = try Self.resultJSON(kind: output.kind, id: output.id)
            let done = try await executions.complete(
                id: execution.id, outputKind: output.kind, outputID: output.id,
                resultJSON: resultJSON, now: now)
            return .produced(done)
        } catch {
            do {
                _ = try await executions.markFailed(id: execution.id, reason: "\(error)", now: now)
            } catch let markError {
                KalsmritikoshLog.app.error("Automation receipt could not be marked failed: \(String(describing: markError), privacy: .public)")
            }
            throw error
        }
    }

    // MARK: - Action adapters (closed enum dispatch — NO persona switch)

    /// The identity a task output of `executionID` gets: stable for the receipt, distinct from it.
    public nonisolated static func outputID(for executionID: UUID) -> UUID {
        let d = Array(SHA256.hash(data: Data("automation-output|\(executionID.uuidString)".utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], (d[6] & 0x0F) | 0x50, d[7],
                           (d[8] & 0x3F) | 0x80, d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    private func produceOutput(
        definition: PersonaAutomationDefinition,
        request: PersonaAutomationRequest,
        outputID: UUID,
        now: Date
    ) async throws -> (kind: WorkflowAutomationOutputKind, id: UUID) {
        let proposedBy = "\(definition.id.rawValue)@\(definition.version)"
        switch definition.action {
        case .createSuggestion:
            let id = try await attentionOutput(
                definition: definition, request: request, severity: .advisory, now: now)
            return (.attentionItem, id)

        case .createAttentionItem:
            let id = try await attentionOutput(
                definition: definition, request: request, severity: request.severity, now: now)
            return (.attentionItem, id)

        case .createReviewQueueItem:
            let id = try await attentionOutput(
                definition: definition, request: request, severity: request.severity, now: now)
            return (.attentionItem, id)

        case .createCandidateTask:
            if let made = try await tasks.task(id: outputID) { return (.candidateTask, made.id) }   // resumed run
            let task = try await tasks.createCandidate(
                id: outputID, workspaceID: request.workspaceID, primaryIssueID: request.primaryIssueID,
                title: request.title, detail: request.detail, type: request.taskType,
                priority: request.priority, owner: nil,
                origin: .automationProposed, proposedBy: proposedBy, at: now)
            return (.candidateTask, task.id)

        case .createMissingEvidenceRequest:
            if let made = try await tasks.task(id: outputID) { return (.candidateTask, made.id) }   // resumed run
            let task = try await tasks.createCandidate(
                id: outputID, workspaceID: request.workspaceID, primaryIssueID: request.primaryIssueID,
                title: request.title, detail: request.detail, type: .evidenceRequest,
                priority: request.priority, owner: nil,
                origin: .automationProposed, proposedBy: proposedBy, at: now)
            return (.candidateTask, task.id)

        case .createCandidateDeadline:
            guard let taskID = request.targetTaskID,
                  let value = request.deadlineValue,
                  let kind = request.deadlineKind else {
                throw PersonaAutomationRuntimeError.candidateDeadlineRequiresTaskAndValue
            }
            let candidate = try await deadlines.createCandidate(
                taskID: taskID, value: value, kind: kind,
                origin: .automationProposed, confidence: nil, proposedBy: proposedBy,
                ruleID: nil, ruleVersion: nil, at: now)
            return (.candidateDeadline, candidate.id)
        }
    }

    /// Create a workflow attention item with a `.automation` source identity that
    /// carries the automation definition/version. Automation may create the item
    /// but never resolves or dismisses it.
    private func attentionOutput(
        definition: PersonaAutomationDefinition,
        request: PersonaAutomationRequest,
        severity: WorkflowAttentionSeverity,
        now: Date
    ) async throws -> UUID {
        guard let runID = request.workflowRunID else {
            throw PersonaAutomationRuntimeError.attentionOutputRequiresRun
        }
        let before = try await workflowRuns.fetchRun(runID)
        let beforeIDs = Set(before.attentionItems.map(\.id))
        let sourceID = "\(definition.id.rawValue)@\(definition.version)"
        let after = try await workflowRuns.createAttentionItem(
            runID: runID, stepRunID: request.stepRunID,
            sourceKind: .automation, sourceID: sourceID,
            severity: severity, title: request.title, detail: request.detail,
            expectedRevision: before.run.revision,
            actorKind: .system, actorIdentifier: sourceID, now: now)
        guard let newItem = after.attentionItems.first(where: { !beforeIDs.contains($0.id) }) else {
            throw PersonaAutomationRuntimeError.outputNotObserved
        }
        return newItem.id
    }

    // MARK: - Identity / canonical encoding

    private static func idempotencyKey(
        definition: PersonaAutomationDefinition,
        applicationID: ApplicationDefinitionID,
        request: PersonaAutomationRequest,
        trigger: PersonaAutomationTriggerEvent
    ) -> String {
        let composed = [
            applicationID.rawValue,
            definition.id.rawValue,
            String(definition.version),
            request.workspaceID.uuidString,
            request.workflowRunID?.uuidString ?? "-",
            request.stepRunID?.uuidString ?? "-",
            trigger.kind.rawValue,
            trigger.eventKey,
            definition.action.rawValue
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(composed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct RequestIdentity: Codable {
        let applicationDefinitionID: String
        let automationDefinitionID: String
        let automationDefinitionVersion: Int
        let workspaceID: String
        let workflowRunID: String?
        let stepRunID: String?
        let triggerKind: String
        let triggerEventKey: String
        let actionKind: String
        let title: String
    }

    private static func requestJSON(
        definition: PersonaAutomationDefinition,
        applicationID: ApplicationDefinitionID,
        request: PersonaAutomationRequest,
        trigger: PersonaAutomationTriggerEvent
    ) throws -> String {
        let identity = RequestIdentity(
            applicationDefinitionID: applicationID.rawValue,
            automationDefinitionID: definition.id.rawValue,
            automationDefinitionVersion: definition.version,
            workspaceID: request.workspaceID.uuidString,
            workflowRunID: request.workflowRunID?.uuidString,
            stepRunID: request.stepRunID?.uuidString,
            triggerKind: trigger.kind.rawValue,
            triggerEventKey: trigger.eventKey,
            actionKind: definition.action.rawValue,
            title: request.title)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(identity), as: UTF8.self)
    }

    private struct OutputResult: Codable {
        let outputKind: String
        let outputID: String
    }

    private static func resultJSON(kind: WorkflowAutomationOutputKind, id: UUID) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(
            OutputResult(outputKind: kind.rawValue, outputID: id.uuidString)), as: UTF8.self)
    }
}
