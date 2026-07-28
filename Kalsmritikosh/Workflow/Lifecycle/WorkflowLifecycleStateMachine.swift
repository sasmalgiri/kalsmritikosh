//
//  WorkflowLifecycleStateMachine.swift
//  Kalsmritikosh
//
//  PJE-004 — Deterministic run-state and step-state transition tables.
//  No persistence. No I/O. Pure function: (state, action) → allowed/error.
//

import Foundation

/// Pre-computed lookup tables for one workflow run's lifecycle.
/// Built once from a `ValidatedWorkflowDefinition`; reused for all actions on the same run.
public struct OperationalWorkflowDefinition: Sendable {
    public let validated: ValidatedWorkflowDefinition
    /// Step definition keyed by step ID — O(1) lookup.
    public let stepByID: [StepDefinitionID: PersonaWorkflowStepDefinition]
    /// Declaration order index for each step ID — used for return-transition ordering.
    public let declarationIndexByStepID: [StepDefinitionID: Int]

    public nonisolated init(validated: ValidatedWorkflowDefinition) {
        self.validated = validated
        var byID = [StepDefinitionID: PersonaWorkflowStepDefinition]()
        var indexByID = [StepDefinitionID: Int]()
        for (idx, step) in validated.definition.steps.enumerated() {
            byID[step.id] = step
            indexByID[step.id] = idx
        }
        self.stepByID = byID
        self.declarationIndexByStepID = indexByID
    }
}

/// Pure deterministic transition policy. No state, no I/O.
public struct WorkflowLifecycleStateMachine: Sendable {
    public nonisolated init() {}

    // MARK: - Run-state transition guard

    /// Returns `true` if `action` is a legal run-state action from `status`.
    /// Throws `illegalRunTransition` or `terminalRunImmutable` otherwise.
    public nonisolated func assertRunTransitionAllowed(
        from status: WorkflowRunStatus,
        action: WorkflowLifecycleAction
    ) throws {
        let terminalStatuses: Set<WorkflowRunStatus> = [.completed, .cancelled, .superseded]
        if terminalStatuses.contains(status) {
            throw WorkflowLifecycleError.terminalRunImmutable(runID: UUID(), status: status)
        }
        let allowed = Self.allowedActions(for: status)
        guard allowed.contains(action) else {
            throw WorkflowLifecycleError.illegalRunTransition(from: status, action: action)
        }
    }

    /// Run-state → allowed lifecycle actions.
    public nonisolated static func allowedActions(for status: WorkflowRunStatus) -> Set<WorkflowLifecycleAction> {
        switch status {
        case .draft:
            return [.start, .cancel, .supersede]
        case .active:
            return [.save, .pause, .block, .advance, .chooseBranch, .requestHumanDecision,
                    .returnToPriorStep, .complete, .cancel, .supersede]
        case .paused:
            return [.save, .resume, .cancel, .supersede]
        case .waitingForHuman:
            return [.save, .recordHumanDecision, .recordHumanApproval, .cancel, .supersede]
        case .blocked:
            return [.save, .unblock, .cancel, .supersede]
        case .completed, .cancelled, .superseded:
            return []
        }
    }

    // MARK: - Step-state compatibility

    /// Returns the step-run status that is compatible with the run status.
    public nonisolated func requiredStepRunStatus(for runStatus: WorkflowRunStatus) -> WorkflowStepRunStatus? {
        switch runStatus {
        case .active: return .active
        case .paused: return .waiting
        case .waitingForHuman: return .waiting
        case .blocked: return .blocked
        default: return nil
        }
    }

    // MARK: - Structural projection

    /// Compute the structural action set and available transitions for a run aggregate.
    public nonisolated func project(
        run: WorkflowRun,
        currentStepRun: WorkflowStepRun?,
        opDef: OperationalWorkflowDefinition
    ) -> WorkflowLifecycleProjection {
        let allowed = Self.allowedActions(for: run.status)
        var currentStep: PersonaWorkflowStepDefinition? = nil
        var forwardTransitions: [WorkflowTransitionDefinition] = []
        var returnTransitions: [WorkflowTransitionDefinition] = []

        if let stepDefID = run.currentStepDefinitionID,
           let step = opDef.stepByID[stepDefID] {
            currentStep = step
            forwardTransitions = step.transitions.filter { !$0.isReturn }
            returnTransitions = step.transitions.filter { $0.isReturn }
        }

        return WorkflowLifecycleProjection(
            runStatus: run.status,
            currentStep: currentStep,
            currentStepRun: currentStepRun,
            structuralActions: allowed,
            forwardTransitions: forwardTransitions,
            returnTransitions: returnTransitions
        )
    }

