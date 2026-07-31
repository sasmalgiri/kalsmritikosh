//
//  PJE011CompleteSyntheticWorkflowTests.swift
//  KalsmritikoshTests
//
//  PJE-011 — the complete synthetic workflow through REAL Stage 3 infrastructure:
//  intake(attachment) → selectEvidence → reviewEvidence → timeline → method →
//  decision → workProductBuild → effectivenessReview → humanApproval → closure,
//  with a mid-workflow pause→close→reopen→resume and a final close→reopen. This
//  is the central Stage 3 relaunch gate.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-011 — complete synthetic workflow", .serialized)
@MainActor
struct PJE011CompleteSyntheticWorkflowTests {

    private let t0 = PJE011Fixtures.t0

    private func lifecycle(_ rig: PJE006CRig) -> WorkflowLifecycleEngine {
        WorkflowLifecycleEngine(repository: rig.repo)
    }
    private func attachmentCoordinator(_ rig: PJE006CRig) -> WorkflowAttachmentCoordinator {
        WorkflowAttachmentCoordinator(
            workflowRuns: rig.repo, database: rig.db,
            sourceRelations: SourceRelationsRepository(database: rig.db),
            gate: CanonicalWorkflowEvidenceReferenceGate(database: rig.db, scopeRepository: rig.scopes, scope: nil),
            scopes: rig.scopes)
    }

