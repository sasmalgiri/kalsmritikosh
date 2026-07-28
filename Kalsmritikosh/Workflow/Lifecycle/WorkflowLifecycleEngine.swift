//
//  WorkflowLifecycleEngine.swift
//  Kalsmritikosh
//
//  PJE-004 — Workflow Lifecycle Engine.
//  Orchestrates lifecycle actions: validates, plans, and delegates to the repository.
//  All lifecycle actions are atomic (one SAVEPOINT per action).
//  The frozen contract snapshot is the sole authority for the definition — never consults
//  the live PersonaJobCatalog.
//

import Foundation

public actor WorkflowLifecycleEngine {

    private let repository: WorkflowRunRepository
    private let stateMachine: WorkflowLifecycleStateMachine
    private let validator: WorkflowLifecycleDefinitionValidator
    private let codec: WorkflowLifecyclePayloadCodec
    private let conditionEvaluator: any WorkflowTransitionConditionEvaluating
    private let requirementsEngine: WorkflowRequirementsEngine?

    public init(
        repository: WorkflowRunRepository,
        conditionEvaluator: any WorkflowTransitionConditionEvaluating = RejectingWorkflowTransitionConditionEvaluator(),
        requirementsEngine: WorkflowRequirementsEngine? = nil
    ) {
        self.repository = repository
        self.stateMachine = WorkflowLifecycleStateMachine()
        self.validator = WorkflowLifecycleDefinitionValidator()
        self.codec = WorkflowLifecyclePayloadCodec()
        self.conditionEvaluator = conditionEvaluator
        self.requirementsEngine = requirementsEngine
    }

    // MARK: - Start

    /// Transition a draft run to active and enter the first step.
    @discardableResult
    public func start(
        runID: UUID,
        entryPayload: WorkflowStepEntryPayload = .empty,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .start)
        guard aggregate.run.status == .draft else {
            throw WorkflowLifecycleError.invalidDraftState(runID)
        }
        try codec.validate(entryPayload)

        let opDef = try makeOpDef(aggregate)
        let entryStepID = opDef.validated.entryStepID
        guard let entryStep = opDef.stepByID[entryStepID] else {
            throw WorkflowLifecycleError.currentStepDefinitionMissing(entryStepID)
        }

        let stepRunID = UUID()
        let stateHash = try codec.stateSHA256(for: entryPayload.stateJSON)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .active,
                currentStepDefinitionID: entryStepID,
                currentStepRunID: stepRunID,
                startedAt: now,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [WorkflowLifecycleStepInsert(
                id: stepRunID,
                stepDefinitionID: entryStepID,
                stepKind: entryStep.kind,
                attempt: 1,
                status: .active,
                inputJSON: entryPayload.inputJSON,
                stateJSON: entryPayload.stateJSON,
                stateSHA256: stateHash,
                outputJSON: nil,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                completedAt: nil
            )],
            stepsToUpdate: [],
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )

        return try await repository.applyLifecyclePlan(
            runID: runID,
            expectedRevision: aggregate.run.revision,
            plan: plan,
            now: now
        )
    }

    // MARK: - Save (checkpoint without state change)

    @discardableResult
    public func save(
        runID: UUID,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .save)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: aggregate.run.status,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: aggregate.run.pausedAt,
                completedAt: aggregate.run.completedAt,
                cancelledAt: aggregate.run.cancelledAt,
                cancellationReason: aggregate.run.cancellationReason,
                supersededByRunID: aggregate.run.supersededByRunID
            ),
            stepsToInsert: [],
            stepsToUpdate: [],
            decisionToInsert: nil,
            checkpointReason: .explicitSave,
            eventType: .checkpointCreated,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )

        return try await repository.applyLifecyclePlan(
            runID: runID,
            expectedRevision: aggregate.run.revision,
            plan: plan,
            now: now
        )
    }

    // MARK: - Pause

    @discardableResult
    public func pause(
        runID: UUID,
        stepCompletion: WorkflowStepCompletionPayload = WorkflowStepCompletionPayload(),
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .pause)

        let currentStepRun = try requireCurrentStepRun(aggregate)
        let (stateJSON, outputJSON) = try codec.resolveCompletionPayload(stepCompletion, current: currentStepRun)
        let stateHash = try codec.stateSHA256(for: stateJSON)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .paused,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: now,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .waiting,
                stateJSON: stateJSON,
                stateSHA256: stateHash,
                outputJSON: outputJSON,
                completedAt: nil
            )],
            decisionToInsert: nil,
            checkpointReason: .pause,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )

        return try await repository.applyLifecyclePlan(
            runID: runID,
            expectedRevision: aggregate.run.revision,
            plan: plan,
            now: now
        )
    }

    // MARK: - Resume

    @discardableResult
    public func resume(
        runID: UUID,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .resume)

        let currentStepRun = try requireCurrentStepRun(aggregate)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .active,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .active,
                stateJSON: currentStepRun.stateJSON,
                stateSHA256: currentStepRun.stateSHA256,
                outputJSON: currentStepRun.outputJSON,
                completedAt: nil
            )],
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )

        return try await repository.applyLifecyclePlan(
            runID: runID,
            expectedRevision: aggregate.run.revision,
            plan: plan,
            now: now
        )
    }

    // MARK: - Block / Unblock

    @discardableResult
    public func block(
        runID: UUID,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .block)
        let currentStepRun = try requireCurrentStepRun(aggregate)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .blocked,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .blocked,
                stateJSON: currentStepRun.stateJSON,
                stateSHA256: currentStepRun.stateSHA256,
                outputJSON: currentStepRun.outputJSON,
                completedAt: nil
            )],
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    @discardableResult
    public func unblock(
        runID: UUID,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .unblock)
        let currentStepRun = try requireCurrentStepRun(aggregate)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .active,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .active,
                stateJSON: currentStepRun.stateJSON,
                stateSHA256: currentStepRun.stateSHA256,
                outputJSON: currentStepRun.outputJSON,
                completedAt: nil
            )],
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Advance (forward transition)

    @discardableResult
    public func advance(
        runID: UUID,
        selector: WorkflowTransitionSelector,
        completion: WorkflowStepCompletionPayload = WorkflowStepCompletionPayload(),
        entryPayload: WorkflowStepEntryPayload = .empty,
        scope: SensitiveScope? = nil,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .advance)

        let opDef = try makeOpDef(aggregate)
        let (currentStepDef, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)

        let transition = try stateMachine.resolveForwardTransition(selector: selector, step: currentStepDef)
        guard !transition.isReturn else { throw WorkflowLifecycleError.expectedForwardTransition }

        // Evaluate condition if present
        if let condition = transition.condition {
            let ctx = WorkflowTransitionConditionContext(
                run: aggregate.run, currentStepRun: currentStepRun,
                workflow: opDef.validated, transition: transition)
            let eval = try await conditionEvaluator.evaluate(condition: condition, context: ctx)
            switch eval {
            case .unavailable:
                throw WorkflowLifecycleError.conditionedTransitionUnavailable(
                    stepID: currentStepDef.id, condition: condition)
            case .notSatisfied(_, _):
                throw WorkflowLifecycleError.conditionedTransitionRejected(
                    stepID: currentStepDef.id, condition: condition)
            case .satisfied(_, _):
                break
            }
        }

        // PJE-005: evaluate requirements gate before committing the lifecycle plan
        var requirementsEval: WorkflowRequirementsEvaluation? = nil
        if let reqEngine = requirementsEngine {
            let eval = try await reqEngine.evaluate(
                stepDefinition: currentStepDef,
                aggregate: aggregate,
                scope: scope
            )
            if eval.hasBlockingFailure {
                if let outcome = eval.requirementOutcomes.first(where: { $0.isBlockingFailed }),
                   case .failed(let reqID, let label, _, _) = outcome {
                    throw WorkflowLifecycleError.blockingRequirementNotMet(
                        stepID: currentStepDef.id, requirementID: reqID, label: label)
                }
                if let outcome = eval.validationOutcomes.first(where: { $0.isBlockingFailed }),
                   case .failed(let valID, let label, _, _) = outcome {
                    throw WorkflowLifecycleError.blockingValidationNotPassed(
                        stepID: currentStepDef.id, validationID: valID, label: label)
                }
            }
            requirementsEval = eval
        }

        let (stateJSON, outputJSON) = try codec.resolveCompletionPayload(completion, current: currentStepRun)
        let stateHash = try codec.stateSHA256(for: stateJSON)
        try codec.validate(entryPayload)

        let nextStepID = transition.targetStepID
        guard let nextStepDef = opDef.stepByID[nextStepID] else {
            throw WorkflowLifecycleError.currentStepDefinitionMissing(nextStepID)
        }

        let isTerminal = opDef.validated.terminalStepIDs.contains(nextStepID)
        let nextRunStatus: WorkflowRunStatus = isTerminal ? .completed : .active
        let nextStepRunStatus: WorkflowStepRunStatus = isTerminal ? .completed : .active
        let nextStepRunID = UUID()
        let nextStateHash = try codec.stateSHA256(for: entryPayload.stateJSON)

        let stepsToUpdate: [WorkflowLifecycleStepPatch] = [
            WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .completed,
                stateJSON: stateJSON,
                stateSHA256: stateHash,
                outputJSON: outputJSON,
                completedAt: now
            )
        ]
        var stepsToInsert: [WorkflowLifecycleStepInsert] = []
        var nextStepRunIDOpt: UUID? = nil

        if !isTerminal {
            let nextAttempt = aggregate.stepRuns
                .filter { $0.stepDefinitionID == nextStepID }
                .map { $0.attempt }
                .max() ?? 0
            stepsToInsert.append(WorkflowLifecycleStepInsert(
                id: nextStepRunID,
                stepDefinitionID: nextStepID,
                stepKind: nextStepDef.kind,
                attempt: nextAttempt + 1,
                status: nextStepRunStatus,
                inputJSON: entryPayload.inputJSON,
                stateJSON: entryPayload.stateJSON,
                stateSHA256: nextStateHash,
                outputJSON: nil,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                completedAt: nil
            ))
            nextStepRunIDOpt = nextStepRunID
        } else {
            // For terminal step, update the current step to completed (already in stepsToUpdate)
            // The terminal step itself becomes the current step
        }

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: nextRunStatus,
                currentStepDefinitionID: isTerminal ? currentStepDef.id : nextStepID,
                currentStepRunID: isTerminal ? currentStepRun.id : nextStepRunIDOpt,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: isTerminal ? now : nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: stepsToInsert,
            stepsToUpdate: stepsToUpdate,
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )

        let result = try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)

        // PJE-005: apply advisory attention items after the plan succeeds (non-throwing)
        if let eval = requirementsEval, let reqEngine = requirementsEngine {
            await reqEngine.applyAttentionItems(
                evaluation: eval,
                runID: runID,
                stepRunID: currentStepRun.id,
                initialAggregate: result,
                actor: actor,
                now: now
            )
        }
        return result
    }

    // MARK: - Choose Branch (decision step)

    @discardableResult
    public func chooseBranch(
        runID: UUID,
        branch: String,
        rationale: String?,
        completion: WorkflowStepCompletionPayload = WorkflowStepCompletionPayload(),
        entryPayload: WorkflowStepEntryPayload = .empty,
        scope: SensitiveScope? = nil,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .chooseBranch)

        let opDef = try makeOpDef(aggregate)
        let (currentStepDef, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)

        let transition = try stateMachine.resolveDecisionBranch(branch: branch, step: currentStepDef)

        // PJE-005: evaluate requirements gate before committing the lifecycle plan
        var requirementsEval: WorkflowRequirementsEvaluation? = nil
        if let reqEngine = requirementsEngine {
            let eval = try await reqEngine.evaluate(
                stepDefinition: currentStepDef,
                aggregate: aggregate,
                scope: scope
            )
            if eval.hasBlockingFailure {
                if let outcome = eval.requirementOutcomes.first(where: { $0.isBlockingFailed }),
                   case .failed(let reqID, let label, _, _) = outcome {
                    throw WorkflowLifecycleError.blockingRequirementNotMet(
                        stepID: currentStepDef.id, requirementID: reqID, label: label)
                }
                if let outcome = eval.validationOutcomes.first(where: { $0.isBlockingFailed }),
                   case .failed(let valID, let label, _, _) = outcome {
                    throw WorkflowLifecycleError.blockingValidationNotPassed(
                        stepID: currentStepDef.id, validationID: valID, label: label)
                }
            }
            requirementsEval = eval
        }

        let (stateJSON, outputJSON) = try codec.resolveCompletionPayload(completion, current: currentStepRun)
        let stateHash = try codec.stateSHA256(for: stateJSON)
        try codec.validate(entryPayload)

        let nextStepID = transition.targetStepID
        guard let nextStepDef = opDef.stepByID[nextStepID] else {
            throw WorkflowLifecycleError.currentStepDefinitionMissing(nextStepID)
        }
        let isTerminal = opDef.validated.terminalStepIDs.contains(nextStepID)
        let nextStepRunID = UUID()
        let decisionID = UUID()
        let nextStateHash = try codec.stateSHA256(for: entryPayload.stateJSON)

        var stepsToInsert: [WorkflowLifecycleStepInsert] = []
        if !isTerminal {
            let nextAttempt = aggregate.stepRuns
                .filter { $0.stepDefinitionID == nextStepID }
                .map { $0.attempt }.max() ?? 0
            stepsToInsert.append(WorkflowLifecycleStepInsert(
                id: nextStepRunID,
                stepDefinitionID: nextStepID,
                stepKind: nextStepDef.kind,
                attempt: nextAttempt + 1,
                status: .active,
                inputJSON: entryPayload.inputJSON,
                stateJSON: entryPayload.stateJSON,
                stateSHA256: nextStateHash,
                outputJSON: nil,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                completedAt: nil
            ))
        }

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: isTerminal ? .completed : .active,
                currentStepDefinitionID: isTerminal ? currentStepDef.id : nextStepID,
                currentStepRunID: isTerminal ? currentStepRun.id : nextStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: isTerminal ? now : nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: stepsToInsert,
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .completed,
                stateJSON: stateJSON,
                stateSHA256: stateHash,
                outputJSON: outputJSON,
                completedAt: now
            )],
            decisionToInsert: WorkflowLifecycleDecisionInsert(
                id: decisionID,
                stepRunID: currentStepRun.id,
                decisionKey: "branch",
                kind: .branchSelection,
                selectedOption: branch,
                rationale: rationale,
                actorKind: actor.kind,
                actorIdentifier: actor.identifier,
                supersedesDecisionID: nil,
                metadataJSON: "{}"
            ),
            checkpointReason: nil,
            eventType: .decisionRecorded,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )

        let result = try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)

        // PJE-005: apply advisory attention items after the plan succeeds (non-throwing)
        if let eval = requirementsEval, let reqEngine = requirementsEngine {
            await reqEngine.applyAttentionItems(
                evaluation: eval,
                runID: runID,
                stepRunID: currentStepRun.id,
                initialAggregate: result,
                actor: actor,
                now: now
            )
        }
        return result
    }

    // MARK: - Request Human Decision

    @discardableResult
    public func requestHumanDecision(
        runID: UUID,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .requestHumanDecision)
        let currentStepRun = try requireCurrentStepRun(aggregate)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .waitingForHuman,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .waiting,
                stateJSON: currentStepRun.stateJSON,
                stateSHA256: currentStepRun.stateSHA256,
                outputJSON: currentStepRun.outputJSON,
                completedAt: nil
            )],
            decisionToInsert: nil,
            checkpointReason: .beforeDecision,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Record Human Decision

    @discardableResult
    public func recordHumanDecision(
        runID: UUID,
        decisionKey: String,
        selectedOption: String,
        rationale: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .recordHumanDecision)
        try stateMachine.assertHumanActor(actor)

        let opDef = try makeOpDef(aggregate)
        let (currentStepDef, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)
        guard currentStepDef.kind == .decision || currentStepDef.kind == .humanApproval else {
            throw WorkflowLifecycleError.humanDecisionStepRequired
        }

        let decisionID = UUID()
        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .active,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .active,
                stateJSON: currentStepRun.stateJSON,
                stateSHA256: currentStepRun.stateSHA256,
                outputJSON: currentStepRun.outputJSON,
                completedAt: nil
            )],
            decisionToInsert: WorkflowLifecycleDecisionInsert(
                id: decisionID,
                stepRunID: currentStepRun.id,
                decisionKey: decisionKey,
                kind: .humanDecision,
                selectedOption: selectedOption,
                rationale: rationale,
                actorKind: actor.kind,
                actorIdentifier: actor.identifier,
                supersedesDecisionID: nil,
                metadataJSON: "{}"
            ),
            checkpointReason: nil,
            eventType: .decisionRecorded,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Record Human Approval

    @discardableResult
    public func recordHumanApproval(
        runID: UUID,
        approved: Bool,
        rationale: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .recordHumanApproval)

        let opDef = try makeOpDef(aggregate)
        let (currentStepDef, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)
        guard currentStepDef.kind == .humanApproval else {
            throw WorkflowLifecycleError.humanApprovalStepRequired
        }
        try stateMachine.assertHumanApproverRole(actor: actor, step: currentStepDef)

        let decisionID = UUID()
        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .active,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .active,
                stateJSON: currentStepRun.stateJSON,
                stateSHA256: currentStepRun.stateSHA256,
                outputJSON: currentStepRun.outputJSON,
                completedAt: nil
            )],
            decisionToInsert: WorkflowLifecycleDecisionInsert(
                id: decisionID,
                stepRunID: currentStepRun.id,
                decisionKey: "approval",
                kind: .humanApproval,
                selectedOption: approved ? "approved" : "rejected",
                rationale: rationale,
                actorKind: actor.kind,
                actorIdentifier: actor.identifier,
                supersedesDecisionID: nil,
                metadataJSON: "{}"
            ),
            checkpointReason: nil,
            eventType: .decisionRecorded,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Return to Prior Step

    @discardableResult
    public func returnToPriorStep(
        runID: UUID,
        selector: WorkflowTransitionSelector,
        completion: WorkflowStepCompletionPayload = WorkflowStepCompletionPayload(),
        entryPayload: WorkflowStepEntryPayload = .empty,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .returnToPriorStep)

        let opDef = try makeOpDef(aggregate)
        let (currentStepDef, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)

        let transition = try stateMachine.resolveReturnTransition(selector: selector, step: currentStepDef)
        guard transition.isReturn else { throw WorkflowLifecycleError.expectedReturnTransition }
        try stateMachine.assertReturnTransitionPolicy(
            transition: transition, sourceStep: currentStepDef, opDef: opDef)

        let (stateJSON, outputJSON) = try codec.resolveCompletionPayload(completion, current: currentStepRun)
        let stateHash = try codec.stateSHA256(for: stateJSON)
        try codec.validate(entryPayload)

        let targetStepID = transition.targetStepID
        guard let targetStepDef = opDef.stepByID[targetStepID] else {
            throw WorkflowLifecycleError.currentStepDefinitionMissing(targetStepID)
        }

        let newStepRunID = UUID()
        let priorAttempts = aggregate.stepRuns
            .filter { $0.stepDefinitionID == targetStepID }
            .map { $0.attempt }.max() ?? 0
        let nextStateHash = try codec.stateSHA256(for: entryPayload.stateJSON)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .active,
                currentStepDefinitionID: targetStepID,
                currentStepRunID: newStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [WorkflowLifecycleStepInsert(
                id: newStepRunID,
                stepDefinitionID: targetStepID,
                stepKind: targetStepDef.kind,
                attempt: priorAttempts + 1,
                status: .active,
                inputJSON: entryPayload.inputJSON,
                stateJSON: entryPayload.stateJSON,
                stateSHA256: nextStateHash,
                outputJSON: nil,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                completedAt: nil
            )],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .completed,
                stateJSON: stateJSON,
                stateSHA256: stateHash,
                outputJSON: outputJSON,
                completedAt: now
            )],
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Complete

    @discardableResult
    public func complete(
        runID: UUID,
        completion: WorkflowStepCompletionPayload = WorkflowStepCompletionPayload(),
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .complete)

        let opDef = try makeOpDef(aggregate)
        let (_, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)

        let (stateJSON, outputJSON) = try codec.resolveCompletionPayload(completion, current: currentStepRun)
        let stateHash = try codec.stateSHA256(for: stateJSON)

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .completed,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: now,
                cancelledAt: nil,
                cancellationReason: nil,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: [WorkflowLifecycleStepPatch(
                id: currentStepRun.id,
                newStatus: .completed,
                stateJSON: stateJSON,
                stateSHA256: stateHash,
                outputJSON: outputJSON,
                completedAt: now
            )],
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Cancel

    @discardableResult
    public func cancel(
        runID: UUID,
        reason: String,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        guard !reason.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WorkflowLifecycleError.cancellationReasonRequired
        }
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .cancel)

        var stepsToUpdate: [WorkflowLifecycleStepPatch] = []
        if let stepRun = aggregate.stepRuns.last(where: {
            $0.id == aggregate.run.currentStepRunID
        }), stepRun.status != .completed && stepRun.status != .cancelled && stepRun.status != .superseded {
            stepsToUpdate.append(WorkflowLifecycleStepPatch(
                id: stepRun.id,
                newStatus: .cancelled,
                stateJSON: stepRun.stateJSON,
                stateSHA256: stepRun.stateSHA256,
                outputJSON: stepRun.outputJSON,
                completedAt: now
            ))
        }

        let plan = WorkflowLifecyclePlan(
            runPatch: WorkflowLifecycleRunPatch(
                newStatus: .cancelled,
                currentStepDefinitionID: aggregate.run.currentStepDefinitionID,
                currentStepRunID: aggregate.run.currentStepRunID,
                startedAt: aggregate.run.startedAt,
                pausedAt: nil,
                completedAt: nil,
                cancelledAt: now,
                cancellationReason: reason,
                supersededByRunID: nil
            ),
            stepsToInsert: [],
            stepsToUpdate: stepsToUpdate,
            decisionToInsert: nil,
            checkpointReason: nil,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Supersede

    /// Atomically supersede an existing run and create a new draft replacement.
    public func supersede(
        runID: UUID,
        package: ResolvedPersonaApplicationPackage,
        selectedWorkflowID: WorkflowDefinitionID,
        workspaceID: Workspace.ID,
        title: String?,
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> WorkflowSupersessionResult {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .supersede)

        return try await repository.applySupersession(
            runID: runID,
            expectedRevision: aggregate.run.revision,
            package: package,
            selectedWorkflowID: selectedWorkflowID,
            workspaceID: workspaceID,
            title: title,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier,
            now: now
        )
    }

    // MARK: - Project

    public func project(runID: UUID) async throws -> WorkflowLifecycleProjection {
        let aggregate = try await repository.fetchRun(runID)
        let opDef = try makeOpDef(aggregate)
        let currentStepRun = aggregate.stepRuns.last(where: { $0.id == aggregate.run.currentStepRunID })
        return stateMachine.project(run: aggregate.run, currentStepRun: currentStepRun, opDef: opDef)
    }

    // MARK: - Validate definition

    public func validateDefinition(_ validated: ValidatedWorkflowDefinition) throws {
        try validator.validate(validated)
    }

    // MARK: - Private helpers

    private func makeOpDef(_ aggregate: ReopenedWorkflowRun) throws -> OperationalWorkflowDefinition {
        guard let validated = aggregate.contract.reconstructDefinition() else {
            throw WorkflowLifecycleError.aggregateInvariantViolation(
                runID: aggregate.run.id, detail: "contract snapshot failed to reconstruct definition")
        }
        return OperationalWorkflowDefinition(validated: validated)
    }

    private func requireCurrentStepRun(_ aggregate: ReopenedWorkflowRun) throws -> WorkflowStepRun {
        guard let stepRunID = aggregate.run.currentStepRunID else {
            throw WorkflowLifecycleError.missingCurrentStep(aggregate.run.id)
        }
        guard let stepRun = aggregate.stepRuns.first(where: { $0.id == stepRunID }) else {
            throw WorkflowLifecycleError.currentStepReferenceMismatch(aggregate.run.id)
        }
        return stepRun
    }

    private func requireCurrentStep(
        _ aggregate: ReopenedWorkflowRun,
        opDef: OperationalWorkflowDefinition
    ) throws -> (PersonaWorkflowStepDefinition, WorkflowStepRun) {
        let stepRun = try requireCurrentStepRun(aggregate)
        guard let stepDef = opDef.stepByID[stepRun.stepDefinitionID] else {
            throw WorkflowLifecycleError.currentStepDefinitionMissing(stepRun.stepDefinitionID)
        }
        guard stepDef.kind == stepRun.stepKind else {
            throw WorkflowLifecycleError.currentStepKindMismatch(
                stored: stepRun.stepKind, defined: stepDef.kind)
        }
        return (stepDef, stepRun)
    }
}
