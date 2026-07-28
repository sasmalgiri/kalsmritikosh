//
//  DecisionStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006C — Handles the `decision` step kind.
//
//  Two-phase, relaunch-safe decision flow:
//    request human decision → run waits → human decision persisted as a
//    WorkflowDecision (PJE-004) → applyRecordedDecision inspects the PERSISTED
//    decision from the aggregate and follows the exact branch deterministically.
//
//  Executor state can never impersonate a decision record: the selected option
//  always comes from context.aggregate.decisions, never from command JSON.
//  Commands: setQuestion, setOptions, requestHumanDecision,
//            selectDeterministicBranch, applyRecordedDecision.
//

import Foundation

// MARK: - Mode / status

public enum DecisionStepMode: String, Codable, CaseIterable, Sendable {
    case humanRequired
    case deterministicAllowed
}

public enum DecisionStepStatus: String, Codable, CaseIterable, Sendable {
    case preparing
    case awaitingHuman
    case decisionRecorded
}

// MARK: - State

public nonisolated struct DecisionStepState: Codable, Hashable, Sendable {
    public let question: String
    public let options: [String]
    public let mode: DecisionStepMode
    public let status: DecisionStepStatus
    public let recordedDecisionID: UUID?
    public let selectedOption: String?

    public nonisolated init(
        question: String = "",
        options: [String] = [],
        mode: DecisionStepMode = .humanRequired,
        status: DecisionStepStatus = .preparing,
        recordedDecisionID: UUID? = nil,
        selectedOption: String? = nil
    ) {
        self.question = question
        self.options = options
        self.mode = mode
        self.status = status
        self.recordedDecisionID = recordedDecisionID
        self.selectedOption = selectedOption
    }
}

// MARK: - Command

public enum DecisionStepCommand: Sendable, Equatable {
    case setQuestion(String)
    case setOptions(options: [String], mode: DecisionStepMode)
    case requestHumanDecision
    case selectDeterministicBranch(branch: String, rationale: String?)
    case applyRecordedDecision
}

extension DecisionStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, question, options, mode, branch, rationale }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setQuestion":
            self = .setQuestion(try c.decode(String.self, forKey: .question))
        case "setOptions":
            self = .setOptions(
                options: try c.decode([String].self, forKey: .options),
                mode: try c.decode(DecisionStepMode.self, forKey: .mode))
        case "requestHumanDecision":
            self = .requestHumanDecision
        case "selectDeterministicBranch":
            self = .selectDeterministicBranch(
                branch: try c.decode(String.self, forKey: .branch),
                rationale: try c.decodeIfPresent(String.self, forKey: .rationale))
        case "applyRecordedDecision":
            self = .applyRecordedDecision
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setQuestion(let question):
            try c.encode("setQuestion", forKey: .type)
            try c.encode(question, forKey: .question)
        case .setOptions(let options, let mode):
            try c.encode("setOptions", forKey: .type)
            try c.encode(options, forKey: .options)
            try c.encode(mode, forKey: .mode)
        case .requestHumanDecision:
            try c.encode("requestHumanDecision", forKey: .type)
        case .selectDeterministicBranch(let branch, let rationale):
            try c.encode("selectDeterministicBranch", forKey: .type)
            try c.encode(branch, forKey: .branch)
            if let rationale = rationale { try c.encode(rationale, forKey: .rationale) }
        case .applyRecordedDecision:
            try c.encode("applyRecordedDecision", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct DecisionStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.decision"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    public nonisolated let handledKind: WorkflowStepKind = .decision

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: DecisionStepState(), stepKind: handledKind)
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
        let state = try decodeCurrentState(DecisionStepState.self, from: context.stepRun)
        let command: DecisionStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(DecisionStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save(_ newState: DecisionStepState,
                  disposition: WorkflowStepExecutionDisposition = .remainActive
        ) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: newState, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: disposition)
        }

        switch command {
        case .setQuestion(let question):
            guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "question", reason: "Decision question must not be blank")
            }
            return try save(DecisionStepState(
                question: question, options: state.options, mode: state.mode,
                status: state.status,
                recordedDecisionID: state.recordedDecisionID,
                selectedOption: state.selectedOption))

        case .setOptions(let options, let mode):
            let trimmed = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.isEmpty }) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "options", reason: "Options must be nonblank")
            }
            guard Set(trimmed).count == trimmed.count else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "options", reason: "Options must be unique")
            }
            // Options must match the frozen step definition's decision branches.
            guard Set(trimmed) == Set(context.step.decisionBranches) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "options",
                    reason: "Options must match the step definition's declared decision branches")
            }
            return try save(DecisionStepState(
                question: state.question, options: trimmed, mode: mode,
                status: state.status,
                recordedDecisionID: state.recordedDecisionID,
                selectedOption: state.selectedOption))

        case .requestHumanDecision:
            guard state.mode == .humanRequired else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "mode", reason: "requestHumanDecision requires humanRequired mode")
            }
            guard !state.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !state.options.isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "question", reason: "Question and options must be set before requesting a decision")
            }
            guard Self.latestDecision(in: context) == nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "decision", reason: "A decision is already recorded for this step")
            }
            return try save(DecisionStepState(
                question: state.question, options: state.options, mode: state.mode,
                status: .awaitingHuman,
                recordedDecisionID: nil, selectedOption: nil),
                disposition: .requestHumanDecision)

        case .selectDeterministicBranch(let branch, let rationale):
            guard state.mode == .deterministicAllowed else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "mode",
                    reason: "A human-required decision cannot be selected by an executor")
            }
            guard context.actor.kind == .deterministicRule || context.actor.kind == .system else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "actor",
                    reason: "Deterministic branch selection requires a rule or system actor")
            }
            guard context.step.decisionBranches.contains(branch) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "branch", reason: "Branch is not declared in the frozen definition")
            }
            let newState = DecisionStepState(
                question: state.question, options: state.options, mode: state.mode,
                status: .decisionRecorded,
                recordedDecisionID: nil, selectedOption: branch)
            return try save(newState, disposition: .chooseBranch(branch: branch, rationale: rationale))

        case .applyRecordedDecision:
            // The PERSISTED decision is the source of truth — never command-supplied IDs.
            guard let decision = Self.latestDecision(in: context) else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No persisted human decision for this step")
            }
            guard context.step.decisionBranches.contains(decision.selectedOption) else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "decision",
                    reason: "Persisted decision option is not a declared branch")
            }
            let newState = DecisionStepState(
                question: state.question, options: state.options, mode: state.mode,
                status: .decisionRecorded,
                recordedDecisionID: decision.id,
                selectedOption: decision.selectedOption)
            return try save(newState, disposition: .chooseBranch(
                branch: decision.selectedOption, rationale: decision.rationale))
        }
    }

    // MARK: - Persisted decision lookup

    /// Latest nonsuperseded humanDecision recorded against the CURRENT step run.
    static nonisolated func latestDecision(
        in context: WorkflowStepExecutionContext
    ) -> WorkflowDecision? {
        let superseded = Set(context.aggregate.decisions.compactMap { $0.supersedesDecisionID })
        return context.aggregate.decisions
            .filter { $0.stepRunID == context.stepRun.id && $0.kind == .humanDecision }
            .filter { !superseded.contains($0.id) }
            .max { $0.decidedAt < $1.decidedAt }
    }
}
