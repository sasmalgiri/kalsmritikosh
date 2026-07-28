//
//  EffectivenessReviewStepExecutorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — EffectivenessReviewStepExecutor: human-judgment assessment,
//  criterion-anchored observations, workflow-review-only vocabulary. 10 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — EffectivenessReviewStepExecutor")
@MainActor
struct EffectivenessReviewStepExecutorTests {

    private func humanActor(_ id: String = "reviewer-1") -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: nil)
    }

    private func rigAndState(
        gate: FixtureEvidenceGate = FixtureEvidenceGate()
    ) async throws -> (EffectivenessReviewStepExecutor, ExecutorTestRig, String) {
        let executor = EffectivenessReviewStepExecutor(gate: gate)
        let rig = try makeExecutorTestRig(kind: .effectivenessReview)
        let prep = try await executor.prepare(context: makePreparationCtx(rig: rig))
        return (executor, rig, prep.stateJSON)
    }

    private func criterion(_ id: String = "crit.1") -> EffectivenessCriterion {
        EffectivenessCriterion(
            id: id, label: "No recurrence",
            expectedCondition: "No repeat incident within 90 days")
    }

    private func withCriterion(
        executor: EffectivenessReviewStepExecutor, rig: ExecutorTestRig, prepJSON: String
    ) async throws -> String {
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(
            EffectivenessReviewStepCommand.addCriterion(criterion()))
        return try await executor.execute(context: ctx, commandJSON: cmd).stateJSON
    }

    private func assessJSON(
        _ assessment: WorkflowEffectivenessAssessment = .effective,
        rationale: String = "Both criteria observed satisfied",
        followUpRequired: Bool = false,
        followUpNote: String? = nil
    ) throws -> String {
        try WorkflowStepPayloadCodec.encode(EffectivenessReviewStepCommand.recordAssessment(
            assessment: assessment, rationale: rationale,
            followUpRequired: followUpRequired, followUpNote: followUpNote))
    }

    @Test("Criterion IDs must be unique")
    func criteriaUnique() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let withOne = try await withCriterion(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: withOne)
        let dup = try WorkflowStepPayloadCodec.encode(
            EffectivenessReviewStepCommand.addCriterion(criterion()))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: dup)
        }
    }

    @Test("An observation must reference a declared criterion")
    func observationRequiresDeclaredCriterion() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        let cmd = try WorkflowStepPayloadCodec.encode(
            EffectivenessReviewStepCommand.addObservation(
                criterionID: "crit.ghost", observation: "obs", evidenceReferences: []))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("Canonical observation references are workspace-gated")
    func observationReferencesGated() async throws {
        let deniedID = UUID()
        let (executor, rig, prepJSON) = try await rigAndState(
            gate: FixtureEvidenceGate(deniedIDs: [deniedID]))
        let withOne = try await withCriterion(executor: executor, rig: rig, prepJSON: prepJSON)
        let ctx = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: withOne)
        let cmd = try WorkflowStepPayloadCodec.encode(
            EffectivenessReviewStepCommand.addObservation(
                criterionID: "crit.1", observation: "Denied source",
                evidenceReferences: [WorkflowMethodProvenanceReference(
                    objectKind: "evidenceBlock", canonicalObjectID: deniedID.uuidString)]))
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: cmd)
        }
    }

    @Test("A system actor cannot record the final assessment")
    func systemCannotAssess() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: .system)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try assessJSON())
        }
    }

    @Test("A deterministic rule cannot record the final assessment")
    func ruleCannotAssess() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let rule = WorkflowLifecycleActor(kind: .deterministicRule, identifier: "rule-9", role: nil)
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: rule)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx, commandJSON: try assessJSON())
        }
    }

    @Test("A human assessment round-trips with reviewer identity")
    func humanAssessmentRoundTrips() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor("qa-lead"))
        let r = try await executor.execute(
            context: ctx, commandJSON: try assessJSON(.partiallyEffective))
        let state = try decodeEnvelopeState(EffectivenessReviewStepState.self, from: r.stateJSON)
        #expect(state.assessment == .partiallyEffective)
        #expect(state.reviewedBy == "qa-lead")
        #expect(state.rationale == "Both criteria observed satisfied")
    }

    @Test("A follow-up note is required when follow-up is required")
    func followUpNoteRequired() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor())
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(
                context: ctx,
                commandJSON: try assessJSON(.ineffective, followUpRequired: true, followUpNote: nil))
        }
        // With a note it succeeds.
        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor())
        let r = try await executor.execute(
            context: ctx2,
            commandJSON: try assessJSON(.ineffective, followUpRequired: true,
                                        followUpNote: "Re-audit next quarter"))
        let state = try decodeEnvelopeState(EffectivenessReviewStepState.self, from: r.stateJSON)
        #expect(state.followUpRequired == true)
        #expect(state.followUpNote == "Re-audit next quarter")
    }

    @Test("An inconclusive assessment is permitted")
    func inconclusivePermitted() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor())
        let r = try await executor.execute(context: ctx, commandJSON: try assessJSON(.inconclusive))
        let state = try decodeEnvelopeState(EffectivenessReviewStepState.self, from: r.stateJSON)
        #expect(state.assessment == .inconclusive)
    }

    @Test("Completion is blocked without an assessment; advances with one and labels output as workflow review")
    func completionRequiresAssessment() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let complete = try WorkflowStepPayloadCodec.encode(EffectivenessReviewStepCommand.complete)
        let ctx1 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: prepJSON)
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await executor.execute(context: ctx1, commandJSON: complete)
        }
        let ctx2 = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor())
        let assessed = try await executor.execute(context: ctx2, commandJSON: try assessJSON()).stateJSON
        let ctx3 = try makeExecutionCtx(executor: executor, rig: rig, stateJSON: assessed)
        let r = try await executor.execute(context: ctx3, commandJSON: complete)
        #expect(r.disposition == .advance(.label("next")))
        let output = try #require(r.outputJSON)
        #expect(output.contains("workflowEffectivenessReview"))
        #expect(output.contains("not canonical evidence status"))
    }

    @Test("The assessment never closes the workflow automatically and alters no evidence status")
    func assessmentIsWorkflowOwnedOnly() async throws {
        let (executor, rig, prepJSON) = try await rigAndState()
        let ctx = try makeExecutionCtx(
            executor: executor, rig: rig, stateJSON: prepJSON, actor: humanActor())
        let r = try await executor.execute(context: ctx, commandJSON: try assessJSON(.effective))
        // Recording an assessment stays on the step — no advance, no terminal completion.
        #expect(r.disposition == .remainActive)
        // The vocabulary is workflow-review-only: no evidence-status terms in the envelope.
        let lowered = r.stateJSON.lowercased()
        #expect(!lowered.contains("evidencestatus"))
        #expect(!lowered.contains("confirmedclaim"))
        #expect(!lowered.contains("capa"))
    }
}
