//
//  ScopeStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — ScopeStepExecutor: prepare, objective/boundary/constraint/criterion commands.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — ScopeStepExecutor")
struct ScopeStepExecutorTests {

    private let executor = ScopeStepExecutor()

    // MARK: - Identity

    @Test("executorID, executorVersion, handledKind are stable")
    func identity() {
        #expect(executor.executorID.rawValue == "com.kalsmritikosh.step.scope")
        #expect(executor.executorVersion.rawValue == "1.0")
        #expect(executor.handledKind == .scope)
    }

    // MARK: - prepare()

    @Test("prepare() returns empty ScopeStepState")
    func prepareEmptyState() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let result = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let state = try decodeEnvelopeState(ScopeStepState.self, from: result.stateJSON)
        #expect(state.objective == "")
        #expect(state.boundaries.isEmpty)
        #expect(state.constraints.isEmpty)
        #expect(state.successCriteria.isEmpty)
    }

    // MARK: - setObjective

    @Test("setObjective updates objective and returns remainActive")
    func setObjective() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.setObjective("Reduce latency"))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        let state = try decodeEnvelopeState(ScopeStepState.self, from: result.stateJSON)
        #expect(result.disposition == .remainActive)
        #expect(state.objective == "Reduce latency")
    }

    // MARK: - addBoundary / addConstraint idempotency

    @Test("addBoundary is idempotent")
    func addBoundaryIdempotent() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.addBoundary("No external APIs"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: cmd)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: cmd)
        let state = try decodeEnvelopeState(ScopeStepState.self, from: r2.stateJSON)
        #expect(state.boundaries.count == 1)
    }

    @Test("addConstraint and removeConstraint work correctly")
    func constraintAddRemove() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.addConstraint("budget"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let removeCmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.removeConstraint("budget"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: removeCmd)
        let state = try decodeEnvelopeState(ScopeStepState.self, from: r2.stateJSON)
        #expect(state.constraints.isEmpty)
    }

    // MARK: - addSuccessCriterion

    @Test("addSuccessCriterion is idempotent")
    func addSuccessCriterion() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.addSuccessCriterion("P99 < 50ms"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: cmd)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: cmd)
        let state = try decodeEnvelopeState(ScopeStepState.self, from: r2.stateJSON)
        #expect(state.successCriteria.count == 1)
    }

    // MARK: - complete

    @Test("complete with objective returns advance")
    func completeWithObjective() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let setCmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.setObjective("Goal"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: setCmd)
        let completeCmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.complete)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let result = try await executor.execute(context: ec2, commandJSON: completeCmd)
        if case .advance(.label(let label)) = result.disposition {
            #expect(label == "next")
        } else {
            Issue.record("Expected .advance(.label(\"next\"))")
        }
    }

    @Test("complete with empty objective throws completionNotReady")
    func completeEmptyObjectiveFails() async throws {
        let rig = try makeExecutorTestRig(kind: .scope)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(ScopeStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(context: ec, commandJSON: cmd)
        }
    }
}
