//
//  WorkflowStepExecutionEngine.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Coordinates executor dispatch with the PJE-004 lifecycle engine.
//  Sole actor in the system allowed to persist step state; executors themselves
//  contain no database access.
//
//  Key invariants:
//  • Target executor `prepare()` succeeds before any lifecycle mutation.
//  • Blocking PJE-005 requirements gate before transitions, not here.
//  • Engine recalculates state hash from stateJSON; does not trust executor's stated hash.
//  • Old step runs are never promoted to a newer executor version.
//  • Brainstorm proposals are proposal-layer only — no Claims or EvidenceBlocks.
//

import Foundation

public actor WorkflowStepExecutionEngine {

    private let registry: WorkflowStepExecutorRegistry
    private let lifecycleEngine: WorkflowLifecycleEngine
    private let repository: WorkflowRunRepository
    private let workProductCoordinator: WorkflowWorkProductBuildCoordinator?

    public init(
        registry: WorkflowStepExecutorRegistry,
        lifecycleEngine: WorkflowLifecycleEngine,
        repository: WorkflowRunRepository,
        workProductCoordinator: WorkflowWorkProductBuildCoordinator? = nil
    ) {
        self.registry = registry
        self.lifecycleEngine = lifecycleEngine
        self.repository = repository
        self.workProductCoordinator = workProductCoordinator
    }

    // MARK: - Start a workflow run

    /// Prepares the entry step executor and calls `lifecycleEngine.start()`.
    /// The entry executor's `prepare()` must succeed before any lifecycle mutation is applied.
    @discardableResult
    public func startRun(
        runID: UUID,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        guard let validated = aggregate.contract.reconstructDefinition() else {
            throw WorkflowStepExecutionError.preparationFailed(
                kind: .intake, reason: "Cannot reconstruct workflow definition from contract"
            )
        }
        guard let entryStep = validated.definition.steps.first(where: { $0.id == validated.entryStepID }) else {
            throw WorkflowStepExecutionError.preparationFailed(
                kind: .intake, reason: "Entry step definition not found"
            )
        }
        let schemaVersion = validated.definition.schemaVersion
        guard let executor = registry.resolveExecutor(
            workflowSchemaVersion: schemaVersion,
            stepKind: entryStep.kind
        ) else {
            guard let binding = registry.binding(
                workflowSchemaVersion: schemaVersion,
                stepKind: entryStep.kind
            ) else {
                throw WorkflowStepExecutionError.executorBindingMissing(
                    workflowSchemaVersion: schemaVersion,
                    kind: entryStep.kind
                )
            }
            throw WorkflowStepExecutionError.executorNotFound(
                id: binding.executorID,
                version: binding.executorVersion
            )
        }

        let prepCtx = WorkflowStepPreparationContext(
            runID: runID,
            workspaceID: aggregate.run.workspaceID,
            runRevision: aggregate.run.revision,
            workflow: validated,
            step: entryStep,
            actor: actor,
            preparedAt: now
        )
        let prepResult = try await executor.prepare(context: prepCtx)

        // Verify identity
        guard prepResult.executorID == executor.executorID else {
            throw WorkflowStepExecutionError.preparationFailed(
                kind: entryStep.kind, reason: "Executor prepare() returned mismatched executorID"
            )
        }

        // Recalculate hash — do not trust executor's stated hash.
        // PJE-006B.1: unified contract — SHA-256 of the exact stored UTF-8 bytes.
        let canonicalHash = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: prepResult.stateJSON)

        let entryPayload = WorkflowStepEntryPayload(
            inputJSON: prepResult.inputJSON,
            stateJSON: prepResult.stateJSON,
            executorID: prepResult.executorID.rawValue,
            executorVersion: prepResult.executorVersion.rawValue
        )
        _ = canonicalHash  // hash is carried inside the entry payload via the lifecycle engine codec

        return try await lifecycleEngine.start(
            runID: runID,
            entryPayload: entryPayload,
            actor: actor,
            now: now
        )
    }

    // MARK: - Execute command

    /// Dispatches a command to the current step's executor, then routes based on the
    /// returned disposition.
    @discardableResult
    public func executeCommand(
        runID: UUID,
        commandJSON: String,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        let (validated, currentStep, currentStepRun) = try resolveCurrentStep(aggregate)

        // Look up the exact executor bound to this step run (never promotes to newer version)
        guard
            let execIDString = currentStepRun.executorID,
            let execVersionString = currentStepRun.executorVersion
        else {
            throw WorkflowStepExecutionError.executorBindingMissing(
                workflowSchemaVersion: validated.definition.schemaVersion,
                kind: currentStep.kind
            )
        }
        let execID = WorkflowStepExecutorID(rawValue: execIDString)
        let execVersion = WorkflowStepExecutorVersion(rawValue: execVersionString)
        guard let executor = registry.executor(id: execID, version: execVersion) else {
            throw WorkflowStepExecutionError.executorNotFound(id: execID, version: execVersion)
        }

        let execCtx = try WorkflowStepExecutionContext(
            aggregate: aggregate,
            workflow: validated,
            step: currentStep,
            stepRun: currentStepRun,
            actor: actor,
            executedAt: now,
            executorID: execID,
            executorVersion: execVersion
        )

        let result = try await executor.execute(context: execCtx, commandJSON: commandJSON)

        // Engine recalculates hash; does not trust executor's stated hash.
        // PJE-006B.1: unified contract — SHA-256 of the exact stored UTF-8 bytes.
        let canonicalHash = try WorkflowPersistedJSONIntegrity.sha256(storedJSON: result.stateJSON)

        switch result.disposition {
        case .remainActive:
            return try await saveCurrentProgress(
                aggregate: aggregate,
                stepRun: currentStepRun,
                stateJSON: result.stateJSON,
                stateSHA256: canonicalHash,
                outputJSON: result.outputJSON,
                actor: actor,
                now: now
            )

        case .advance(let selector):
            return try await routeAdvance(
                aggregate: aggregate,
                validated: validated,
                currentStep: currentStep,
                currentStepRun: currentStepRun,
                selector: selector,
                stateJSON: result.stateJSON,
                stateSHA256: canonicalHash,
                outputJSON: result.outputJSON,
                actor: actor,
                now: now
            )

        case .returnToPriorStep(let selector):
            return try await routeReturnToPriorStep(
                aggregate: aggregate,
                validated: validated,
                currentStep: currentStep,
                currentStepRun: currentStepRun,
                selector: selector,
                stateJSON: result.stateJSON,
                stateSHA256: canonicalHash,
                outputJSON: result.outputJSON,
                actor: actor,
                now: now
            )

        case .chooseBranch(let branch, let rationale):
            return try await routeChooseBranch(
                aggregate: aggregate,
                validated: validated,
                currentStep: currentStep,
                branch: branch,
                rationale: rationale,
                stateJSON: result.stateJSON,
                outputJSON: result.outputJSON,
                actor: actor,
                now: now
            )

        case .requestHumanDecision, .requestHumanApproval:
            // Persist the executor's state FIRST — a failure here prevents the
            // lifecycle transition, so no waiting run ever has unsaved state.
            let saved = try await saveCurrentProgress(
                aggregate: aggregate,
                stepRun: currentStepRun,
                stateJSON: result.stateJSON,
                stateSHA256: canonicalHash,
                outputJSON: result.outputJSON,
                actor: actor,
                now: now
            )
            return try await lifecycleEngine.requestHumanDecision(
                runID: saved.run.id, actor: actor, now: now)

        case .buildWorkProduct(let request):
            // The engine persists nothing itself here — the coordinator's single
            // SAVEPOINT owns the whole build. A missing coordinator fails closed.
            guard let coordinator = workProductCoordinator else {
                throw WorkflowStepExecutionError.unsupportedOperation(kind: currentStep.kind)
            }
            return try await coordinator.build(
                runID: aggregate.run.id, request: request, actor: actor, now: now)

        case .completeTerminal:
            // Gated PJE-004 terminal completion — never bypasses PJE-005.
            return try await lifecycleEngine.complete(
                runID: aggregate.run.id,
                completion: WorkflowStepCompletionPayload(
                    stateJSON: result.stateJSON, outputJSON: result.outputJSON),
                actor: actor,
                now: now
            )
        }
    }

    // MARK: - Human decision / approval submission (PJE-006C)

    /// Record an identified human's decision on the current decision step.
    /// The run must be waitingForHuman; the option must be a frozen decision branch.
    /// Two-phase and relaunch-safe: the decision is persisted here; a later
    /// applyRecordedDecision command follows the persisted branch deterministically.
    @discardableResult
    public func submitHumanDecision(
        runID: UUID,
        decisionKey: String,
        selectedOption: String,
        rationale: String?,
        actor: WorkflowLifecycleActor,
        at now: Date = Date()
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        let (_, currentStep, currentStepRun) = try resolveCurrentStep(aggregate)
        guard currentStep.kind == .decision,
              currentStepRun.executorID == "com.kalsmritikosh.step.decision" else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: WorkflowStepExecutorID(rawValue: currentStepRun.executorID ?? "unknown"),
                expected: .decision, actual: currentStep.kind)
        }
        guard aggregate.run.status == .waitingForHuman else {
            throw WorkflowStepExecutionError.unsupportedOperation(kind: currentStep.kind)
        }
        guard currentStep.decisionBranches.contains(selectedOption) else {
            throw WorkflowStepExecutionError.validationFailed(
                field: "selectedOption",
                reason: "Option is not a declared decision branch")
        }
        // recordHumanDecision asserts a human actor with a nonblank identifier.
        return try await lifecycleEngine.recordHumanDecision(
            runID: runID, decisionKey: decisionKey,
            selectedOption: selectedOption, rationale: rationale,
            actor: actor, now: now)
    }

    /// Record an identified, role-authorized human's approval on the current
    /// human-approval step. The run must be waitingForHuman; the actor's role
    /// must appear in the frozen step definition's approverRoles.
    @discardableResult
    public func submitHumanApproval(
        runID: UUID,
        approved: Bool,
        rationale: String?,
        actor: WorkflowLifecycleActor,
        at now: Date = Date()
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        let (_, currentStep, currentStepRun) = try resolveCurrentStep(aggregate)
        guard currentStep.kind == .humanApproval,
              currentStepRun.executorID == "com.kalsmritikosh.step.human-approval" else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: WorkflowStepExecutorID(rawValue: currentStepRun.executorID ?? "unknown"),
                expected: .humanApproval, actual: currentStep.kind)
        }
        guard aggregate.run.status == .waitingForHuman else {
            throw WorkflowStepExecutionError.unsupportedOperation(kind: currentStep.kind)
        }
        // recordHumanApproval asserts human actor + nonblank identifier + nonblank
        // role that appears in the frozen approverRoles.
        return try await lifecycleEngine.recordHumanApproval(
            runID: runID, approved: approved, rationale: rationale,
            actor: actor, now: now)
    }

    // MARK: - Private: route chooseBranch

    private func routeChooseBranch(
        aggregate: ReopenedWorkflowRun,
        validated: ValidatedWorkflowDefinition,
        currentStep: PersonaWorkflowStepDefinition,
        branch: String,
        rationale: String?,
        stateJSON: String,
        outputJSON: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        // Resolve the branch's target so the next executor is prepared BEFORE
        // the lifecycle mutation (terminal targets need no preparation).
        guard let transition = currentStep.transitions.first(where: { $0.label == branch }) else {
            throw WorkflowStepExecutionError.completionNotReady(
                kind: currentStep.kind,
                reason: "No transition for branch '\(branch)'")
        }
        let targetStepID = transition.targetStepID
        let entryPayload: WorkflowStepEntryPayload
        if validated.terminalStepIDs.contains(targetStepID) {
            entryPayload = .empty
        } else {
            guard let targetStep = validated.definition.steps.first(where: { $0.id == targetStepID }) else {
                throw WorkflowStepExecutionError.preparationFailed(
                    kind: currentStep.kind,
                    reason: "Branch target step definition not found: \(targetStepID.rawValue)")
            }
            entryPayload = try await prepareNextExecutor(
                targetStep: targetStep,
                validated: validated,
                aggregate: aggregate,
                actor: actor,
                now: now)
        }
        return try await lifecycleEngine.chooseBranch(
            runID: aggregate.run.id,
            branch: branch,
            rationale: rationale,
            completion: WorkflowStepCompletionPayload(stateJSON: stateJSON, outputJSON: outputJSON),
            entryPayload: entryPayload,
            actor: actor,
            now: now
        )
    }

    // MARK: - Private: save current progress

    private func saveCurrentProgress(
        aggregate: ReopenedWorkflowRun,
        stepRun: WorkflowStepRun,
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        guard aggregate.run.status == .active else {
            throw WorkflowStepExecutionError.unsupportedOperation(kind: stepRun.stepKind)
        }
        guard stepRun.status == .active else {
            throw WorkflowStepExecutionError.unsupportedOperation(kind: stepRun.stepKind)
        }
        return try await repository.updateStepRunState(
            stepRunID: stepRun.id,
            runID: aggregate.run.id,
            newStatus: .active,
            stateJSON: stateJSON,
            stateSHA256: stateSHA256,
            outputJSON: outputJSON,
            expectedRevision: aggregate.run.revision,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier,
            now: now
        )
    }

    // MARK: - Private: route advance

    private func routeAdvance(
        aggregate: ReopenedWorkflowRun,
        validated: ValidatedWorkflowDefinition,
        currentStep: PersonaWorkflowStepDefinition,
        currentStepRun: WorkflowStepRun,
        selector: WorkflowTransitionSelector,
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let completion = WorkflowStepCompletionPayload(
            stateJSON: stateJSON,
            outputJSON: outputJSON
        )

        // Determine target step and prepare its executor before lifecycle mutation
        let targetStepID = try resolveTargetStepID(
            selector: selector,
            step: currentStep,
            validated: validated
        )
        let isTerminal = validated.terminalStepIDs.contains(targetStepID)

        let entryPayload: WorkflowStepEntryPayload
        if isTerminal {
            // Terminal steps get an empty entry payload — no executor preparation needed
            entryPayload = .empty
        } else {
            guard let targetStep = validated.definition.steps.first(where: { $0.id == targetStepID }) else {
                throw WorkflowStepExecutionError.preparationFailed(
                    kind: currentStep.kind,
                    reason: "Target step definition not found: \(targetStepID.rawValue)"
                )
            }
            entryPayload = try await prepareNextExecutor(
                targetStep: targetStep,
                validated: validated,
                aggregate: aggregate,
                actor: actor,
                now: now
            )
        }

        return try await lifecycleEngine.advance(
            runID: aggregate.run.id,
            selector: selector,
            completion: completion,
            entryPayload: entryPayload,
            actor: actor,
            now: now
        )
    }

    // MARK: - Private: route return to prior step

    private func routeReturnToPriorStep(
        aggregate: ReopenedWorkflowRun,
        validated: ValidatedWorkflowDefinition,
        currentStep: PersonaWorkflowStepDefinition,
        currentStepRun: WorkflowStepRun,
        selector: WorkflowTransitionSelector,
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let completion = WorkflowStepCompletionPayload(
            stateJSON: stateJSON,
            outputJSON: outputJSON
        )

        let targetStepID = try resolveTargetStepID(
            selector: selector,
            step: currentStep,
            validated: validated
        )

        guard let targetStep = validated.definition.steps.first(where: { $0.id == targetStepID }) else {
            throw WorkflowStepExecutionError.preparationFailed(
                kind: currentStep.kind,
                reason: "Return target step definition not found: \(targetStepID.rawValue)"
            )
        }

        let entryPayload = try await prepareNextExecutor(
            targetStep: targetStep,
            validated: validated,
            aggregate: aggregate,
            actor: actor,
            now: now
        )

        return try await lifecycleEngine.returnToPriorStep(
            runID: aggregate.run.id,
            selector: selector,
            completion: completion,
            entryPayload: entryPayload,
            actor: actor,
            now: now
        )
    }

    // MARK: - Private: prepare next executor

    private func prepareNextExecutor(
        targetStep: PersonaWorkflowStepDefinition,
        validated: ValidatedWorkflowDefinition,
        aggregate: ReopenedWorkflowRun,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> WorkflowStepEntryPayload {
        let schemaVersion = validated.definition.schemaVersion
        guard let nextExecutor = registry.resolveExecutor(
            workflowSchemaVersion: schemaVersion,
            stepKind: targetStep.kind
        ) else {
            guard let binding = registry.binding(
                workflowSchemaVersion: schemaVersion,
                stepKind: targetStep.kind
            ) else {
                throw WorkflowStepExecutionError.executorBindingMissing(
                    workflowSchemaVersion: schemaVersion,
                    kind: targetStep.kind
                )
            }
            throw WorkflowStepExecutionError.executorNotFound(
                id: binding.executorID,
                version: binding.executorVersion
            )
        }

        let prepCtx = WorkflowStepPreparationContext(
            runID: aggregate.run.id,
            workspaceID: aggregate.run.workspaceID,
            runRevision: aggregate.run.revision,
            workflow: validated,
            step: targetStep,
            actor: actor,
            preparedAt: now
        )
        let prepResult = try await nextExecutor.prepare(context: prepCtx)

        // Verify identity returned by prepare()
        guard prepResult.executorID == nextExecutor.executorID else {
            throw WorkflowStepExecutionError.preparationFailed(
                kind: targetStep.kind,
                reason: "Executor prepare() returned mismatched executorID"
            )
        }

        return WorkflowStepEntryPayload(
            inputJSON: prepResult.inputJSON,
            stateJSON: prepResult.stateJSON,
            executorID: prepResult.executorID.rawValue,
            executorVersion: prepResult.executorVersion.rawValue
        )
    }

    // MARK: - Private: resolve current step

    private func resolveCurrentStep(
        _ aggregate: ReopenedWorkflowRun
    ) throws -> (ValidatedWorkflowDefinition, PersonaWorkflowStepDefinition, WorkflowStepRun) {
        guard let validated = aggregate.contract.reconstructDefinition() else {
            throw WorkflowStepExecutionError.noCurrentStep(aggregate.run.id)
        }
        guard
            let currentStepRunID = aggregate.run.currentStepRunID,
            let currentStepRun = aggregate.stepRuns.first(where: { $0.id == currentStepRunID })
        else {
            throw WorkflowStepExecutionError.noCurrentStep(aggregate.run.id)
        }
        guard
            let currentStepDefID = aggregate.run.currentStepDefinitionID,
            let currentStep = validated.definition.steps.first(where: { $0.id == currentStepDefID })
        else {
            throw WorkflowStepExecutionError.noCurrentStep(aggregate.run.id)
        }
        return (validated, currentStep, currentStepRun)
    }

    // MARK: - Private: resolve target step ID from selector

    private func resolveTargetStepID(
        selector: WorkflowTransitionSelector,
        step: PersonaWorkflowStepDefinition,
        validated: ValidatedWorkflowDefinition
    ) throws -> StepDefinitionID {
        switch selector {
        case .label(let label):
            guard let transition = step.transitions.first(where: { $0.label == label }) else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: step.kind,
                    reason: "No transition with label '\(label)' on step '\(step.id.rawValue)'"
                )
            }
            return transition.targetStepID
        case .targetStepID(let stepID):
            guard validated.reachableStepIDs.contains(stepID) else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: step.kind,
                    reason: "Target step '\(stepID.rawValue)' is not reachable in this workflow"
                )
            }
            return stepID
        }
    }
}
