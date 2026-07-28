//
//  WorkflowLifecycleTypes.swift
//  Kalsmritikosh
//
//  PJE-004 — Workflow Lifecycle State Machine.
//  Core lifecycle vocabulary: actions, actor, payloads, transition selector,
//  condition evaluation protocol, structural projection, errors.
//

import Foundation

// MARK: - Lifecycle action vocabulary

public enum WorkflowLifecycleAction: String, Codable, CaseIterable, Sendable {
    case start
    case save
    case pause
    case resume
    case block
    case unblock
    case requestHumanDecision
    case advance
    case chooseBranch
    case recordHumanDecision
    case recordHumanApproval
    case returnToPriorStep
    case complete
    case cancel
    case supersede
}

// MARK: - Lifecycle actor

public struct WorkflowLifecycleActor: Codable, Hashable, Sendable {
    public let kind: WorkflowDecisionActorKind
    public let identifier: String?
    public let role: String?

    public nonisolated init(
        kind: WorkflowDecisionActorKind,
        identifier: String?,
        role: String?
    ) {
        self.kind = kind
        self.identifier = identifier
        self.role = role
    }

    public static func human(
        identifier: String,
        role: String? = nil
    ) throws -> WorkflowLifecycleActor {
        guard !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WorkflowLifecycleError.humanIdentifierRequired
        }
        if let role = role {
            guard !role.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw WorkflowLifecycleError.humanRoleRequired
            }
        }
        return WorkflowLifecycleActor(kind: .human, identifier: identifier, role: role)
    }

    public static func deterministicRule(
        identifier: String
    ) throws -> WorkflowLifecycleActor {
        guard !identifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WorkflowLifecycleError.humanIdentifierRequired
        }
        return WorkflowLifecycleActor(kind: .deterministicRule, identifier: identifier, role: nil)
    }

    public static nonisolated let system = WorkflowLifecycleActor(kind: .system, identifier: nil, role: nil)
}

// MARK: - Step entry payload

public struct WorkflowStepEntryPayload: Codable, Hashable, Sendable {
    public let inputJSON: String
    public let stateJSON: String
    public let executorID: String?
    public let executorVersion: String?

    public nonisolated init(
        inputJSON: String = "{}",
        stateJSON: String = "{}",
        executorID: String? = nil,
        executorVersion: String? = nil
    ) {
        self.inputJSON = inputJSON
        self.stateJSON = stateJSON
        self.executorID = executorID
        self.executorVersion = executorVersion
    }

    public static nonisolated let empty = WorkflowStepEntryPayload(inputJSON: "{}", stateJSON: "{}")
}

// MARK: - Step completion payload

public struct WorkflowStepCompletionPayload: Codable, Hashable, Sendable {
    public let stateJSON: String?
    public let outputJSON: String?

    public nonisolated init(stateJSON: String? = nil, outputJSON: String? = nil) {
        self.stateJSON = stateJSON
        self.outputJSON = outputJSON
    }
}

// MARK: - Transition selector

public enum WorkflowTransitionSelector: Hashable, Sendable {
    case label(String)
    case targetStepID(StepDefinitionID)
}

// MARK: - Condition evaluation

public struct WorkflowTransitionConditionContext: Sendable {
    public let run: WorkflowRun
    public let currentStepRun: WorkflowStepRun
    public let workflow: ValidatedWorkflowDefinition
    public let transition: WorkflowTransitionDefinition

    public nonisolated init(
        run: WorkflowRun,
        currentStepRun: WorkflowStepRun,
        workflow: ValidatedWorkflowDefinition,
        transition: WorkflowTransitionDefinition
    ) {
        self.run = run
        self.currentStepRun = currentStepRun
        self.workflow = workflow
        self.transition = transition
    }
}

public enum WorkflowConditionEvaluation: Sendable, Equatable {
    case satisfied(evaluatorID: String, detail: String?)
    case notSatisfied(evaluatorID: String, detail: String?)
    case unavailable
}

public protocol WorkflowTransitionConditionEvaluating: Sendable {
    func evaluate(
        condition: String,
        context: WorkflowTransitionConditionContext
    ) async throws -> WorkflowConditionEvaluation
}

/// Default evaluator: returns `.unavailable` for every condition.
/// Conditioned transitions fail closed — supply an explicit evaluator to permit them.
public struct RejectingWorkflowTransitionConditionEvaluator: WorkflowTransitionConditionEvaluating, Sendable {
    public nonisolated init() {}

    public func evaluate(
        condition: String,
        context: WorkflowTransitionConditionContext
    ) async throws -> WorkflowConditionEvaluation {
        return .unavailable
    }
}

// MARK: - Structural action projection

