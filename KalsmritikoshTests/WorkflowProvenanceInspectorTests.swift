//
//  WorkflowProvenanceInspectorTests.swift
//  KalsmritikoshTests
//
//  PJE-007 — WorkflowProvenanceInspector: scoped inspection with the CURRENT
//  access policy reapplied at read time. Denied references never expose
//  annotations; missing targets are reported (never silently dropped); legacy
//  rows are reported as untracked, never fabricated. Historical provenance is
//  never rewritten by reading it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — provenance inspector")
@MainActor
struct WorkflowProvenanceInspectorTests {

    private let t0 = PJE007Fixtures.t0

    private struct Prepared {
        let rig: PJE007Rig
        let runID: UUID
        let workspaceID: UUID
        let entityID: UUID
        let gapID: UUID
        let stepRunID: UUID
    }

    /// A run with a selectEvidence step holding an entity (with a reason note)
    /// and a gap reference.
    private func prepareSelection() async throws -> Prepared {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entityID = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let gapID = try await PJE007Fixtures.seedGap(rig.db)
        let (pkg, wfID) = try PJE007Fixtures.evidencePackage(suffix: "insp")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        var time = t0.addingTimeInterval(60)
        _ = try await PJE007Fixtures.exec(rig, runID: created.run.id, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entityID.uuidString, reason: "primary subject"), at: time)
        time.addTimeInterval(10)
        let after = try await PJE007Fixtures.exec(rig, runID: created.run.id, SelectEvidenceStepCommand.select(
            kind: .gap, canonicalObjectID: gapID.uuidString, reason: "gap"), at: time)
        let stepRunID = try #require(after.run.currentStepRunID)
        return Prepared(rig: rig, runID: created.run.id, workspaceID: ws,
                        entityID: entityID, gapID: gapID, stepRunID: stepRunID)
    }

    private func attach(_ level: SensitivityLevel? = nil) async throws
        -> (rig: PJE007Rig, ws: UUID, artifactID: UUID, src: PJE007Fixtures.SeededSource) {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "insp-att")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let coordinator = WorkflowAttachmentCoordinator(
            workflowRuns: rig.repo, database: rig.db,
            sourceRelations: rig.sourceRelations, gate: rig.gate, scopes: rig.scopes)
        let after = try await coordinator.attachCanonicalSource(
            runID: created.run.id,
            request: WorkflowCanonicalAttachmentRequest(
                artifactDefinitionID: PJE007Fixtures.attachmentArtifactDefID,
                sourceVersionID: src.svID, displayName: "Report.pdf"),
            actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(30))
        let artifactID = try #require(after.artifacts.first).id
        if let level = level {
            _ = try await rig.scopes.assign(
                target: SensitiveScopeTarget(kind: .sourceVersion, id: src.svID),
                sensitivity: level, authority: .systemRule(tag: "pje007"),
                reason: "t", at: t0)
        }
        return (rig, ws, artifactID, src)
    }

    // MARK: - Owner inspection

    @Test("Inspection returns references in deterministic ordinal order")
    func referencesInOrder() async throws {
        let p = try await prepareSelection()
        let inspection = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID))
        #expect(inspection.references.map(\.canonicalObjectID) == [p.entityID, p.gapID])
        #expect(inspection.inaccessibleReferenceCount == 0)
    }

    @Test("Inspection reports the exact producer identity")
    func producerReported() async throws {
        let p = try await prepareSelection()
        let inspection = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID))
        #expect(inspection.producerID == "com.kalsmritikosh.step.selectEvidence")
    }

    @Test("An available reference exposes its workflow annotations")
    func availableExposesAnnotations() async throws {
        let p = try await prepareSelection()
        let inspection = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID))
        let entityRef = try #require(inspection.references.first { $0.canonicalObjectID == p.entityID })
        #expect(entityRef.availability == .available)
        #expect(entityRef.note == "primary subject")
    }

    @Test("Access is reapplied at read time: a newly confidential reference is denied")
    func accessReappliedAtReadTime() async throws {
        let p = try await prepareSelection()
        _ = try await p.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: p.entityID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje007"),
            reason: "t", at: t0)
        let inspection = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID, level: .publicLevel))
        let entityRef = try #require(inspection.references.first { $0.canonicalObjectID == p.entityID })
        #expect(entityRef.availability == .accessDenied)
        #expect(inspection.inaccessibleReferenceCount == 1)
    }

    @Test("A denied reference strips label, note and locator")
    func deniedStripsAnnotations() async throws {
        let p = try await prepareSelection()
        _ = try await p.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: p.entityID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje007"),
            reason: "t", at: t0)
        let inspection = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID, level: .publicLevel))
        let entityRef = try #require(inspection.references.first { $0.canonicalObjectID == p.entityID })
        #expect(entityRef.note == nil)
        #expect(entityRef.label == nil)
        #expect(entityRef.locatorJSON == nil)
    }

    @Test("A reference whose canonical target is gone is reported unresolved, not dropped")
    func unresolvedTargetReported() async throws {
        let p = try await prepareSelection()
        // Remove the entity from workspace membership so the target no longer resolves.
        try await p.rig.db.exec(
            "DELETE FROM workspace_entities WHERE entity_id = ?;", [.uuid(p.entityID)])
        try await p.rig.db.exec("DELETE FROM entities WHERE id = ?;", [.uuid(p.entityID)])
        let inspection = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID))
        let entityRef = try #require(inspection.references.first { $0.canonicalObjectID == p.entityID })
        #expect(entityRef.availability == .unresolved)
        // The reference is still present — count stays honest.
        #expect(inspection.references.count == 2)
    }

    @Test("A legacyUntracked owner is reported as unavailable, never fabricated")
    func legacyOwnerUnavailable() async throws {
        let p = try await prepareSelection()
        try await p.rig.db.exec(
            "UPDATE workflow_step_runs SET provenance_semantics = 'legacyUntracked' WHERE id = ?;",
            [.uuid(p.stepRunID)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.inspector.inspect(
                owner: .stepRun(p.stepRunID),
                access: PJE007Fixtures.exportAccess(p.workspaceID))
        }
    }

    @Test("An owner with no provenance record throws snapshotMissing")
    func missingOwnerThrows() async throws {
        let p = try await prepareSelection()
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.inspector.inspect(
                owner: .stepRun(UUID()),
                access: PJE007Fixtures.exportAccess(p.workspaceID))
        }
    }

    @Test("Reading provenance does not rewrite the stored snapshot or its semantics")
    func readingDoesNotRewrite() async throws {
        let p = try await prepareSelection()
        let before = try #require(try await p.rig.repo.provenanceSnapshots(owner: .stepRun(p.stepRunID)).last)
        _ = try await p.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: p.entityID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje007"),
            reason: "t", at: t0)
        _ = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID, level: .publicLevel))
        let after = try #require(try await p.rig.repo.provenanceSnapshots(owner: .stepRun(p.stepRunID)).last)
        #expect(after.snapshotJSON == before.snapshotJSON)
        #expect(after.snapshotSHA256 == before.snapshotSHA256)
        let semantics = try await p.rig.repo.provenanceSemantics(owner: .stepRun(p.stepRunID))
        #expect(semantics == .snapshotV1)
    }

    // MARK: - Attachment inspection

    @Test("Attachment inspection resolves to its canonical source version")
    func attachmentResolvesToCanonicalSource() async throws {
        let (rig, ws, artifactID, src) = try await attach()
        let inspection = try await rig.inspector.inspectAttachment(
            artifactID: artifactID, access: PJE007Fixtures.exportAccess(ws))
        #expect(inspection.sourceAvailability == .available)
        #expect(inspection.binding.sourceVersionID == src.svID)
        #expect(inspection.binding.sourceContentSHA256 == src.contentHash)
    }

    @Test("An artifact/binding hash divergence is detected as tampering")
    func attachmentHashMismatchDetected() async throws {
        let (rig, ws, artifactID, _) = try await attach()
        try await rig.db.exec(
            "UPDATE workflow_artifacts SET content_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "f", count: 64)), .uuid(artifactID)])
        do {
            _ = try await rig.inspector.inspectAttachment(
                artifactID: artifactID, access: PJE007Fixtures.exportAccess(ws))
            Issue.record("Expected attachmentHashMismatch")
        } catch WorkflowProvenanceError.attachmentHashMismatch {
            // Expected
        }
    }

    @Test("A deleted canonical source is reported unresolved, never silently removed")
    func attachmentDeletedSourceUnresolved() async throws {
        let (rig, ws, artifactID, src) = try await attach()
        try await rig.db.exec("DELETE FROM source_versions WHERE id = ?;", [.uuid(src.svID)])
        let inspection = try await rig.inspector.inspectAttachment(
            artifactID: artifactID, access: PJE007Fixtures.exportAccess(ws))
        #expect(inspection.sourceAvailability == .unresolved)
    }

    @Test("A legacyUntracked attachment is reported unavailable")
    func attachmentLegacyUnavailable() async throws {
        let (rig, ws, artifactID, _) = try await attach()
        try await rig.db.exec(
            "UPDATE workflow_artifacts SET provenance_semantics = 'legacyUntracked' WHERE id = ?;",
            [.uuid(artifactID)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await rig.inspector.inspectAttachment(
                artifactID: artifactID, access: PJE007Fixtures.exportAccess(ws))
        }
    }

    @Test("Inspecting a non-attachment artifact throws artifactKindMismatch")
    func nonAttachmentArtifactThrows() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "insp-nonatt")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let agg = try await rig.repo.recordArtifact(
            runID: created.run.id, stepRunID: nil,
            artifactDefinitionID: "art.report", kind: .generatedProduct, label: "R",
            workProductRunID: nil, targetKind: nil, targetID: nil, referenceURI: nil,
            mediaType: nil, contentSHA256: nil, metadataJSON: "{}",
            supersedesArtifactID: nil, expectedRevision: created.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0)
        let artifactID = try #require(agg.artifacts.first).id
        do {
            _ = try await rig.inspector.inspectAttachment(
                artifactID: artifactID, access: PJE007Fixtures.exportAccess(ws))
            Issue.record("Expected artifactKindMismatch")
        } catch WorkflowProvenanceError.artifactKindMismatch {
            // Expected
        }
    }

    @Test("A now-confidential attachment source is denied under a public scope")
    func attachmentAccessDenied() async throws {
        let (rig, ws, artifactID, _) = try await attach(.confidential)
        do {
            _ = try await rig.inspector.inspectAttachment(
                artifactID: artifactID,
                access: PJE007Fixtures.exportAccess(ws, level: .publicLevel))
            Issue.record("Expected attachmentAccessDenied")
        } catch WorkflowProvenanceError.attachmentAccessDenied {
            // Expected
        }
    }

    // MARK: - Denial-after-persistence end-to-end

    @Test("Denial after persistence: inspector denies, strips detail, and never rewrites history")
    func denialAfterPersistence() async throws {
        let p = try await prepareSelection()
        // Provenance persisted while permitted.
        let permitted = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID))
        #expect(permitted.references.first { $0.canonicalObjectID == p.entityID }?.availability == .available)
        let storedBefore = try #require(try await p.rig.repo.provenanceSnapshots(owner: .stepRun(p.stepRunID)).last)

        // Access removed after the fact.
        _ = try await p.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: p.entityID),
            sensitivity: .restricted, authority: .systemRule(tag: "pje007"),
            reason: "sealed", at: t0.addingTimeInterval(500))

        let denied = try await p.rig.inspector.inspect(
            owner: .stepRun(p.stepRunID),
            access: PJE007Fixtures.exportAccess(p.workspaceID, level: .internalLevel))
        let ref = try #require(denied.references.first { $0.canonicalObjectID == p.entityID })
        #expect(ref.availability == .accessDenied)
        #expect(ref.note == nil && ref.label == nil && ref.locatorJSON == nil)

        // Stored historical provenance is unchanged.
        let storedAfter = try #require(try await p.rig.repo.provenanceSnapshots(owner: .stepRun(p.stepRunID)).last)
        #expect(storedAfter.snapshotJSON == storedBefore.snapshotJSON)
    }
}