    // MARK: - Transition resolution

    /// Resolve a `WorkflowTransitionSelector` to a single forward transition.
    public nonisolated func resolveForwardTransition(
        selector: WorkflowTransitionSelector,
        step: PersonaWorkflowStepDefinition
    ) throws -> WorkflowTransitionDefinition {
        let candidates = step.transitions.filter { !$0.isReturn }
        let matches: [WorkflowTransitionDefinition]
        switch selector {
        case .label(let label):
            matches = candidates.filter { $0.label == label }
        case .targetStepID(let targetID):
            matches = candidates.filter { $0.targetStepID == targetID }
        }
        if matches.isEmpty {
            throw WorkflowLifecycleError.transitionNotFound(stepID: step.id)
        }
        if matches.count > 1 {
            throw WorkflowLifecycleError.ambiguousTransition(stepID: step.id)
        }
        return matches[0]
    }

    /// Resolve a `WorkflowTransitionSelector` to a single return transition.
    public nonisolated func resolveReturnTransition(
        selector: WorkflowTransitionSelector,
        step: PersonaWorkflowStepDefinition
    ) throws -> WorkflowTransitionDefinition {
        let candidates = step.transitions.filter { $0.isReturn }
        let matches: [WorkflowTransitionDefinition]
        switch selector {
        case .label(let label):
            matches = candidates.filter { $0.label == label }
        case .targetStepID(let targetID):
            matches = candidates.filter { $0.targetStepID == targetID }
        }
        if matches.isEmpty {
            throw WorkflowLifecycleError.transitionNotFound(stepID: step.id)
        }
        if matches.count > 1 {
            throw WorkflowLifecycleError.ambiguousTransition(stepID: step.id)
        }
        return matches[0]
    }

    // MARK: - Decision branch resolution

    public nonisolated func resolveDecisionBranch(
        branch: String,
        step: PersonaWorkflowStepDefinition
    ) throws -> WorkflowTransitionDefinition {
        guard step.decisionBranches.contains(branch) else {
            throw WorkflowLifecycleError.undeclaredDecisionBranch(stepID: step.id, branch: branch)
        }
        let match = step.transitions.first { !$0.isReturn && $0.label == branch }
        guard let t = match else {
            throw WorkflowLifecycleError.decisionBranchTransitionMismatch(stepID: step.id, branch: branch)
        }
        return t
    }

    // MARK: - Human actor enforcement

    public nonisolated func assertHumanActor(_ actor: WorkflowLifecycleActor) throws {
        guard actor.kind == .human else {
            throw WorkflowLifecycleError.humanActorRequired
        }
        guard let id = actor.identifier, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WorkflowLifecycleError.humanIdentifierRequired
        }
    }

    public nonisolated func assertHumanApproverRole(
        actor: WorkflowLifecycleActor,
        step: PersonaWorkflowStepDefinition
    ) throws {
        try assertHumanActor(actor)
        guard let role = actor.role, !role.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WorkflowLifecycleError.humanRoleRequired
        }
        guard step.approverRoles.contains(role) else {
            throw WorkflowLifecycleError.unauthorizedApproverRole(
                supplied: role, allowed: step.approverRoles)
        }
    }

    // MARK: - Return transition policy enforcement

    public nonisolated func assertReturnTransitionPolicy(
        transition: WorkflowTransitionDefinition,
        sourceStep: PersonaWorkflowStepDefinition,
        opDef: OperationalWorkflowDefinition
    ) throws {
        guard let policy = sourceStep.loopPolicy else {
            throw WorkflowLifecycleError.returnTransitionMissingLoopPolicy(stepID: sourceStep.id)
        }
        switch policy {
        case .returnsToStep:
            guard let sourceIdx = opDef.declarationIndexByStepID[sourceStep.id],
                  let targetIdx = opDef.declarationIndexByStepID[transition.targetStepID] else { return }
            if targetIdx >= sourceIdx {
                throw WorkflowLifecycleError.returnTransitionToLaterStep(
                    stepID: sourceStep.id, targetStepID: transition.targetStepID)
            }
        case .iterates:
            if transition.targetStepID != sourceStep.id {
                throw WorkflowLifecycleError.invalidSelfReturn(stepID: sourceStep.id)
            }
        }
    }
}