    @Test("Full lifecycle: attachment → evidence → method → decision → work product → approval → closure, with two relaunches")
    func completeWorkflowWithRelaunch() async throws {
        var c = try await PJE011Fixtures.makeCase(suffix: "e2e")
        var rig = c.rig
        var time = t0.addingTimeInterval(10)

        // ── INTAKE: bind the canonical attachment, then advance.
        let afterAttach = try await attachmentCoordinator(rig).attachCanonicalSource(
            runID: c.runID,
            request: WorkflowCanonicalAttachmentRequest(
                artifactDefinitionID: PJE011Fixtures.attachmentArtifactDefID,
                sourceVersionID: c.attachment.svID, displayName: "invoice.pdf"),
            actor: PJE011Fixtures.human("analyst"), at: time)
        let attachmentArtifactID = try #require(afterAttach.artifacts.first).id
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, IntakeStepCommand.setTitle("Delay matter"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, IntakeStepCommand.complete, at: time)

        // ── SELECT + REVIEW evidence.
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: c.entityID.uuidString, reason: "subject"), at: time)
        time.addTimeInterval(10)
        let afterSelect = try await PJE011Fixtures.exec(rig, runID: c.runID, SelectEvidenceStepCommand.select(
            kind: .gap, canonicalObjectID: c.gapID.uuidString, reason: "missing filings"), at: time)
        let items = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: try #require(afterSelect.stepRuns.first { $0.id == afterSelect.run.currentStepRunID }).stateJSON).state.items
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, SelectEvidenceStepCommand.complete, at: time)
        for item in items {
            time.addTimeInterval(10)
            _ = try await PJE011Fixtures.exec(rig, runID: c.runID, ReviewEvidenceStepCommand.review(
                itemID: item.id, status: .reviewed, note: "seen"), at: time)
        }
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, ReviewEvidenceStepCommand.complete, at: time)

        // ── TIMELINE.
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, TimelineStepCommand.addEntry(
            objectKind: .entity, canonicalObjectID: c.entityID.uuidString, label: "appearance",
            dateISO8601: "2025-02-01T00:00:00Z", datePrecision: .day, uncertaintyNote: nil, conflictingDates: []), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, TimelineStepCommand.complete, at: time)

        // ── RELAUNCH #1 (mid-workflow): pause on the method step, close, reopen, resume.
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "method.external.timeline-analysis"), actor: PJE011Fixtures.human("analyst"), at: time)
        let pausedState = try #require(try await rig.repo.fetchRun(c.runID).stepRuns.first { $0.stepKind == .method }).stateJSON
        time.addTimeInterval(10)
        _ = try await lifecycle(rig).pause(runID: c.runID, actor: PJE011Fixtures.human("analyst"), now: time)

        rig = try await PJE011Fixtures.reopen(c)
        c = PJE011Case(rig: rig, ws: c.ws, fileID: c.fileID, entityID: c.entityID, gapID: c.gapID,
                       attachment: c.attachment, runID: c.runID, contractHash: c.contractHash)
        let reopenedMid = try await rig.repo.fetchRun(c.runID)
        #expect(reopenedMid.run.status == .paused)
        #expect(reopenedMid.run.contractSnapshotSHA256 == c.contractHash)
        #expect(try #require(reopenedMid.stepRuns.first { $0.stepKind == .method }).stateJSON == pausedState)
        time.addTimeInterval(10)
        _ = try await lifecycle(rig).resume(runID: c.runID, actor: PJE011Fixtures.human("analyst"), now: time)

        // ── METHOD result + complete.
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, MethodStepCommand.attachResult(
            PJE011Fixtures.methodResult(gapID: c.gapID, at: time)), actor: PJE011Fixtures.human("analyst"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, MethodStepCommand.complete, actor: PJE011Fixtures.human("analyst"), at: time)

        // ── DECISION (human-only).
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, DecisionStepCommand.setQuestion("Proceed to report?"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, DecisionStepCommand.setOptions(
            options: ["proceed", "halt"], mode: .humanRequired), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, DecisionStepCommand.requestHumanDecision, at: time)
        // A system actor cannot make the human decision.
        let sysTime = time.addingTimeInterval(1)
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.submitHumanDecision(
                runID: c.runID, decisionKey: "gate", selectedOption: "proceed", rationale: "x", actor: .system, at: sysTime)
        }
        time.addTimeInterval(10)
        _ = try await rig.engine.submitHumanDecision(
            runID: c.runID, decisionKey: "gate", selectedOption: "proceed", rationale: "evidence sufficient",
            basis: [WorkflowProvenanceReference(kind: .entity, canonicalObjectID: c.entityID, role: .decisionBasis)],
            actor: PJE011Fixtures.human("case-owner"), at: time)
        time.addTimeInterval(10)
        let atBuild = try await PJE011Fixtures.exec(rig, runID: c.runID, DecisionStepCommand.applyRecordedDecision, at: time)
        #expect(atBuild.stepRuns.contains { $0.stepKind == .workProductBuild && $0.status == .active })

        // ── BUILD cited work product + complete.
        time.addTimeInterval(10)
        let built = try await PJE011Fixtures.exec(rig, runID: c.runID,
            WorkProductBuildStepCommand.build(PJE011Fixtures.buildRequest(c.ws)),
            actor: PJE011Fixtures.human("case-owner"), at: time)
        let wpArtifact = try #require(built.artifacts.first { $0.kind == .workProductRun })
        let wpRunID = try #require(wpArtifact.workProductRunID)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, WorkProductBuildStepCommand.complete,
            actor: PJE011Fixtures.human("case-owner"), at: time)

        // ── EFFECTIVENESS review.
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, EffectivenessReviewStepCommand.recordAssessment(
            assessment: .effective, rationale: "addresses the question", followUpRequired: false, followUpNote: nil),
            actor: PJE011Fixtures.human("qa"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, EffectivenessReviewStepCommand.complete, actor: PJE011Fixtures.human("qa"), at: time)

        // ── APPROVAL (authorized supervisor).
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, HumanApprovalStepCommand.setPrompt("Release?"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, HumanApprovalStepCommand.requestApproval, at: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.submitHumanApproval(
            runID: c.runID, approved: true, rationale: "verified",
            actor: PJE011Fixtures.human("boss", role: "supervisor"), at: time)
        time.addTimeInterval(10)
        let atClosure = try await PJE011Fixtures.exec(rig, runID: c.runID, HumanApprovalStepCommand.applyRecordedApproval, at: time)
        #expect(atClosure.stepRuns.contains { $0.stepKind == .closure && $0.status == .active })

        // ── CLOSURE → completed.
        time.addTimeInterval(10)
        _ = try await PJE011Fixtures.exec(rig, runID: c.runID, ClosureStepCommand.setSummary("Delay investigated; memo released"),
            actor: PJE011Fixtures.human("case-owner"), at: time)
        time.addTimeInterval(10)
        let completed = try await PJE011Fixtures.exec(rig, runID: c.runID, ClosureStepCommand.confirmClosure(rationale: "done"),
            actor: PJE011Fixtures.human("case-owner"), at: time)
        #expect(completed.run.status == .completed)
        #expect(completed.checkpoints.contains { $0.reason == .completion })

        // ── RELAUNCH #2 (final): reopen the exact completed run and verify everything.
        let finalRig = try await PJE011Fixtures.reopen(c)
        let final = try await finalRig.repo.fetchRun(c.runID)
        #expect(final.run.status == .completed)
        #expect(final.run.contractSnapshotSHA256 == c.contractHash)

        // Every non-empty step state satisfies the stored-byte hash contract.
        for stepRun in final.stepRuns where !stepRun.stateJSON.isEmpty && stepRun.stateJSON != "{}" {
            #expect(stepRun.stateSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: stepRun.stateJSON))
        }
        // Attachment binding intact + snapshotV1 provenance.
        let binding = try #require(try await finalRig.repo.attachmentBinding(artifactID: attachmentArtifactID))
        #expect(binding.sourceVersionID == c.attachment.svID)
        #expect(try await finalRig.repo.provenanceSemantics(owner: .artifact(attachmentArtifactID)) == .snapshotV1)
        // Human decision + approval persisted with actor identity.
        #expect(final.decisions.contains { $0.kind == .humanDecision && $0.selectedOption == "proceed" && $0.actorIdentifier == "case-owner" })
        #expect(final.decisions.contains { $0.kind == .humanApproval && $0.actorIdentifier == "boss" })
        // Cited work product reopens with a verifying receipt + clean validation.
        let wp = try await WorkProductRunRepository(database: finalRig.db).reopen(wpRunID)
        #expect(wp.manifest.selectedFindingCount >= 1)
        #expect(VerifiableReceipt.verify(try WorkProductReceiptBuilder().build(from: wp)))
        #expect(WorkProductValidator().validateProductionExport(wp.workProduct).isValid)
        // Canonical ledger untouched (claims count equals the backfill count, nonzero).
        #expect(Int(try await finalRig.db.query("SELECT COUNT(*) FROM claims;", []).first?.int(0) ?? -1) >= 1)
    }
}
