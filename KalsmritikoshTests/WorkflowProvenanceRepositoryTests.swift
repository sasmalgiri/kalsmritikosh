//
//  WorkflowProvenanceRepositoryTests.swift
//  KalsmritikoshTests
//
//  PJE-007 — repository-level provenance persistence, reopen verification,
//  tamper detection, legacy semantics, and SAVEPOINT rollback. Provenance rides
//  in the SAME transaction as the state mutation it describes; a provenance
//  failure rolls everything back and no extra event is appended for provenance.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — provenance repository round-trip, tamper, legacy, rollback")
@MainActor
struct WorkflowProvenanceRepositoryTests {

    private struct TestFault: Error {}

    private let t0 = PJE007Fixtures.t0

    // MARK: - Helpers

    /// A run started on the selectEvidence step, plus a seeded workspace/entity/gap.
    private struct Prepared {
        let rig: PJE007Rig
        let runID: UUID
        let workspaceID: UUID
        let entityID: UUID
        let gapID: UUID
    }

    private func prepareSelect(_ url: URL) async throws -> Prepared {
        let rig = try await PJE007Fixtures.makeRig(at: url)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entityID = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let gapID = try await PJE007Fixtures.seedGap(rig.db)
        let (pkg, wfID) = try PJE007Fixtures.evidencePackage(suffix: "repo")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: "Repo Prov", parentRunID: nil,
            actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        return Prepared(rig: rig, runID: created.run.id, workspaceID: ws,
                        entityID: entityID, gapID: gapID)
    }

