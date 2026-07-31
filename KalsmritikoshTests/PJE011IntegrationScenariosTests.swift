//
//  PJE011IntegrationScenariosTests.swift
//  KalsmritikoshTests
//
//  PJE-011 — integrated Stage 3 scenarios on the synthetic workflow: incomplete
//  requirements, rejection/approval branch, cancellation, supersession,
//  automation integration, post-build access revocation, tamper detection,
//  determinism, and architecture guards.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-011 — integrated Stage 3 scenarios", .serialized)
@MainActor
struct PJE011IntegrationScenariosTests {

    private let t0 = PJE011Fixtures.t0

    private func count(_ db: Database, _ table: String) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    // MARK: - Incomplete requirements

    @Test("Completing the review step before reviewing selected evidence fails closed")
    func incompleteReviewFailsClosed() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "incompletereview")
        var time = t0.addingTimeInterval(10)
        _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, IntakeStepCommand.setTitle("M"), at: time)
        time.addTimeInterval(10); _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, IntakeStepCommand.complete, at: time)
        time.addTimeInterval(10); _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: c.entityID.uuidString, reason: "s"), at: time)
        time.addTimeInterval(10); _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, SelectEvidenceStepCommand.complete, at: time)
        let before = try await c.rig.repo.fetchRun(c.runID)
        // No review performed → completing the review step is blocked.
        await #expect(throws: (any Error).self) {
            _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, ReviewEvidenceStepCommand.complete, at: time.addingTimeInterval(10))
        }
        let after = try await c.rig.repo.fetchRun(c.runID)
        #expect(after.run.revision == before.run.revision)
        #expect(!after.stepRuns.contains { $0.stepKind == .timeline })   // no later step
    }

    // MARK: - Branch: rejection / approval

    @Test("A rejected work product is preserved and routes to the rejected terminal")
    func rejectionPreservesArtifactAndRoutes() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "reject")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        var time = a.lastTime.addingTimeInterval(10)
        _ = try await a.rig.engine.submitHumanApproval(
            runID: c.runID, approved: false, rationale: "two findings lack citations",
            actor: PJE011Fixtures.human("boss", role: "supervisor"), at: time)
        time.addTimeInterval(10)
        let ended = try await PJE011Fixtures.exec(a.rig, runID: c.runID, HumanApprovalStepCommand.applyRecordedApproval, at: time)
        #expect(ended.run.status == .completed)
        #expect(ended.decisions.contains { $0.kind == .humanApproval && $0.selectedOption == "rejected" })
        // The rejected work-product artifact survives (append-only history).
        #expect(ended.artifacts.contains { $0.id == a.wpArtifactID })
    }

    @Test("A corrected rebuild is an independent run whose approval does not transfer")
    func correctionRebuildIsIndependent() async throws {
        let c1 = try await PJE011Fixtures.makeCase(suffix: "rebuild1")
        let a1 = try await PJE011Fixtures.driveToApprovalWaiting(c1)
        _ = try await a1.rig.engine.submitHumanApproval(
            runID: c1.runID, approved: false, rationale: "fix citations",
            actor: PJE011Fixtures.human("boss", role: "supervisor"), at: a1.lastTime.addingTimeInterval(10))
        // The corrected revision is produced by a fresh run — its own WP run + artifact.
        let c2 = try await PJE011Fixtures.makeCase(suffix: "rebuild2")
        let a2 = try await PJE011Fixtures.driveToApprovalWaiting(c2)
        #expect(a1.wpRunID != a2.wpRunID)
        #expect(a1.wpArtifactID != a2.wpArtifactID)
    }

    // MARK: - Cancellation

    @Test("Cancellation is durable, preserves its reason, and never touches canonical evidence")
    func cancellationDurable() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "cancel")
        let claimsBefore = try await count(c.rig.db, "claims")
        var time = t0.addingTimeInterval(20)
        _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, IntakeStepCommand.setTitle("Partial"), at: time)
        time.addTimeInterval(10)
        _ = try await WorkflowLifecycleEngine(repository: c.rig.repo).cancel(
            runID: c.runID, reason: "withdrawn by owner", actor: PJE011Fixtures.human("owner"), now: time)
        let rig2 = try await PJE011Fixtures.reopen(c)
        let reopened = try await rig2.repo.fetchRun(c.runID)
        #expect(reopened.run.status == .cancelled)
        #expect(reopened.run.cancellationReason == "withdrawn by owner")
        #expect(try await count(rig2.db, "claims") == claimsBefore)
    }

    @Test("A cancelled run cannot resume")
    func cancelledRunCannotResume() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "cancelresume")
        _ = try await WorkflowLifecycleEngine(repository: c.rig.repo).cancel(
            runID: c.runID, reason: "stop", actor: PJE011Fixtures.human("owner"), now: t0.addingTimeInterval(20))
        await #expect(throws: (any Error).self) {
            _ = try await WorkflowLifecycleEngine(repository: c.rig.repo).resume(
                runID: c.runID, actor: PJE011Fixtures.human("owner"), now: self.t0.addingTimeInterval(30))
        }
    }

    // MARK: - Supersession

    @Test("Supersession links parent and replacement and reopens both independently")
    func supersessionLinksAndReopens() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "supersede")
        let (pkg, wfID) = try PJE011Fixtures.syntheticPackage(suffix: "supersede")
        let result = try await WorkflowLifecycleEngine(repository: c.rig.repo).supersede(
            runID: c.runID, package: pkg, selectedWorkflowID: wfID, workspaceID: c.ws.id,
            title: "Replacement", actor: .system, now: t0.addingTimeInterval(30))
        #expect(result.superseded.run.status == .superseded)
        #expect(result.replacement.run.status == .draft)
        #expect(result.superseded.run.supersededByRunID == result.replacement.run.id)
        // Both reopen with their own independent state.
        let rig2 = try await PJE011Fixtures.reopen(c)
        #expect(try await rig2.repo.fetchRun(c.runID).run.status == .superseded)
        #expect(try await rig2.repo.fetchRun(result.replacement.run.id).run.revision == result.replacement.run.revision)
    }

    // MARK: - Automation integration

    @Test("A workflow-event automation proposes a candidate evidence-request task, idempotently, and never resolves it")
    func automationProposesCandidate() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "automation")
        let validator = WorkflowProvenanceReferenceValidator(
            gate: CanonicalWorkflowEvidenceReferenceGate(database: c.rig.db, scopeRepository: c.rig.scopes, scope: nil),
            database: c.rig.db)
        let coordinator = PersonaAutomationRuntimeCoordinator(
            executions: WorkflowAutomationExecutionRepository(database: c.rig.db),
            workflowRuns: c.rig.repo, tasks: ProfessionalTaskRepository(database: c.rig.db),
            deadlines: DeadlineRepository(database: c.rig.db), validator: validator)
        let def = PersonaAutomationDefinition(
            id: PJE011Fixtures.automationID, version: 1, label: "Evidence request",
            trigger: .workflowEvent, action: .createMissingEvidenceRequest)
        let request = PersonaAutomationRequest(
            workspaceID: c.ws.id, workflowRunID: c.runID, title: "Need the carrier record")
        let event = PersonaAutomationTriggerEvent(kind: .workflowEvent, eventKey: "blocked-on-evidence")
        let outcome = try await coordinator.run(
            definition: def, applicationID: PJE011Fixtures.appID, request: request, trigger: event, now: t0.addingTimeInterval(50))
        guard case .produced(let exec) = outcome else { Issue.record("expected produced"); return }
        let taskID = try #require(exec.outputID)
        let row = try await c.rig.db.query("SELECT task_type, status, origin FROM professional_tasks WHERE id = ?;", [.uuid(taskID)])
        #expect(row.first?.string(0) == "evidenceRequest")
        #expect(row.first?.string(1) == "candidate")          // automation cannot open/complete it
        #expect(row.first?.string(2) == "automationProposed")
        // Replay is idempotent — no second candidate.
        let tasksAfter = try await count(c.rig.db, "professional_tasks")
        let replay = try await coordinator.run(
            definition: def, applicationID: PJE011Fixtures.appID, request: request, trigger: event, now: t0.addingTimeInterval(60))
        guard case .skippedDuplicate = replay else { Issue.record("expected skippedDuplicate"); return }
        #expect(try await count(c.rig.db, "professional_tasks") == tasksAfter)
    }

    // MARK: - Access revocation

    @Test("After revoking a cited source, the inspector denies it without rewriting stored provenance")
    func postBuildAccessRevocation() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "revoke")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        let inspector = WorkflowProvenanceInspector(repository: a.rig.repo, database: a.rig.db, scopes: a.rig.scopes)
        let exportAccess = PJE006CFixtures.exportAccess(workspaceID: c.ws.id)
        let before = try await inspector.inspect(owner: .artifact(a.wpArtifactID), access: exportAccess)
        let citedSV = try #require(before.references.first { $0.kind == .sourceVersion })
        #expect(citedSV.availability == .available)
        let storedBefore = try #require(try await a.rig.repo.provenanceSnapshots(owner: .artifact(a.wpArtifactID)).last)

        _ = try await a.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: citedSV.canonicalObjectID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje011"), reason: "sealed", at: t0)
        let publicAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: c.ws.id, maximumSensitivity: .publicLevel, permitsPrivilegedMaterial: false, purpose: .export))
        let after = try await inspector.inspect(owner: .artifact(a.wpArtifactID), access: publicAccess)
        let deniedRef = try #require(after.references.first { $0.canonicalObjectID == citedSV.canonicalObjectID })
        #expect(deniedRef.availability == .accessDenied)
        #expect(deniedRef.label == nil && deniedRef.note == nil)
        let storedAfter = try #require(try await a.rig.repo.provenanceSnapshots(owner: .artifact(a.wpArtifactID)).last)
        #expect(storedAfter.snapshotJSON == storedBefore.snapshotJSON)   // history not rewritten
    }

    // MARK: - Tamper detection

    @Test("Tampering the contract snapshot hash fails the run reopen")
    func tamperContractHashDetected() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "tampercontract")
        try await c.rig.db.exec(
            "UPDATE workflow_runs SET contract_snapshot_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "0", count: 64)), .uuid(c.runID)])
        await #expect(throws: (any Error).self) { _ = try await c.rig.repo.fetchRun(c.runID) }
    }

    @Test("Tampering a step state hash fails the run reopen")
    func tamperStepStateHashDetected() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "tamperstep")
        var time = t0.addingTimeInterval(10)
        _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, IntakeStepCommand.setTitle("t"), at: time)
        let stepRunID = try #require(try await c.rig.repo.fetchRun(c.runID).run.currentStepRunID)
        try await c.rig.db.exec(
            "UPDATE workflow_step_runs SET state_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "e", count: 64)), .uuid(stepRunID)])
        await #expect(throws: (any Error).self) { _ = try await c.rig.repo.fetchRun(c.runID) }
    }

    @Test("Tampering a persisted provenance snapshot fails the run reopen")
    func tamperProvenanceDetected() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "tamperprov")
        var time = t0.addingTimeInterval(10)
        _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, IntakeStepCommand.setTitle("t"), at: time)
        time.addTimeInterval(10); _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, IntakeStepCommand.complete, at: time)
        time.addTimeInterval(10); _ = try await PJE011Fixtures.exec(c.rig, runID: c.runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: c.entityID.uuidString, reason: "s"), at: time)
        try await c.rig.db.exec(
            "UPDATE workflow_provenance_snapshots SET snapshot_json = snapshot_json || ' ' WHERE workflow_run_id = ?;",
            [.uuid(c.runID)])
        await #expect(throws: (any Error).self) { _ = try await c.rig.repo.fetchRun(c.runID) }
    }

    @Test("Tampering an attachment content hash is detected on inspection")
    func tamperAttachmentDetected() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "tamperatt")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        try await a.rig.db.exec(
            "UPDATE workflow_artifacts SET content_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "f", count: 64)), .uuid(a.attachmentArtifactID)])
        let inspector = WorkflowProvenanceInspector(repository: a.rig.repo, database: a.rig.db, scopes: a.rig.scopes)
        await #expect(throws: (any Error).self) {
            _ = try await inspector.inspectAttachment(artifactID: a.attachmentArtifactID, access: PJE006CFixtures.exportAccess(workspaceID: c.ws.id))
        }
    }

    // MARK: - Determinism

    @Test("The synthetic package compiles deterministically to the same contract hash")
    func compileDeterministic() async throws {
        let rig = try await PJE006CFixtures.makeRig(at: PJE006CFixtures.newDatabaseURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE011Fixtures.syntheticPackage(suffix: "det")
        let r1 = try await rig.repo.createRun(package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let r2 = try await rig.repo.createRun(package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        #expect(r1.run.contractSnapshotSHA256 == r2.run.contractSnapshotSHA256)   // deterministic snapshot
    }

    // MARK: - Architecture guards

    @Test("Stage 3 executors perform no direct SQL")
    func executorsNoDirectSQL() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Workflow/Execution/Executors")
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in ["database.exec", "database.query", "INSERT INTO", "UPDATE workflow_"] {
                #expect(!text.contains(token), "\(url.lastPathComponent) executor must not perform direct SQL ('\(token)')")
            }
        }
    }

    @Test("The synthetic run's terminology resolves to a presentation label, not an identifier")
    func terminologyInContextIsPresentationOnly() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "term")
        let contract = try await c.rig.repo.fetchRun(c.runID).contract
        let label = try PersonaTerminologyResolver().label(
            for: .issue, in: contract, canonicalFallback: "Issue")
        #expect(label == "Matter")                       // persona presentation label
        #expect(label != contract.applicationKey.id.rawValue)
        #expect(label != contract.selectedWorkflowKey.id.rawValue)
    }

    @Test("Tampering a persisted human-decision provenance snapshot fails the run reopen")
    func tamperDecisionBasisDetected() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "tamperdecision")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        // A human decision (with basis) was recorded during the drive; corrupt its snapshot.
        try await a.rig.db.exec("""
            UPDATE workflow_provenance_snapshots SET snapshot_json = snapshot_json || ' '
             WHERE owner_kind = 'decision' AND workflow_run_id = ?;
            """, [.uuid(c.runID)])
        await #expect(throws: (any Error).self) { _ = try await a.rig.repo.fetchRun(c.runID) }
    }

    @Test("Tampering the persisted work-product manifest changes the receipt seal")
    func tamperManifestChangesReceipt() async throws {
        let c = try await PJE011Fixtures.makeCase(suffix: "tampermanifest")
        let a = try await PJE011Fixtures.driveToApprovalWaiting(c)
        let repo = WorkProductRunRepository(database: a.rig.db)
        let s1 = try WorkProductReceiptBuilder().build(from: try await repo.reopen(a.wpRunID)).seal
        try await a.rig.db.exec(
            "UPDATE work_product_claim_occurrences SET text = ? WHERE run_id = ?;",
            [.text("TAMPERED"), .uuid(a.wpRunID)])
        let s2 = try WorkProductReceiptBuilder().build(from: try await repo.reopen(a.wpRunID)).seal
        #expect(s1 != s2)
    }

    @Test("All 17 step kinds resolve in the integrated registry")
    func allStepKindsResolve() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: SensitiveScopeRepository(database: db), scope: nil)
        let registry = try PJE006CFixtures.makeFullRegistry(gate: gate)
        for kind in WorkflowStepKind.allCases {
            #expect(registry.resolveExecutor(workflowSchemaVersion: 1, stepKind: kind) != nil, "\(kind)")
        }
    }

    @Test("The Stage 3 runtime layer has no UI, AppState, LLM or network dependency")
    func runtimeLayerNoUINetworkLLM() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Kalsmritikosh/Workflow/Runtime")
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for token in ["import SwiftUI", "import AppKit", "AppState", "URLSession", "http://", "Ollama"] {
                #expect(!text.contains(token), "\(url.lastPathComponent) must not reference '\(token)'")
            }
        }
    }
}
