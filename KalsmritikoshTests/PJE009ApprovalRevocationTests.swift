//
//  PJE009ApprovalRevocationTests.swift
//  KalsmritikoshTests
//
//  PJE-009 — work-product approval boundaries and post-build access revocation.
//  A composer/build never approves its own output; approval requires an
//  authorized human; completion cannot bypass approval; and current access rules
//  are reapplied when a built product's provenance is inspected after the fact.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-009 — approval boundaries + post-build revocation", .serialized)
@MainActor
struct PJE009ApprovalRevocationTests {

    private let t0 = PJE009Fixtures.t0

    // MARK: - Approval package (build → review → humanApproval → terminal)

    private func approvalPackage(suffix: String) throws -> (ResolvedPersonaApplicationPackage, WorkflowDefinitionID) {
        let ids = (
            build: StepDefinitionID(rawValue: "step.build.\(suffix)"),
            review: StepDefinitionID(rawValue: "step.review.\(suffix)"),
            approval: StepDefinitionID(rawValue: "step.approval.\(suffix)"),
            done: StepDefinitionID(rawValue: "step.done.\(suffix)"),
            rejected: StepDefinitionID(rawValue: "step.rejected.\(suffix)")
        )
        let steps = [
            PersonaWorkflowStepDefinition(
                id: ids.build, kind: .workProductBuild, label: "Build", isEntry: true,
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.review)],
                requirements: [PersonaWorkflowRequirement(
                    id: "req.artifact", kind: .artifactGenerated, label: "Report generated", isBlocking: true)],
                artifacts: [PersonaWorkflowArtifactDefinition(
                    id: PJE006CFixtures.artifactDefID, label: "Summary report",
                    workProductTemplateID: PJE006CFixtures.wpDefID, isRequired: true)]),
            PersonaWorkflowStepDefinition(
                id: ids.review, kind: .effectivenessReview, label: "Review",
                transitions: [WorkflowTransitionDefinition(label: "next", targetStepID: ids.approval)]),
            PersonaWorkflowStepDefinition(
                id: ids.approval, kind: .humanApproval, label: "Approve",
                transitions: [
                    WorkflowTransitionDefinition(label: "approved", targetStepID: ids.done),
                    WorkflowTransitionDefinition(label: "rejected", targetStepID: ids.rejected)
                ],
                approverRoles: ["reviewer"]),
            PersonaWorkflowStepDefinition(id: ids.done, kind: .closure, label: "Done", isTerminal: true),
            PersonaWorkflowStepDefinition(id: ids.rejected, kind: .closure, label: "Rejected", isTerminal: true)
        ]
        let appID = ApplicationDefinitionID(rawValue: "com.pje009.app.\(suffix)")
        let wfID = WorkflowDefinitionID(rawValue: "com.pje009.wf.\(suffix)")
        let wfDef = PersonaWorkflowDefinition(
            id: wfID, version: 1, schemaVersion: 1, label: "PJE-009 Approval WF", steps: steps)
        let validated = try WorkflowDefinitionCompiler().compile(wfDef)
        let termID = TerminologyDefinitionID(rawValue: "com.pje009.term.\(suffix)")
        let term = PersonaTerminologyDefinition(id: termID, version: 1, applicationID: appID, labels: [:])
        let wp = PersonaWorkProductDefinition(
            id: WorkProductDefinitionID(rawValue: PJE006CFixtures.wpDefID),
            version: 1, label: "Summary", template: .generalSummary)
        let pkg = ResolvedPersonaApplicationPackage(
            applicationKey: RegistryKey(id: appID, version: 1),
            application: PersonaApplicationDefinition(id: appID, version: 1, label: "PJE-009 App"),
            toolKeys: [], tools: [],
            workflowKeys: [RegistryKey(id: wfID, version: 1)], workflows: [validated],
            terminologyKey: RegistryKey(id: termID, version: 1), terminology: term,
            objectSchemaKeys: [], objectSchemas: [],
            workProductKeys: [RegistryKey(id: wp.id, version: wp.version)], workProducts: [wp],
            validatorKeys: [], validators: [],
            automationKeys: [], automations: [])
        return (pkg, wfID)
    }

    private struct AtApproval {
        let rig: PJE006CRig
        let runID: UUID
        let artifactID: UUID
        let ws: Workspace
    }

    /// Build a work product and drive to the waiting-for-approval state.
    private func driveToApproval(suffix: String) async throws -> AtApproval {
        let rig = try await PJE006CFixtures.makeRig(at: PJE006CFixtures.newDatabaseURL())
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "delayed on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let (pkg, wfID) = try approvalPackage(suffix: suffix)
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0.addingTimeInterval(10))
        var time = t0.addingTimeInterval(20)
        let request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "WS", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        let built = try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.build(request)),
            actor: PJE009Fixtures.human("builder"), now: time)
        let artifactID = built.artifacts.first!.id
        time.addTimeInterval(10)
        _ = try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.complete),
            actor: PJE009Fixtures.human("builder"), now: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(
                EffectivenessReviewStepCommand.recordAssessment(
                    assessment: .effective, rationale: "addresses the question",
                    followUpRequired: false, followUpNote: nil)),
            actor: PJE009Fixtures.human("qa"), now: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(EffectivenessReviewStepCommand.complete),
            actor: PJE009Fixtures.human("qa"), now: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.setPrompt("Release?")),
            actor: .system, now: time)
        time.addTimeInterval(10)
        _ = try await rig.engine.executeCommand(
            runID: runID, commandJSON: try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.requestApproval),
            actor: .system, now: time)
        return AtApproval(rig: rig, runID: runID, artifactID: artifactID, ws: ws)
    }

    // MARK: - 1: Build creates no approval decision

    @Test("Building a work product records no human approval decision")
    func buildCreatesNoApprovalDecision() async throws {
        let a = try await driveToApproval(suffix: "noapproval")
        let agg = try await a.rig.repo.fetchRun(a.runID)
        #expect(!agg.decisions.contains { $0.kind == .humanApproval })
        #expect(agg.run.status == .waitingForHuman)   // gated, not completed
    }

    // MARK: - 2: Completion cannot bypass approval

    @Test("The run cannot complete until approval is submitted")
    func completionCannotBypassApproval() async throws {
        let a = try await driveToApproval(suffix: "gate")
        let agg = try await a.rig.repo.fetchRun(a.runID)
        #expect(agg.run.status != .completed)
    }

    // MARK: - 3: A non-human (system) actor cannot approve

    @Test("A system actor cannot approve a work product")
    func systemCannotApprove() async throws {
        let a = try await driveToApproval(suffix: "sysdeny")
        await #expect(throws: (any Error).self) {
            _ = try await a.rig.engine.submitHumanApproval(
                runID: a.runID, approved: true, rationale: "ok", actor: .system,
                at: t0.addingTimeInterval(200))
        }
    }

    // MARK: - 4: An unauthorized role cannot approve

    @Test("An unauthorized human role cannot approve a work product")
    func unauthorizedRoleCannotApprove() async throws {
        let a = try await driveToApproval(suffix: "wrongrole")
        await #expect(throws: (any Error).self) {
            _ = try await a.rig.engine.submitHumanApproval(
                runID: a.runID, approved: true, rationale: "ok",
                actor: PJE009Fixtures.human("x", role: "not-reviewer"), at: t0.addingTimeInterval(200))
        }
    }

    // MARK: - 5: Authorized approval continues to completion

    @Test("An authorized reviewer approval completes the workflow")
    func authorizedApprovalCompletes() async throws {
        let a = try await driveToApproval(suffix: "approve")
        var time = t0.addingTimeInterval(200)
        _ = try await a.rig.engine.submitHumanApproval(
            runID: a.runID, approved: true, rationale: "release",
            actor: PJE009Fixtures.human("rev-1", role: "reviewer"), at: time)
        time.addTimeInterval(10)
        let done = try await a.rig.engine.executeCommand(
            runID: a.runID, commandJSON: try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval),
            actor: PJE009Fixtures.human("rev-1", role: "reviewer"), now: time)
        #expect(done.run.status == .completed)
    }

    // MARK: - 6: Rejection preserves the artifact and its reason

    @Test("Rejection is recorded and the built artifact is preserved")
    func rejectionPreservesArtifact() async throws {
        let a = try await driveToApproval(suffix: "reject")
        var time = t0.addingTimeInterval(200)
        _ = try await a.rig.engine.submitHumanApproval(
            runID: a.runID, approved: false, rationale: "two findings lack citations",
            actor: PJE009Fixtures.human("rev-1", role: "reviewer"), at: time)
        time.addTimeInterval(10)
        let ended = try await a.rig.engine.executeCommand(
            runID: a.runID, commandJSON: try WorkflowStepPayloadCodec.encode(HumanApprovalStepCommand.applyRecordedApproval),
            actor: PJE009Fixtures.human("rev-1", role: "reviewer"), now: time)
        #expect(ended.decisions.contains { $0.kind == .humanApproval && $0.selectedOption == "rejected" })
        // The work-product artifact survives a rejection (append-only history).
        #expect(ended.artifacts.contains { $0.id == a.artifactID })
    }

    // MARK: - 7: Two builds produce independent runs and artifacts

    @Test("Two independent builds produce distinct work-product runs and artifacts")
    func twoBuildsAreIndependent() async throws {
        let b1 = try await PJE009Fixtures.buildWorkProduct(suffix: "indep1", factValue: "alpha on 2025-01-01")
        let b2 = try await PJE009Fixtures.buildWorkProduct(suffix: "indep2", factValue: "beta on 2025-02-02")
        #expect(b1.wpRunID != b2.wpRunID)
        #expect(b1.artifactID != b2.artifactID)
    }

    // MARK: - 8: Post-build revocation — inspector reapplies current access

    @Test("After revoking access to a cited source, the inspector reports it accessDenied")
    func postBuildRevocationInspectorDenies() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "revoke")
        let inspector = WorkflowProvenanceInspector(
            repository: b.rig.repo, database: b.rig.db, scopes: b.rig.scopes)
        let exportAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: b.ws.id, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        let before = try await inspector.inspect(owner: .artifact(b.artifactID), access: exportAccess)
        let citedSV = try #require(before.references.first { $0.kind == .sourceVersion })
        #expect(citedSV.availability == .available)

        // Access is removed after the build.
        _ = try await b.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: citedSV.canonicalObjectID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje009"), reason: "sealed", at: t0)
        let publicAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: b.ws.id, maximumSensitivity: .publicLevel,
            permitsPrivilegedMaterial: false, purpose: .export))
        let after = try await inspector.inspect(owner: .artifact(b.artifactID), access: publicAccess)
        let deniedRef = try #require(after.references.first { $0.canonicalObjectID == citedSV.canonicalObjectID })
        #expect(deniedRef.availability == .accessDenied)
        #expect(deniedRef.label == nil && deniedRef.note == nil)
    }

    // MARK: - 9: Revocation does not rewrite stored historical provenance

    @Test("Revoking access does not rewrite the stored artifact provenance")
    func revocationDoesNotRewriteHistory() async throws {
        let b = try await PJE009Fixtures.buildWorkProduct(suffix: "revokehist")
        let before = try #require(try await b.rig.repo.provenanceSnapshots(owner: .artifact(b.artifactID)).last)
        let svs = try await PJE009Fixtures.sourceVersionIDs(b.rig)
        for sv in svs {
            _ = try await b.rig.scopes.assign(
                target: SensitiveScopeTarget(kind: .sourceVersion, id: sv),
                sensitivity: .confidential, authority: .systemRule(tag: "pje009"), reason: "s", at: t0)
        }
        let inspector = WorkflowProvenanceInspector(
            repository: b.rig.repo, database: b.rig.db, scopes: b.rig.scopes)
        _ = try await inspector.inspect(owner: .artifact(b.artifactID),
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: b.ws.id, maximumSensitivity: .publicLevel,
                permitsPrivilegedMaterial: false, purpose: .export)))
        let after = try #require(try await b.rig.repo.provenanceSnapshots(owner: .artifact(b.artifactID)).last)
        #expect(after.snapshotJSON == before.snapshotJSON)
        #expect(after.snapshotSHA256 == before.snapshotSHA256)
    }

    // MARK: - 10: A wrong-purpose access is refused at build time

    @Test("A non-export purpose access fails the build closed")
    func nonExportPurposeFailsBuild() async throws {
        let rig = try await PJE006CFixtures.makeRig(at: PJE006CFixtures.newDatabaseURL())
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "delayed on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let (pkg, wfID) = try PJE006CFixtures.makeBuildOnlyPackage(suffix: "wrongpurpose")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0.addingTimeInterval(10))
        let badRequest = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "WS", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: ws.id, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .retrieval)))  // not .export
        await #expect(throws: (any Error).self) {
            _ = try await rig.engine.executeCommand(
                runID: created.run.id,
                commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.build(badRequest)),
                actor: PJE009Fixtures.human("builder"), now: t0.addingTimeInterval(30))
        }
    }
}
