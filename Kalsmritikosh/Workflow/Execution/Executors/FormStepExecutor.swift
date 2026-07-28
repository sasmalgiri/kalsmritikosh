//
//  FormStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Handles the `form` step kind.
//  Produces WorkflowStepRequirementFact entries for .formFieldCompleted requirements.
//  Commands: setField, clearField, complete.
//

import Foundation

// MARK: - Form value

/// Closed enum for the typed values a form field may hold.
public enum WorkflowFormValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case date(String)       // ISO-8601 string
    case selection(String)
    case multiSelection([String])
}

extension WorkflowFormValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":           self = .text(try c.decode(String.self, forKey: .value))
        case "number":         self = .number(try c.decode(Double.self, forKey: .value))
        case "boolean":        self = .boolean(try c.decode(Bool.self, forKey: .value))
        case "date":           self = .date(try c.decode(String.self, forKey: .value))
        case "selection":      self = .selection(try c.decode(String.self, forKey: .value))
        case "multiSelection": self = .multiSelection(try c.decode([String].self, forKey: .value))
        default: throw WorkflowStepExecutionError.malformedStateJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let v):           try c.encode("text", forKey: .type);           try c.encode(v, forKey: .value)
        case .number(let v):         try c.encode("number", forKey: .type);         try c.encode(v, forKey: .value)
        case .boolean(let v):        try c.encode("boolean", forKey: .type);        try c.encode(v, forKey: .value)
        case .date(let v):           try c.encode("date", forKey: .type);           try c.encode(v, forKey: .value)
        case .selection(let v):      try c.encode("selection", forKey: .type);      try c.encode(v, forKey: .value)
        case .multiSelection(let v): try c.encode("multiSelection", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - Form state

public nonisolated struct FormStepState: Codable, Sendable {
    public var fields: [String: WorkflowFormValue]

    public nonisolated init(fields: [String: WorkflowFormValue] = [:]) {
        self.fields = fields
    }
}

// MARK: - Form command

public enum FormStepCommand: Sendable, Equatable {
    case setField(id: String, value: WorkflowFormValue)
    case clearField(id: String)
    case complete
}

extension FormStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, id, value }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "setField":
            self = .setField(id: try c.decode(String.self, forKey: .id),
                             value: try c.decode(WorkflowFormValue.self, forKey: .value))
        case "clearField":
            self = .clearField(id: try c.decode(String.self, forKey: .id))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setField(let id, let value):
            try c.encode("setField", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(value, forKey: .value)
        case .clearField(let id):
            try c.encode("clearField", forKey: .type)
            try c.encode(id, forKey: .id)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct FormStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.form"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .form

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let formReqs = context.step.requirements.filter { $0.kind == .formFieldCompleted }
        let initialFacts = formReqs.map { req in
            WorkflowStepRequirementFact(requirementID: req.id, kind: .formFieldCompleted, isSatisfied: false)
        }
        let (json, sha) = try makeEnvelope(
            state: FormStepState(),
            stepKind: handledKind,
            requirementFacts: initialFacts
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
        let envelope = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<FormStepState>.self,
            from: context.stepRun.stateJSON
        )
        guard envelope.stepKind == handledKind else {
            throw WorkflowStepExecutionError.stateEnvelopeKindMismatch
        }
        var state = envelope.state
        let command: FormStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(FormStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        switch command {
        case .setField(let id, let value):
            state.fields[id] = value
            let facts = buildFacts(state: state, step: context.step)
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind, requirementFacts: facts)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)

        case .clearField(let id):
            state.fields.removeValue(forKey: id)
            let facts = buildFacts(state: state, step: context.step)
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind, requirementFacts: facts)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)

        case .complete:
            let facts = buildFacts(state: state, step: context.step)
            let blockingUnsatisfied = context.step.requirements
                .filter { $0.kind == .formFieldCompleted && $0.isBlocking }
                .filter { req in
                    !(facts.first { $0.requirementID == req.id }?.isSatisfied ?? false)
                }
            guard blockingUnsatisfied.isEmpty else {
                let ids = blockingUnsatisfied.map { $0.id }.joined(separator: ", ")
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "Required fields not completed: \(ids)"
                )
            }
            guard let firstTransition = context.step.transitions.first else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No transitions declared"
                )
            }
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind, requirementFacts: facts)
            return WorkflowStepExecutionResult(
                stateJSON: json, stateSHA256: sha,
                disposition: .advance(.label(firstTransition.label))
            )
        }
    }

    // MARK: - Private

    /// Produces one fact per .formFieldCompleted requirement.
    /// A requirement is satisfied if a field with the requirement's ID is present in state.
    private nonisolated func buildFacts(
        state: FormStepState,
        step: PersonaWorkflowStepDefinition
    ) -> [WorkflowStepRequirementFact] {
        step.requirements
            .filter { $0.kind == .formFieldCompleted }
            .map { req in
                let satisfied = state.fields[req.id] != nil
                return WorkflowStepRequirementFact(
                    requirementID: req.id,
                    kind: .formFieldCompleted,
                    isSatisfied: satisfied,
                    detail: satisfied ? nil : req.detail
                )
            }
    }
}