public struct WorkflowLifecycleProjection: Sendable {
    public let runStatus: WorkflowRunStatus
    public let currentStep: PersonaWorkflowStepDefinition?
    public let currentStepRun: WorkflowStepRun?
    public let structuralActions: Set<WorkflowLifecycleAction>
    public let forwardTransitions: [WorkflowTransitionDefinition]
    public let returnTransitions: [WorkflowTransitionDefinition]

    public nonisolated init(
        runStatus: WorkflowRunStatus,
        currentStep: PersonaWorkflowStepDefinition?,
        currentStepRun: WorkflowStepRun?,
        structuralActions: Set<WorkflowLifecycleAction>,
        forwardTransitions: [WorkflowTransitionDefinition],
        returnTransitions: [WorkflowTransitionDefinition]
    ) {
        self.runStatus = runStatus
        self.currentStep = currentStep
        self.currentStepRun = currentStepRun
        self.structuralActions = structuralActions
        self.forwardTransitions = forwardTransitions
        self.returnTransitions = returnTransitions
    }
}

// MARK: - Supersession result

public struct WorkflowSupersessionResult: Sendable {
    public let superseded: ReopenedWorkflowRun
    public let replacement: ReopenedWorkflowRun

    public nonisolated init(superseded: ReopenedWorkflowRun, replacement: ReopenedWorkflowRun) {
        self.superseded = superseded
        self.replacement = replacement
    }
}

// MARK: - Lifecycle errors

public enum WorkflowLifecycleError: Error, Equatable, Sendable {
    // Terminal state
    case terminalRunImmutable(runID: UUID, status: WorkflowRunStatus)
    // Illegal transitions
    case illegalRunTransition(from: WorkflowRunStatus, action: WorkflowLifecycleAction)
    case illegalStepTransition(from: WorkflowStepRunStatus, to: WorkflowStepRunStatus)
    // Aggregate invariants
    case missingCurrentStep(UUID)
    case currentStepReferenceMismatch(UUID)
    case currentStepDefinitionMissing(StepDefinitionID)
    case currentStepKindMismatch(stored: WorkflowStepKind, defined: WorkflowStepKind)
    case invalidDraftState(UUID)
    case invalidTerminalState(UUID)
    // Definition validator: structural
    case terminalStepHasTransitions(StepDefinitionID)
    case nonterminalStepHasNoTransitions(StepDefinitionID)
    case closureStepNotTerminal(StepDefinitionID)
    // Definition validator: transition labels/targets
    case blankTransitionLabel(stepID: StepDefinitionID)
    case duplicateTransitionLabel(stepID: StepDefinitionID, label: String)
    case duplicateTransitionTarget(stepID: StepDefinitionID, targetStepID: StepDefinitionID)
    // Transition resolution
    case transitionNotFound(stepID: StepDefinitionID)
    case ambiguousTransition(stepID: StepDefinitionID)
    case expectedForwardTransition
    case expectedReturnTransition
    // Decision branch validation
    case undeclaredDecisionBranch(stepID: StepDefinitionID, branch: String)
    case decisionBranchTransitionMismatch(stepID: StepDefinitionID, branch: String)
    case decisionBranchWithCondition(stepID: StepDefinitionID)
    // Condition evaluation
    case conditionedTransitionUnavailable(stepID: StepDefinitionID, condition: String)
    case conditionedTransitionRejected(stepID: StepDefinitionID, condition: String)
    // Human actor enforcement
    case humanActorRequired
    case humanIdentifierRequired
    case humanRoleRequired
    case unauthorizedApproverRole(supplied: String, allowed: [String])
    case humanDecisionStepRequired
    case humanApprovalStepRequired
    // Human-approval definition checks
    case humanApprovalBlankRole(stepID: StepDefinitionID)
    case humanApprovalDuplicateRole(stepID: StepDefinitionID, role: String)
    case humanApprovalConditionedTransition(stepID: StepDefinitionID)
    // Return transition definition checks
    case returnTransitionMissingLoopPolicy(stepID: StepDefinitionID)
    case returnTransitionToLaterStep(stepID: StepDefinitionID, targetStepID: StepDefinitionID)
    case invalidSelfReturn(stepID: StepDefinitionID)
    // Cancel policy
    case cancellationReasonRequired
    // Payload / JSON
    case invalidJSONPayload
    // Aggregate structural integrity
    case aggregateInvariantViolation(runID: UUID, detail: String)
    // PJE-005 requirement and validation gate
    case blockingRequirementNotMet(stepID: StepDefinitionID, requirementID: String, label: String)
    case blockingValidationNotPassed(stepID: StepDefinitionID, validationID: String, label: String)
    // PJE-006C: terminal completion is blocked by an open blocking attention item.
    case blockingAttentionOpen(itemID: UUID, title: String)
}
