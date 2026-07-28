//
//  BrainstormStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Handles the `brainstorm` step kind.
//  Proposals are proposal-layer only — never Claims or EvidenceBlocks.
//  Commands: addProposal, updateProposal, removeProposal, promoteProposal,
//            demoteProposal, setNotes, complete.
//

import Foundation

// MARK: - Brainstorm state

public nonisolated struct BrainstormProposal: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var isPriority: Bool

    public nonisolated init(id: String, text: String, isPriority: Bool = false) {
        self.id = id
        self.text = text
        self.isPriority = isPriority
    }
}

public nonisolated struct BrainstormStepState: Codable, Sendable, Equatable {
    public var proposals: [BrainstormProposal]
    public var notes: String

    public nonisolated init(proposals: [BrainstormProposal] = [], notes: String = "") {
        self.proposals = proposals
        self.notes = notes
    }
}

// MARK: - Brainstorm command

public enum BrainstormStepCommand: Sendable, Equatable {
    case addProposal(id: String, text: String)
    case updateProposal(id: String, text: String)
    case removeProposal(id: String)
    case promoteProposal(id: String)
    case demoteProposal(id: String)
    case setNotes(String)
    case complete
}

extension BrainstormStepCommand: Codable {
    private enum CodingKeys: String, CodingKey { case type, id, text, value }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "addProposal":
            self = .addProposal(id: try c.decode(String.self, forKey: .id),
                                text: try c.decode(String.self, forKey: .text))
        case "updateProposal":
            self = .updateProposal(id: try c.decode(String.self, forKey: .id),
                                   text: try c.decode(String.self, forKey: .text))
        case "removeProposal":
            self = .removeProposal(id: try c.decode(String.self, forKey: .id))
        case "promoteProposal":
            self = .promoteProposal(id: try c.decode(String.self, forKey: .id))
        case "demoteProposal":
            self = .demoteProposal(id: try c.decode(String.self, forKey: .id))
        case "setNotes":
            self = .setNotes(try c.decode(String.self, forKey: .value))
        case "complete":
            self = .complete
        default:
            throw WorkflowStepExecutionError.malformedCommandJSON
        }
    }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addProposal(let id, let text):
            try c.encode("addProposal", forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        case .updateProposal(let id, let text):
            try c.encode("updateProposal", forKey: .type)
            try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        case .removeProposal(let id):
            try c.encode("removeProposal", forKey: .type); try c.encode(id, forKey: .id)
        case .promoteProposal(let id):
            try c.encode("promoteProposal", forKey: .type); try c.encode(id, forKey: .id)
        case .demoteProposal(let id):
            try c.encode("demoteProposal", forKey: .type); try c.encode(id, forKey: .id)
        case .setNotes(let v):
            try c.encode("setNotes", forKey: .type); try c.encode(v, forKey: .value)
        case .complete:
            try c.encode("complete", forKey: .type)
        }
    }
}

// MARK: - Executor

public nonisolated struct BrainstormStepExecutor: WorkflowStepExecutor {

    public nonisolated let executorID = WorkflowStepExecutorID(
        rawValue: "com.kalsmritikosh.step.brainstorm"
    )
    public nonisolated let executorVersion = WorkflowStepExecutorVersion(rawValue: "1.0")
    public nonisolated let handledKind: WorkflowStepKind = .brainstorm

    public nonisolated init() {}

    public func prepare(
        context: WorkflowStepPreparationContext
    ) async throws -> WorkflowStepPreparationResult {
        guard context.step.kind == handledKind else {
            throw WorkflowStepExecutionError.executorKindMismatch(
                executor: executorID, expected: handledKind, actual: context.step.kind
            )
        }
        let (json, sha) = try makeEnvelope(state: BrainstormStepState(), stepKind: handledKind)
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
        var state = try decodeCurrentState(BrainstormStepState.self, from: context.stepRun)
        let command: BrainstormStepCommand
        do {
            command = try WorkflowStepPayloadCodec.decode(BrainstormStepCommand.self, from: commandJSON)
        } catch {
            throw WorkflowStepExecutionError.malformedCommandJSON
        }

        func save() throws -> WorkflowStepExecutionResult {
            let (json, sha) = try makeEnvelope(state: state, stepKind: handledKind)
            return WorkflowStepExecutionResult(stateJSON: json, stateSHA256: sha, disposition: .remainActive)
        }

        switch command {
        case .addProposal(let id, let text):
            guard !state.proposals.contains(where: { $0.id == id }) else {
                return try save()
            }
            state.proposals.append(BrainstormProposal(id: id, text: text))
            return try save()
        case .updateProposal(let id, let text):
            if let i = state.proposals.firstIndex(where: { $0.id == id }) {
                state.proposals[i].text = text
            }
            return try save()
        case .removeProposal(let id):
            state.proposals.removeAll { $0.id == id }
            return try save()
        case .promoteProposal(let id):
            if let i = state.proposals.firstIndex(where: { $0.id == id }) {
                state.proposals[i].isPriority = true
            }
            return try save()
        case .demoteProposal(let id):
            if let i = state.proposals.firstIndex(where: { $0.id == id }) {
                state.proposals[i].isPriority = false
            }
            return try save()
        case .setNotes(let v):
            state.notes = v
            return try save()
        case .complete:
            guard !state.proposals.isEmpty else {
                throw WorkflowStepExecutionError.completionNotReady(
                    kind: handledKind, reason: "At least one proposal is required"
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
