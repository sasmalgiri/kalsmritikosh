//
//  PJE009Fixtures.swift
//  KalsmritikoshTests
//
//  PJE-009 — shared work-product build helper over the PJE-006C rig.
//

import Foundation
@testable import Kalsmritikosh

struct PJE009BuiltWorkProduct {
    let rig: PJE006CRig
    let runID: UUID
    let wpRunID: UUID
    let artifactID: UUID
    let ws: Workspace
    let fileID: UUID
}

enum PJE009Fixtures {

    static let t0 = Date(timeIntervalSince1970: 1_753_600_000)

    static func human(_ id: String, role: String? = nil) -> WorkflowLifecycleActor {
        WorkflowLifecycleActor(kind: .human, identifier: id, role: role)
    }

    /// Build a work product through a build-only workflow and return the run + artifact.
    @MainActor
    static func buildWorkProduct(
        suffix: String, factValue: String = "shipment delayed on 2025-02-01"
    ) async throws -> PJE009BuiltWorkProduct {
        let url = PJE006CFixtures.newDatabaseURL()
        let rig = try await PJE006CFixtures.makeRig(at: url)
        let (fileID, _) = try await PJE006CFixtures.seedFact(rig, value: factValue)
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
        let artifact = built.artifacts.first!
        return PJE009BuiltWorkProduct(
            rig: rig, runID: created.run.id, wpRunID: artifact.workProductRunID!,
            artifactID: artifact.id, ws: ws, fileID: fileID)
    }

    /// The source_version id(s) that back the seeded fact (for citation-exactness tests).
    @MainActor
    static func sourceVersionIDs(_ rig: PJE006CRig) async throws -> [UUID] {
        try await rig.db.query("SELECT id FROM source_versions;", []).compactMap { $0.uuid(0) }
    }
}
