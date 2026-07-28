//
//  WorkflowStepExecutionTypes.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Foundation types: stable IDs, bindings, contexts, results,
//  dispositions, and the typed error vocabulary.
//  No executor logic, no persistence, no lifecycle policy.
//

import Foundation

// MARK: - Stable executor IDs

/// Stable, string-backed identity for a step executor implementation.
/// Reverse-domain convention: `"com.kalsmritikosh.step.intake"`.
public nonisolated struct WorkflowStepExecutorID:
    RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

/// Immutable version token for a step executor implementation.
/// Must not use a build timestamp. Use a stable semantic identifier.
public nonisolated struct WorkflowStepExecutorVersion:
    RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public nonisolated init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Executor binding

/// Deterministic binding: for a given frozen workflow schema version and step kind,
/// resolves to the exact executor ID + version to use.
public nonisolated struct WorkflowStepExecutorBinding:
    Hashable, Codable, Sendable {
    public let workflowSchemaVersion: Int
    public let stepKind: WorkflowStepKind
    public let executorID: WorkflowStepExecutorID
    public let executorVersion: WorkflowStepExecutorVersion

    public nonisolated init(
        workflowSchemaVersion: Int,
        stepKind: WorkflowStepKind,
        executorID: WorkflowStepExecutorID,
        executorVersion: WorkflowStepExecutorVersion
    ) {
        self.workflowSchemaVersion = workflowSchemaVersion
        self.stepKind = stepKind
        self.executorID = executorID
        self.executorVersion = executorVersion
    }
}

// MARK: - Preparation context

/// Context passed to `WorkflowStepExecutor.prepare()` when entering a step for the first time.
/// The workflow and step come from the frozen run contract — never from the live catalog.
public nonisolated struct WorkflowStepPreparationContext: Sendable {
    public let runID: UUID
    public let workspaceID: Workspace.ID
    public let runRevision: Int
    public let workflow: ValidatedWorkflowDefinition
    public let step: PersonaWorkflowStepDefinition
    public let actor: WorkflowLifecycleActor
    public let preparedAt: Date

    public nonisolated init(
        runID: UUID,
        workspaceID: Workspace.ID,
        runRevision: Int,
        workflow: ValidatedWorkflowDefinition,
        step: PersonaWorkflowStepDefinition,
        actor: WorkflowLifecycleActor,
        preparedAt: Date
    ) {
        self.runID = runID
        self.workspaceID = workspaceID
        self.runRevision = runRevision
        self.workflow = workflow
        self.step = step
        self.actor = actor
        self.preparedAt = preparedAt
    }
}

// MARK: - Execution context

/// Context passed to `WorkflowStepExecutor.execute()` on each command invocation.
/// Validated at construction: kind match, executor identity match, current step invariants.
public nonisolated struct WorkflowStepExecutionContext: Sendable {
    public let aggregate: ReopenedWorkflowRun
    public let workflow: ValidatedWorkflowDefinition
    public let step: PersonaWorkflowStepDefinition
    public let stepRun: WorkflowStepRun
    public let actor: WorkflowLifecycleActor
    public let executedAt: Date

    /// Validates all structural invariants before creating the context.
    public nonisolated init(
        aggregate: ReopenedWorkflowRun,
        workflow: ValidatedWorkflowDefinition,
        step: PersonaWorkflowStepDefinition,
        stepRun: WorkflowStepRun,
        actor: WorkflowLifecycleActor,
        executedAt: Date,
        executorID: WorkflowStepExecutorID,
        executorVersion: WorkflowStepExecutorVersion
    ) throws {
        guard stepRun.workflowRunID == aggregate.run.id else {
            throw WorkflowStepExecutionError.currentStepMismatch(aggregate.run.id)
        }
        guard workflow.definition.steps.contains(where: { $0.id == step.id }) else {
            throw WorkflowStepExecutionError.currentStepMismatch(aggregate.run.id)
        }
        guard stepRun.stepKind == step.kind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID,
                expected: step.kind,
                actual: stepRun.stepKind
            )
        }
        guard stepRun.executorID == executorID.rawValue else {
            throw WorkflowStepExecutionError.executorNotFound(id: executorID, version: executorVersion)
        }
        guard stepRun.executorVersion == executorVersion.rawValue else {
            throw WorkflowStepExecutionError.executorNotFound(id: executorID, version: executorVersion)
        }
        guard aggregate.run.currentStepRunID == stepRun.id else {
            throw WorkflowStepExecutionError.noCurrentStep(aggregate.run.id)
        }
        let terminalStatuses: [WorkflowRunStatus] = [.completed, .cancelled, .superseded]
        guard !terminalStatuses.contains(aggregate.run.status) else {
            throw WorkflowStepExecutionError.unsupportedOperation(kind: step.kind)
        }
        self.aggregate = aggregate
        self.workflow = workflow
        self.step = step
        self.stepRun = stepRun
        self.actor = actor
        self.executedAt = executedAt
    }
}

