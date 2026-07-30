//
//  WorkflowProvenanceIntegrationTests.swift
//  KalsmritikoshTests
//
//  PJE-007 — executor/engine integration and end-to-end provenance. Each
//  reference-holding executor emits its ordered references from the RESULTING
//  state; the engine revalidates before persistence; invalid output writes
//  nothing; work-product provenance is derived from the accepted manifest and
//  citations, never prose; and a complete run survives close and reopen.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — executor/engine integration and E2E", .serialized)
@MainActor
struct WorkflowProvenanceIntegrationTests {

    private let t0 = PJE007Fixtures.t0

    // MARK: - Helpers

    private func latestRefs(_ rig: PJE007Rig, step id: UUID) async throws -> [WorkflowProvenanceReference] {
        let rows = try await rig.repo.provenanceSnapshots(owner: .stepRun(id))
        let latest = try #require(rows.last)
        return try WorkflowProvenanceCodec.decodeAndVerify(
            json: latest.snapshotJSON, expectedSHA256: latest.snapshotSHA256).references
    }

    private func stepRun(_ agg: ReopenedWorkflowRun, _ kind: WorkflowStepKind) throws -> UUID {
        try #require(agg.stepRuns.first { $0.stepKind == kind }).id
    }

    // MARK: - 1: Evidence/analytical executors emit their expected roles

