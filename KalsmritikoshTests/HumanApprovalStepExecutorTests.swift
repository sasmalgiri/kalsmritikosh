//
//  HumanApprovalStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — HumanApprovalStepExecutor: frozen approver roles, no executor/
//  automation approval, persisted-approval application. 9 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — HumanApprovalStepExecutor")
@MainActor
struct HumanApprovalStepExecutorTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_600_000)

    private func rigAndState() async throws -> (HumanApprovalStepExecutor, ExecutorTestRig, String) {
        let executor = HumanApprovalStepExecutor()
        let rig = try makeExecutorTestRig(
            kind: .humanApproval,
            transitionLabels: ["approved", "rejected"],
            approverRoles: ["supervisor", "lead-reviewer"])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func promptedState(
        executor: HumanApprovalStepExecutor, rig: ExecutorTestRig, prepJSON: String
    ) async throws -> String {
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(
            HumanApprovalStepCommand.setPrompt("Approve the final memo for release?"))
        return try await executor.execute(context: ctx, commandJSON: cmd).stateJSON
    }

    private func approvalDecision(approved: Bool, role: String = "supervisor") -> WorkflowDecision {
        WorkflowDecision(
            id: UUID(), workflowRunID: UUID(), stepRunID: UUID(),
            decisionKey: "approval", kind: .humanApproval,
            selectedOption: approved ? "approved" : "rejected",
            rationale: "checked", actorKind: .human, actorIdentifier: "boss-1",
            supersedesDecisionID: nil, metadataJSON: "{}", decidedAt: t0)
    }

    @Test("Allowed roles come from the frozen definition, never from commands")
    func rolesComeFromFrozenDefinition() async throws {
        let (_, _, stateJSON) = try await rigAndState()
        let state = try decodeEnvelopeState(HumanApprovalStepState.self, from: stateJSON)
        #expect(state.allowedRoles == ["supervisor", "lead-reviewer"])
        // The command vocabulary has no way to set roles at all.
        #expect(state.status == .preparing)
    }

    @Test("A blank prompt is rejected")
    func blankPromptRejected() async throws {
        let (executor, rig, stateJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: stateJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.setPrompt("  "))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("requestApproval requires a prompt, then emits the waiting disposition")
    func requestApprovalEmitsWaiting() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        // Without prompt → refused
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let request = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.requestApproval)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: request)
        }
        // With prompt → waiting
        let prompted = try await promptedState(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx2 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prompted)
        let r = try await executor.execute(context: ctx2, commandJSON: request)
        #expect(r.disposition == .requestHumanApproval)
        #expect(try decodeEnvelopeState(HumanApprovalStepState.self, from: r.stateJSON).status == .awaitingApproval)
    }

    @Test("The executor cannot fabricate approval state — apply requires a persisted decision")
    func executorCannotFabricateApproval() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let prompted = try await promptedState(executor: executor, rig: rig, prepJSON: prepJSON)
        // No persisted humanApproval decision in the aggregate → refused, regardless
        // of what any command or state claims.
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prompted)
        let apply = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: apply)
        }
    }

    @Test("A persisted approval follows the declared 'approved' transition")
    func approvedTransitionFollowed() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let prompted = try await promptedState(executor: executor, rig: rig, prepJSON: prepJSON)
        let decision = approvalDecision(approved: true)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prompted, decisions: [decision])
        let apply = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval)
        let r = try await executor.execute(context: ctx, commandJSON: apply)
        #expect(r.disposition == .advance(.label("approved")))
        let state = try decodeEnvelopeState(HumanApprovalStepState.self, from: r.stateJSON)
        #expect(state.approved == true)
        #expect(state.decisionID == decision.id)
        #expect(state.status == .approvalRecorded)
    }

    @Test("A persisted rejection follows the declared 'rejected' transition")
    func rejectedTransitionFollowed() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let prompted = try await promptedState(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prompted,
            decisions: [approvalDecision(approved: false)])
        let apply = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval)
        let r = try await executor.execute(context: ctx, commandJSON: apply)
        #expect(r.disposition == .advance(.label("rejected")))
        #expect(try decodeEnvelopeState(HumanApprovalStepState.self, from: r.stateJSON).approved == false)
    }

    @Test("No invented fallback: a missing declared transition label refuses the apply")
    func missingDeclaredTransitionRefused() async throws {
        // Step declares ONLY 'approved' — a persisted rejection cannot invent a branch.
        let executor = HumanApprovalStepExecutor()
        let rig = try makeExecutorTestRig(
            kind: .humanApproval, suffix: "only-approved",
            transitionLabels: ["approved"],
            approverRoles: ["supervisor"])
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prep.stateJSON)
        let prompted = try await executor.execute(
            context: ctx1,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                HumanApprovalStepCommand.setPrompt("Approve?"))).stateJSON
        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prompted,
            decisions: [approvalDecision(approved: false)])
        let apply = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx2, commandJSON: apply)
        }
    }

    @Test("Lifecycle role assertion rejects blank, undeclared, and nonhuman approvers")
    func lifecycleRoleAssertionEnforced() async throws {
        let rig = try makeExecutorTestRig(
            kind: .humanApproval, suffix: "roles",
            transitionLabels: ["approved", "rejected"],
            approverRoles: ["supervisor"])
        let stateMachine = WorkflowLifecycleStateMachine()
        let step = rig.entryStep

        // Undeclared role
        #expect(throws: WorkflowLifecycleError.self) {
            try stateMachine.assertHumanApproverRole(
                actor: WorkflowLifecycleActor(kind: .human, identifier: "u", role: "intern"),
                step: step)
        }
        // Blank role
        #expect(throws: WorkflowLifecycleError.self) {
            try stateMachine.assertHumanApproverRole(
                actor: WorkflowLifecycleActor(kind: .human, identifier: "u", role: "  "),
                step: step)
        }
        // System actor
        #expect(throws: WorkflowLifecycleError.self) {
            try stateMachine.assertHumanApproverRole(
                actor: WorkflowLifecycleActor(kind: .system, identifier: nil, role: "supervisor"),
                step: step)
        }
        // Deterministic rule
        #expect(throws: WorkflowLifecycleError.self) {
            try stateMachine.assertHumanApproverRole(
                actor: WorkflowLifecycleActor(kind: .deterministicRule, identifier: "r", role: "supervisor"),
                step: step)
        }
        // Declared human role passes
        try stateMachine.assertHumanApproverRole(
            actor: WorkflowLifecycleActor(kind: .human, identifier: "boss", role: "supervisor"),
            step: step)
    }

    @Test("Approval state survives relaunch byte-exact through the envelope")
    func approvalStateSurvivesRelaunch() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let prompted = try await promptedState(executor: executor, rig: rig, prepJSON: prepJSON)
        let decision = approvalDecision(approved: true)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prompted, decisions: [decision])
        let apply = try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval)
        let r = try await executor.execute(context: ctx, commandJSON: apply)
        // Reopen simulation: decode the persisted envelope again.
        let reopened = try decodeEnvelopeState(HumanApprovalStepState.self, from: r.stateJSON)
        #expect(reopened.decisionID == decision.id)
        #expect(reopened.approved == true)
        #expect(r.stateSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: r.stateJSON))
    }
}
