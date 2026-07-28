//
//  WorkflowStepExecutor.swift
//  Kalsmritikosh
//
//  PJE-006A — Step Executor Runtime and Working-Surface Pack.
//  Protocol that all step executors conform to.
//  Executors are stateless; they read the aggregate and return results.
//  No database access, no lifecycle mutations, no LLM calls.
//

import Foundation

// MARK: - Step executor protocol

/// A stateless, concrete implementation of a specific workflow step kind.
/// Conforming types are pure functions: they read the current aggregate + command,
/// compute the next state, and declare a disposition.
///
/// Executors MUST NOT:
/// - Access any repository or database type
/// - Call any language model
/// - Perform lifecycle transitions
/// - Retain mutable state between invocations
public protocol WorkflowStepExecutor: Sendable {

    // MARK: - Stable identity

    /// Stable reverse-domain ID (e.g. `"com.kalsmritikosh.step.intake"`).
    nonisolated var executorID: WorkflowStepExecutorID { get }

    /// Immutable version token (e.g. `"1.0"`).
    nonisolated var executorVersion: WorkflowStepExecutorVersion { get }

    /// The step kind this executor handles.
    nonisolated var handledKind: WorkflowStepKind { get }

    // MARK: - Lifecycle callbacks

    /// Called once when the engine enters this step for the first time.
    /// Must succeed before any lifecycle mutation is applied.
    /// Returns the initial state JSON + hash for the new step run record.
    func prepare(context: WorkflowStepPreparationContext) async throws
        -> WorkflowStepPreparationResult

    /// Called on every command invocation.
    /// Returns the updated state JSON, a new hash, optional output JSON,
    /// and the requested disposition.
    func execute(
        context: WorkflowStepExecutionContext,
        commandJSON: String
    ) async throws -> WorkflowStepExecutionResult
}

// MARK: - Convenience helpers on the protocol

public extension WorkflowStepExecutor {

    /// Build an envelope from a typed state value, computing the hash via the codec.
    nonisolated func makeEnvelope<State: Codable & Sendable>(
        state: State,
        stepKind: WorkflowStepKind,
        requirementFacts: [WorkflowStepRequirementFact] = []
    ) throws -> (json: String, sha256: String) {
        let envelope = WorkflowStepStateEnvelope(
            stepKind: stepKind,
            executorID: executorID.rawValue,
            executorVersion: executorVersion.rawValue,
            state: state,
            requirementFacts: requirementFacts
        )
        let json = try WorkflowStepPayloadCodec.encode(envelope)
        let sha256 = try WorkflowStepPayloadCodec.hashJSON(json)
        return (json, sha256)
    }

    /// Decode the current state from a step run's stateJSON.
    /// Checks kind and executor identity first (via the header) before decoding the typed state,
    /// so that a kind mismatch throws stateEnvelopeKindMismatch rather than a DecodingError.
    nonisolated func decodeCurrentState<State: Codable & Sendable>(
        _ type: State.Type,
        from stepRun: WorkflowStepRun
    ) throws -> State {
        let header = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelopeHeader.self,
            from: stepRun.stateJSON
        )
        guard header.stepKind == handledKind else {
            throw WorkflowStepExecutionError.stateEnvelopeKindMismatch
        }
        guard header.executorID == executorID.rawValue else {
            throw WorkflowStepExecutionError.stateEnvelopeExecutorMismatch
        }
        let envelope = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<State>.self,
            from: stepRun.stateJSON
        )
        return envelope.state
    }
}
