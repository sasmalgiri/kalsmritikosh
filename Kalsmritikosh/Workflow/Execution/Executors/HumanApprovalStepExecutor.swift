//
//  HumanApprovalStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006C — Handles the `humanApproval` step kind.
//
//  Allowed roles come EXCLUSIVELY from the frozen step definition's approverRoles —
//  never from mutable command data. The executor cannot approve; automation cannot
//  approve; system and deterministic-rule actors cannot approve. Approval is
//  recorded as a persisted WorkflowDecision through the PJE-004 lifecycle
//  (submitHumanApproval on the engine), and applyRecordedApproval follows the
//  declared "approved"/"rejected" transition labels — no invented fallbacks.
//  Commands: setPrompt, requestApproval, applyRecordedApproval.
//

import Foundation

// MARK: - Status

public enum HumanApprovalStepStatus: String, Codable, CaseIterable, Sendable {
    case preparing
    case awaitingApproval
    case approvalRecorded
}

// MARK: - State

public nonisolated struct HumanApprovalStepState: Codable, Hashable, Sendable {
    public let prompt: String
    public let allowedRoles: [String]
    public let status: HumanApprovalStepStatus
    public let decisionID: UUID?
    public let approved: Bool?

    public nonisolated init(
        prompt: String = "",
        allowedRoles: [String] = [],
        status: HumanApprovalStepStatus = .preparing,
        decisionID: UUID? = nil,
        approved: Bool? = nil
    ) {
        self.prompt = prompt
        self.allowedRoles = allowedRoles
        self.status = status
        self.decisionID = decisionID
        self.approved = approved
    }
}

// MARK: - Command

public enum HumanApprovalStepCommand: Sendable, Equatable {
    case setPrompt(String)
    case requestApproval
    case applyRecordedApproval
}

extension HumanApprovalStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, prompt }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setPrompt":            self = .setPrompt(try c.decode(String.self, forKey: .prompt))
        case "requestApproval":      self = .requestApproval
        case "applyRecordedApproval": self = .applyRecordedApproval
        default: throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setPrompt(let prompt):
            try c.encode("setPrompt", forKey: .type)
            try c.encode(prompt, forKey: .prompt)
        case .requestApproval:
            try c.encode("requestApproval", forKey: .type)
        case .applyRecordedApproval:
            try c.encode("applyRecordedApproval", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct HumanApprovalStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.human-approval"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    public nonisolated let handledKind: WorkflowStepKind = .humanApproval

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        // allowedRoles are FROZEN — copied once from the step definition.
        let state = HumanApprovalStepState(allowedRoles: context.step.approverRoles)
        let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
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
        let state = try decodeCurrentState(HumanApprovalStepState.self, from: context.stepRun)
        let command: HumanApprovalStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(HumanApprovalStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save(_ newState: HumanApprovalStepState,
                  disposition: WorkflowStepExecutionDisposition = .remainActive
        ) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: newState, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: disposition)
        }

        switch command {
        case .setPrompt(let prompt):
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "prompt", reason: "Approval prompt must not be blank")
            }
            return try save(HumanApprovalStepState(
                prompt: prompt,
                allowedRoles: context.step.approverRoles,  // roles never come from commands
                status: state.status,
                decisionID: state.decisionID, approved: state.approved))

        case .requestApproval:
            guard !state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "prompt", reason: "Prompt must be set before requesting approval")
            }
            guard Self.latestApproval(in: context) == nil else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "approval", reason: "An approval is already recorded for this step")
            }
            return try save(HumanApprovalStepState(
                prompt: state.prompt, allowedRoles: context.step.approverRoles,
                status: .awaitingApproval, decisionID: nil, approved: nil),
                disposition: .requestHumanApproval)

        case .applyRecordedApproval:
            // The PERSISTED approval decision is the only source of truth.
            guard let decision = Self.latestApproval(in: context) else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No persisted human approval for this step")
            }
            let approved = decision.selectedOption == "approved"
            let label = approved ? "approved" : "rejected"
            // Follow the DECLARED transition label — no invented fallback branches.
            guard context.step.transitions.contains(where: { $0.label == label }) else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "Step declares no '\(label)' transition")
            }
            let newState = HumanApprovalStepState(
                prompt: state.prompt, allowedRoles: context.step.approverRoles,
                status: .approvalRecorded,
                decisionID: decision.id, approved: approved)
            return try save(newState, disposition: .advance(.label(label)))
        }
    }

    // MARK: - Persisted approval lookup

    /// Latest nonsuperseded humanApproval decision on the CURRENT step run.
    static nonisolated func latestApproval(
        in context: WorkflowStepExecutionContext
    ) -> WorkflowDecision? {
        let superseded = Set(context.aggregate.decisions.compactMap { $0.supersedesDecisionID })
        return context.aggregate.decisions
            .filter { $0.stepRunID == context.stepRun.id && $0.kind == .humanApproval }
            .filter { !superseded.contains($0.id) }
            .max { $0.decidedAt < $1.decidedAt }
    }
}
