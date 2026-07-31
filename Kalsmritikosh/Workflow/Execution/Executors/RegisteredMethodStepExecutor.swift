//
//  RegisteredMethodStepExecutor.swift
//  Kalsmritikosh
//
//  PM-003 — the v2 `.method` step executor. Where v1 records an external result
//  envelope, v2 drives a REGISTERED professional method: select an exact
//  definition+version, link an exact persisted MethodRun, and attach a completed
//  result whose provenance is DERIVED by the bridge from persisted method evidence
//  links (never caller-supplied).
//
//  Identity: the SAME executor id as v1 (`com.kalsmritikosh.step.method`), version
//  `"2"`, handled kind `.method`. The v1 executor and its schema-version-1 binding
//  are untouched; frozen v1 workflows keep reopening under v1.
//
//  The executor depends ONLY on the read-only WorkflowProfessionalMethodRunResolving
//  protocol — never persistence, a method store, the method registry, or SQL.
//  Completing this workflow step means only that the workflow ACCEPTED a method
//  result; it never confirms the result as truth or promotes a finding into a Claim.
//

import Foundation

// MARK: - Derived status (presentation only — NOT a second truth system)

public enum RegisteredMethodStepStatus: String, Codable, CaseIterable, Sendable {
    case awaitingSelection
    case awaitingRun
    case methodInProgress
    case resultAttached
}

// MARK: - State

public nonisolated struct RegisteredMethodStepState: Codable, Hashable, Sendable {
    public let selection: WorkflowProfessionalMethodSelection?
    public let instructions: String?
    public let linkedRun: WorkflowProfessionalMethodRunReference?
    public let result: WorkflowProfessionalMethodResultReference?

    public nonisolated init(
        selection: WorkflowProfessionalMethodSelection? = nil,
        instructions: String? = nil,
        linkedRun: WorkflowProfessionalMethodRunReference? = nil,
        result: WorkflowProfessionalMethodResultReference? = nil
    ) {
        self.selection = selection
        self.instructions = instructions
        self.linkedRun = linkedRun
        self.result = result
    }

    /// Working-state projection; derived, never a stored truth field.
    public nonisolated var derivedStatus: RegisteredMethodStepStatus {
        if result != nil { return .resultAttached }
        if linkedRun != nil { return .methodInProgress }
        if selection != nil { return .awaitingRun }
        return .awaitingSelection
    }
}

// MARK: - Commands

public enum RegisteredMethodStepCommand: Sendable, Equatable, Codable {
    case selectMethod(methodDefinitionID: String, methodDefinitionVersion: Int)
    case setInstructions(String)
    case linkRun(methodRunID: UUID)
    case unlinkRun
    case attachCompletedResult(summary: String, limitations: [String])
    case removeResult
    case complete

    private enum CodingKeys: String, CodingKey {
        case type, methodDefinitionID, methodDefinitionVersion, instructions, methodRunID, summary, limitations
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "selectMethod":
            self = .selectMethod(
                methodDefinitionID: try c.decode(String.self, forKey: .methodDefinitionID),
                methodDefinitionVersion: try c.decode(Int.self, forKey: .methodDefinitionVersion))
        case "setInstructions":
            self = .setInstructions(try c.decode(String.self, forKey: .instructions))
        case "linkRun":
            self = .linkRun(methodRunID: try c.decode(UUID.self, forKey: .methodRunID))
        case "unlinkRun":
            self = .unlinkRun
        case "attachCompletedResult":
            self = .attachCompletedResult(
                summary: try c.decode(String.self, forKey: .summary),
                limitations: try c.decodeIfPresent([String].self, forKey: .limitations) ?? [])
        case "removeResult":
            self = .removeResult
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selectMethod(let id, let version):
            try c.encode("selectMethod", forKey: .type)
            try c.encode(id, forKey: .methodDefinitionID)
            try c.encode(version, forKey: .methodDefinitionVersion)
        case .setInstructions(let text):
            try c.encode("setInstructions", forKey: .type)
            try c.encode(text, forKey: .instructions)
        case .linkRun(let runID):
            try c.encode("linkRun", forKey: .type)
            try c.encode(runID, forKey: .methodRunID)
        case .unlinkRun:
            try c.encode("unlinkRun", forKey: .type)
        case .attachCompletedResult(let summary, let limitations):
            try c.encode("attachCompletedResult", forKey: .type)
            try c.encode(summary, forKey: .summary)
            try c.encode(limitations, forKey: .limitations)
        case .removeResult:
            try c.encode("removeResult", forKey: .type)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct RegisteredMethodStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(rawValue: "com.kalsmritikosh.step.method")
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "2")
    public nonisolated let handledKind: WorkflowStepKind = .method

    private let resolver: any WorkflowProfessionalMethodRunResolving

    public nonisolated init(resolver: any WorkflowProfessionalMethodRunResolving) {
        self.resolver = resolver
    }