// MARK: - Preparation result

/// Returned by `WorkflowStepExecutor.prepare()`.
/// The engine verifies that the executor identity matches and recalculates the state hash.
public nonisolated struct WorkflowStepPreparationResult: Sendable {
    public let inputJSON: String
    public let stateJSON: String
    public let stateSHA256: String
    public let executorID: WorkflowStepExecutorID
    public let executorVersion: WorkflowStepExecutorVersion

    public nonisolated init(
        inputJSON: String,
        stateJSON: String,
        stateSHA256: String,
        executorID: WorkflowStepExecutorID,
        executorVersion: WorkflowStepExecutorVersion
    ) {
        self.inputJSON = inputJSON
        self.stateJSON = stateJSON
        self.stateSHA256 = stateSHA256
        self.executorID = executorID
        self.executorVersion = executorVersion
    }
}

// MARK: - Execution disposition

/// How the executor wants to transition (or not) the workflow state after a command.
/// Executors REQUEST operations; the engine performs them. Executors never perform
/// lifecycle or persistence operations themselves.
public enum WorkflowStepExecutionDisposition: Sendable, Equatable {
    /// Stay on the current step; persist updated state without advancing.
    case remainActive
    /// Advance to the target step via the given transition selector.
    case advance(WorkflowTransitionSelector)
    /// Return to a prior step via the given return transition selector.
    case returnToPriorStep(WorkflowTransitionSelector)
    /// Follow a declared decision branch (PJE-004 chooseBranch).
    case chooseBranch(branch: String, rationale: String?)
    /// Persist executor state, then place the run in waitingForHuman for a decision.
    case requestHumanDecision
    /// Persist executor state, then place the run in waitingForHuman for an approval.
    case requestHumanApproval
    /// Build a cited work product through the accepted assembly path (coordinator).
    case buildWorkProduct(WorkflowWorkProductBuildRequest)
    /// Complete the workflow terminally (gated PJE-004 completion).
    case completeTerminal
}

// MARK: - Work-product build request (PJE-006C)

