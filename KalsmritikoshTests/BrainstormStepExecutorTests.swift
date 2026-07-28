//
//  BrainstormStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006A — BrainstormStepExecutor: proposal-layer only, never Claims.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006A — BrainstormStepExecutor")
struct BrainstormStepExecutorTests {

    private let executor = BrainstormStepExecutor()

    // MARK: - Identity

    @Test("executorID, executorVersion, handledKind are stable")
    func identity() {
        #expect(executor.executorID.rawValue == "com.kalsmritikosh.step.brainstorm")
        #expect(executor.executorVersion.rawValue == "1.0")
        #expect(executor.handledKind == .brainstorm)
    }

    // MARK: - prepare()

    @Test("prepare() returns empty BrainstormStepState")
    func prepareEmptyState() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let result = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let state = try decodeEnvelopeState(BrainstormStepState.self, from: result.stateJSON)
        #expect(state.proposals.isEmpty)
        #expect(state.notes == "")
    }

    // MARK: - addProposal

    @Test("addProposal appends proposal and returns remainActive")
    func addProposal() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.addProposal(id: "p1", text: "Use caching"))
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let result = try await executor.execute(context: ec, commandJSON: cmd)
        let state = try decodeEnvelopeState(BrainstormStepState.self, from: result.stateJSON)
        #expect(result.disposition == .remainActive)
        #expect(state.proposals.count == 1)
        #expect(state.proposals.first?.id == "p1")
        #expect(state.proposals.first?.text == "Use caching")
    }

    @Test("addProposal with duplicate id is idempotent")
    func addProposalDuplicateIdNoOp() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.addProposal(id: "p1", text: "First"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: cmd)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: cmd)
        let state = try decodeEnvelopeState(BrainstormStepState.self, from: r2.stateJSON)
        #expect(state.proposals.count == 1)
    }

    // MARK: - removeProposal

    @Test("removeProposal removes the proposal")
    func removeProposal() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.addProposal(id: "p1", text: "idea"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let removeCmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.removeProposal(id: "p1"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: removeCmd)
        let state = try decodeEnvelopeState(BrainstormStepState.self, from: r2.stateJSON)
        #expect(state.proposals.isEmpty)
    }

    // MARK: - promoteProposal

    @Test("promoteProposal sets isPriority true")
    func promoteProposal() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.addProposal(id: "p2", text: "idea"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let promoteCmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.promoteProposal(id: "p2"))
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let r2 = try await executor.execute(context: ec2, commandJSON: promoteCmd)
        let state = try decodeEnvelopeState(BrainstormStepState.self, from: r2.stateJSON)
        #expect(state.proposals.first(where: { $0.id == "p2" })?.isPriority == true)
    }

    // MARK: - complete

    @Test("complete with proposals returns advance")
    func completeWithProposals() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let addCmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.addProposal(id: "p1", text: "idea"))
        let ec1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let r1 = try await executor.execute(context: ec1, commandJSON: addCmd)
        let completeCmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.complete)
        let ec2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let result = try await executor.execute(context: ec2, commandJSON: completeCmd)
        if case .advance(.label(let label)) = result.disposition {
            #expect(label == "next")
        } else {
            Issue.record("Expected .advance(.label(\"next\"))")
        }
    }

    @Test("complete with no proposals throws completionNotReady")
    func completeNoProposalsFails() async throws {
        let rig = try makeExecutorTestRig(kind: .brainstorm)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let cmd = try WorkflowStepPayloadCodec.encode(BrainstormStepCommand.complete)
        let ec = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(context: ec, commandJSON: cmd)
        }
    }
}
