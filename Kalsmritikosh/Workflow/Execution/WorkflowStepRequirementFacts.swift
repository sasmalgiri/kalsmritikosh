//
//  WorkflowStepRequirementFacts.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Typed requirement facts produced by executors (e.g. FormStepExecutor),
//  the envelope header for engine-side validation, and the adapter that
//  enables WorkflowRequirementsEngine to evaluate .formFieldCompleted
//  without needing the executor at evaluation time.
//

import Foundation

// MARK: - Requirement fact

/// A single requirement-satisfaction record attached to a step state envelope.
/// Executors produce these; the adapter reads them to resolve requirement checks.
public nonisolated struct WorkflowStepRequirementFact: Codable, Sendable, Equatable {
    public let requirementID: String
    public let kind: WorkflowRequirementKind
    public let isSatisfied: Bool
    public let detail: String?

    public nonisolated init(
        requirementID: String,
        kind: WorkflowRequirementKind,
        isSatisfied: Bool,
        detail: String? = nil
    ) {
        self.requirementID = requirementID
        self.kind = kind
        self.isSatisfied = isSatisfied
        self.detail = detail
    }
}

// MARK: - State envelope header (non-generic)

/// Minimal header-only struct for envelope validation without instantiating the full
/// generic `WorkflowStepStateEnvelope<State>`. The engine uses this to verify kind,
/// executor identity, and to read requirement facts without knowing the concrete State type.
public nonisolated struct WorkflowStepStateEnvelopeHeader: Codable, Sendable {
    public let envelopeSchemaVersion: Int
    public let stepKind: WorkflowStepKind
    public let executorID: String
    public let executorVersion: String
    public let requirementFacts: [WorkflowStepRequirementFact]

    public nonisolated init(
        envelopeSchemaVersion: Int,
        stepKind: WorkflowStepKind,
        executorID: String,
        executorVersion: String,
        requirementFacts: [WorkflowStepRequirementFact]
    ) {
        self.envelopeSchemaVersion = envelopeSchemaVersion
        self.stepKind = stepKind
        self.executorID = executorID
        self.executorVersion = executorVersion
        self.requirementFacts = requirementFacts
    }
}

// MARK: - State envelope (generic)

/// Generic state envelope that each executor encodes as the step run's `stateJSON`.
/// The engine calls `WorkflowStepPayloadCodec.encode()` on this value.
/// Never use JSONDecoder directly — always go through WorkflowStepPayloadCodec.
public nonisolated struct WorkflowStepStateEnvelope<State: Codable & Sendable>:
    Codable, Sendable {

    public let envelopeSchemaVersion: Int
    public let stepKind: WorkflowStepKind
    public let executorID: String
    public let executorVersion: String
    public let state: State
    public let requirementFacts: [WorkflowStepRequirementFact]

    public nonisolated init(
        stepKind: WorkflowStepKind,
        executorID: String,
        executorVersion: String,
        state: State,
        requirementFacts: [WorkflowStepRequirementFact] = []
    ) {
        self.envelopeSchemaVersion = 1
        self.stepKind = stepKind
        self.executorID = executorID
        self.executorVersion = executorVersion
        self.state = state
        self.requirementFacts = requirementFacts
    }
}

// MARK: - Requirement facts adapter

/// Reads the requirement facts embedded in a step run's stateJSON to enable
/// WorkflowRequirementsEngine to evaluate `.formFieldCompleted` requirements.
/// PJE-005 deferred this evaluation; PJE-006A closes the gap via this adapter.
public actor WorkflowStepRequirementFactsAdapter {

    public init() {}

    /// Reads requirement facts for a given requirement from the step run's stateJSON.
    /// Returns `nil` if the stateJSON cannot be decoded (e.g. no envelope written yet).
    public func factForRequirement(
        _ requirementID: String,
        in stepRun: WorkflowStepRun
    ) -> WorkflowStepRequirementFact? {
        guard let header = try? WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self,
            from: stepRun.stateJSON
        ) else {
            return nil
        }
        return header.requirementFacts.first { $0.requirementID == requirementID }
    }

    /// Reads all requirement facts from a step run's stateJSON.
    /// Returns an empty array if the stateJSON cannot be decoded.
    public func allFacts(in stepRun: WorkflowStepRun) -> [WorkflowStepRequirementFact] {
        guard let header = try? WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self,
            from: stepRun.stateJSON
        ) else {
            return []
        }
        return header.requirementFacts
    }
}
