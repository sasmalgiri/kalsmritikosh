//
//  WorkflowRequirementsEngine.swift
//  Kalsmritikosh
//
//  PJE-005 — Requirements, Validators, and Attention Engine.
//  Evaluates PersonaWorkflowRequirement and PersonaWorkflowValidation against the current
//  run aggregate, drives attention-item creation and resolution, and gates advancement
//  on blocking failures.
//
//  Requirement kinds handled deterministically (no executor needed):
//    canonicalObjectLinked — workspace entity count via WorkspaceRepository (injected)
//    evidenceSelected      — workspace source count via WorkspaceRepository (injected)
//    humanDecisionRecorded — decisions on current step run (from aggregate)
//    sensitiveScopeSatisfied — scope.purpose vs step's declared purposes (from argument)
//    artifactGenerated     — required artifacts present on current step run (from aggregate)
//    validationPassed      — meta: all blocking validations passed (computed during eval)
//
//  Requirement kinds deferred (need executor or retrieval context):
//    evidenceReviewed      — deferred (no review-decision accessor without retrieval context)
//    formFieldCompleted    — deferred to PJE-006 step executors
//    methodResultPresent   — deferred to PJE-006 step executors
//

import Foundation
import OSLog

public actor WorkflowRequirementsEngine {

    private let repository: WorkflowRunRepository
    private let workspaces: WorkspaceRepository?
    private var executors: [String: any WorkflowValidatorExecuting] = [:]

    public init(
        repository: WorkflowRunRepository,
        workspaces: WorkspaceRepository? = nil
    ) {
        self.repository = repository
        self.workspaces = workspaces
    }

    // MARK: - Executor registry

    public func registerExecutor(_ executor: any WorkflowValidatorExecuting) {
        executors[executor.validatorID] = executor
    }

    public func unregisterExecutor(validatorID: String) {
        executors.removeValue(forKey: validatorID)
    }

    // MARK: - Pure evaluation (no DB side effects)

    /// Evaluate all step requirements and validations for a run aggregate.
    /// Validates first (so validationPassed requirement can use their results),
    /// then evaluates requirements.
    public func evaluate(
        stepDefinition: PersonaWorkflowStepDefinition,
        aggregate: ReopenedWorkflowRun,
        scope: SensitiveScope? = nil
    ) async throws -> WorkflowRequirementsEvaluation {
        let validationOutcomes = try await evaluateValidations(
            stepDefinition: stepDefinition,
            aggregate: aggregate
        )
        let requirementOutcomes = try await evaluateRequirements(
            stepDefinition: stepDefinition,
            aggregate: aggregate,
            scope: scope,
            validationOutcomes: validationOutcomes
        )
        return WorkflowRequirementsEvaluation(
            requirementOutcomes: requirementOutcomes,
            validationOutcomes: validationOutcomes
        )
    }

    // MARK: - Attention-item lifecycle (DB side effects)

    /// Create attention items for any failures and resolve items for satisfied requirements.
    /// Called after a successful lifecycle plan application so the items reflect post-transition state.
    /// Individual DB errors are logged and swallowed — a transient attention-item failure does not
    /// invalidate a successful lifecycle transition.
    ///
    /// - Parameter stepRunID: The step run that was active BEFORE the transition (attention items
    ///   are associated with the step they were evaluated on, not the next step).
    public func applyAttentionItems(
        evaluation: WorkflowRequirementsEvaluation,
        runID: UUID,
        stepRunID: UUID?,
        initialAggregate: ReopenedWorkflowRun,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async {
        var current = initialAggregate

        // 1. Resolve items whose requirement is now satisfied
        for outcome in evaluation.requirementOutcomes {
            if case .satisfied(let reqID) = outcome {
                let toResolve = current.attentionItems.filter {
                    $0.status == .open && $0.sourceKind == .requirement && $0.sourceID == reqID
                }
                for item in toResolve {
                    do {
                        current = try await repository.resolveAttentionItem(
                            attentionItemID: item.id,
                            runID: current.run.id,
                            newStatus: .resolved,
                            resolvedBy: actor.identifier,
                            resolutionNote: "Requirement satisfied",
                            expectedRevision: current.run.revision,
                            actorKind: actor.kind,
                            actorIdentifier: actor.identifier,
                            now: now
                        )
                    } catch {
                        KalsmritikoshLog.workflow.error("PJE-005 applyAttentionItems: resolve req '\(reqID)' item \(item.id): \(error)")
                    }
                }
            }
        }

        // 2. Resolve items whose validation is now passing
        for outcome in evaluation.validationOutcomes {
            if case .passed(let valID) = outcome {
                let toResolve = current.attentionItems.filter {
                    $0.status == .open && $0.sourceKind == .validation && $0.sourceID == valID
                }
                for item in toResolve {
                    do {
                        current = try await repository.resolveAttentionItem(
                            attentionItemID: item.id,
                            runID: current.run.id,
                            newStatus: .resolved,
                            resolvedBy: actor.identifier,
                            resolutionNote: "Validation now passing",
                            expectedRevision: current.run.revision,
                            actorKind: actor.kind,
                            actorIdentifier: actor.identifier,
                            now: now
                        )
                    } catch {
                        KalsmritikoshLog.workflow.error("PJE-005 applyAttentionItems: resolve val '\(valID)' item \(item.id): \(error)")
                    }
                }
            }
        }

        // 3. Create new items for failed requirements (dedup: skip if already open)
        for outcome in evaluation.requirementOutcomes {
            if case .failed(let reqID, let label, let isBlocking, let detail) = outcome {
                let alreadyOpen = current.attentionItems.contains {
                    $0.status == .open && $0.sourceKind == .requirement && $0.sourceID == reqID
                }
                guard !alreadyOpen else { continue }
                do {
                    current = try await repository.createAttentionItem(
                        runID: current.run.id,
                        stepRunID: stepRunID,
                        sourceKind: .requirement,
                        sourceID: reqID,
                        severity: isBlocking ? .blocking : .advisory,
                        title: label,
                        detail: detail,
                        expectedRevision: current.run.revision,
                        actorKind: actor.kind,
                        actorIdentifier: actor.identifier,
                        now: now
                    )
                } catch {
                    KalsmritikoshLog.workflow.error("PJE-005 applyAttentionItems: create req '\(reqID)': \(error)")
                }
            }
        }

        // 4. Create new items for failed validations (dedup: skip if already open)
        for outcome in evaluation.validationOutcomes {
            if case .failed(let valID, let label, let isBlocking, let detail) = outcome {
                let alreadyOpen = current.attentionItems.contains {
                    $0.status == .open && $0.sourceKind == .validation && $0.sourceID == valID
                }
                guard !alreadyOpen else { continue }
                do {
                    current = try await repository.createAttentionItem(
                        runID: current.run.id,
                        stepRunID: stepRunID,
                        sourceKind: .validation,
                        sourceID: valID,
                        severity: isBlocking ? .blocking : .advisory,
                        title: label,
                        detail: detail,
                        expectedRevision: current.run.revision,
                        actorKind: actor.kind,
                        actorIdentifier: actor.identifier,
                        now: now
                    )
                } catch {
                    KalsmritikoshLog.workflow.error("PJE-005 applyAttentionItems: create val '\(valID)': \(error)")
                }
            }
        }
    }

    // MARK: - Private: requirement evaluation dispatch

    private func evaluateRequirements(
        stepDefinition: PersonaWorkflowStepDefinition,
        aggregate: ReopenedWorkflowRun,
        scope: SensitiveScope?,
        validationOutcomes: [WorkflowValidationOutcome]
    ) async throws -> [WorkflowRequirementOutcome] {
        var outcomes: [WorkflowRequirementOutcome] = []
        for req in stepDefinition.requirements {
            let outcome = try await evaluateRequirement(
                req,
                stepDefinition: stepDefinition,
                aggregate: aggregate,
                scope: scope,
                validationOutcomes: validationOutcomes
            )
            outcomes.append(outcome)
        }
        return outcomes
    }

    private func evaluateRequirement(
        _ req: PersonaWorkflowRequirement,
        stepDefinition: PersonaWorkflowStepDefinition,
        aggregate: ReopenedWorkflowRun,
        scope: SensitiveScope?,
        validationOutcomes: [WorkflowValidationOutcome]
    ) async throws -> WorkflowRequirementOutcome {
        switch req.kind {
        case .canonicalObjectLinked:
            return try await evaluateCanonicalObjectLinked(req, workspaceID: aggregate.run.workspaceID)
        case .evidenceSelected:
            return try await evaluateEvidenceSelected(req, workspaceID: aggregate.run.workspaceID)
        case .evidenceReviewed:
            return .skipped(requirementID: req.id, reason: "Evidence review check requires retrieval context")
        case .humanDecisionRecorded:
            return evaluateHumanDecisionRecorded(req, aggregate: aggregate)
        case .sensitiveScopeSatisfied:
            return evaluateSensitiveScopeSatisfied(req, stepDefinition: stepDefinition, scope: scope)
        case .formFieldCompleted:
            return .skipped(requirementID: req.id, reason: "Form field evaluation requires step executor context")
        case .artifactGenerated:
            return evaluateArtifactGenerated(req, stepDefinition: stepDefinition, aggregate: aggregate)
        case .validationPassed:
            return evaluateValidationPassed(req, validationOutcomes: validationOutcomes)
        case .methodResultPresent:
            return .skipped(requirementID: req.id, reason: "Method result check requires step executor context")
        }
    }

    // MARK: - Private: individual requirement evaluators

    private func evaluateCanonicalObjectLinked(
        _ req: PersonaWorkflowRequirement,
        workspaceID: Workspace.ID
    ) async throws -> WorkflowRequirementOutcome {
        guard let workspaces = workspaces else {
            return .skipped(requirementID: req.id, reason: "Workspace context not available")
        }
        let entityIDs = try await workspaces.entityIDs(in: workspaceID)
        if entityIDs.isEmpty {
            return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                           detail: req.detail ?? "No canonical objects linked to workspace")
        }
        return .satisfied(requirementID: req.id)
    }

    private func evaluateEvidenceSelected(
        _ req: PersonaWorkflowRequirement,
        workspaceID: Workspace.ID
    ) async throws -> WorkflowRequirementOutcome {
        guard let workspaces = workspaces else {
            return .skipped(requirementID: req.id, reason: "Workspace context not available")
        }
        let count = try await workspaces.sourceCount(in: workspaceID)
        if count == 0 {
            return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                           detail: req.detail ?? "No evidence sources selected for workspace")
        }
        return .satisfied(requirementID: req.id)
    }

    private func evaluateHumanDecisionRecorded(
        _ req: PersonaWorkflowRequirement,
        aggregate: ReopenedWorkflowRun
    ) -> WorkflowRequirementOutcome {
        guard let currentStepRunID = aggregate.run.currentStepRunID else {
            return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                           detail: "No active step run")
        }
        let hasDecision = aggregate.decisions.contains {
            $0.stepRunID == currentStepRunID && $0.kind == .humanDecision
        }
        if hasDecision {
            return .satisfied(requirementID: req.id)
        }
        return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                       detail: req.detail ?? "Human decision not yet recorded for this step")
    }

    private func evaluateSensitiveScopeSatisfied(
        _ req: PersonaWorkflowRequirement,
        stepDefinition: PersonaWorkflowStepDefinition,
        scope: SensitiveScope?
    ) -> WorkflowRequirementOutcome {
        guard let scopeReq = stepDefinition.sensitiveScope, !scopeReq.purposes.isEmpty else {
            return .satisfied(requirementID: req.id)
        }
        guard let scope = scope else {
            return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                           detail: req.detail ?? "No active sensitive scope provided for step")
        }
        if scopeReq.purposes.contains(scope.purpose) {
            return .satisfied(requirementID: req.id)
        }
        return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                       detail: req.detail ?? "Active scope does not cover declared sensitive purposes")
    }

    private func evaluateArtifactGenerated(
        _ req: PersonaWorkflowRequirement,
        stepDefinition: PersonaWorkflowStepDefinition,
        aggregate: ReopenedWorkflowRun
    ) -> WorkflowRequirementOutcome {
        let currentStepRunID = aggregate.run.currentStepRunID
        let requiredIDs = stepDefinition.artifacts.filter { $0.isRequired }.map { $0.id }
        guard !requiredIDs.isEmpty else {
            return .satisfied(requirementID: req.id)
        }
        let generatedIDs = Set(
            aggregate.artifacts
                .filter { $0.stepRunID == currentStepRunID }
                .map { $0.artifactDefinitionID }
        )
        let missing = requiredIDs.filter { !generatedIDs.contains($0) }
        if missing.isEmpty {
            return .satisfied(requirementID: req.id)
        }
        let detail = req.detail ?? "Required artifacts not yet generated: \(missing.joined(separator: ", "))"
        return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking, detail: detail)
    }

    private func evaluateValidationPassed(
        _ req: PersonaWorkflowRequirement,
        validationOutcomes: [WorkflowValidationOutcome]
    ) -> WorkflowRequirementOutcome {
        let blockingFailed = validationOutcomes.filter { $0.isBlockingFailed }
        if blockingFailed.isEmpty {
            return .satisfied(requirementID: req.id)
        }
        let ids = blockingFailed.map { $0.validationID }.joined(separator: ", ")
        return .failed(requirementID: req.id, label: req.label, isBlocking: req.isBlocking,
                       detail: "Blocking validations not passed: \(ids)")
    }

    // MARK: - Private: validation execution

    private func evaluateValidations(
        stepDefinition: PersonaWorkflowStepDefinition,
        aggregate: ReopenedWorkflowRun
    ) async throws -> [WorkflowValidationOutcome] {
        guard !stepDefinition.validations.isEmpty else { return [] }
        guard let currentStepRunID = aggregate.run.currentStepRunID else {
            return stepDefinition.validations.map {
                .skipped(validationID: $0.id, reason: "No active step run")
            }
        }
        guard let stepRun = aggregate.stepRuns.first(where: { $0.id == currentStepRunID }) else {
            return stepDefinition.validations.map {
                .skipped(validationID: $0.id, reason: "Current step run not found in aggregate")
            }
        }
        var outcomes: [WorkflowValidationOutcome] = []
        for validation in stepDefinition.validations {
            let outcome = await executeValidation(
                validation,
                stepRun: stepRun,
                stepDefinition: stepDefinition,
                run: aggregate.run
            )
            outcomes.append(outcome)
        }
        return outcomes
    }

    private func executeValidation(
        _ validation: PersonaWorkflowValidation,
        stepRun: WorkflowStepRun,
        stepDefinition: PersonaWorkflowStepDefinition,
        run: WorkflowRun
    ) async -> WorkflowValidationOutcome {
        guard let executor = executors[validation.validatorID] else {
            return .skipped(validationID: validation.id,
                            reason: "Validator '\(validation.validatorID)' not registered")
        }
        let context = WorkflowValidationContext(
            stepRun: stepRun,
            stepDefinition: stepDefinition,
            run: run
        )
        do {
            let result = try await executor.execute(context: context)
            if result.passed {
                return .passed(validationID: validation.id)
            }
            return .failed(validationID: validation.id, label: validation.label,
                           isBlocking: validation.isBlocking,
                           detail: result.detail ?? validation.detail)
        } catch {
            KalsmritikoshLog.workflow.error("PJE-005: Validator '\(validation.validatorID)' threw for '\(validation.id)': \(error)")
            return .failed(validationID: validation.id, label: validation.label,
                           isBlocking: validation.isBlocking,
                           detail: "Validator execution error: \(error)")
        }
    }
}
