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
            actorIdentifier: actor.identifier,
            stepProvenance: [try stepProvenanceInput(
                runID: runID, stepRunID: stepRunID,
                revision: aggregate.run.revision + 1,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                stateSHA256: stateHash, references: [])]
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

        // PJE-007: a pause whose completion payload CHANGES the step state must
        // ride with a fresh provenance snapshot in the SAME savepoint, or the
        // step's latest snapshot would stop describing its persisted state and
        // reopen would fail. References are carried forward from the step's
        // existing snapshot — never fabricated or dropped. Legacy steps and
        // no-op pauses (unchanged state) are left untouched.
        var pauseProvenance: [WorkflowProvenancePersistenceInput] = []
        if stateHash != currentStepRun.stateSHA256,
           try await repository.provenanceSemantics(owner: .stepRun(currentStepRun.id)) == .snapshotV1 {
            let carried = try await currentStepSnapshotReferences(stepRunID: currentStepRun.id)
            pauseProvenance = [try stepProvenanceInput(
                runID: runID, stepRunID: currentStepRun.id,
                revision: aggregate.run.revision + 1,
                executorID: currentStepRun.executorID,
                executorVersion: currentStepRun.executorVersion,
                stateSHA256: stateHash, references: carried)]
        }

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
            actorIdentifier: actor.identifier,
            stepProvenance: pauseProvenance
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
        completionReferences: [WorkflowProvenanceReference] = [],
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

        // PJE-007: completed-step snapshot (executor references) + prepared-step
        // snapshot (empty) ride in the SAME SAVEPOINT as the transition.
        var stepProvenance: [WorkflowProvenancePersistenceInput] = [
            try stepProvenanceInput(
                runID: runID, stepRunID: currentStepRun.id,
                revision: aggregate.run.revision + 1,
                executorID: currentStepRun.executorID,
                executorVersion: currentStepRun.executorVersion,
                stateSHA256: stateHash, references: completionReferences)
        ]
        if !isTerminal {
            stepProvenance.append(try stepProvenanceInput(
                runID: runID, stepRunID: nextStepRunID,
                revision: aggregate.run.revision + 1,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                stateSHA256: nextStateHash, references: []))
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
            actorIdentifier: actor.identifier,
            stepProvenance: stepProvenance
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
        completionReferences: [WorkflowProvenanceReference] = [],
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

        // PJE-007: completed-step + prepared-step snapshots for this branch transition.
        var branchStepProvenance: [WorkflowProvenancePersistenceInput] = [
            try stepProvenanceInput(
                runID: runID, stepRunID: currentStepRun.id,
                revision: aggregate.run.revision + 1,
                executorID: currentStepRun.executorID,
                executorVersion: currentStepRun.executorVersion,
                stateSHA256: stateHash, references: completionReferences)
        ]
        if !isTerminal {
            branchStepProvenance.append(try stepProvenanceInput(
                runID: runID, stepRunID: nextStepRunID,
                revision: aggregate.run.revision + 1,
                executorID: entryPayload.executorID,
                executorVersion: entryPayload.executorVersion,
                stateSHA256: nextStateHash, references: []))
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
            actorIdentifier: actor.identifier,
            stepProvenance: branchStepProvenance,
            decisionProvenance: try decisionProvenanceInput(
                runID: runID, decisionID: decisionID,
                revision: aggregate.run.revision + 1, basis: [])
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
        basis: [WorkflowProvenanceReference] = [],
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
            actorIdentifier: actor.identifier,
            decisionProvenance: try decisionProvenanceInput(
                runID: runID, decisionID: decisionID,
                revision: aggregate.run.revision + 1, basis: basis)
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
        basis: [WorkflowProvenanceReference] = [],
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
            actorIdentifier: actor.identifier,
            decisionProvenance: try decisionProvenanceInput(
                runID: runID, decisionID: decisionID,
                revision: aggregate.run.revision + 1, basis: basis)
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
        completionReferences: [WorkflowProvenanceReference] = [],
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
            actorIdentifier: actor.identifier,
            stepProvenance: [
                try stepProvenanceInput(
                    runID: runID, stepRunID: currentStepRun.id,
                    revision: aggregate.run.revision + 1,
                    executorID: currentStepRun.executorID,
                    executorVersion: currentStepRun.executorVersion,
                    stateSHA256: stateHash, references: completionReferences),
                try stepProvenanceInput(
                    runID: runID, stepRunID: newStepRunID,
                    revision: aggregate.run.revision + 1,
                    executorID: entryPayload.executorID,
                    executorVersion: entryPayload.executorVersion,
                    stateSHA256: nextStateHash, references: [])
            ]
        )
        return try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)
    }

    // MARK: - Complete

    /// PJE-006C: terminal completion applies the SAME PJE-005 gate as advance and
    /// chooseBranch — blocking requirement/validation failures and open blocking
    /// attention items prevent completion, and a durable completion checkpoint is
    /// created inside the same plan. completeTerminal can never bypass PJE-005.
    @discardableResult
    public func complete(
        runID: UUID,
        completion: WorkflowStepCompletionPayload = WorkflowStepCompletionPayload(),
        scope: SensitiveScope? = nil,
        completionReferences: [WorkflowProvenanceReference] = [],
        actor: WorkflowLifecycleActor,
        now: Date
    ) async throws -> ReopenedWorkflowRun {
        let aggregate = try await repository.fetchRun(runID)
        try stateMachine.assertRunTransitionAllowed(from: aggregate.run.status, action: .complete)

        let opDef = try makeOpDef(aggregate)
        let (currentStepDef, currentStepRun) = try requireCurrentStep(aggregate, opDef: opDef)

        // 1–3. Evaluate current-step validations + requirements; throw on blocking failure.
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

        // 4. Open blocking attention items prevent terminal completion.
        if let openBlocking = aggregate.attentionItems.first(where: {
            $0.status == .open && $0.severity == .blocking
        }) {
            throw WorkflowLifecycleError.blockingAttentionOpen(
                itemID: openBlocking.id, title: openBlocking.title)
        }

        let (stateJSON, outputJSON) = try codec.resolveCompletionPayload(completion, current: currentStepRun)
        let stateHash = try codec.stateSHA256(for: stateJSON)

        // 5–6. Apply the terminal plan with a durable completion checkpoint.
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
            checkpointReason: .completion,
            eventType: .runStateChanged,
            actorKind: actor.kind,
            actorIdentifier: actor.identifier,
            stepProvenance: [try stepProvenanceInput(
                runID: runID, stepRunID: currentStepRun.id,
                revision: aggregate.run.revision + 1,
                executorID: currentStepRun.executorID,
                executorVersion: currentStepRun.executorVersion,
                stateSHA256: stateHash, references: completionReferences)]
        )
        let result = try await repository.applyLifecyclePlan(
            runID: runID, expectedRevision: aggregate.run.revision, plan: plan, now: now)

        // 7. Advisory attention-item updates after successful completion (non-throwing).
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

    // MARK: - PJE-007 provenance helpers

    /// Build a step-state snapshot input. Producer identity is the exact
    /// executor identity when known; otherwise the lifecycle fallback identity.
    private nonisolated func stepProvenanceInput(
        runID: UUID,
        stepRunID: UUID,
        revision: Int,
        executorID: String?,
        executorVersion: String?,
        stateSHA256: String,
        references: [WorkflowProvenanceReference]
    ) throws -> WorkflowProvenancePersistenceInput {
        let producerID = (executorID?.isEmpty == false)
            ? executorID! : WorkflowProvenanceProducers.lifecycleID
        let producerVersion = (executorVersion?.isEmpty == false)
            ? executorVersion! : WorkflowProvenanceProducers.lifecycleVersion
        let snapshot = WorkflowProvenanceSnapshot(
            ownerKind: .stepState,
            workflowRunID: runID,
            ownerID: stepRunID,
            workflowRunRevision: revision,
            producerID: producerID,
            producerVersion: producerVersion,
            sourceStateSHA256: stateSHA256,
            references: references)
        return try WorkflowProvenancePersistenceInput.make(snapshot: snapshot)
    }

    /// The references on a step's latest provenance snapshot, decoded and
    /// hash-verified. Empty when the step has no snapshot. Used to carry an
    /// executor's references forward through a state-changing pause so provenance
    /// is preserved rather than fabricated or dropped.
    private func currentStepSnapshotReferences(
        stepRunID: UUID
    ) async throws -> [WorkflowProvenanceReference] {
        let rows = try await repository.provenanceSnapshots(owner: .stepRun(stepRunID))
        guard let latest = rows.last else { return [] }
        return try WorkflowProvenanceCodec.decodeAndVerify(
            json: latest.snapshotJSON, expectedSHA256: latest.snapshotSHA256,
            snapshotID: latest.id).references
    }

    /// Build a decision snapshot input (empty basis snapshots are valid).
    private nonisolated func decisionProvenanceInput(
        runID: UUID,
        decisionID: UUID,
        revision: Int,
        basis: [WorkflowProvenanceReference]
    ) throws -> WorkflowProvenancePersistenceInput {
        let snapshot = WorkflowProvenanceSnapshot(
            ownerKind: .decision,
            workflowRunID: runID,
            ownerID: decisionID,
            workflowRunRevision: revision,
            producerID: WorkflowProvenanceProducers.decisionID,
            producerVersion: WorkflowProvenanceProducers.decisionVersion,
            sourceStateSHA256: nil,
            references: basis)
        return try WorkflowProvenancePersistenceInput.make(snapshot: snapshot)
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
