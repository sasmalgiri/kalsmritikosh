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
//

import Foundation
import CryptoKit

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
        now: Date
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
            return .skippedDuplicate(existing)
        case .started(let started):
            execution = started
        }

        // 6. Produce exactly ONE proposal output (adapter dispatch on the closed
        // action enum), then complete the receipt. On failure, mark it failed —
        // no proposal output survives.
        do {
            let output = try await produceOutput(
                definition: definition, request: request, now: now)
            let resultJSON = try Self.resultJSON(kind: output.kind, id: output.id)
            let done = try await executions.complete(
                id: execution.id, outputKind: output.kind, outputID: output.id,
                resultJSON: resultJSON, now: now)
            return .produced(done)
        } catch {
            _ = try? await executions.markFailed(
                id: execution.id, reason: "\(error)", now: now)
            throw error
        }
    }

    // MARK: - Action adapters (closed enum dispatch — NO persona switch)

    private func produceOutput(
        definition: PersonaAutomationDefinition,
        request: PersonaAutomationRequest,
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
            let task = try await tasks.createCandidate(
                workspaceID: request.workspaceID, primaryIssueID: request.primaryIssueID,
                title: request.title, detail: request.detail, type: request.taskType,
                priority: request.priority, owner: nil,
                origin: .automationProposed, proposedBy: proposedBy, at: now)
            return (.candidateTask, task.id)

        case .createMissingEvidenceRequest:
            let task = try await tasks.createCandidate(
                workspaceID: request.workspaceID, primaryIssueID: request.primaryIssueID,
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
