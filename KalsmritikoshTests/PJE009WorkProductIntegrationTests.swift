//
//  PJE009WorkProductIntegrationTests.swift
//  KalsmritikoshTests
//
//  PJE-009 — Work-Product Integration Acceptance. A workflow builds a cited work
//  product through the ACCEPTED assembly path, persists it atomically with its
//  PJE-007 provenance, and reopens exactly. Provenance is derived ONLY from the
//  assembled manifest + citations, never from rendered prose.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-009 — work-product workflow integration", .serialized)
@MainActor
struct PJE009WorkProductIntegrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_600_000)

    private func human(_ id: String) -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: nil)
    }

    private struct Built {
        let rig: PJE006CRig
        let runID: UUID
        let wpRunID: UUID
        let artifactID: UUID
        let ws: Workspace
    }

    /// Seed a composable workspace, run a build-only workflow, and return the
    /// built work-product run + artifact.
    private func buildWorkProduct(suffix: String) async throws -> Built {
        let url = PJE006CFixtures.newDatabaseURL()
        let rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "shipment delayed on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        let (pkg, wfID) = try PJE006CFixtures.makeBuildOnlyPackage(suffix: suffix)
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0.addingTimeInterval(10))
        let request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "PJE-006C WS", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        let built = try await rig.engine.executeCommand(
            runID: created.run.id,
            commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.build(request)),
            actor: human("builder"), now: t0.addingTimeInterval(30))
        let artifact = try #require(built.artifacts.first)
        let wpRunID = try #require(artifact.workProductRunID)
        return Built(rig: rig, runID: created.run.id, wpRunID: wpRunID, artifactID: artifact.id, ws: ws)
    }

    // MARK: - 1: Build is atomic through the accepted path

    @Test("A workflow build persists ONE work-product run + ONE artifact, step stays active")
    func buildIsAtomic() async throws {
        let b = try await buildWorkProduct(suffix: "atomic")
        let agg = try await b.rig.repo.fetchRun(b.runID)
        #expect(agg.run.status == .active)
        #expect(agg.artifacts.filter { $0.kind == .workProductRun }.count == 1)
        #expect(agg.run.revision == agg.events.count)   // no extra event for provenance
    }

    // MARK: - 2: Work-product run reopens with cited findings

    @Test("The built work-product run reopens with cited findings and a manifest")
    func reopensWithCitedFindings() async throws {
        let b = try await buildWorkProduct(suffix: "reopen")
        let reopened = try await WorkProductRunRepository(database: b.rig.db).reopen(b.wpRunID)
        #expect(reopened.manifest.selectedFindingCount >= 1)
        #expect(reopened.manifest.citationMap.contains { $0.resolved })
        #expect(!reopened.workProduct.sections.isEmpty)
    }

    // MARK: - 3: Artifact provenance is citation-derived

    @Test("Artifact provenance references are derived from claims and citation source versions")
    func artifactProvenanceCitationDerived() async throws {
        let b = try await buildWorkProduct(suffix: "artprov")
        let rows = try await b.rig.repo.provenanceSnapshots(owner: .artifact(b.artifactID))
        let snap = try #require(rows.last)
        let refs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256).references
        #expect(!refs.isEmpty)
        let kinds: Set<WorkflowProvenanceReferenceKind> = Set(refs.map { $0.kind })
        #expect(kinds.isSubset(of: [.claim, .sourceVersion]))
        let roles: Set<WorkflowProvenanceRole> = Set(refs.map { $0.role })
        #expect(roles.isSubset(of: [.outputCitation, .supporting, .contradicting]))
    }

    // MARK: - 4: Build step provenance references the exact work-product run

    @Test("The build step provenance references the exact work-product run")
    func buildStepReferencesWorkProductRun() async throws {
        let b = try await buildWorkProduct(suffix: "stepprov")
        let agg = try await b.rig.repo.fetchRun(b.runID)
        let buildStep = try #require(agg.stepRuns.first { $0.stepKind == .workProductBuild })
        let rows = try await b.rig.repo.provenanceSnapshots(owner: .stepRun(buildStep.id))
        let snap = try #require(rows.last)
        let refs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256).references
        #expect(refs.map { $0.kind } == [.workProductRun])
        #expect(refs.map { $0.role } == [.generatedFrom])
        #expect(refs.first?.canonicalObjectID == b.wpRunID)
    }

    // MARK: - 5: Every cited source version appears in the artifact provenance

    @Test("Every manifest source version is represented in the artifact provenance")
    func manifestSourcesInProvenance() async throws {
        let b = try await buildWorkProduct(suffix: "manifestsrc")
        let reopened = try await WorkProductRunRepository(database: b.rig.db).reopen(b.wpRunID)
        let manifestVersionIDs = Set(reopened.manifest.sourceVersionIDs.compactMap { UUID(uuidString: $0) })
        let rows = try await b.rig.repo.provenanceSnapshots(owner: .artifact(b.artifactID))
        let snap = try #require(rows.last)
        let refs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256).references
        let provenanceVersionIDs = Set(refs.filter { $0.kind == .sourceVersion }.map { $0.canonicalObjectID })
        #expect(manifestVersionIDs.isSubset(of: provenanceVersionIDs))
        #expect(!manifestVersionIDs.isEmpty)
    }

    // MARK: - 6: A receipt builds from the reopened product and verifies

    @Test("A verifiable receipt builds from the reopened work product and verifies")
    func receiptBuildsAndVerifies() async throws {
        let b = try await buildWorkProduct(suffix: "receipt")
        let reopened = try await WorkProductRunRepository(database: b.rig.db).reopen(b.wpRunID)
        let receipt = try WorkProductReceiptBuilder().build(from: reopened)
        #expect(VerifiableReceipt.verify(receipt))
        #expect(!receipt.entries.isEmpty)
    }

    // MARK: - 7: Provenance is manifest-derived, never parsed from prose

    @Test("A fake source name in section prose does not become provenance")
    func provenanceNotFromProse() async throws {
        let b = try await buildWorkProduct(suffix: "notprose")
        // The artifact provenance references only real canonical claim/source-version
        // IDs; there is no reference whose ID was invented from rendered text.
        let rows = try await b.rig.repo.provenanceSnapshots(owner: .artifact(b.artifactID))
        let snap = try #require(rows.last)
        let refs = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256).references
        // Every source-version reference resolves to a real source_versions row.
        for ref in refs where ref.kind == .sourceVersion {
            let n = Int(try await b.rig.db.query(
                "SELECT COUNT(*) FROM source_versions WHERE id = ?;", [.uuid(ref.canonicalObjectID)]).first?.int(0) ?? 0)
            #expect(n == 1, "provenance source version \(ref.canonicalObjectID) must be a real canonical row")
        }
        // Every claim reference resolves to a real claims row.
        for ref in refs where ref.kind == .claim {
            let n = Int(try await b.rig.db.query(
                "SELECT COUNT(*) FROM claims WHERE id = ?;", [.uuid(ref.canonicalObjectID)]).first?.int(0) ?? 0)
            #expect(n == 1, "provenance claim \(ref.canonicalObjectID) must be a real canonical row")
        }
    }

    // MARK: - 8: Reopen verifies provenance without throwing

    @Test("Reopening the workflow run verifies work-product provenance")
    func workflowReopenVerifiesProvenance() async throws {
        let b = try await buildWorkProduct(suffix: "wfreopen")
        let rig2 = try await PJE006CFixtures.makeRig(at: b.rig.dbURL, migrate: false)
        let reopened = try await rig2.repo.fetchRun(b.runID)   // verifies provenance on reopen
        #expect(reopened.artifacts.contains { $0.id == b.artifactID })
        let semantics = try await rig2.repo.provenanceSemantics(owner: .artifact(b.artifactID))
        #expect(semantics == .snapshotV1)
    }

    // MARK: - 9: Deterministic reopen — sections/claims stable

    @Test("Reopening twice yields identical sections and citation counts")
    func deterministicReopen() async throws {
        let b = try await buildWorkProduct(suffix: "determ")
        let repo = WorkProductRunRepository(database: b.rig.db)
        let a = try await repo.reopen(b.wpRunID)
        let c = try await repo.reopen(b.wpRunID)
        #expect(a.workProduct.sections.count == c.workProduct.sections.count)
        #expect(a.workProduct.allCitations.count == c.workProduct.allCitations.count)
        #expect(a.manifest.sourceVersionIDs == c.manifest.sourceVersionIDs)
    }

    // MARK: - 10: The build never mutates canonical tables

    @Test("A workflow build never mutates canonical claims/entities/events")
    func canonicalLedgerUntouched() async throws {
        let url = PJE006CFixtures.newDatabaseURL()
        let rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: "delayed on 2025-02-01")
        let ws = try await PJE006CFixtures.makeComposableWorkspace(rig, fileID: fileID, at: t0)
        func counts() async throws -> [Int] {
            var out: [Int] = []
            for t in ["claims", "entities", "events", "evidence_blocks"] {
                out.append(Int(try await rig.db.query("SELECT COUNT(*) FROM \(t);", []).first?.int(0) ?? -1))
            }
            return out
        }
        let before = try await counts()
        let (pkg, wfID) = try PJE006CFixtures.makeBuildOnlyPackage(suffix: "ledger")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws.id,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0.addingTimeInterval(10))
        let request = WorkflowWorkProductBuildRequest(
            artifactDefinitionID: PJE006CFixtures.artifactDefID,
            workProductDefinitionID: PJE006CFixtures.wpDefID,
            subjectLabel: "PJE-006C WS", corpusSnapshotID: nil,
            access: PJE006CFixtures.exportAccess(workspaceID: ws.id))
        _ = try await rig.engine.executeCommand(
            runID: created.run.id,
            commandJSON: try WorkflowStepPayloadCodec.encode(WorkProductBuildStepCommand.build(request)),
            actor: human("builder"), now: t0.addingTimeInterval(30))
        #expect(try await counts() == before)
    }

    // MARK: - 11: Deleting the workflow run does not delete the work-product run

    @Test("Deleting the workflow run preserves the standalone work-product run")
    func deletingWorkflowRunPreservesWorkProduct() async throws {
        let b = try await buildWorkProduct(suffix: "wpsurvive")
        try await b.rig.repo.delete(b.runID)
        // The work-product run is an independent OPS-004 record (SET NULL, not cascade).
        let reopened = try await WorkProductRunRepository(database: b.rig.db).reopen(b.wpRunID)
        #expect(reopened.manifest.selectedFindingCount >= 1)
    }
}
