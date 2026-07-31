//
//  ProfessionalMethodWorkflowBridgeTests.swift
//  KalsmritikoshTests
//
//  PM-003 — the reference-only bridge: exact draft-run creation, linked-run
//  validation against the exact selection + workflow back-references, and
//  completed-result construction whose provenance is derived solely from persisted
//  method evidence links (fail-closed), with canonical isolation and exact reopen.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-003 — ProfessionalMethodWorkflowBridge", .serialized)
struct ProfessionalMethodWorkflowBridgeTests {

    private let t0 = PM003Fixtures.t0

    private struct Case {
        let rig: PM003Rig
        let ws: UUID
        let entity: UUID
        let wfRunID: UUID
        let wfStepRunID: UUID
    }

    private func makeCase(suffix: String = "bridge") async throws -> Case {
        // Register v1 + v2 so a definition-version mismatch (selection v2 vs a v1 run)
        // passes selection validation and reaches the definitionMismatch check.
        let rig = try await PM003Fixtures.makeRig(
            at: PJE006CFixtures.newDatabaseURL(),
            definitions: [PM003Fixtures.syntheticDefinition(version: 1), PM003Fixtures.syntheticDefinition(version: 2)])
        let ws = UUID(); try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let pkg = try PM003Fixtures.methodV2Package(suffix: suffix)
        let (wfRunID, wfStepRunID) = try await PM003Fixtures.startMethodRun(rig, package: pkg, workspaceID: ws, at: t0)
        return Case(rig: rig, ws: ws, entity: entity, wfRunID: wfRunID, wfStepRunID: wfStepRunID)
    }

    private var selection: WorkflowProfessionalMethodSelection {
        WorkflowProfessionalMethodSelection(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 1)
    }

    private func count(_ db: Database, _ table: String) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    // MARK: - Draft-run creation

    @Test("The bridge creates an exact registered draft run through the accepted repository")
    func createsDraftRun() async throws {
        let c = try await makeCase()
        let ref = try await c.rig.bridge.createDraftRun(
            selection: selection, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            title: "Investigate", createdBy: "analyst", now: t0)
        let run = try await c.rig.methodRepo.run(id: ref.methodRunID)
        #expect(run?.status == .draft)
        #expect(run?.methodDefinitionID.rawValue == PM003Fixtures.methodDefID)
        #expect(run?.methodDefinitionVersion == 1)
        #expect(run?.workflowRunID == c.wfRunID && run?.workflowStepRunID == c.wfStepRunID)
    }