    /// Select the entity then the gap; returns the (reopened run, select step run ID).
    private func selectEntityAndGap(_ p: Prepared) async throws -> (ReopenedWorkflowRun, UUID) {
        var time = t0.addingTimeInterval(60)
        _ = try await PJE007Fixtures.exec(p.rig, runID: p.runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: p.entityID.uuidString, reason: "subject"), at: time)
        time.addTimeInterval(10)
        let after = try await PJE007Fixtures.exec(p.rig, runID: p.runID, SelectEvidenceStepCommand.select(
            kind: .gap, canonicalObjectID: p.gapID.uuidString, reason: "missing"), at: time)
        let stepRunID = try #require(after.run.currentStepRunID)
        return (after, stepRunID)
    }

    private func latestSnapshot(_ rig: PJE007Rig, _ owner: WorkflowProvenanceOwner) async throws -> WorkflowProvenanceSnapshotRow {
        let rows = try await rig.repo.provenanceSnapshots(owner: owner)
        return try #require(rows.last)
    }

    // MARK: - 1: Step state + provenance persist atomically

    @Test("A selectEvidence save persists step state and a snapshotV1 provenance snapshot atomically")
    func stepStateAndProvenanceAtomic() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (after, stepRunID) = try await selectEntityAndGap(p)

        let semantics = try await p.rig.repo.provenanceSemantics(owner: .stepRun(stepRunID))
        #expect(semantics == .snapshotV1)
        let snapshots = try await p.rig.repo.provenanceSnapshots(owner: .stepRun(stepRunID))
        #expect(!snapshots.isEmpty)
        // Atomicity: revision equals event count — no separate provenance event.
        #expect(after.run.revision == after.events.count)
    }

    // MARK: - 2: Latest snapshot carries every reference in order

    @Test("The latest step snapshot carries the selected references in selection order")
    func latestSnapshotReferencesInOrder() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)

        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        let snapshot = try WorkflowProvenanceCodec.decodeAndVerify(
            json: latest.snapshotJSON, expectedSHA256: latest.snapshotSHA256)
        #expect(snapshot.references.map(\.canonicalObjectID) == [p.entityID, p.gapID])
        #expect(snapshot.references.allSatisfy { $0.role == .selected })
    }

    // MARK: - 3: Stored-byte hash verification

    @Test("The stored snapshot hash equals the raw SHA-256 of the exact stored JSON bytes")
    func storedByteHashVerified() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        #expect(latest.snapshotSHA256 == WorkflowPersistedJSONIntegrity.rawSHA256(of: latest.snapshotJSON))
    }

    // MARK: - 4: Producer identity is the exact executor

    @Test("A step snapshot records the exact producing executor identity")
    func producerIsExactExecutor() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        #expect(latest.producerID == "com.kalsmritikosh.step.selectEvidence")
        #expect(latest.producerVersion == "1.0")
    }

    // MARK: - 5: Reference ordinals are continuous 0..<count

    @Test("Reference rows use continuous ordinals starting at zero")
    func referenceOrdinalsContinuous() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        let rows = try await p.rig.db.query(
            "SELECT ordinal FROM workflow_provenance_references WHERE snapshot_id = ? ORDER BY ordinal;",
            [.uuid(latest.id)])
        #expect(rows.compactMap { $0.int(0).map(Int.init) } == [0, 1])
    }

    // MARK: - 6: Reopen reproduces exact snapshots and references

    @Test("Reopening over the same file reproduces the exact snapshot references")
    func reopenReproducesExactSnapshots() async throws {
        let url = PJE007Fixtures.newURL()
        let p = try await prepareSelect(url)
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let before = try await latestSnapshot(p.rig, .stepRun(stepRunID))

        let rig2 = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        _ = try await rig2.repo.fetchRun(p.runID)  // verifies provenance on reopen
        let after = try await latestSnapshot(rig2, .stepRun(stepRunID))
        #expect(after.snapshotJSON == before.snapshotJSON)
        #expect(after.snapshotSHA256 == before.snapshotSHA256)
    }

    // MARK: - 7: Relaunch reconstruction is identical

    @Test("Two independent relaunches reconstruct byte-identical provenance")
    func relaunchReconstructionIdentical() async throws {
        let url = PJE007Fixtures.newURL()
        let p = try await prepareSelect(url)
        let (_, stepRunID) = try await selectEntityAndGap(p)

        let rigA = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        let a = try await latestSnapshot(rigA, .stepRun(stepRunID))
        let rigB = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        let b = try await latestSnapshot(rigB, .stepRun(stepRunID))
        #expect(a.snapshotJSON == b.snapshotJSON)
        #expect(a.snapshotSHA256 == b.snapshotSHA256)
    }

    // MARK: - 8: Snapshot JSON tamper detected on reopen

    @Test("Tampering the snapshot JSON is detected on reopen (hash mismatch)")
    func snapshotJSONTamperDetected() async throws {
        let url = PJE007Fixtures.newURL()
        let p = try await prepareSelect(url)
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        try await p.rig.db.exec(
            "UPDATE workflow_provenance_snapshots SET snapshot_json = snapshot_json || ' ' WHERE id = ?;",
            [.uuid(latest.id)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 9: Snapshot hash tamper detected on reopen

    @Test("Tampering the stored snapshot hash is detected on reopen")
    func snapshotHashTamperDetected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        try await p.rig.db.exec(
            "UPDATE workflow_provenance_snapshots SET snapshot_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "0", count: 64)), .uuid(latest.id)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 10: Reference-row deletion changes count → detected

    @Test("Deleting the highest-ordinal reference row is detected as a count mismatch on reopen")
    func referenceCountMismatchDetected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        try await p.rig.db.exec("""
            DELETE FROM workflow_provenance_references
             WHERE snapshot_id = ? AND ordinal = (
                 SELECT MAX(ordinal) FROM workflow_provenance_references WHERE snapshot_id = ?);
            """, [.uuid(latest.id), .uuid(latest.id)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 11: Ordinal gap detected

    @Test("Deleting the first ordinal leaves an ordinal gap detected on reopen")
    func referenceOrdinalGapDetected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        try await p.rig.db.exec(
            "DELETE FROM workflow_provenance_references WHERE snapshot_id = ? AND ordinal = 0;",
            [.uuid(latest.id)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 12: Duplicate ordinal rejected by the schema

    @Test("A duplicate (snapshot_id, ordinal) reference row is rejected by the UNIQUE index")
    func duplicateOrdinalRejected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        let latest = try await latestSnapshot(p.rig, .stepRun(stepRunID))
        await #expect(throws: (any Error).self) {
            try await p.rig.db.exec("""
                INSERT INTO workflow_provenance_references
                    (id, snapshot_id, ordinal, reference_kind, canonical_object_id,
                     role, disposition, created_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(latest.id), .integer(0), .text("entity"),
                      .uuid(UUID()), .text("selected"), .text("active"), .real(0)])
        }
    }

    // MARK: - 13: Owner mismatch detected

    @Test("A snapshot whose JSON owner disagrees with its owner column is detected on reopen")
    func ownerMismatchDetected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "DELETE FROM workflow_provenance_snapshots WHERE step_run_id = ?;", [.uuid(stepRunID)])
        let wrongOwner = UUID()
        let snapshot = WorkflowProvenanceSnapshot(
            ownerKind: .stepState, workflowRunID: p.runID, ownerID: wrongOwner,
            workflowRunRevision: 2, producerID: "com.test", producerVersion: "1",
            sourceStateSHA256: String(repeating: "a", count: 64), references: [])
        try await PJE007Fixtures.craftSnapshotRow(
            p.rig.db, runID: p.runID, ownerColumn: .stepRun(stepRunID),
            revisionColumn: 2, snapshot: snapshot)
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 14: Revision beyond the run revision detected

    @Test("A snapshot whose revision exceeds the run revision is rejected on reopen")
    func revisionBeyondRunDetected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (after, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "DELETE FROM workflow_provenance_snapshots WHERE step_run_id = ?;", [.uuid(stepRunID)])
        let bigRevision = after.run.revision + 50
        let snapshot = WorkflowProvenanceSnapshot(
            ownerKind: .stepState, workflowRunID: p.runID, ownerID: stepRunID,
            workflowRunRevision: bigRevision,
            producerID: "com.test", producerVersion: "1",
            sourceStateSHA256: String(repeating: "a", count: 64), references: [])
        try await PJE007Fixtures.craftSnapshotRow(
            p.rig.db, runID: p.runID, ownerColumn: .stepRun(stepRunID),
            revisionColumn: bigRevision, snapshot: snapshot)
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 15: State-hash mismatch detected

    @Test("A step whose current state hash diverges from its latest snapshot is detected on reopen")
    func stateHashMismatchDetected() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "UPDATE workflow_step_runs SET state_sha256 = ? WHERE id = ?;",
            [.text(String(repeating: "e", count: 64)), .uuid(stepRunID)])
        // The PJE-006B.1 step-state hash guard fires first (WorkflowRunRepositoryError.
        // stepStateHashMismatch); either way a state/snapshot divergence fails closed.
        await #expect(throws: (any Error).self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 16: Missing snapshot for a snapshotV1 owner fails closed

    @Test("A snapshotV1 step with no snapshot rows fails closed on reopen")
    func missingSnapshotForV1FailsClosed() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "DELETE FROM workflow_provenance_snapshots WHERE step_run_id = ?;", [.uuid(stepRunID)])
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await p.rig.repo.fetchRun(p.runID)
        }
    }

    // MARK: - 17: Legacy rows reopen without provenance verification

    @Test("A legacyUntracked step reopens cleanly even with no snapshot")
    func legacyRowReopensWithoutVerification() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "DELETE FROM workflow_provenance_snapshots WHERE step_run_id = ?;", [.uuid(stepRunID)])
        try await p.rig.db.exec(
            "UPDATE workflow_step_runs SET provenance_semantics = 'legacyUntracked' WHERE id = ?;",
            [.uuid(stepRunID)])
        _ = try await p.rig.repo.fetchRun(p.runID)  // must not throw
    }

    // MARK: - 18: Legacy rows are not silently upgraded during read

    @Test("Reopening a legacyUntracked row does not upgrade its semantics")
    func legacyNotSilentlyUpgraded() async throws {
        let url = PJE007Fixtures.newURL()
        let p = try await prepareSelect(url)
        let (_, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "DELETE FROM workflow_provenance_snapshots WHERE step_run_id = ?;", [.uuid(stepRunID)])
        try await p.rig.db.exec(
            "UPDATE workflow_step_runs SET provenance_semantics = 'legacyUntracked' WHERE id = ?;",
            [.uuid(stepRunID)])
        let rig2 = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        _ = try await rig2.repo.fetchRun(p.runID)
        let semantics = try await rig2.repo.provenanceSemantics(owner: .stepRun(stepRunID))
        #expect(semantics == .legacyUntracked)
    }

    // MARK: - 19: A mutation upgrades a legacy row to snapshotV1

    @Test("Mutating a legacyUntracked step upgrades it to snapshotV1")
    func mutationUpgradesLegacyRow() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        let (_, stepRunID) = try await selectEntityAndGap(p)
        try await p.rig.db.exec(
            "UPDATE workflow_step_runs SET provenance_semantics = 'legacyUntracked' WHERE id = ?;",
            [.uuid(stepRunID)])
        let entity2 = try await PJE007Fixtures.seedEntity(p.rig.db, in: p.workspaceID)
        _ = try await PJE007Fixtures.exec(p.rig, runID: p.runID, SelectEvidenceStepCommand.select(
            kind: .entity, canonicalObjectID: entity2.uuidString, reason: "third"),
            at: t0.addingTimeInterval(200))
        let semantics = try await p.rig.repo.provenanceSemantics(owner: .stepRun(stepRunID))
        #expect(semantics == .snapshotV1)
    }

    // MARK: - 20: Artifact state + binding + provenance persist atomically

    @Test("A canonical attachment persists artifact, binding and a snapshotV1 provenance snapshot atomically")
    func artifactAndProvenanceAtomic() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "atomic")
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
            actor: PJE007Fixtures.human("analyst"), at: t0.addingTimeInterval(30))

        let artifact = try #require(after.artifacts.first)
        let semantics = try await rig.repo.provenanceSemantics(owner: .artifact(artifact.id))
        #expect(semantics == .snapshotV1)
        let binding = try await rig.repo.attachmentBinding(artifactID: artifact.id)
        #expect(binding != nil)
        let snaps = try await rig.repo.provenanceSnapshots(owner: .artifact(artifact.id))
        #expect(!snaps.isEmpty)
        _ = try await rig.repo.fetchRun(created.run.id)  // reopen verifies artifact provenance
    }

    // MARK: - 21: Decision basis + provenance persist atomically

    @Test("A human decision with a basis persists the decision and a snapshotV1 provenance snapshot atomically")
    func decisionBasisAndProvenanceAtomic() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let entityID = try await PJE007Fixtures.seedEntity(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.decisionPackage(suffix: "basis")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        _ = try await rig.engine.startRun(runID: runID, actor: .system, now: t0)

        var time = t0.addingTimeInterval(30)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, IntakeStepCommand.setTitle("Case"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, IntakeStepCommand.complete, at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.setQuestion("Proceed?"), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.setOptions(
            options: ["proceed", "halt"], mode: .humanRequired), at: time)
        time.addTimeInterval(10)
        _ = try await PJE007Fixtures.exec(rig, runID: runID, DecisionStepCommand.requestHumanDecision, at: time)

        time.addTimeInterval(10)
        let basis = [WorkflowProvenanceReference(
            kind: .entity, canonicalObjectID: entityID, role: .decisionBasis)]
        let decided = try await rig.engine.submitHumanDecision(
            runID: runID, decisionKey: "gate", selectedOption: "proceed",
            rationale: "sufficient", basis: basis,
            actor: PJE007Fixtures.human("owner"), at: time)

        let decision = try #require(decided.decisions.first { $0.kind == .humanDecision })
        let semantics = try await rig.repo.provenanceSemantics(owner: .decision(decision.id))
        #expect(semantics == .snapshotV1)
        let snap = try await latestSnapshot(rig, .decision(decision.id))
        let decoded = try WorkflowProvenanceCodec.decodeAndVerify(
            json: snap.snapshotJSON, expectedSHA256: snap.snapshotSHA256)
        #expect(decoded.references.map(\.canonicalObjectID) == [entityID])
        #expect(decoded.references.allSatisfy { $0.role == .decisionBasis })
    }

    // MARK: - 22: Injected failure rolls back state AND provenance

    @Test("An injected failure after the snapshot insert rolls back the artifact, binding, snapshot and revision")
    func injectedFailureRollsBackStateAndProvenance() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "rollback")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        let startRevision = created.run.revision

        let artifactID = UUID()
        let binding = WorkflowAttachmentBinding(
            artifactID: artifactID, logicalSourceID: src.fileID, sourceVersionID: src.svID,
            parentLogicalSourceID: nil, sourceRelation: nil, displayName: "Doc",
            mediaType: src.mediaType, byteCount: src.byteCount,
            sourceContentSHA256: src.contentHash, createdAt: t0)
        let provenance = try WorkflowProvenancePersistenceInput.make(
            snapshot: WorkflowProvenanceSnapshot(
                ownerKind: .artifact, workflowRunID: runID, ownerID: artifactID,
                workflowRunRevision: startRevision + 1,
                producerID: WorkflowProvenanceProducers.attachmentID,
                producerVersion: WorkflowProvenanceProducers.attachmentVersion,
                sourceStateSHA256: nil,
                references: [WorkflowProvenanceReference(
                    kind: .sourceVersion, canonicalObjectID: src.svID,
                    role: .attachmentSource, sourceVersionID: src.svID)]))

        await #expect(throws: (any Error).self) {
            _ = try await rig.repo.applyCanonicalAttachment(
                workflowRunID: runID, expectedRevision: startRevision,
                artifactID: artifactID, artifactDefinitionID: "art.x",
                supersedesArtifactID: nil, binding: binding, provenance: provenance,
                actor: .system, at: t0.addingTimeInterval(30),
                fault: { point in if point == .afterSnapshotInsert { throw TestFault() } })
        }
        let reopened = try await rig.repo.fetchRun(runID)
        #expect(reopened.run.revision == startRevision)
        #expect(reopened.artifacts.isEmpty)
        let binding2 = try await rig.repo.attachmentBinding(artifactID: artifactID)
        #expect(binding2 == nil)
        let snapCount = try await rig.db.query(
            "SELECT COUNT(*) FROM workflow_provenance_snapshots WHERE workflow_run_id = ?;", [.uuid(runID)])
        #expect(Int(snapCount.first?.int(0) ?? -1) == 0)
    }

    // MARK: - 23: No partial provenance references survive a rollback

    @Test("An injected failure before the event insert leaves no orphan provenance references")
    func noPartialProvenanceAfterRollback() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "partial")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let runID = created.run.id
        let artifactID = UUID()
        let binding = WorkflowAttachmentBinding(
            artifactID: artifactID, logicalSourceID: src.fileID, sourceVersionID: src.svID,
            parentLogicalSourceID: nil, sourceRelation: nil, displayName: "Doc",
            mediaType: src.mediaType, byteCount: src.byteCount,
            sourceContentSHA256: src.contentHash, createdAt: t0)
        let provenance = try WorkflowProvenancePersistenceInput.make(
            snapshot: WorkflowProvenanceSnapshot(
                ownerKind: .artifact, workflowRunID: runID, ownerID: artifactID,
                workflowRunRevision: created.run.revision + 1,
                producerID: WorkflowProvenanceProducers.attachmentID,
                producerVersion: WorkflowProvenanceProducers.attachmentVersion,
                sourceStateSHA256: nil,
                references: [WorkflowProvenanceReference(
                    kind: .sourceVersion, canonicalObjectID: src.svID,
                    role: .attachmentSource, sourceVersionID: src.svID)]))
        await #expect(throws: (any Error).self) {
            _ = try await rig.repo.applyCanonicalAttachment(
                workflowRunID: runID, expectedRevision: created.run.revision,
                artifactID: artifactID, artifactDefinitionID: "art.x",
                supersedesArtifactID: nil, binding: binding, provenance: provenance,
                actor: .system, at: t0.addingTimeInterval(30),
                fault: { point in if point == .beforeEventInsert { throw TestFault() } })
        }
        let refCount = try await rig.db.query(
            "SELECT COUNT(*) FROM workflow_provenance_references;", [])
        #expect(Int(refCount.first?.int(0) ?? -1) == 0)
    }

    // MARK: - 24: Every non-empty step run is snapshotV1

    @Test("Every non-empty step run in a run carries snapshotV1 provenance")
    func everyNonEmptyStepIsSnapshotV1() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        _ = try await selectEntityAndGap(p)
        _ = try await PJE007Fixtures.exec(p.rig, runID: p.runID, SelectEvidenceStepCommand.complete,
                                          at: t0.addingTimeInterval(120))
        let agg = try await p.rig.repo.fetchRun(p.runID)
        for stepRun in agg.stepRuns where !stepRun.stateJSON.isEmpty && stepRun.stateJSON != "{}" {
            let semantics = try await p.rig.repo.provenanceSemantics(owner: .stepRun(stepRun.id))
            #expect(semantics == .snapshotV1, "step \(stepRun.stepDefinitionID.rawValue) not snapshotV1")
        }
    }

    // MARK: - 25: Provenance snapshots cascade-delete with the run

    @Test("Deleting a run cascades to its provenance snapshots and references")
    func deleteRunCascadesProvenance() async throws {
        let p = try await prepareSelect(PJE007Fixtures.newURL())
        _ = try await selectEntityAndGap(p)
        try await p.rig.repo.delete(p.runID)
        let snaps = try await p.rig.db.query(
            "SELECT COUNT(*) FROM workflow_provenance_snapshots WHERE workflow_run_id = ?;", [.uuid(p.runID)])
        #expect(Int(snaps.first?.int(0) ?? -1) == 0)
        let refs = try await p.rig.db.query(
            "SELECT COUNT(*) FROM workflow_provenance_references;", [])
        #expect(Int(refs.first?.int(0) ?? -1) == 0)
    }
}
