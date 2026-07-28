//
//  ScopeStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Handles the `scope` step kind.
//  Commands: setObjective, addBoundary, removeBoundary, addConstraint, removeConstraint,
//            addSuccessCriterion, removeSuccessCriterion, complete.
//

import Foundation

// MARK: - Scope state

public nonisolated struct ScopeStepState: Codable, Sendable, Equatable {
    public var objective: String
    public var boundaries: [String]
    public var constraints: [String]
    public var successCriteria: [String]

    public nonisolated init(
        objective: String = "",
        boundaries: [String] = [],
        constraints: [String] = [],
        successCriteria: [String] = []
    ) {
        self.objective = objective
        self.boundaries = boundaries
        self.constraints = constraints
        self.successCriteria = successCriteria
    }
}

// MARK: - Scope command

public enum ScopeStepCommand: Sendable, Equatable {
    case setObjective(String)
    case addBoundary(String)
    case removeBoundary(String)
    case addConstraint(String)
    case removeConstraint(String)
    case addSuccessCriterion(String)
    case removeSuccessCriterion(String)
    case complete
}

extension ScopeStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "setObjective":        self = .setObjective(try c.decode(String.self, forKey: .value))
        case "addBoundary":         self = .addBoundary(try c.decode(String.self, forKey: .value))
        case "removeBoundary":      self = .removeBoundary(try c.decode(String.self, forKey: .value))
        case "addConstraint":       self = .addConstraint(try c.decode(String.self, forKey: .value))
        case "removeConstraint":    self = .removeConstraint(try c.decode(String.self, forKey: .value))
        case "addSuccessCriterion": self = .addSuccessCriterion(try c.decode(String.self, forKey: .value))
        case "removeSuccessCriterion": self = .removeSuccessCriterion(try c.decode(String.self, forKey: .value))
        case "complete":            self = .complete
        default: throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setObjective(let v):           try c.encode("setObjective", forKey: .type); try c.encode(v, forKey: .value)
        case .addBoundary(let v):            try c.encode("addBoundary", forKey: .type); try c.encode(v, forKey: .value)
        case .removeBoundary(let v):         try c.encode("removeBoundary", forKey: .type); try c.encode(v, forKey: .value)
        case .addConstraint(let v):          try c.encode("addConstraint", forKey: .type); try c.encode(v, forKey: .value)
        case .removeConstraint(let v):       try c.encode("removeConstraint", forKey: .type); try c.encode(v, forKey: .value)
        case .addSuccessCriterion(let v):    try c.encode("addSuccessCriterion", forKey: .type); try c.encode(v, forKey: .value)
        case .removeSuccessCriterion(let v): try c.encode("removeSuccessCriterion", forKey: .type); try c.encode(v, forKey: .value)
        case .complete: try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct ScopeStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.scope"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .scope

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: ScopeStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(ScopeStepState.self, from: context.stepRun)
        let command: ScopeStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(ScopeStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .setObjective(let v):
            state.objective = v; return try save()
        case .addBoundary(let v):
            if !state.boundaries.contains(v) { state.boundaries.append(v) }; return try save()
        case .removeBoundary(let v):
            state.boundaries.removeAll { $0 == v }; return try save()
        case .addConstraint(let v):
            if !state.constraints.contains(v) { state.constraints.append(v) }; return try save()
        case .removeConstraint(let v):
            state.constraints.removeAll { $0 == v }; return try save()
        case .addSuccessCriterion(let v):
            if !state.successCriteria.contains(v) { state.successCriteria.append(v) }; return try save()
        case .removeSuccessCriterion(let v):
            state.successCriteria.removeAll { $0 == v }; return try save()
        case .complete:
            guard !state.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Objective must not be empty"
                )
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared"
                )
            }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }
}
