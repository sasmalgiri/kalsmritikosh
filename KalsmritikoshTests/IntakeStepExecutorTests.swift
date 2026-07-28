//
//  IntakeStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — IntakeStepExecutor: prepare, commands, completion guard.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — IntakeStepExecutor")
struct IntakeStepExecutorTests {

    private let executor = IntakeStepExecutor()

    // MARK: - Identity

    @Test("executorID, executorVersion, handledKind are stable")
    func identity() {
        #expect(executor.executorID.rawValue == "com.kalsmritikosh.step.intake")
        #expect(executor.executorVersion.rawValue == "1.0")
        #expect(executor.handledKind == .intake)
    }

    // MARK: - prepare()

    @Test("prepare() returns empty IntakeStepState")
    func prepareReturnsEmptyState() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let ctx = makePreparationCtx(rig: rig)
        let result = try await executor.prepare(context: ctx)
        let state = try decodeEnvelopeState(IntakeStepState.self, from: result.stateJSON)
        #expect(state.title == "")
        #expect(state.summary == "")
        #expect(state.tags.isEmpty)
        #expect(result.executorID == executor.executorID)
        #expect(result.executorVersion == executor.executorVersion)
    }

    @Test("prepare() with wrong step kind throws executorKindMismatch")
    func prepareWrongKind() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let wrongStep = PersonaWorkflowStepDefinition(
            id: StepDefinitionID(rawValue: "step.wrong"),
            kind: .scope, label: "Wrong")
        let ctx = WorkflowStepPreparationContext(
            runID: UUID(), workspaceID: UUID(), runRevision: 1,
            workflow: rig.validated, step: wrongStep,
            actor: .system, preparedAt: Date())
        await #expect(throws: (any Error).self) {
            _ = try await executor.prepare(context: ctx)
        }
    }

    // MARK: - setTitle command

    @Test("setTitle updates title and returns remainActive")
    func setTitleCommand() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let ctx0 = makePreparationCtx(rig: rig)
        let prep = try await executor.prepare(context: ctx0)
        let cmdJSON = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setTitle("My Title"))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmdJSON)
        let state = try decodeEnvelopeState(IntakeStepState.self, from: result.stateJSON)
        #expect(result.disposition == .remainActive)
        #expect(state.title == "My Title")
    }

    // MARK: - setSummary command

    @Test("setSummary updates summary")
    func setSummaryCommand() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmdJSON = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setSummary("A summary"))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmdJSON)
        let state = try decodeEnvelopeState(IntakeStepState.self, from: result.stateJSON)
        #expect(state.summary == "A summary")
    }

    // MARK: - tag commands

    @Test("addTag is idempotent")
    func addTagIdempotent() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.addTag("alpha"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: cmd)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: cmd)
        let state = try decodeEnvelopeState(IntakeStepState.self, from: r2.stateJSON)
        #expect(state.tags.count == 1)
        #expect(state.tags.first == "alpha")
    }

    @Test("removeTag removes only the matching tag")
    func removeTag() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.addTag("beta"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let removeCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.removeTag("beta"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: removeCmd)
        let state = try decodeEnvelopeState(IntakeStepState.self, from: r2.stateJSON)
        #expect(state.tags.isEmpty)
    }

    // MARK: - complete command

    @Test("complete with non-empty title returns advance with first transition")
    func completeAdvances() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let setCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.setTitle("Ready"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: setCmd)
        let completeCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.complete)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let result = try await executor.execute(context: ec2, commandJSON: completeCmd)
        if case .advance(.label(let label)) = result.disposition {
            #expect(label == "next")
        } else {
            Issue.record("Expected .advance(.label(\"next\")), got \(result.disposition)")
        }
    }

    @Test("complete with empty title throws completionNotReady")
    func completeEmptyTitleFails() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let completeCmd = try WorkflowStepPayloadCodec.encode(IntakeStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(context: ec, commandJSON: completeCmd)
        }
    }

    // MARK: - error handling

    @Test("unknown command type throws malformedCommandJSON")
    func malformedCommand() async throws {
        let rig = try makeExecutorTestRig(kind: .intake)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: WorkflowStepExecutionError.malformedCommandJSON) {
            _ = try await executor.execute(context: ec, commandJSON: "{\"type\":\"unknownCmd\"}")
        }
    }
}
