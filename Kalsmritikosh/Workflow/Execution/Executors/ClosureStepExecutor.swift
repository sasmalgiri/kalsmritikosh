//
//  ClosureStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006C — Handles the `closure` step kind.
//
//  Closure is HUMAN judgment: automations, deterministic rules and system actors
//  cannot confirm closure. confirmClosure requires a nonblank summary, every
//  checklist item satisfied, and no open blocking attention item; the gated
//  PJE-004 terminal completion then re-evaluates blocking requirements and
//  validations (PJE-005) before the run completes. Closure never deletes
//  workflow history.
//  Commands: setSummary, addLimitation, removeLimitation, setChecklistItem,
//            confirmClosure, returnForMoreWork.
//

import Foundation

// MARK: - Decision vocabulary

public enum WorkflowClosureDecision: String, Codable, CaseIterable, Sendable {
    case close
    case returnForMoreWork
}

// MARK: - Checklist

public nonisolated struct WorkflowClosureChecklistItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let isSatisfied: Bool
    public let detail: String?

    public nonisolated init(id: String, label: String, isSatisfied: Bool, detail: String? = nil) {
        self.id = id
        self.label = label
        self.isSatisfied = isSatisfied
        self.detail = detail
    }
}

// MARK: - State

public nonisolated struct ClosureStepState: Codable, Hashable, Sendable {
    public let summary: String
    public let knownLimitations: [String]
    public let checklist: [WorkflowClosureChecklistItem]
    public let decision: WorkflowClosureDecision?
    public let decidedBy: String?
    public let decidedAt: Date?
    public let rationale: String?

    public nonisolated init(
        summary: String = "",
        knownLimitations: [String] = [],
        checklist: [WorkflowClosureChecklistItem] = [],
        decision: WorkflowClosureDecision? = nil,
        decidedBy: String? = nil,
        decidedAt: Date? = nil,
        rationale: String? = nil
    ) {
        self.summary = summary
        self.knownLimitations = knownLimitations
        self.checklist = checklist
        self.decision = decision
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.rationale = rationale
    }
}

// MARK: - Command

public enum ClosureStepCommand: Sendable, Equatable {
    case setSummary(String)
    case addLimitation(String)
    case removeLimitation(String)
    case setChecklistItem(WorkflowClosureChecklistItem)
    case confirmClosure(rationale: String?)
    case returnForMoreWork(selector: WorkflowTransitionSelector, rationale: String?)
}

extension ClosureStepCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, summary, limitation, item, rationale, transitionLabel, targetStepID
    }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "setSummary":
            self = .setSummary(try c.decode(String.self, forKey: .summary))
        case "addLimitation":
            self = .addLimitation(try c.decode(String.self, forKey: .limitation))
        case "removeLimitation":
            self = .removeLimitation(try c.decode(String.self, forKey: .limitation))
        case "setChecklistItem":
            self = .setChecklistItem(try c.decode(WorkflowClosureChecklistItem.self, forKey: .item))
        case "confirmClosure":
            self = .confirmClosure(rationale: try c.decodeIfPresent(String.self, forKey: .rationale))
        case "returnForMoreWork":
            if let label = try c.decodeIfPresent(String.self, forKey: .transitionLabel) {
                self = .returnForMoreWork(
                    selector: .label(label),
                    rationale: try c.decodeIfPresent(String.self, forKey: .rationale))
            } else {
                let target = try c.decode(String.self, forKey: .targetStepID)
                self = .returnForMoreWork(
                    selector: .targetStepID(StepDefinitionID(rawValue: target)),
                    rationale: try c.decodeIfPresent(String.self, forKey: .rationale))
            }
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setSummary(let summary):
            try c.encode("setSummary", forKey: .type)
            try c.encode(summary, forKey: .summary)
        case .addLimitation(let limitation):
            try c.encode("addLimitation", forKey: .type)
            try c.encode(limitation, forKey: .limitation)
        case .removeLimitation(let limitation):
            try c.encode("removeLimitation", forKey: .type)
            try c.encode(limitation, forKey: .limitation)
        case .setChecklistItem(let item):
            try c.encode("setChecklistItem", forKey: .type)
            try c.encode(item, forKey: .item)
        case .confirmClosure(let rationale):
            try c.encode("confirmClosure", forKey: .type)
            if let rationale = rationale { try c.encode(rationale, forKey: .rationale) }
        case .returnForMoreWork(let selector, let rationale):
            try c.encode("returnForMoreWork", forKey: .type)
            switch selector {
            case .label(let label): try c.encode(label, forKey: .transitionLabel)
            case .targetStepID(let id): try c.encode(id.rawValue, forKey: .targetStepID)
            }
            if let rationale = rationale { try c.encode(rationale, forKey: .rationale) }
        }
    }
}