    // MARK: Prepare

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind)
        }
        let state = RegisteredMethodStepState()
        let (json, sha) = try makeEnvelope(
            state: state, stepKind: handledKind,
            requirementFacts: Self.buildFacts(state: state, step: context.step))
        return WorkflowStepPreparationResult(
            inputJSON: "{}", stateJSON: json, stateSHA256: sha,
            executorID: executorID, executorVersion: executorVersion)
    }

    // MARK: Execute

    public func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind)
        }
        let state = try decodeCurrentState(RegisteredMethodStepState.self, from: context.stepRun)
        let command: RegisteredMethodStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(RegisteredMethodStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        let workspaceID = context.aggregate.run.workspaceID
        let workflowRunID = context.aggregate.run.id
        let workflowStepRunID = context.stepRun.id

        func save(_ newState: RegisteredMethodStepState) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(
                state: newState, stepKind: handledKind,
                requirementFacts: Self.buildFacts(state: newState, step: context.step))
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {

        case .selectMethod(let id, let version):
            let selection = WorkflowProfessionalMethodSelection(
                methodDefinitionID: id, methodDefinitionVersion: version)
            try selection.validateStructure()
            // Changing an already-selected method requires no run/result linked.
            if let existing = state.selection, existing != selection {
                guard state.linkedRun == nil, state.result == nil else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "selection",
                        reason: "Cannot change the selected method after a run or result is linked")
                }
            }
            try await resolver.validateSelection(selection)
            return try save(RegisteredMethodStepState(
                selection: selection, instructions: state.instructions,
                linkedRun: state.linkedRun, result: state.result))

        case .setInstructions(let text):
            return try save(RegisteredMethodStepState(
                selection: state.selection, instructions: text,
                linkedRun: state.linkedRun, result: state.result))

        case .linkRun(let methodRunID):
            guard let selection = state.selection else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "selection", reason: "A method must be selected before linking a run")
            }
            guard state.linkedRun == nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "linkedRun", reason: "A run is already linked")
            }
            let reference = try await resolver.validateLinkedRun(
                runID: methodRunID, selection: selection, workspaceID: workspaceID,
                workflowRunID: workflowRunID, workflowStepRunID: workflowStepRunID)
            return try save(RegisteredMethodStepState(
                selection: selection, instructions: state.instructions,
                linkedRun: reference, result: state.result))

        case .unlinkRun:
            guard state.linkedRun != nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "linkedRun", reason: "No run is linked")
            }
            guard state.result == nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "result", reason: "Remove the attached result before unlinking the run")
            }
            return try save(RegisteredMethodStepState(
                selection: state.selection, instructions: state.instructions,
                linkedRun: nil, result: nil))

        case .attachCompletedResult(let summary, let limitations):
            guard let selection = state.selection else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "selection", reason: "A method must be selected before attaching a result")
            }
            guard let linkedRun = state.linkedRun else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "linkedRun", reason: "A run must be linked before attaching a result")
            }
            guard context.actor.kind == .human,
                  let actorID = context.actor.identifier,
                  !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "actor", reason: "A human actor is required to attach a completed method result")
            }
            // The bridge derives provenance, revision, definition/run identity and
            // completion time — none are accepted from the command payload.
            let result = try await resolver.completedResult(
                runID: linkedRun.methodRunID, selection: selection, workspaceID: workspaceID,
                workflowRunID: workflowRunID, workflowStepRunID: workflowStepRunID,
                summary: summary, completedBy: actorID, limitations: limitations)
            return try save(RegisteredMethodStepState(
                selection: selection, instructions: state.instructions,
                linkedRun: linkedRun, result: result))

        case .removeResult:
            guard state.result != nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "result", reason: "No attached result to remove")
            }
            return try save(RegisteredMethodStepState(
                selection: state.selection, instructions: state.instructions,
                linkedRun: state.linkedRun, result: nil))

        case .complete:
            guard state.selection != nil else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "A method must be selected before completion")
            }
            guard state.linkedRun != nil else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "A run must be linked before completion")
            }
            guard state.result != nil else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "A completed method result must be attached before completion")
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared")
            }
            let (json, sha) = try makeEnvelope(
                state: state, stepKind: handledKind,
                requirementFacts: Self.buildFacts(state: state, step: context.step))
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label)))
        }
    }

    // MARK: Requirement facts

    private static nonisolated func buildFacts(
        state: RegisteredMethodStepState,
        step: PersonaWorkflowStepDefinition
    ) -> [WorkflowStepRequirementFact] {
        step.requirements
            .filter { $0.kind == .methodResultPresent }
            .map { requirement in
                WorkflowStepRequirementFact(
                    requirementID: requirement.id,
                    kind: .methodResultPresent,
                    isSatisfied: state.result != nil,
                    detail: state.result == nil ? "No completed method result attached" : nil)
            }
    }
}
