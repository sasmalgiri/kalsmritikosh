//
//  WorkflowStepExecutorProtocolTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — Protocol extension helpers: makeEnvelope, decodeCurrentState.
//  Uses IntakeStepExecutor as the concrete conformer under test.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — WorkflowStepExecutor protocol helpers")
struct WorkflowStepExecutorProtocolTests {

    private let executor = IntakeStepExecutor()
    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    // MARK: - makeEnvelope

    @Test("makeEnvelope produces parseable JSON")
    func makeEnvelopeProducesValidJSON() throws {
        let state = IntakeStepState(title: "Hello", summary: "World")
        let (json, _) = try executor.makeEnvelope(state: state, stepKind: .intake)
        let env = try WorkflowStepPayloadCodec.decode(WorkflowStepStateEnvelope<IntakeStepState>.self, from: json)
        #expect(env.state.title == "Hello")
        #expect(env.state.summary == "World")
    }

    @Test("makeEnvelope hash matches hashJSON of the returned json")
    func makeEnvelopeHashConsistency() throws {
        let state = IntakeStepState(title: "A")
        let (json, sha256) = try executor.makeEnvelope(state: state, stepKind: .intake)
        let recomputed = try WorkflowStepPayloadCodec.hashJSON(json)
        #expect(sha256 == recomputed)
    }

    @Test("makeEnvelope embeds requirementFacts in envelope")
    func makeEnvelopeWithFacts() throws {
        let fact = WorkflowStepRequirementFact(
            requirementID: "r1", kind: .formFieldCompleted, isSatisfied: true)
        let formExecutor = FormStepExecutor()
        let state = FormStepState()
        let (json, _) = try formExecutor.makeEnvelope(state: state, stepKind: .form, requirementFacts: [fact])
        let header = try WorkflowStepPayloadCodec.decode(WorkflowStepStateEnvelopeHeader.self, from: json)
        #expect(header.requirementFacts.count == 1)
        #expect(header.requirementFacts.first?.requirementID == "r1")
    }

    // MARK: - decodeCurrentState

    @Test("decodeCurrentState roundtrip preserves state")
    func decodeCurrentStateRoundtrip() throws {
        let state = IntakeStepState(title: "Test", tags: ["a", "b"])
        let (json, sha) = try executor.makeEnvelope(state: state, stepKind: .intake)
        let stepRun = makeStepRun(stateJSON: json, sha256: sha, kind: .intake, executorID: executor.executorID.rawValue)
        let decoded = try executor.decodeCurrentState(IntakeStepState.self, from: stepRun)
        #expect(decoded.title == "Test")
        #expect(decoded.tags == ["a", "b"])
    }

    @Test("decodeCurrentState throws stateEnvelopeKindMismatch on kind mismatch")
    func decodeCurrentStateKindMismatch() throws {
        let formExec = FormStepExecutor()
        let formState = FormStepState()
        let (json, sha) = try formExec.makeEnvelope(state: formState, stepKind: .form)
        // Feed a form-envelope stateJSON to the intake executor
        let stepRun = makeStepRun(stateJSON: json, sha256: sha, kind: .form, executorID: formExec.executorID.rawValue)
        #expect(throws: WorkflowStepExecutionError.stateEnvelopeKindMismatch) {
            _ = try executor.decodeCurrentState(IntakeStepState.self, from: stepRun)
        }
    }

    @Test("decodeCurrentState throws stateEnvelopeExecutorMismatch on ID mismatch")
    func decodeCurrentStateExecutorMismatch() throws {
        // Manually craft an envelope claiming intake kind but a different executor ID
        let spoofed = WorkflowStepStateEnvelope(
            stepKind: .intake,
            executorID: "com.other.executor",
            executorVersion: "1.0",
            state: IntakeStepState()
        )
        let json = try WorkflowStepPayloadCodec.encode(spoofed)
        let sha = try WorkflowStepPayloadCodec.hashJSON(json)
        let stepRun = makeStepRun(stateJSON: json, sha256: sha, kind: .intake, executorID: "com.other.executor")
        #expect(throws: WorkflowStepExecutionError.stateEnvelopeExecutorMismatch) {
            _ = try executor.decodeCurrentState(IntakeStepState.self, from: stepRun)
        }
    }

    // MARK: - Helper

    private func makeStepRun(stateJSON: String, sha256: String, kind: WorkflowStepKind, executorID: String) -> WorkflowStepRun {
        WorkflowStepRun(
            id: UUID(), workflowRunID: UUID(),
            stepDefinitionID: StepDefinitionID(rawValue: "step.entry"),
            stepKind: kind,
            attempt: 1, sequence: 1, status: .active,
            executorID: executorID,
            executorVersion: "1.0",
            inputJSON: "{}", stateJSON: stateJSON,
            outputJSON: nil, stateSHA256: sha256,
            enteredAt: t0, updatedAt: t0, completedAt: nil
        )
    }
}
