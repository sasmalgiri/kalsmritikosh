//
//  WorkflowWorkProductBuildCoordinatorTests.swift
//  KalsmritikoshTests
//
//  PJE-006C — the atomic work-product build path: accepted assembly reuse,
//  fail-closed gates, single-SAVEPOINT persistence, full rollback on any
//  injected failure. 10 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006C — WorkflowWorkProductBuildCoordinator", .serialized)
@MainActor
struct WorkflowWorkProductBuildCoordinatorTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_700_000)

    private func humanActor() -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: "builder-1", role: nil)
    }

    /// A rig with a composable workspace and a build-entry workflow started to the build step.
    private func startedBuildRun(
        suffix: String
    ) async throws -> (PJE006CRig, Workspace, UUID) {
        let rig = try await PJE006CFixtures.makeRig(at: PJE006CFixtures.newDatabaseURL())
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "invoice paid on 2025-03-11")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let (pkg, wfID) = try PJE006CFixtures.makeBuildOnlyPackage(suffix: suffix)
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        return (rig, ws, created.run.id)
    }

    private func buildRequest(workspaceID: UUID) -> WorkflowWorkProductBuildRequest {
        WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "PJE-006C WS",
            corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: workspaceID))
    }

    private func workProductRunCount(_ rig: PJE006CRig) async throws -> Int {
        Int(try await rig.db.query("SELECT COUNT(*) FROM work_product_runs;", []).first?.int(0) ?? -1)
    }

    private func artifactCount(_ rig: PJE006CRig) async throws -> Int {
        Int(try await rig.db.query("SELECT COUNT(*) FROM workflow_artifacts;", []).first?.int(0) ?? -1)
    }

    @Test("A successful build saves ONE work-product run + ONE artifact atomically, step stays active")
    func successfulBuildIsAtomic() async throws {
        let (rig, ws, runID) = try await startedBuildRun(suffix: "happy")
        let after = try await rig.engine.executeCommand(
            runID: runID,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                WorkProductBuildStepCommand.build(buildRequest(workspaceID: ws.id))),
            actor: humanActor(), now: t0.addingTimeInterval(60))

        #expect(after.run.status == .active)
        #expect(try await workProductRunCount(rig) == 1)
        #expect(after.artifacts.count == 1)
        let artifact = try #require(after.artifacts.first)
        #expect(artifact.kind == .workProductRun)
        #expect(artifact.artifactDefinitionID == PJE006CFixtures.artifactDefID)

        // Step state was updated inside the same SAVEPOINT, under V1 hash semantics.
        let stepRunID = try #require(after.run.currentStepRunID)
        let stepRun = try #require(after.stepRuns.first { $0.id == stepRunID })
        #expect(stepRun.status == .active, "Step remains active after a successful build")
        let state = try WorkflowStepPayloadCodec.decode(
            WorkflowStepStateEnvelope<WorkProductBuildStepState>.self,
            from: stepRun.stateJSON).state
        #expect(state.status == .built)
        #expect(state.workProductRunID == artifact.workProductRunID)
        #expect(state.workflowArtifactID == artifact.id)
        #expect(try await rig.repo.stepStateHashSemantics(stepRunID: stepRunID) == .storedUTF8BytesV1)

        // Exactly one artifactRecorded event.
        #expect(after.events.filter { $0.type == .artifactRecorded }.count == 1)

        // The immutable run reopens independently with citations intact.
        let wpRunID = try #require(state.workProductRunID)
        let reopened = try await WorkProductRunRepository(database: rig.db).reopen(wpRunID)
        #expect(reopened.workProduct.template == .generalSummary)
        #expect(reopened.manifest.selectedFindingCount >= 1)
    }

    @Test("A later complete command advances after PJE-005 confirms the artifact requirement")
    func completeAdvancesAfterBuild() async throws {
        let (rig, ws, runID) = try await startedBuildRun(suffix: "adv")
        _ = try await rig.engine.executeCommand(
            runID: runID,
            commandJSON: try WorkflowStepPayloadCodec.encode(
                WorkProductBuildStepCommand.build(buildRequest(workspaceID: ws.id))),
            actor: humanActor(), now: t0.addingTimeInterval(60))
        let done = try await rig.engine.executeCommand(
            runID: runID,
            commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.complete),
            actor: humanActor(), now: t0.addingTimeInterval(120))
        #expect(done.run.status == .completed) // build → terminal done step
    }

    @Test("The artifactGenerated requirement blocks advancing BEFORE a build")
    func artifactRequirementBlocksBeforeBuild() async throws {
        let (rig, _, runID) = try await startedBuildRun(suffix: "block")
        // Craft a fake 'built' completion attempt without any build: executor refuses first.
        await #expect(throws: WorkflowStepExecutionError.self) {
            _ = try await rig.engine.executeCommand(
                runID: runID,
                commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.complete),
                actor: self.humanActor(), now: self.t0.addingTimeInterval(60))
        }
    }

    @Test("A wrong current step fails closed")
    func wrongCurrentStepFailsClosed() async throws {
        let rig = try await PJE006CFixtures.makeRig(at: PJE006CFixtures.newDatabaseURL())
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "x")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        // Stage-3 package starts on a METHOD step, not the build step.
        let (pkg, wfID) = try PJE006CFixtures.makeStage3Package(suffix: "wrongstep")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        await #expect(throws: WorkflowWorkProductBuildError.self) {
            _ = try await rig.coordinator.build(
                runID: created.run.id, request: self.buildRequest(workspaceID: ws.id),
                actor: self.humanActor(), now: self.t0)
        }
        #expect(try await workProductRunCount(rig) == 0)
    }

    @Test("A missing frozen artifact definition fails closed with no rows")
    func missingArtifactDefinitionFailsClosed() async throws {
        let (rig, ws, runID) = try await startedBuildRun(suffix: "noart")
        var request = buildRequest(workspaceID: ws.id)
        request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: "artifact.ghost",
            workProductDefinitionID: request.workProductDefinitionID,
            subjectLabel: request.subjectLabel,
            corpusSnapshotID: nil, access: request.access)
        await #expect(throws: WorkflowWorkProductBuildError.self) {
            _ = try await rig.coordinator.build(
                runID: runID, request: request, actor: self.humanActor(), now: self.t0)
        }
        #expect(try await workProductRunCount(rig) == 0)
        #expect(try await artifactCount(rig) == 0)
    }

    @Test("A wrong-purpose scope fails closed")
    func wrongPurposeFailsClosed() async throws {
        let (rig, ws, runID) = try await startedBuildRun(suffix: "purpose")
        let request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "S", corpusSnapshotID: nil,
            access: SensitiveAccessContext(scope: SensitiveScope(
                workspaceID: ws.id, maximumSensitivity: .restricted,
                permitsPrivilegedMaterial: false, purpose: .retrieval)))
        await #expect(throws: WorkflowWorkProductBuildError.self) {
            _ = try await rig.coordinator.build(
                runID: runID, request: request, actor: self.humanActor(), now: self.t0)
        }
        #expect(try await workProductRunCount(rig) == 0)
    }

    @Test("A missing composer fails closed with no rows (registry throws, nothing persisted)")
    func missingComposerFailsClosed() async throws {
        // Coordinator wired to an assembly whose registry is EMPTY.
        let url = PJE006CFixtures.newDatabaseURL()
        let rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "y")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let claims = ClaimRepository(database: rig.db)
        let emptyAssembly = WorkProductAssemblyService(
            workspaces: rig.workspaces,
            knowledgeObjects: KnowledgeObjectRepository(database: rig.db),
            evidence: EvidenceStore(database: rig.db),
            sensitiveScopes: rig.scopes,
            selection: ClaimSelectionService(
                claims: claims,
                resolver: ClaimResolver(claims: claims,
                                        reviews: ClaimReviewRepository(database: rig.db)),
                temporalClaims: TemporalClaimRepository(database: rig.db),
                events: EventsRepository(database: rig.db)),
            disclosures: DisclosureSelectionService(
                contradictions: ContradictionsRepository(database: rig.db),
                claimContradictions: ClaimContradictionRepository(database: rig.db),
                gaps: GapNodeRepository(database: rig.db)),
            registry: WorkProductComposerRegistry())
        let coordinator = WorkflowWorkProductBuildCoordinator(
            assembly: emptyAssembly, workflowRuns: rig.repo, workspaces: rig.workspaces)

        let (pkg, wfID) = try PJE006CFixtures.makeBuildOnlyPackage(suffix: "nocomposer")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)

        await #expect(throws: WorkProductAssemblyError.self) {
            _ = try await coordinator.build(
                runID: created.run.id, request: self.buildRequest(workspaceID: ws.id),
                actor: self.humanActor(), now: self.t0)
        }
        #expect(try await workProductRunCount(rig) == 0)
        #expect(try await artifactCount(rig) == 0)
    }

    @Test("A CAS conflict persists nothing")
    func casConflictPersistsNothing() async throws {
        let (rig, ws, runID) = try await startedBuildRun(suffix: "cas")
        let aggregate = try await rig.repo.fetchRun(runID)
        let stepRunID = try #require(aggregate.run.currentStepRunID)
        let assembled = try await rig.assembly.compose(
            workspace: try #require(try await rig.workspaces.find(ws.id)),
            template: .generalSummary, subjectLabel: "S", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        let stateJSON = "{\"v\":1}"
        await #expect(throws: WorkflowRunRepositoryError.self) {
            _ = try await rig.repo.applyWorkProductBuild(
                workflowRunID: runID, stepRunID: stepRunID,
                expectedRevision: aggregate.run.revision + 7,   // stale CAS
                assembled: assembled,
                workProductRunID: UUID(), artifactID: UUID(),
                artifactDefinitionID: PJE006CFixtures.artifactDefID,
                subjectLabel: "S", corpusSnapshotID: nil,
                newStepStateJSON: stateJSON,
                newStepStateSHA256: WorkflowPersistedJSONIntegrity.rawSHA256(of: stateJSON),
                actor: self.humanActor(), at: self.t0)
        }
        #expect(try await workProductRunCount(rig) == 0)
        #expect(try await artifactCount(rig) == 0)
        let after = try await rig.repo.fetchRun(runID)
        #expect(after.run.revision == aggregate.run.revision, "Revision unchanged on CAS conflict")
    }

    @Test("Every injected failure point rolls back ALL output rows, state, revision and events")
    func injectedFailuresRollBackEverything() async throws {
        struct InjectedFailure: Error {}
        let points: [WorkflowRunRepository.WorkProductBuildFaultPoint] = [
            .afterCAS, .afterWorkProductInsert, .afterArtifactInsert,
            .afterStepStateUpdate, .beforeEventInsert
        ]
        for point in points {
            let (rig, ws, runID) = try await startedBuildRun(
                suffix: "fault-\(String(describing: point))")
            let before = try await rig.repo.fetchRun(runID)
            let stepRunID = try #require(before.run.currentStepRunID)
            let beforeStep = try #require(before.stepRuns.first { $0.id == stepRunID })
            let assembled = try await rig.assembly.compose(
                workspace: try #require(try await rig.workspaces.find(ws.id)),
                template: .generalSummary, subjectLabel: "S", corpusSnapshotID: nil,
                access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
            let stateJSON = "{\"v\":2}"

            await #expect(throws: (any Error).self, "fault \(point) must throw") {
                _ = try await rig.repo.applyWorkProductBuild(
                    workflowRunID: runID, stepRunID: stepRunID,
                    expectedRevision: before.run.revision,
                    assembled: assembled,
                    workProductRunID: UUID(), artifactID: UUID(),
                    artifactDefinitionID: PJE006CFixtures.artifactDefID,
                    subjectLabel: "S", corpusSnapshotID: nil,
                    newStepStateJSON: stateJSON,
                    newStepStateSHA256: WorkflowPersistedJSONIntegrity.rawSHA256(of: stateJSON),
                    actor: self.humanActor(), at: self.t0,
                    fault: { p in if p == point { throw InjectedFailure() } })
            }

            let after = try await rig.repo.fetchRun(runID)
            #expect(after.run.revision == before.run.revision, "revision unchanged at \(point)")
            #expect(after.events.count == before.events.count, "no event at \(point)")
            let afterStep = try #require(after.stepRuns.first { $0.id == stepRunID })
            #expect(afterStep.stateJSON == beforeStep.stateJSON, "state unchanged at \(point)")
            #expect(try await workProductRunCount(rig) == 0, "no work-product run at \(point)")
            #expect(try await artifactCount(rig) == 0, "no artifact at \(point)")
            let sections = Int(try await rig.db.query(
                "SELECT COUNT(*) FROM work_product_sections;", []).first?.int(0) ?? -1)
            let manifests = Int(try await rig.db.query(
                "SELECT COUNT(*) FROM work_product_manifests;", []).first?.int(0) ?? -1)
            #expect(sections == 0, "no sections at \(point)")
            #expect(manifests == 0, "no manifest at \(point)")
        }
    }

    @Test("Existing standalone WorkProductRunRepository.save still round-trips via the shared writer")
    func standaloneSaveStillRoundTrips() async throws {
        let (rig, ws, _) = try await startedBuildRun(suffix: "shared")
        let assembled = try await rig.assembly.compose(
            workspace: try #require(try await rig.workspaces.find(ws.id)),
            template: .generalSummary, subjectLabel: "S", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        let repo = WorkProductRunRepository(database: rig.db)
        let saved = try await repo.save(assembled, workspaceID: ws.id, subjectLabel: "S")
        let reopened = try await repo.reopen(saved.id)
        #expect(reopened.workProduct.title == assembled.workProduct.title)
        #expect(reopened.manifest.selectedFindingCount == assembled.manifest.selectedFindingCount)
        #expect(reopened.manifest.sourceHashes == assembled.manifest.sourceHashes)
    }
}
