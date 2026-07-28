//
//  MethodStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006C — Handles the `method` step kind as an ADAPTER only.
//  Records that a method result was produced outside/ahead of the Stage 4
//  Professional Method Engine. Emits `.methodResultPresent` requirement facts
//  for the requirement IDs declared on the frozen step definition.
//
//  This executor never creates a Claim, never confirms a root cause, and never
//  labels a result a confirmed fact.
//  Commands: setRequestedMethod, setInstructions, attachResult, removeResult, complete.
//

import Foundation

// MARK: - Status

public enum MethodStepStatus: String, Codable, CaseIterable, Sendable {
    case awaitingResult
    case resultAttached
}

// MARK: - State

public nonisolated struct MethodStepState: Codable, Hashable, Sendable {
    public let requestedMethodDefinitionID: String?
    public let instructions: String?
    public let status: MethodStepStatus
    public let result: WorkflowMethodResultReference?

    public nonisolated init(
        requestedMethodDefinitionID: String? = nil,
        instructions: String? = nil,
        status: MethodStepStatus = .awaitingResult,
        result: WorkflowMethodResultReference? = nil
    ) {
        self.requestedMethodDefinitionID = requestedMethodDefinitionID
        self.instructions = instructions
        self.status = status
        self.result = result
    }
}

// MARK: - Command

public enum MethodStepCommand: Sendable, Equatable {
    case setRequestedMethod(methodDefinitionID: String)
    case setInstructions(String)
    case attachResult(WorkflowMethodResultReference)
    case removeResult
    case complete
}

extension MethodStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, methodDefinitionID, instructions, result }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setRequestedMethod":
            self = .setRequestedMethod(
                methodDefinitionID: try c.decode(String.self, forKey: .methodDefinitionID))
        case "setInstructions":
            self = .setInstructions(try c.decode(String.self, forKey: .instructions))
        case "attachResult":
            self = .attachResult(try c.decode(WorkflowMethodResultReference.self, forKey: .result))
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
        case .setRequestedMethod(let id):
            try c.encode("setRequestedMethod", forKey: .type)
            try c.encode(id, forKey: .methodDefinitionID)
        case .setInstructions(let text):
            try c.encode("setInstructions", forKey: .type)
            try c.encode(text, forKey: .instructions)
        case .attachResult(let result):
            try c.encode("attachResult", forKey: .type)
            try c.encode(result, forKey: .result)
        case .removeResult:
            try c.encode("removeResult", forKey: .type)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct MethodStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.method"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    public nonisolated let handledKind: WorkflowStepKind = .method

    private let gate: any WorkflowEvidenceReferenceGating

    public nonisolated init(gate: any WorkflowEvidenceReferenceGating) {
        self.gate = gate
    }

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let state = MethodStepState()
        let (json, sha) = try makeEnvelope(
            state: state, stepKind: handledKind,
            requirementFacts: Self.buildFacts(state: state, step: context.step)
        )
        return WorkflowStepPreparationResult(
            inputJSON: "{}", stateJSON: json, stateSHA256: sha,
            executorID: executorID, executorVersion: executorVersion
        )
    }

    public func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let state = try decodeCurrentState(MethodStepState.self, from: context.stepRun)
        let command: MethodStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(MethodStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save(_ newState: MethodStepState) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(
                state: newState, stepKind: handledKind,
                requirementFacts: Self.buildFacts(state: newState, step: context.step)
            )
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .setRequestedMethod(let methodDefinitionID):
            guard !methodDefinitionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "methodDefinitionID", reason: "Method definition ID must not be blank")
            }
            return try save(MethodStepState(
                requestedMethodDefinitionID: methodDefinitionID,
                instructions: state.instructions,
                status: state.status, result: state.result))

        case .setInstructions(let text):
            return try save(MethodStepState(
                requestedMethodDefinitionID: state.requestedMethodDefinitionID,
                instructions: text,
                status: state.status, result: state.result))

        case .attachResult(let result):
            try result.validateStructure()
            // Provenance references pointing at canonical objects are workspace-gated.
            for ref in result.provenanceReferences {
                guard let kind = WorkflowEvidenceObjectKind(rawValue: ref.objectKind) else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "provenanceReferences",
                        reason: "Unknown canonical object kind '\(ref.objectKind)'")
                }
                guard let objectUUID = UUID(uuidString: ref.canonicalObjectID) else {
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "provenanceReferences", reason: "Not a valid canonical object UUID")
                }
                let verdict = await gate.verdict(
                    kind: kind, canonicalObjectID: objectUUID,
                    workspaceID: context.aggregate.run.workspaceID)
                guard case .permitted = verdict else {
                    if case .denied(let why) = verdict {
                        throw WorkflowStepExecutionError.validationFailed(
                            field: "provenanceReferences", reason: why)
                    }
                    throw WorkflowStepExecutionError.validationFailed(
                        field: "provenanceReferences", reason: "Reference denied")
                }
            }
            return try save(MethodStepState(
                requestedMethodDefinitionID: state.requestedMethodDefinitionID,
                instructions: state.instructions,
                status: .resultAttached, result: result))

        case .removeResult:
            guard state.result != nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "result", reason: "No attached result to remove")
            }
            return try save(MethodStepState(
                requestedMethodDefinitionID: state.requestedMethodDefinitionID,
                instructions: state.instructions,
                status: .awaitingResult, result: nil))

        case .complete:
            guard state.result != nil else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "A valid method result must be attached before completion")
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared")
            }
            let (json, sha) = try makeEnvelope(
                state: state, stepKind: handledKind,
                requirementFacts: Self.buildFacts(state: state, step: context.step)
            )
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }

    // MARK: - Requirement facts

    /// One fact per `.methodResultPresent` requirement DECLARED on the frozen step —
    /// the requirement ID comes from the step definition, never from human-readable detail.
    private static nonisolated func buildFacts(
        state: MethodStepState,
        step: PersonaWorkflowStepDefinition
    ) -> [WorkflowStepRequirementFact] {
        step.requirements
            .filter { $0.kind == .methodResultPresent }
            .map { req in
                WorkflowStepRequirementFact(
                    requirementID: req.id,
                    kind: .methodResultPresent,
                    isSatisfied: state.result != nil,
                    detail: state.result == nil ? "No method result attached" : nil
                )
            }
    }
}