    @Test("An unknown definition or version is rejected before any database write")
    func unknownSelectionNoWrite() async throws {
        let c = try await makeCase()
        let before = try await count(c.rig.db, "method_runs")
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.unknownMethodDefinition("com.k.ghost")) {
            _ = try await c.rig.bridge.createDraftRun(
                selection: WorkflowProfessionalMethodSelection(methodDefinitionID: "com.k.ghost", methodDefinitionVersion: 1),
                workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
                title: nil, createdBy: "a", now: self.t0)
        }
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.unknownMethodVersion(id: PM003Fixtures.methodDefID, version: 9)) {
            _ = try await c.rig.bridge.createDraftRun(
                selection: WorkflowProfessionalMethodSelection(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 9),
                workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
                title: nil, createdBy: "a", now: self.t0)
        }
        #expect(try await count(c.rig.db, "method_runs") == before)
    }

    // MARK: - Linked-run validation

    @Test("A matching linked run validates; workspace/workflow/step/definition mismatches fail closed")
    func linkedRunValidation() async throws {
        let c = try await makeCase()
        let runID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0, markCompleted: false)
        let ref = try await c.rig.bridge.validateLinkedRun(
            runID: runID, selection: selection, workspaceID: c.ws,
            workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID)
        #expect(ref.methodRunID == runID)

        await #expect(throws: ProfessionalMethodWorkflowBridgeError.workspaceMismatch(runID)) {
            _ = try await c.rig.bridge.validateLinkedRun(runID: runID, selection: self.selection, workspaceID: UUID(),
                workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID)
        }
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.workflowRunMismatch(runID)) {
            _ = try await c.rig.bridge.validateLinkedRun(runID: runID, selection: self.selection, workspaceID: c.ws,
                workflowRunID: UUID(), workflowStepRunID: c.wfStepRunID)
        }
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.workflowStepMismatch(runID)) {
            _ = try await c.rig.bridge.validateLinkedRun(runID: runID, selection: self.selection, workspaceID: c.ws,
                workflowRunID: c.wfRunID, workflowStepRunID: UUID())
        }
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.definitionMismatch(runID)) {
            _ = try await c.rig.bridge.validateLinkedRun(runID: runID,
                selection: WorkflowProfessionalMethodSelection(methodDefinitionID: PM003Fixtures.methodDefID, methodDefinitionVersion: 2),
                workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID)
        }
    }

    @Test("A missing, cancelled or superseded run fails closed")
    func terminalRunsRejected() async throws {
        let c = try await makeCase()
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.self) {
            _ = try await c.rig.bridge.validateLinkedRun(runID: UUID(), selection: self.selection, workspaceID: c.ws,
                workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID)
        }
        for status in ["cancelled", "superseded"] {
            let runID = try await PM003Fixtures.makeCompletedMethodRun(
                c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
                entityID: c.entity, at: t0, markCompleted: false)
            try await c.rig.db.exec("UPDATE method_runs SET status=? WHERE id=?;", [.text(status), .uuid(runID)])
            await #expect(throws: ProfessionalMethodWorkflowBridgeError.terminalInvalidRun(runID, status: status)) {
                _ = try await c.rig.bridge.validateLinkedRun(runID: runID, selection: self.selection, workspaceID: c.ws,
                    workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID)
            }
        }
    }

    // MARK: - Completed-result construction

    @Test("A completed run yields a result with a stable revision and evidence-link-derived provenance")
    func completedResultDerivesProvenance() async throws {
        let c = try await makeCase()
        let runID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0)
        let result = try await c.rig.bridge.completedResult(
            runID: runID, selection: selection, workspaceID: c.ws,
            workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            summary: "Carrier handoff is the leading candidate", completedBy: "analyst", limitations: ["single source"])
        #expect(result.completedRevision == 2)                       // createRun(1) + addEvidenceLink(→2)
        #expect(result.run.methodRunID == runID)
        #expect(result.provenanceReferences.count == 1)
        #expect(result.provenanceReferences[0].objectKind == "entity")
        #expect(result.provenanceReferences[0].canonicalObjectID == c.entity.uuidString)
    }

    @Test("An incomplete run or a run missing its completion timestamp is rejected")
    func incompleteRunRejected() async throws {
        let c = try await makeCase()
        let draft = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0, markCompleted: false)
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.runNotCompleted(draft, status: "draft")) {
            _ = try await c.rig.bridge.completedResult(runID: draft, selection: self.selection, workspaceID: c.ws,
                workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID, summary: "s", completedBy: "a", limitations: [])
        }
        // completed status but no completed_at (the CHECK permits this shape).
        let noStamp = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0, markCompleted: false)
        try await c.rig.db.exec("UPDATE method_runs SET status='completed' WHERE id=?;", [.uuid(noStamp)])
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.missingCompletionTimestamp(noStamp)) {
            _ = try await c.rig.bridge.completedResult(runID: noStamp, selection: self.selection, workspaceID: c.ws,
                workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID, summary: "s", completedBy: "a", limitations: [])
        }
    }

    @Test("Provenance is deterministically ordered by (ordinal, id), preserving contradicting links")
    func deterministicProvenanceOrder() async throws {
        let c = try await makeCase()
        let entity2 = try await PJE007Fixtures.seedEntity(c.rig.db, in: c.ws)   // real second entity in ws
        // First link (ordinal 0) is the supporting entity from makeCompletedMethodRun.
        let runID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0, markCompleted: false)
        // A CONTRADICTING link at a higher ordinal — it must be preserved and ordered after.
        _ = try await c.rig.methodRepo.addEvidenceLink(
            MethodEvidenceLink(methodRunID: runID, targetKind: .entity, targetID: entity2,
                role: .contradicting, ordinal: 1, addedBy: "a", addedAt: t0),
            expectedRevision: 2, gate: c.rig.gate, now: t0)
        try await c.rig.db.exec("UPDATE method_runs SET status='completed', completed_at=? WHERE id=?;", [.date(t0), .uuid(runID)])
        let result = try await c.rig.bridge.completedResult(
            runID: runID, selection: selection, workspaceID: c.ws,
            workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            summary: "s", completedBy: "a", limitations: [])
        #expect(result.provenanceReferences.map(\.canonicalObjectID) == [c.entity.uuidString, entity2.uuidString])
    }

    @Test("A currently scope-denied evidence reference fails the result closed")
    func gateDeniedReferenceRejected() async throws {
        let c = try await makeCase()
        let runID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0)
        // Seal the cited entity AFTER the link was added — the fail-closed default gate now denies it.
        _ = try await c.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: c.entity),
            sensitivity: .confidential, authority: .systemRule(tag: "pm003"), reason: "sealed", at: t0)
        await #expect(throws: ProfessionalMethodWorkflowBridgeError.deniedCanonicalReference(kind: "entity", id: c.entity)) {
            _ = try await c.rig.bridge.completedResult(runID: runID, selection: self.selection, workspaceID: c.ws,
                workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID, summary: "s", completedBy: "a", limitations: [])
        }
    }

    @Test("Building a result never mutates any canonical ledger table")
    func canonicalIsolation() async throws {
        let c = try await makeCase()
        let runID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0)
        let tables = ["claims", "evidence_blocks", "source_versions", "events", "entities",
                      "relationships", "contradictions", "gap_nodes"]
        var before: [String: Int] = [:]
        for t in tables { before[t] = try await count(c.rig.db, t) }
        _ = try await c.rig.bridge.completedResult(runID: runID, selection: selection, workspaceID: c.ws,
            workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID, summary: "s", completedBy: "a", limitations: [])
        for t in tables { #expect(try await count(c.rig.db, t) == before[t], "\(t) changed") }
    }

    @Test("A completed result reconstructs exactly after a database reopen")
    func exactReopen() async throws {
        let c = try await makeCase()
        let runID = try await PM003Fixtures.makeCompletedMethodRun(
            c.rig, workspaceID: c.ws, workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID,
            entityID: c.entity, at: t0)
        let first = try await c.rig.bridge.completedResult(runID: runID, selection: selection, workspaceID: c.ws,
            workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID, summary: "s", completedBy: "a", limitations: ["x"])
        // Reopen the database with a fresh bridge.
        let db2 = try MigrationFixtureBuilder.reopen(at: c.rig.url)
        let repo2 = MethodRunRepository(database: db2)
        let scopes2 = SensitiveScopeRepository(database: db2)
        let gate2 = CanonicalWorkflowEvidenceReferenceGate(database: db2, scopeRepository: scopes2, scope: nil)
        let bridge2 = ProfessionalMethodWorkflowBridge(
            registry: try PM003Fixtures.registry([PM003Fixtures.syntheticDefinition()]),
            repository: repo2, evidenceGate: gate2)
        let second = try await bridge2.completedResult(runID: runID, selection: selection, workspaceID: c.ws,
            workflowRunID: c.wfRunID, workflowStepRunID: c.wfStepRunID, summary: "s", completedBy: "a", limitations: ["x"])
        #expect(first == second)
    }
}