    @Test("selectEvidence, reviewEvidence, timeline, graph and calculation emit their expected reference roles")
    func evidenceExecutorProvenanceRoles() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let e1 = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let e2 = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.evidencePackage(suffix: "roles")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)

        var time = t0.addingTimeInterval(30)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: e1.uuidString, reason: "s1"), at: time)
        time.addTimeInterval(10)
        let afterSelect = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: e2.uuidString, reason: "s2"), at: time)
        let selectStep = try #require(afterSelect.run.currentStepRunID)
        let selectRefs = try await latestRefs(rig, step: selectStep)
        #expect(selectRefs.count == 2)
        #expect(selectRefs.allSatisfy { $0.role == .selected })

        // Reach review with the selected item IDs.
        let items = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: try #require(afterSelect.stepRuns.first { $0.id == selectStep }).stateJSON).state.items
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.review(
            itemID: items[0].id, status: .reviewed, note: "ok"), at: time)
        time.addTimeInterval(10)
        let afterReview = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.review(
            itemID: items[1].id, status: .needsFollowUp, note: "later"), at: time)
        let reviewStep = try #require(afterReview.run.currentStepRunID)
        let reviewRefs = try await latestRefs(rig, step: reviewStep)
        #expect(reviewRefs.allSatisfy { $0.role == .reviewed })
        #expect(Set(reviewRefs.map(\.disposition)) == [.active, .needsFollowUp])

        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.complete, at: time)

        // Timeline → .contextual
        time.addTimeInterval(10)
        let afterTimeline = try await PJE007Fixtures.exec(rig, runID: runID, TimelineStepCommand.addEntry(
            objectKind: .entity, canonicalObjectID: e1.uuidString, label: "First",
            dateISO8601: "2025-03-11T00:00:00Z", datePrecision: .day,
            uncertaintyNote: nil, conflictingDates: []), at: time)
        let timelineRefs = try await latestRefs(rig, step: try #require(afterTimeline.run.currentStepRunID))
        #expect(timelineRefs.map(\.role) == [.contextual])
        #expect(timelineRefs.map(\.canonicalObjectID) == [e1])

        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, TimelineStepCommand.complete, at: time)

        // Graph → canonical node only (proposal node excluded from provenance)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, GraphStepCommand.addCanonicalNode(
            kind: .entity, canonicalObjectID: e1.uuidString), at: time)
        time.addTimeInterval(10)
        let afterGraph = try await PJE007Fixtures.exec(rig, runID: runID, GraphStepCommand.addProposalNode(
            label: "suspected"), at: time)
        let graphRefs = try await latestRefs(rig, step: try #require(afterGraph.run.currentStepRunID))
        #expect(graphRefs.map(\.canonicalObjectID) == [e1])
        #expect(graphRefs.allSatisfy { $0.role == .contextual })

        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, GraphStepCommand.complete, at: time)

        // Calculation → .calculationInput on the referenced input
        time.addTimeInterval(10)
        let afterCalc = try await PJE007Fixtures.exec(rig, runID: runID, CalculationStepCommand.define(
            operation: .sum,
            inputs: [
                WorkflowCalculationInput(literal: .number(10), referenceKind: .entity, referenceID: e1.uuidString),
                WorkflowCalculationInput(literal: .number(20))
            ], units: "EUR"), at: time)
        let calcRefs = try await latestRefs(rig, step: try #require(afterCalc.run.currentStepRunID))
        #expect(calcRefs.map(\.role) == [.calculationInput])
        #expect(calcRefs.map(\.canonicalObjectID) == [e1])
    }

    // MARK: - 2: Method executor records method inputs

    @Test("method records method-input references from its result without implementing a Stage 4 method")
    func methodRecordsInputReferences() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let gap = try await PJE007Fixtures.seedGap(rig.db)
        let (pkg, wfID) = try methodPackage(suffix: "method")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)
        var time = t0.addingTimeInterval(30)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, MethodStepCommand.setRequestedMethod(
            methodDefinitionID: "method.external"), actor: PJE007Fixtures.human("a"), at: time)
        time.addTimeInterval(10)
        let result = WorkflowMethodResultReference(
            providerID: "com.ext", providerVersion: "1.0",
            methodDefinitionID: "method.external",
            methodRunReferenceID: "run-1", resultReferenceID: "res-1",
            summary: "s",
            provenanceReferences: [WorkflowMethodProvenanceReference(
                objectKind: "gap", canonicalObjectID: gap.uuidString)],
            completedBy: "a", completedAt: time, limitations: [])
        let after = try await PJE007Fixtures.exec(rig, runID: runID, MethodStepCommand.attachResult(result),
                                                  actor: PJE007Fixtures.human("a"), at: time)
        let methodStep = try #require(after.run.currentStepRunID)
        let refs = try await latestRefs(rig, step: methodStep)
        #expect(refs.map(\.role) == [.methodInput])
        #expect(refs.map(\.canonicalObjectID) == [gap])
    }

    // MARK: - 3: Engine fails closed without a wired validator

    @Test("Nonempty executor references without a validator fail closed (no state persisted)")
    func engineFailsClosedWithoutValidator() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        // An engine WITHOUT a provenance validator.
        let builder = WorkflowStepExecutorRegistryBuilder()
        let select = SelectEvidenceStepExecutor(gate: rig.gate)
        try builder.register(select)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .selectEvidence,
            executorID: select.executorID, executorVersion: select.executorVersion))
        let closure = ClosureStepExecutor()
        try builder.register(closure)
        try builder.bind(WorkflowStepExecutorBinding(
            workflowSchemaVersion: 1, stepKind: .closure,
            executorID: closure.executorID, executorVersion: closure.executorVersion))
        let engineNoValidator = WorkflowStepExecutionEngine(
            registry: builder.build(),
            lifecycleEngine: WorkflowLifecycleEngine(repository: rig.repo),
            repository: rig.repo)  // no provenanceValidator

        let (pkg, wfID) = try selectClosurePackage(suffix: "noval")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await engineNoValidator.startRun(runID: runID, actor: .system, now: t0)
        let before = try await rig.repo.fetchRun(runID)
        // Baseline snapshot count (startRun writes one empty-reference entry snapshot).
        let snapsBeforeRow = try await rig.db.query(
            "SELECT COUNT(*) FROM workflow_provenance_snapshots WHERE workflow_run_id = ?;", [.uuid(runID)])
        let snapsBefore = Int(snapsBeforeRow.first?.int(0) ?? -1)
        let cmd = try WorkflowStepPayloadCodec.encode(SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entity.uuidString, reason: "x"))
        await #expect(throws: (any Error).self) {
            _ = try await engineNoValidator.executeCommand(
                runID: runID, commandJSON: cmd, actor: .system, now: t0.addingTimeInterval(30))
        }
        // The failed command persisted nothing: revision and snapshot count unchanged.
        let after = try await rig.repo.fetchRun(runID)
        #expect(after.run.revision == before.run.revision)
        let snapsAfterRow = try await rig.db.query(
            "SELECT COUNT(*) FROM workflow_provenance_snapshots WHERE workflow_run_id = ?;", [.uuid(runID)])
        #expect(Int(snapsAfterRow.first?.int(0) ?? -1) == snapsBefore)
    }

    // MARK: - 4: Invalid executor output writes nothing

    @Test("A malformed command writes neither state nor provenance")
    func invalidCommandCausesNoWrite() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE007Fixtures.evidencePackage(suffix: "malformed")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)
        let before = try await rig.repo.fetchRun(runID)
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.executeCommand(
                runID: runID, commandJSON: "{\"type\":\"nonsense\"}",
                actor: .system, now: t0.addingTimeInterval(30))
        }
        let after = try await rig.repo.fetchRun(runID)
        #expect(after.run.revision == before.run.revision)
    }

    // MARK: - 5: Decision basis accepts only the decisionBasis role

    @Test("A decision basis reference with a non-decisionBasis role is rejected")
    func decisionBasisRoleEnforced() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.decisionPackage(suffix: "role")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)
        var time = t0.addingTimeInterval(30)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, IntakeStepCommand.setTitle("C"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, IntakeStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.setQuestion("Q"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.setOptions(
            options: ["proceed", "halt"], mode: .humanRequired), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.requestHumanDecision, at: time)
        time.addTimeInterval(10)
        // Wrong role — must be .decisionBasis.
        let badBasis = [WorkflowProvenanceReference(kind: .entity, canonicalObjectID: entity, role: .supporting)]
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.submitHumanDecision(
                runID: runID, decisionKey: "gate", selectedOption: "proceed",
                rationale: "r", basis: badBasis, actor: PJE007Fixtures.human("owner"), at: time)
        }
    }

    // MARK: - 6: Work-product provenance from manifest and citations

    @Test("Work-product artifact provenance is derived from citations and the manifest, not prose")
    func workProductProvenanceFromManifest() async throws {
        let url = PJE006CFixtures.newDatabaseURL()
        var rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "delay on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let (pkg, wfID) = try PJE006CFixtures.makeBuildOnlyPackage(suffix: "prov")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0.addingTimeInterval(10))
        let request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "PJE-006C WS", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        let buildJSON = try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.build(request))
        let built = try await rig.engine.executeCommand(
            runID: runID, commandJSON: buildJSON,
            actor: PJE007Fixtures.human("owner"), now: t0.addingTimeInterval(30))

        let artifact = try #require(built.artifacts.first)
        let buildStep = try #require(built.run.currentStepRunID)
        // Artifact provenance: citation-derived references only.
        let artifactRows = try await rig.repo.provenanceSnapshots(owner: .artifact(artifact.id))
        let artifactSnap = try #require(artifactRows.last)
        let artifactRefs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: artifactSnap.snapshotJSON, expectedSHA256: artifactSnap.snapshotSHA256).references
        #expect(!artifactRefs.isEmpty)
        let artifactKinds: Set<WorkflowProvenanceReferenceKind> = Set(artifactRefs.map { $0.kind })
        #expect(artifactKinds.isSubset(of: [.claim, .sourceVersion]))
        let artifactRoles: Set<WorkflowProvenanceRole> = Set(artifactRefs.map { $0.role })
        #expect(artifactRoles.isSubset(of: [.outputCitation, .supporting, .contradicting]))
        // Build step provenance references the exact work-product run.
        let stepRows = try await rig.repo.provenanceSnapshots(owner: .stepRun(buildStep))
        let stepSnap = try #require(stepRows.last)
        let stepRefs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: stepSnap.snapshotJSON, expectedSHA256: stepSnap.snapshotSHA256).references
        let stepKinds: [WorkflowProvenanceReferenceKind] = stepRefs.map { $0.kind }
        let stepRoles: [WorkflowProvenanceRole] = stepRefs.map { $0.role }
        #expect(stepKinds == [.workProductRun])
        #expect(stepRoles == [.generatedFrom])

        // Survives relaunch.
        rig = try await PJE006CFixtures.makeRig(at: url, migrate: false)
        _ = try await rig.repo.fetchRun(runID)
    }

    // MARK: - 7: SensitiveScope still fails closed inside a flow

    @Test("Selecting a confidential entity fails closed inside the flow")
    func sensitiveScopeStillFailsClosed() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        _ = try await rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: entity),
            sensitivity: .confidential, authority: .systemRule(tag: "pje007"), reason: "t", at: t0)
        let (pkg, wfID) = try PJE007Fixtures.evidencePackage(suffix: "scopeclosed")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)
        let before = try await rig.repo.fetchRun(runID)
        let cmd = try WorkflowStepPayloadCodec.encode(SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entity.uuidString, reason: "x"))
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.executeCommand(
                runID: runID, commandJSON: cmd, actor: .system, now: t0.addingTimeInterval(30))
        }
        let after = try await rig.repo.fetchRun(runID)
        #expect(after.run.revision == before.run.revision)
    }

    // MARK: - 8: A complete run survives close and reopen

    @Test("A completed evidence run survives close and reopen with all provenance intact")
    func completeRunSurvivesCloseAndReopen() async throws {
        let url = PJE007Fixtures.newURL()
        let rig = try await PJE007Fixtures.makeRig(at: url)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let e1 = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let runID = try await driveEvidenceToCompletion(rig, ws: ws, entity: e1, suffix: "complete")

        let rig2 = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        let final = try await rig2.repo.fetchRun(runID)
        #expect(final.run.status == .completed)
        for stepRun in final.stepRuns where !stepRun.stateJSON.isEmpty && stepRun.stateJSON != "{}" {
            let semantics = try await rig2.repo.provenanceSemantics(owner: .stepRun(stepRun.id))
            #expect(semantics == .snapshotV1)
        }
    }

    // MARK: - 9: End-to-end attachment → evidence → decision

    @Test("E2E: parent email → canonical attachment → select/review → timeline → human decision, reopened exactly")
    func endToEndAttachmentThroughDecision() async throws {
        let url = PJE007Fixtures.newURL()
        var rig = try await PJE007Fixtures.makeRig(at: url)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)

        // Parent email + attachment source version, linked by source_relations.
        let parentFile = UUID()
        try await rig.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(parentFile), .text("file://email"), .text("eml")])
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        try await PJE007Fixtures.seedSourceRelation(rig.db, parent: parentFile, child: src.fileID, relation: "attachment")

        let (pkg, wfID) = try e2ePackage(suffix: "e2e")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: "E2E", parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)

        // Attach the canonical source while on the intake step.
        let coordinator = WorkflowAttachmentCoordinator(
            workflowRuns: rig.repo, database: rig.db,
            sourceRelations: rig.sourceRelations, gate: rig.gate, scopes: rig.scopes)
        let afterAttach = try await coordinator.attachCanonicalSource(
            runID: runID,
            request: WorkflowCanonicalAttachmentRequest(
                artifactDefinitionID: PJE007Fixtures.attachmentArtifactDefID,
                sourceVersionID: src.svID, parentLogicalSourceID: parentFile,
                expectedRelation: "attachment", displayName: "invoice.pdf"),
            actor: PJE007Fixtures.human("analyst"), at: t0.addingTimeInterval(20))
        let attachmentArtifactID = try #require(afterAttach.artifacts.first).id

        // Advance intake → select the attached source version + the entity.
        var time = t0.addingTimeInterval(30)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, IntakeStepCommand.setTitle("Matter"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, IntakeStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .sourceVersion, canonicalObjectID: src.svID.uuidString, reason: "attached invoice"), at: time)
        time.addTimeInterval(10)
        let afterSelect = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entity.uuidString, reason: "counterparty"), at: time)
        let items = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: try #require(afterSelect.stepRuns.first { $0.id == afterSelect.run.currentStepRunID }).stateJSON).state.items

        // RELAUNCH #1
        rig = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        _ = try await rig.repo.fetchRun(runID)

        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.complete, at: time)
        for item in items {
            time.addTimeInterval(10)
            _ = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.review(
                itemID: item.id, status: .reviewed, note: "seen"), at: time)
        }
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.complete, at: time)

        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, TimelineStepCommand.addEntry(
            objectKind: .entity, canonicalObjectID: entity.uuidString, label: "appearance",
            dateISO8601: "2025-02-01T00:00:00Z", datePrecision: .day,
            uncertaintyNote: nil, conflictingDates: []), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, TimelineStepCommand.complete, at: time)

        // Decision with an explicit basis.
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.setQuestion("Proceed?"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.setOptions(
            options: ["proceed", "halt"], mode: .humanRequired), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.requestHumanDecision, at: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.submitHumanDecision(
            runID: runID, decisionKey: "gate", selectedOption: "proceed", rationale: "sufficient",
            basis: [WorkflowProvenanceReference(kind: .entity, canonicalObjectID: entity, role: .decisionBasis)],
            actor: PJE007Fixtures.human("owner"), at: time)
        time.addTimeInterval(10)
        let completed = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.applyRecordedDecision, at: time)
        #expect(completed.run.status == .completed)

        // RELAUNCH #2 — verify everything survived exactly.
        let finalRig = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        let final = try await finalRig.repo.fetchRun(runID)
        #expect(final.run.status == .completed)

        // Attachment binding intact.
        let binding = try #require(try await finalRig.repo.attachmentBinding(artifactID: attachmentArtifactID))
        #expect(binding.sourceVersionID == src.svID)
        #expect(binding.parentLogicalSourceID == parentFile)
        #expect(binding.sourceRelation == "attachment")
        let attSemantics = try await finalRig.repo.provenanceSemantics(owner: .artifact(attachmentArtifactID))
        #expect(attSemantics == .snapshotV1)

        // Selection provenance references the attached source version and the entity.
        let selectStep = try stepRun(final, .selectEvidence)
        let selectRefs = try await latestRefs(finalRig, step: selectStep)
        #expect(Set(selectRefs.map(\.canonicalObjectID)) == [src.svID, entity])

        // Decision basis persisted with the decisionBasis role.
        let decision = try #require(final.decisions.first { $0.kind == .humanDecision })
        let decisionRows = try await finalRig.repo.provenanceSnapshots(owner: .decision(decision.id))
        let decisionSnap = try #require(decisionRows.last)
        let basisRefs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: decisionSnap.snapshotJSON, expectedSHA256: decisionSnap.snapshotSHA256).references
        #expect(basisRefs.map(\.canonicalObjectID) == [entity])
        #expect(basisRefs.allSatisfy { $0.role == .decisionBasis })
    }

    // MARK: - Local package builders

    private func driveEvidenceToCompletion(
        _ rig: PJE007Rig, ws: UUID, entity: UUID, suffix: String
    ) async throws -> UUID {
        let (pkg, wfID) = try PJE007Fixtures.evidencePackage(suffix: suffix)
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)
        var time = t0.addingTimeInterval(30)
        let afterSelect = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entity.uuidString, reason: "s"), at: time)
        let items = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<SelectEvidenceStepState>.self,
            from: try #require(afterSelect.stepRuns.first { $0.id == afterSelect.run.currentStepRunID }).stateJSON).state.items
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, SelectEvidenceStepCommand.complete, at: time)
        for item in items {
            time.addTimeInterval(10)
            _ = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.review(
                itemID: item.id, status: .reviewed, note: nil), at: time)
        }
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, ReviewEvidenceStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, TimelineStepCommand.addEntry(
            objectKind: .entity, canonicalObjectID: entity.uuidString, label: "x",
            dateISO8601: "2025-01-01T00:00:00Z", datePrecision: .day,
            uncertaintyNote: nil, conflictingDates: []), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, TimelineStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, GraphStepCommand.addCanonicalNode(
            kind: .entity, canonicalObjectID: entity.uuidString), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, GraphStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, CalculationStepCommand.define(
            operation: .sum,
            inputs: [WorkflowCalculationInput(literal: .number(1)),
                     WorkflowCalculationInput(literal: .number(2))], units: nil), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, CalculationStepCommand.complete, at: time)
        return runID
    }

    private func methodPackage(suffix: String) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let methodID = StepDefinitionID(rawValue: "step.method.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let method = PersonaWorkflowStepDefinition(
            id: methodID, kind: .method, label: "Method", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)],
            requirements: [PersonaWorkflowRequirement(
                id: "req.mr", kind: .methodResultPresent, label: "Result", isBlocking: true)])
        let done = PersonaWorkflowStepDefinition(id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try makePackage(suffix: suffix, steps: [method, done])
    }

    private func selectClosurePackage(suffix: String) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let selectID = StepDefinitionID(rawValue: "step.select.\(suffix)")
        let doneID = StepDefinitionID(rawValue: "step.done.\(suffix)")
        let select = PersonaWorkflowStepDefinition(
            id: selectID, kind: .selectEvidence, label: "Select", isEntry: true,
            transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: doneID)])
        let done = PersonaWorkflowStepDefinition(id: doneID, kind: .closure, label: "Done", isTerminal: true)
        return try makePackage(suffix: suffix, steps: [select, done])
    }

    private func e2ePackage(suffix: String) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            intake: StepDefinitionID(rawValue: "step.intake.\(suffix)"),
            select: StepDefinitionID(rawValue: "step.select.\(suffix)"),
            review: StepDefinitionID(rawValue: "step.review.\(suffix)"),
            timeline: StepDefinitionID(rawValue: "step.timeline.\(suffix)"),
            decision: StepDefinitionID(rawValue: "step.decision.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.intake, kind: .intake, label: "Intake", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.select)],
                artifacts: [PersonaWorkflowArtifactDefinition(
                    id: PJE007Fixtures.attachmentArtifactDefID, label: "Attachment",
                    workProductTemplateID: nil, isRequired: false)]),
            PersonaWorkflowStepDefinition(
                id: ids.select, kind: .selectEvidence, label: "Select",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.review)]),
            PersonaWorkflowStepDefinition(
                id: ids.review, kind: .reviewEvidence, label: "Review",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.timeline)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.reviewed", kind: .evidenceReviewed, label: "reviewed", isBlocking: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.timeline, kind: .timeline, label: "Timeline",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.decision)]),
            PersonaWorkflowStepDefinition(
                id: ids.decision, kind: .decision, label: "Decide",
                transitions: [
                    WorkflowTransitionDefinition(label: "proceed", targetStepID: ids.done),
                    WorkflowTransitionDefinition(label: "halt", targetStepID: ids.done)
                ],
                decisionBranches: ["proceed", "halt"]),
            PersonaWorkflowStepDefinition(
                id: ids.done, kind: .closure, label: "Done", isTerminal: true)
        ]
        return try makePackage(suffix: suffix, steps: steps)
    }

    private func makePackage(
        suffix: String, steps: [PersonaWorkflowStepDefinition]
    ) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let appID = ApplicationDefinitionID(rawValue: "com.pje007.int.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pje007.intwf.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-007 Int WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pje007.intterm.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        return (ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "Int App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [], workProducts: [],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: []), wfID)
    }
}