/// The executor-issued request to build a work product. Carries frozen-definition
/// IDs and the caller's SensitiveAccessContext — never composer IDs (composer order
/// comes from the accepted work-product assembly plan).
public nonisolated struct WorkflowWorkProductBuildRequest: Codable, Hashable, Sendable {
    public let artifactDefinitionID: String
    public let workProductDefinitionID: String
    public let subjectLabel: String
    public let corpusSnapshotID: UUID?
    public let access: SensitiveAccessContext

    public nonisolated init(
        artifactDefinitionID: String,
        workProductDefinitionID: String,
        subjectLabel: String,
        corpusSnapshotID: UUID?,
        access: SensitiveAccessContext
    ) {
        self.artifactDefinitionID = artifactDefinitionID
        self.workProductDefinitionID = workProductDefinitionID
        self.subjectLabel = subjectLabel
        self.corpusSnapshotID = corpusSnapshotID
        self.access = access
    }

    // SensitiveAccessContext/SensitiveScope are not Codable/Hashable — encode the
    // scope's four fields explicitly so the request round-trips through command JSON.
    private enum CodingKeys: String, CodingKey {
        case artifactDefinitionID, workProductDefinitionID, subjectLabel, corpusSnapshotID
        case scopeWorkspaceID, scopeMaximumSensitivity, scopePermitsPrivileged, scopePurpose
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artifactDefinitionID = try c.decode(String.self, forKey: .artifactDefinitionID)
        workProductDefinitionID = try c.decode(String.self, forKey: .workProductDefinitionID)
        subjectLabel = try c.decode(String.self, forKey: .subjectLabel)
        corpusSnapshotID = try c.decodeIfPresent(UUID.self, forKey: .corpusSnapshotID)
        let wsID = try c.decode(UUID.self, forKey: .scopeWorkspaceID)
        let sensitivityRaw = try c.decode(Int.self, forKey: .scopeMaximumSensitivity)
        guard let sensitivity = SensitivityLevel(rawValue: sensitivityRaw) else {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
        let privileged = try c.decode(Bool.self, forKey: .scopePermitsPrivileged)
        let purposeRaw = try c.decode(String.self, forKey: .scopePurpose)
        guard let purpose = SensitiveUsePurpose(rawValue: purposeRaw) else {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
        access = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: sensitivity,
            permitsPrivilegedMaterial: privileged, purpose: purpose))
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(artifactDefinitionID, forKey: .artifactDefinitionID)
        try c.encode(workProductDefinitionID, forKey: .workProductDefinitionID)
        try c.encode(subjectLabel, forKey: .subjectLabel)
        if let corpusSnapshotID = corpusSnapshotID {
            try c.encode(corpusSnapshotID, forKey: .corpusSnapshotID)
        }
        try c.encode(access.scope.workspaceID, forKey: .scopeWorkspaceID)
        try c.encode(access.scope.maximumSensitivity.rawValue, forKey: .scopeMaximumSensitivity)
        try c.encode(access.scope.permitsPrivilegedMaterial, forKey: .scopePermitsPrivileged)
        try c.encode(access.scope.purpose.rawValue, forKey: .scopePurpose)
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(artifactDefinitionID)
        hasher.combine(workProductDefinitionID)
        hasher.combine(subjectLabel)
        hasher.combine(corpusSnapshotID)
        hasher.combine(access.scope.workspaceID)
        hasher.combine(access.scope.maximumSensitivity)
        hasher.combine(access.scope.permitsPrivilegedMaterial)
        hasher.combine(access.scope.purpose)
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.artifactDefinitionID == b.artifactDefinitionID
            && a.workProductDefinitionID == b.workProductDefinitionID
            && a.subjectLabel == b.subjectLabel
            && a.corpusSnapshotID == b.corpusSnapshotID
            && a.access == b.access
    }
}

// MARK: - Execution result

/// Returned by `WorkflowStepExecutor.execute()`.
/// State hash is recalculated by the engine; the executor's `stateSHA256` is verified.
public nonisolated struct WorkflowStepExecutionResult: Sendable {
    public let stateJSON: String
    public let stateSHA256: String
    public let outputJSON: String?
    public let disposition: WorkflowStepExecutionDisposition
    public let detail: String?

    public nonisolated init(
        stateJSON: String,
        stateSHA256: String,
        outputJSON: String? = nil,
        disposition: WorkflowStepExecutionDisposition,
        detail: String? = nil
    ) {
        self.stateJSON = stateJSON
        self.stateSHA256 = stateSHA256
        self.outputJSON = outputJSON
        self.disposition = disposition
        self.detail = detail
    }
}

// MARK: - Error vocabulary

public enum WorkflowStepExecutionError: Error, Equatable, Sendable {
    case invalidExecutorID(String)
    case invalidExecutorVersion(String)

    case duplicateExecutor(
        id: WorkflowStepExecutorID,
        version: WorkflowStepExecutorVersion
    )
    case duplicateBinding(
        workflowSchemaVersion: Int,
        kind: WorkflowStepKind
    )
    case executorBindingMissing(
        workflowSchemaVersion: Int,
        kind: WorkflowStepKind
    )
    case executorNotFound(
        id: WorkflowStepExecutorID,
        version: WorkflowStepExecutorVersion
    )
    case executorKindMismatch(
        executor: WorkflowStepExecutorID,
        expected: WorkflowStepKind,
        actual: WorkflowStepKind
    )
    case noCurrentStep(UUID)
    case currentStepMismatch(UUID)

    case malformedCommandJSON
    case malformedStateJSON
    case malformedOutputJSON

    case stateEnvelopeKindMismatch
    case stateEnvelopeExecutorMismatch

    case duplicateRequirementFact(
        requirementID: String,
        kind: WorkflowRequirementKind
    )
    case unsupportedOperation(kind: WorkflowStepKind)
    case validationFailed(field: String, reason: String)
    case completionNotReady(kind: WorkflowStepKind, reason: String)
    case preparationFailed(kind: WorkflowStepKind, reason: String)
}
