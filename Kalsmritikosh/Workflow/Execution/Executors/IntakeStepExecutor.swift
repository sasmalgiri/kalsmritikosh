//
//  IntakeStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Handles the `intake` step kind.
//  Commands: setTitle, setSummary, setContext, addTag, removeTag, complete.
//

import Foundation

// MARK: - Intake state

public nonisolated struct IntakeStepState: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var context: String
    public var tags: [String]

    public nonisolated init(
        title: String = "",
        summary: String = "",
        context: String = "",
        tags: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.context = context
        self.tags = tags
    }
}

// MARK: - Intake command

public enum IntakeStepCommand: Sendable, Equatable {
    case setTitle(String)
    case setSummary(String)
    case setContext(String)
    case addTag(String)
    case removeTag(String)
    case complete
}

extension IntakeStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "setTitle":
            self = .setTitle(try c.decode(String.self, forKey: .value))
        case "setSummary":
            self = .setSummary(try c.decode(String.self, forKey: .value))
        case "setContext":
            self = .setContext(try c.decode(String.self, forKey: .value))
        case "addTag":
            self = .addTag(try c.decode(String.self, forKey: .value))
        case "removeTag":
            self = .removeTag(try c.decode(String.self, forKey: .value))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setTitle(let v):
            try c.encode("setTitle", forKey: .type)
            try c.encode(v, forKey: .value)
        case .setSummary(let v):
            try c.encode("setSummary", forKey: .type)
            try c.encode(v, forKey: .value)
        case .setContext(let v):
            try c.encode("setContext", forKey: .type)
            try c.encode(v, forKey: .value)
        case .addTag(let v):
            try c.encode("addTag", forKey: .type)
            try c.encode(v, forKey: .value)
        case .removeTag(let v):
            try c.encode("removeTag", forKey: .type)
            try c.encode(v, forKey: .value)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct IntakeStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.intake"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .intake

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID,
                expected: handledKind,
                actual: context.step.kind
            )
        }
        let initialState = IntakeStepState()
        let (json, sha) = try makeEnvelope(state: initialState, stepKind: handledKind)
        return WorkflowStepPreparationResult(
            inputJSON: "{}",
            stateJSON: json,
            stateSHA256: sha,
            executorID: executorID,
            executorVersion: executorVersion
        )
    }

    public func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID,
                expected: handledKind,
                actual: context.step.kind
            )
        }
        var state = try decodeCurrentState(IntakeStepState.self, from: context.stepRun)
        let command: IntakeStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(IntakeStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        switch command {
        case .setTitle(let v):
            state.title = v
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha, disposition: .remainActive
            )
        case .setSummary(let v):
            state.summary = v
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha, disposition: .remainActive
            )
        case .setContext(let v):
            state.context = v
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha, disposition: .remainActive
            )
        case .addTag(let tag):
            if !state.tags.contains(tag) { state.tags.append(tag) }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha, disposition: .remainActive
            )
        case .removeTag(let tag):
            state.tags.removeAll { $0 == tag }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha, disposition: .remainActive
            )
        case .complete:
            guard !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Title must not be empty"
                )
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared"
                )
            }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            let selector = WorkflowTransitionSelector.label(firstTransition.label)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(selector)
            )
        }
    }
}