// MARK: - Executor

public nonisolated struct ClosureStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.closure"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1")
    public nonisolated let handledKind: WorkflowStepKind = .closure

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: ClosureStepState(), stepKind: handledKind)
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
        let state = try decodeCurrentState(ClosureStepState.self, from: context.stepRun)
        let command: ClosureStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(ClosureStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save(_ newState: ClosureStepState,
                  disposition: WorkflowStepExecutionDisposition = .remainActive
        ) throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: newState, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: disposition)
        }

        switch command {
        case .setSummary(let summary):
            return try save(ClosureStepState(
                summary: summary, knownLimitations: state.knownLimitations,
                checklist: state.checklist, decision: state.decision,
                decidedBy: state.decidedBy, decidedAt: state.decidedAt,
                rationale: state.rationale))

        case .addLimitation(let limitation):
            guard !limitation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "limitation", reason: "Limitation must not be blank")
            }
            return try save(ClosureStepState(
                summary: state.summary,
                knownLimitations: state.knownLimitations + [limitation],
                checklist: state.checklist, decision: state.decision,
                decidedBy: state.decidedBy, decidedAt: state.decidedAt,
                rationale: state.rationale))

        case .removeLimitation(let limitation):
            return try save(ClosureStepState(
                summary: state.summary,
                knownLimitations: state.knownLimitations.filter { $0 != limitation },
                checklist: state.checklist, decision: state.decision,
                decidedBy: state.decidedBy, decidedAt: state.decidedAt,
                rationale: state.rationale))

        case .setChecklistItem(let item):
            var checklist = state.checklist.filter { $0.id != item.id }
            checklist.append(item)
            return try save(ClosureStepState(
                summary: state.summary, knownLimitations: state.knownLimitations,
                checklist: checklist, decision: state.decision,
                decidedBy: state.decidedBy, decidedAt: state.decidedAt,
                rationale: state.rationale))

        case .confirmClosure(let rationale):
            // Human judgment only — never automation, rules, or system actors.
            guard context.actor.kind == .human,
                  let decider = context.actor.identifier,
                  !decider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "actor", reason: "Only an identified human may confirm closure")
            }
            guard !state.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "Closure summary must not be blank")
            }
            let unsatisfied = state.checklist.filter { !$0.isSatisfied }
            guard unsatisfied.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "\(unsatisfied.count) checklist item(s) not satisfied")
            }
            // No open BLOCKING attention item may remain on the run.
            let openBlocking = context.aggregate.attentionItems.filter {
                $0.status == .open && $0.severity == .blocking
            }
            guard openBlocking.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind,
                    reason: "\(openBlocking.count) open blocking attention item(s)")
            }
            let newState = ClosureStepState(
                summary: state.summary, knownLimitations: state.knownLimitations,
                checklist: state.checklist, decision: .close,
                decidedBy: decider, decidedAt: context.executedAt,
                rationale: rationale)
            // Terminal completion — the engine routes through the GATED PJE-004 complete,
            // which re-evaluates blocking requirements/validations before applying.
            return try save(newState, disposition: .completeTerminal)

        case .returnForMoreWork(let selector, let rationale):
            guard context.actor.kind == .human,
                  let decider = context.actor.identifier,
                  !decider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowStepExecutionError.validationFailed(
                    field: "actor", reason: "Only an identified human may return a run for more work")
            }
            // The declared return transition is required — validated fully by PJE-004.
            let hasReturn = context.step.transitions.contains { $0.isReturn }
            guard hasReturn else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "No declared return transition on this step")
            }
            let newState = ClosureStepState(
                summary: state.summary, knownLimitations: state.knownLimitations,
                checklist: state.checklist, decision: .returnForMoreWork,
                decidedBy: decider, decidedAt: context.executedAt,
                rationale: rationale)
            return try save(newState, disposition: .returnToPriorStep(selector))
        }
    }
}
