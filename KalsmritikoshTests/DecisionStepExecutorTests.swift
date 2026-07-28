//
//  DecisionStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — DecisionStepExecutor: frozen-branch options, human-required
//  protection, persisted-decision application. 11 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — DecisionStepExecutor")
@MainActor
struct DecisionStepExecutorTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_600_000)
    private let branches = ["approve", "reject"]

    private func humanActor(_ id: String = "reviewer-1") -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: nil)
    }

    private func ruleActor() -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .deterministicRule, identifier: "rule-7", role: nil)
    }

    private func rigAndState() async throws -> (DecisionStepExecutor, ExecutorTestRig, String) {
        let executor = DecisionStepExecutor()
        let rig = try makeExecutorTestRig(
            kind: .decision,
            transitionLabels: branches,
            decisionBranches: branches)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    /// State primed with question + options in the given mode.
    private func primedState(
        executor: DecisionStepExecutor, rig: ExecutorTestRig, prepJSON: String,
        mode: DecisionStepMode
    ) async throws -> String {
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let q = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.setQuestion("Proceed with filing?"))
        let r1 = try await executor.execute(context: ctx1, commandJSON: q)
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: r1.stateJSON)
        let o = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.setOptions(options: branches, mode: mode))
        let r2 = try await executor.execute(context: ctx2, commandJSON: o)
        return r2.stateJSON
    }

    private func persistedDecision(option: String, by identifier: String = "reviewer-1") -> WorkflowDecision {
        WorkflowDecision(
            id: UUID(), workflowRunID: UUID(), stepRunID: UUID(),
            decisionKey: "gate", kind: .humanDecision, selectedOption: option,
            rationale: "reviewed", actorKind: .human, actorIdentifier: identifier,
            supersedesDecisionID: nil, metadataJSON: "{}", decidedAt: t0)
    }

    @Test("Options must match the frozen decision branches")
    func optionsMustMatchFrozenBranches() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let bad = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.setOptions(options: ["approve", "escalate"], mode: .humanRequired))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: bad)
        }
    }

    @Test("Duplicate options are rejected")
    func duplicateOptionRejected() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let bad = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.setOptions(options: ["approve", "approve"], mode: .humanRequired))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: bad)
        }
    }

    @Test("An undeclared branch cannot be selected deterministically")
    func undeclaredBranchRejected() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .deterministicAllowed)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: ruleActor())
        let bad = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.selectDeterministicBranch(branch: "escalate", rationale: nil))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: bad)
        }
    }

    @Test("A human-required decision cannot be selected by an executor")
    func humanRequiredCannotBeSelectedDeterministically() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: ruleActor())
        let cmd = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.selectDeterministicBranch(branch: "approve", rationale: nil))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("Deterministic branch selection requires a rule or system actor")
    func deterministicRequiresRuleOrSystemActor() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .deterministicAllowed)
        let humanCtx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: humanActor())
        let cmd = try WorkflowStepPayloadCodec.encode(
            DecisionStepCommand.selectDeterministicBranch(branch: "approve", rationale: nil))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: humanCtx, commandJSON: cmd)
        }
        // Rule actor succeeds and requests the chooseBranch operation.
        let ruleCtx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, actor: ruleActor())
        let r = try await executor.execute(context: ruleCtx, commandJSON: cmd)
        #expect(r.disposition == .chooseBranch(branch: "approve", rationale: nil))
    }

    @Test("requestHumanDecision emits the waiting disposition with awaitingHuman state")
    func requestHumanDecisionEmitsWaiting() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state)
        let cmd = try WorkflowStepPayloadCodec.encode(DecisionStepCommand.requestHumanDecision)
        let r = try await executor.execute(context: ctx, commandJSON: cmd)
        #expect(r.disposition == .requestHumanDecision)
        let decoded = try decodeEnvelopeState(DecisionStepState.self, from: r.stateJSON)
        #expect(decoded.status == .awaitingHuman)
    }

    @Test("requestHumanDecision is refused when a decision is already recorded")
    func requestRefusedWhenDecisionExists() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state,
            decisions: [persistedDecision(option: "approve")])
        let cmd = try WorkflowStepPayloadCodec.encode(DecisionStepCommand.requestHumanDecision)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("applyRecordedDecision uses the PERSISTED decision and follows its branch")
    func applyUsesPersistedDecision() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        let decision = persistedDecision(option: "reject")
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, decisions: [decision])
        let cmd = try WorkflowStepPayloadCodec.encode(DecisionStepCommand.applyRecordedDecision)
        let r = try await executor.execute(context: ctx, commandJSON: cmd)
        #expect(r.disposition == .chooseBranch(branch: "reject", rationale: "reviewed"))
        let decoded = try decodeEnvelopeState(DecisionStepState.self, from: r.stateJSON)
        #expect(decoded.recordedDecisionID == decision.id)
        #expect(decoded.selectedOption == "reject")
        #expect(decoded.status == .decisionRecorded)
    }

    @Test("applyRecordedDecision without a persisted decision is refused — fake IDs in commands are impossible")
    func applyWithoutPersistedDecisionRefused() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        // The command vocabulary carries NO decision ID — a caller cannot inject one.
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: state)
        let cmd = try WorkflowStepPayloadCodec.encode(DecisionStepCommand.applyRecordedDecision)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("A superseded decision is ignored — the latest nonsuperseded decision wins")
    func supersededDecisionIgnored() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        let original = persistedDecision(option: "approve")
        let replacement = WorkflowDecision(
            id: UUID(), workflowRunID: UUID(), stepRunID: UUID(),
            decisionKey: "gate", kind: .humanDecision, selectedOption: "reject",
            rationale: nil, actorKind: .human, actorIdentifier: "reviewer-2",
            supersedesDecisionID: original.id, metadataJSON: "{}",
            decidedAt: t0.addingTimeInterval(60))
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state,
            decisions: [original, replacement])
        let cmd = try WorkflowStepPayloadCodec.encode(DecisionStepCommand.applyRecordedDecision)
        let r = try await executor.execute(context: ctx, commandJSON: cmd)
        #expect(r.disposition == .chooseBranch(branch: "reject", rationale: nil))
    }

    @Test("Executor state cannot impersonate a decision record — persisted option always wins")
    func stateCannotImpersonateDecision() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let state = try await primedState(
            executor: executor, rig: rig, prepJSON: prepJSON, mode: .humanRequired)
        // Even if a prior (tampered) state claimed "approve", applyRecordedDecision
        // reads the aggregate's persisted decision — which says "reject".
        let decision = persistedDecision(option: "reject")
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: state, decisions: [decision])
        let cmd = try WorkflowStepPayloadCodec.encode(DecisionStepCommand.applyRecordedDecision)
        let r = try await executor.execute(context: ctx, commandJSON: cmd)
        if case .chooseBranch(let branch, _) = r.disposition {
            #expect(branch == "reject")
        } else {
            Issue.record("Expected chooseBranch, got \(r.disposition)")
        }
    }
}
