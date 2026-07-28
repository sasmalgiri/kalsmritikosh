//
//  PJE006CEndToEndTests.swift
//  KalsmritikoshTests
//
//  PJE-006C gate — the exact Stage 3 sequence:
//  start → save → destroy actors → reopen → complete method adapter →
//  record human decision → produce cited work product → approve/review →
//  close → destroy actors → reopen exact completed run + exact cited product.
//  Plus: terminal completion is PJE-005 gated. 2 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — Stage 3 end-to-end gate", .serialized)
@MainActor
struct PJE006CEndToEndTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_800_000)

    private func human(_ id: String, role: String? = nil) -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: role)
    }

    private func exec(
        _ rig: PJE006CRig, runID: UUID, _ command: some Encodable,
        actor: WorkflowLifecycleActor, at time: Date
    ) async throws -> ReopenedWorkflowRun {
        try await rig.engine.executeCommand(
            runID: runID,
            commandJSON: try WorkflowStepPayloadCodec.encode(command),
            actor: actor, now: time)
    }

    private func canonicalCounts(_ db: Database) async throws -> [Int] {
        var counts: [Int] = []
        for table in ["entities", "claims", "evidence_blocks", "relationships", "events", "generic_facts"] {
            counts.append(Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1))
        }
        return counts
    }

    @Test("Full Stage 3 flow with two actor destructions: method → decision → build → review → approval → closure")
    func fullStageThreeFlow() async throws {
        let url = PJE006CFixtures.newDatabaseURL()
        var rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "shipment delayed on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let countsBefore = try await canonicalCounts(rig.db)

        let (pkg, wfID) = try PJE006CFixtures.makeStage3Package(suffix: "e2e")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: "Stage 3 gate", parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        let contractHash = created.run.contractSnapshotSHA256

        // ── START on the method step
        var time = t0.addingTimeInterval(60)
        let started = try await rig.engine.startRun(runID: runID, actor: .system, now: time)
        #expect(started.stepRuns.first?.executorID == "com.kalsmritikosh.step.method")
        #expect(started.stepRuns.first?.executorVersion == "1")

        // Attach an external method result (adapter only) after a SAVE + actor destruction.
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "method.external.timeline-analysis"),
            actor: human("analyst-1"), at: time)

        // ── DESTROY ACTORS #1 → recreate over the same file → reopen exact method state
        rig = try await PJE006CFixtures.makeRig(at: url, migrate: false)
        let reopened1 = try await rig.repo.fetchRun(runID)
        let methodState1 = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<MethodStepState>.self,
            from: try #require(reopened1.stepRuns.first?.stateJSON))
        #expect(methodState1.state.requestedMethodDefinitionID == "method.external.timeline-analysis")

        time.addTimeInterval(10)
        let result = WorkflowMethodResultReference(
            providerID: "com.external.provider", providerVersion: "1.0",
            methodDefinitionID: "method.external.timeline-analysis",
            methodRunReferenceID: "ext-run-42", resultReferenceID: "ext-result-42",
            summary: "Delay attributable to carrier handoff window",
            provenanceReferences: [WorkflowMethodProvenanceReference(
                objectKind: "gap", canonicalObjectID: try await seededGapID(rig).uuidString)],
            completedBy: "analyst-1", completedAt: time, limitations: ["one carrier record"])
        _ = try await exec(rig, runID: runID, MethodStepCommand.attachResult(result),
                           actor: human("analyst-1"), at: time)

        // methodResultPresent must gate the advance — and pass now.
        time.addTimeInterval(10)
        let atDecision = try await exec(rig, runID: runID, MethodStepCommand.complete,
                                        actor: human("analyst-1"), at: time)
        #expect(atDecision.stepRuns.contains { $0.stepKind == .decision && $0.status == .active })

        // ── DECISION: question + options, request human decision
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, DecisionStepCommand.setQuestion("Proceed to report?"),
                           actor: .system, at: time)
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, DecisionStepCommand.setOptions(
            options: ["proceed", "halt"], mode: .humanRequired), actor: .system, at: time)
        time.addTimeInterval(10)
        let waiting = try await exec(rig, runID: runID, DecisionStepCommand.requestHumanDecision,
                                     actor: .system, at: time)
        #expect(waiting.run.status == .waitingForHuman)

        // ── DESTROY ACTORS #2 → recreate → submit the identified human decision
        rig = try await PJE006CFixtures.makeRig(at: url, migrate: false)
        time.addTimeInterval(10)
        let decided = try await rig.engine.submitHumanDecision(
            runID: runID, decisionKey: "report-gate", selectedOption: "proceed",
            rationale: "evidence sufficient", actor: human("case-owner"), at: time)
        #expect(decided.run.status == .active)
        let persistedDecision = try #require(decided.decisions.first { $0.kind == .humanDecision })
        #expect(persistedDecision.actorIdentifier == "case-owner")
        #expect(persistedDecision.selectedOption == "proceed")

        // Apply the PERSISTED decision → branch to the build step.
        time.addTimeInterval(10)
        let atBuild = try await exec(rig, runID: runID, DecisionStepCommand.applyRecordedDecision,
                                     actor: .system, at: time)
        #expect(atBuild.stepRuns.contains { $0.stepKind == .workProductBuild && $0.status == .active })

        // ── BUILD a real cited work product through the accepted assembly path
        time.addTimeInterval(10)
        let request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "PJE-006C WS", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        let built = try await exec(rig, runID: runID, WorkProductBuildStepCommand.build(request),
                                   actor: human("case-owner"), at: time)
        let buildStepRun = try #require(built.stepRuns.first {
            $0.id == built.run.currentStepRunID })
        let buildState = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<WorkProductBuildStepState>.self,
            from: buildStepRun.stateJSON).state
        let wpRunID = try #require(buildState.workProductRunID)
        let assembledAtBuild = try await WorkProductRunRepository(database: rig.db).reopen(wpRunID)
        #expect(assembledAtBuild.manifest.selectedFindingCount >= 1,
                "The built product must carry cited findings")
        let artifact = try #require(built.artifacts.first)
        #expect(artifact.workProductRunID == wpRunID,
                "Workflow artifact points to the exact work-product run")

        // artifactGenerated gate passes → effectiveness review.
        time.addTimeInterval(10)
        let atReview = try await exec(rig, runID: runID, WorkProductBuildStepCommand.complete,
                                      actor: human("case-owner"), at: time)
        #expect(atReview.stepRuns.contains { $0.stepKind == .effectivenessReview && $0.status == .active })

        // ── EFFECTIVENESS: human-recorded assessment
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, EffectivenessReviewStepCommand.recordAssessment(
            assessment: .effective, rationale: "Report addresses the delay question",
            followUpRequired: false, followUpNote: nil),
            actor: human("qa-lead"), at: time)
        time.addTimeInterval(10)
        let atApproval = try await exec(rig, runID: runID, EffectivenessReviewStepCommand.complete,
                                        actor: human("qa-lead"), at: time)
        #expect(atApproval.stepRuns.contains { $0.stepKind == .humanApproval && $0.status == .active })

        // ── APPROVAL: request → waiting → submit from an ALLOWED role → apply
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, HumanApprovalStepCommand.setPrompt("Release memo?"),
                           actor: .system, at: time)
        time.addTimeInterval(10)
        let waitingApproval = try await exec(rig, runID: runID, HumanApprovalStepCommand.requestApproval,
                                             actor: .system, at: time)
        #expect(waitingApproval.run.status == .waitingForHuman)
        time.addTimeInterval(10)
        let approved = try await rig.engine.submitHumanApproval(
            runID: runID, approved: true, rationale: "verified",
            actor: human("boss-1", role: "supervisor"), at: time)
        let approvalDecision = try #require(approved.decisions.first { $0.kind == .humanApproval })
        #expect(approvalDecision.actorIdentifier == "boss-1")
        time.addTimeInterval(10)
        let atClosure = try await exec(rig, runID: runID, HumanApprovalStepCommand.applyRecordedApproval,
                                       actor: .system, at: time)
        #expect(atClosure.stepRuns.contains { $0.stepKind == .closure && $0.status == .active })

        // ── CLOSURE: human confirmation → gated terminal completion + checkpoint
        time.addTimeInterval(10)
        _ = try await exec(rig, runID: runID, ClosureStepCommand.setSummary(
            "Delay investigated; memo released"), actor: human("case-owner"), at: time)
        time.addTimeInterval(10)
        let completed = try await exec(rig, runID: runID,
                                       ClosureStepCommand.confirmClosure(rationale: "done"),
                                       actor: human("case-owner"), at: time)
        #expect(completed.run.status == .completed)
        #expect(completed.checkpoints.contains { $0.reason == .completion },
                "Terminal completion must create a durable checkpoint")

        // ── DESTROY ACTORS #3 → reopen the exact completed run + exact cited product
        rig = try await PJE006CFixtures.makeRig(at: url, migrate: false)
        let final = try await rig.repo.fetchRun(runID)
        #expect(final.run.status == .completed)
        #expect(final.run.contractSnapshotSHA256 == contractHash, "Contract snapshot hash unchanged")
        #expect(final.run.workflowDefinitionVersion == created.run.workflowDefinitionVersion)

        // Exact executor IDs and versions retained per step kind.
        let expectedExecutors: [WorkflowStepKind: String] = [
            .method: "com.kalsmritikosh.step.method",
            .decision: "com.kalsmritikosh.step.decision",
            .workProductBuild: "com.kalsmritikosh.step.work-product-build",
            .effectivenessReview: "com.kalsmritikosh.step.effectiveness-review",
            .humanApproval: "com.kalsmritikosh.step.human-approval",
            .closure: "com.kalsmritikosh.step.closure"
        ]
        for stepRun in final.stepRuns {
            guard let expected = expectedExecutors[stepRun.stepKind] else { continue }
            #expect(stepRun.executorID == expected)
            #expect(stepRun.executorVersion == "1")
            // Every step-state hash satisfies its recorded semantics (all V1 here).
            #expect(try await rig.repo.stepStateHashSemantics(stepRunID: stepRun.id) == .storedUTF8BytesV1)
            #expect(stepRun.stateSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: stepRun.stateJSON))
        }

        // Method result reference retained byte-exact.
        let methodRun = try #require(final.stepRuns.first { $0.stepKind == .method })
        let finalMethodState = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<MethodStepState>.self, from: methodRun.stateJSON).state
        #expect(finalMethodState.result == result)

        // Decision + approval persisted with actor identity; branch followed from the decision.
        #expect(final.decisions.contains {
            $0.kind == .humanDecision && $0.selectedOption == "proceed" && $0.actorIdentifier == "case-owner" })
        #expect(final.decisions.contains {
            $0.kind == .branchSelection && $0.selectedOption == "proceed" })
        #expect(final.decisions.contains {
            $0.kind == .humanApproval && $0.selectedOption == "approved" && $0.actorIdentifier == "boss-1" })

        // The work product reopens IDENTICALLY: manifest + citations.
        let reopenedWP = try await WorkProductRunRepository(database: rig.db).reopen(wpRunID)
        #expect(reopenedWP.workProduct.title == assembledAtBuild.workProduct.title)
        #expect(reopenedWP.manifest.selectedFindingCount == assembledAtBuild.manifest.selectedFindingCount)
        #expect(reopenedWP.manifest.sourceVersionIDs == assembledAtBuild.manifest.sourceVersionIDs)
        #expect(reopenedWP.manifest.sourceHashes == assembledAtBuild.manifest.sourceHashes)
        #expect(reopenedWP.workProduct.allCitations.count == assembledAtBuild.workProduct.allCitations.count)

        // Effectiveness assessment remains workflow-owned review vocabulary.
        let reviewRun = try #require(final.stepRuns.first { $0.stepKind == .effectivenessReview })
        #expect(reviewRun.outputJSON?.contains("not canonical evidence status") == true)

        // Completed run is immutable.
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.executeCommand(
                runID: runID,
                commandJSON: try WorkflowStepPayloadCodec.encode(ClosureStepCommand.setSummary("x")),
                actor: self.human("case-owner"), now: time)
        }

        // Canonical ledger unchanged (work-product tables are output, not canonical).
        let countsAfter = try await canonicalCounts(rig.db)
        #expect(countsAfter == countsBefore, "Canonical Claims/evidence/entities/events/relationships unchanged")
    }

    /// Seed one gap node so method provenance can reference a real canonical object.
    private func seededGapID(_ rig: PJE006CRig) async throws -> UUID {
        let gapID = UUID()
        try await rig.db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, detected_at) VALUES (?,?,?,?,?);
        """, [.uuid(gapID), .text("sequenceHole"), .text("carrier records missing"),
              .text("cadence"), .real(t0.timeIntervalSince1970)])
        return gapID
    }

    @Test("Terminal completion is PJE-005 gated: a blocking unmet requirement on the closure step prevents completion")
    func terminalCompletionIsGated() async throws {
        let url = PJE006CFixtures.newDatabaseURL()
        let rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "z")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)

        // Closure step declares a blocking artifactGenerated requirement with a
        // required artifact that is NEVER produced.
        let closureID = StepDefinitionID(rawValue: "step.closure.gated")
        let doneID = StepDefinitionID(rawValue: "step.done.gated")
        let closure = PersonaWorkflowStepDefinition(
            id: closureID, kind: .closure, label: "Close", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "finish", targetStepID: doneID)],
            requirements: [PersonaWorkflowRequirement(
                id: "req.final-artifact", kind: .artifactGenerated,
                label: "Final artifact", isBlocking: true)],
            artifacts: [PersonaWorkflowArtifactDefinition(
                id: "artifact.final", label: "Final report",
                workProductTemplateID: PJE006CFixtures.wpDefID, isRequired: true)])
        let done = PersonaWorkflowStepDefinition(
            id: doneID, kind: .closure, label: "Done", isTerminal: true)
        let wfID = WorkflowDefinitionID(rawValue: "com.pje006c.wf.gated")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "Gated WF", steps: [closure, done])
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let appID = ApplicationDefinitionID(rawValue: "com.pje006c.app.gated")
        let term = PersonaTerminologyDefinition(
            id: TerminologyDefinitionID(rawValue: "com.pje006c.term.gated"),
            version: 1, applicationID: appID, labels: [:])
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "Gated App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: term.id, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)

        var time = t0.addingTimeInterval(60)
        _ = try await exec(rig, runID: created.run.id,
                           ClosureStepCommand.setSummary("Attempting early close"),
                           actor: human("owner"), at: time)
        time.addTimeInterval(10)
        // The executor's checks pass (summary, checklist, attention) — but the
        // hardened PJE-004 complete() re-evaluates PJE-005 and must refuse.
        await #expect(throws: WorkflowLifecycleError.self) {
            _ = try await self.exec(rig, runID: created.run.id,
                                    ClosureStepCommand.confirmClosure(rationale: nil),
                                    actor: self.human("owner"), at: time)
        }
        let after = try await rig.repo.fetchRun(created.run.id)
        #expect(after.run.status != .completed, "Blocking requirement must prevent terminal completion")
    }
}
