//
//  WorkflowAttachmentCoordinatorTests.swift
//  KalsmritikoshTests
//
//  PJE-007 Part F — WorkflowAttachmentCoordinator: bind an ALREADY-INGESTED
//  canonical source version to a run as an attachment artifact. One source
//  store, one content hash, no duplicated bytes/text/EvidenceBlocks; canonical
//  fields resolved from the store (never trusted from the caller); corrections
//  are append-only via supersession; binding + mutation are atomic.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — attachment coordinator")
@MainActor
struct WorkflowAttachmentCoordinatorTests {

    private let t0 = PJE007Fixtures.t0

    private func coordinator(_ rig: PJE007Rig) -> WorkflowAttachmentCoordinator {
        WorkflowAttachmentCoordinator(
            workflowRuns: rig.repo, database: rig.db,
            sourceRelations: rig.sourceRelations, gate: rig.gate, scopes: rig.scopes)
    }

    private func count(_ db: Database, _ table: String) async throws -> Int {
        Int(try await db.query("SELECT COUNT(*) FROM \(table);", []).first?.int(0) ?? -1)
    }

    private struct Started {
        let rig: PJE007Rig
        let runID: UUID
        let ws: UUID
    }

    private func startedRun(suffix: String) async throws -> Started {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: suffix)
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        return Started(rig: rig, runID: created.run.id, ws: ws)
    }

    private func request(
        _ src: PJE007Fixtures.SeededSource,
        parent: UUID? = nil, relation: String? = nil, name: String = "Report.pdf"
    ) -> WorkflowCanonicalAttachmentRequest {
        WorkflowCanonicalAttachmentRequest(
            artifactDefinitionID: PJE007Fixtures.attachmentArtifactDefID,
            sourceVersionID: src.svID, parentLogicalSourceID: parent,
            expectedRelation: relation, displayName: name)
    }

    // MARK: - Happy path

    @Test("Binds an already-ingested canonical source version with fields resolved from the store")
    func bindsCanonicalSource() async throws {
        let s = try await startedRun(suffix: "bind")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws, mediaType: "application/pdf", bytes: 4096)
        let after = try await coordinator(s.rig).attachCanonicalSource(
            runID: s.runID, request: request(src), actor: PJE007Fixtures.human("a"), at: t0.addingTimeInterval(30))
        let artifact = try #require(after.artifacts.first)
        let binding = try #require(try await s.rig.repo.attachmentBinding(artifactID: artifact.id))
        #expect(binding.logicalSourceID == src.fileID)
        #expect(binding.sourceVersionID == src.svID)
        #expect(binding.sourceContentSHA256 == src.contentHash)
        #expect(binding.mediaType == "application/pdf")
        #expect(binding.byteCount == 4096)
    }

    @Test("Attaching does not duplicate source bytes: no new files or source versions")
    func noByteDuplication() async throws {
        let s = try await startedRun(suffix: "nodup")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let filesBefore = try await count(s.rig.db, "files")
        let versionsBefore = try await count(s.rig.db, "source_versions")
        _ = try await coordinator(s.rig).attachCanonicalSource(
            runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        #expect(try await count(s.rig.db, "files") == filesBefore)
        #expect(try await count(s.rig.db, "source_versions") == versionsBefore)
    }

    @Test("Attaching does not duplicate OCR text, chunks, or evidence blocks")
    func noDerivedDuplication() async throws {
        let s = try await startedRun(suffix: "noderiv")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let kos = try await count(s.rig.db, "knowledge_objects")
        let ebs = try await count(s.rig.db, "evidence_blocks")
        let chunks = try await count(s.rig.db, "chunks")
        _ = try await coordinator(s.rig).attachCanonicalSource(
            runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        #expect(try await count(s.rig.db, "knowledge_objects") == kos)
        #expect(try await count(s.rig.db, "evidence_blocks") == ebs)
        #expect(try await count(s.rig.db, "chunks") == chunks)
    }

    @Test("Parent email/attachment lineage is preserved via source_relations")
    func parentLineagePreserved() async throws {
        let s = try await startedRun(suffix: "parent")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let parentFile = UUID()
        try await s.rig.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                                [.uuid(parentFile), .text("file://parent"), .text("eml")])
        try await PJE007Fixtures.seedSourceRelation(
            s.rig.db, parent: parentFile, child: src.fileID, relation: "attachment")
        let relationsBefore = try await count(s.rig.db, "source_relations")
        let after = try await coordinator(s.rig).attachCanonicalSource(
            runID: s.runID,
            request: request(src, parent: parentFile, relation: "attachment"),
            actor: .system, at: t0.addingTimeInterval(30))
        let artifactID = try #require(after.artifacts.first).id
        let binding = try #require(try await s.rig.repo.attachmentBinding(artifactID: artifactID))
        #expect(binding.parentLogicalSourceID == parentFile)
        #expect(binding.sourceRelation == "attachment")
        // source_relations remains the authority — the coordinator never writes to it.
        #expect(try await count(s.rig.db, "source_relations") == relationsBefore)
    }

    @Test("Binding and workflow mutation are atomic (revision + one event + binding + snapshot)")
    func bindingAndMutationAtomic() async throws {
        let s = try await startedRun(suffix: "atomic")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let before = try await s.rig.repo.fetchRun(s.runID)
        let after = try await coordinator(s.rig).attachCanonicalSource(
            runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        #expect(after.run.revision == before.run.revision + 1)
        #expect(after.run.revision == after.events.count)  // exactly one new event
        let artifact = try #require(after.artifacts.first)
        #expect(try await s.rig.repo.attachmentBinding(artifactID: artifact.id) != nil)
        let semantics = try await s.rig.repo.provenanceSemantics(owner: .artifact(artifact.id))
        #expect(semantics == .snapshotV1)
    }

    // MARK: - Fail-closed validation

    @Test("A cross-workspace source version fails closed")
    func crossWorkspaceFails() async throws {
        let s = try await startedRun(suffix: "crossws")
        let wsB = UUID()
        try await PJE007Fixtures.seedWorkspace(s.rig.db, id: wsB)
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: wsB)  // not in the run's workspace
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        }
    }

    @Test("A missing source version fails closed")
    func missingSourceVersionFails() async throws {
        let s = try await startedRun(suffix: "missingsv")
        let bogus = PJE007Fixtures.SeededSource(
            fileID: UUID(), svID: UUID(), docID: UUID(),
            contentHash: String(repeating: "a", count: 64), mediaType: nil, byteCount: 0)
        do {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(bogus), actor: .system, at: t0.addingTimeInterval(30))
            Issue.record("Expected attachmentSourceVersionNotFound")
        } catch WorkflowProvenanceError.attachmentSourceVersionNotFound {
            // Expected
        }
    }

    @Test("A confidential source is access-denied under the default gate")
    func accessDeniedFails() async throws {
        let s = try await startedRun(suffix: "denied")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        _ = try await s.rig.scopes.assign(
            target: SensitiveScopeTarget(kind: .sourceVersion, id: src.svID),
            sensitivity: .confidential, authority: .systemRule(tag: "pje007"), reason: "t", at: t0)
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        }
    }

    @Test("A blank display name is rejected")
    func blankDisplayNameFails() async throws {
        let s = try await startedRun(suffix: "blank")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        do {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src, name: "   "), actor: .system, at: t0.addingTimeInterval(30))
            Issue.record("Expected displayNameBlank")
        } catch WorkflowAttachmentError.displayNameBlank {
            // Expected
        }
    }

    @Test("An unknown artifact definition on the current step is rejected")
    func artifactDefinitionNotFoundFails() async throws {
        let s = try await startedRun(suffix: "nodef")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let badRequest = WorkflowCanonicalAttachmentRequest(
            artifactDefinitionID: "art.does.not.exist",
            sourceVersionID: src.svID, displayName: "X")
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: badRequest, actor: .system, at: t0.addingTimeInterval(30))
        }
    }

    @Test("A work-product artifact definition cannot be used for an attachment")
    func workProductArtifactDefinitionRejected() async throws {
        let rig = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE007Fixtures.workProductArtifactPackage(suffix: "wpdef")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        let req = WorkflowCanonicalAttachmentRequest(
            artifactDefinitionID: PJE007Fixtures.workProductArtifactDefID,
            sourceVersionID: src.svID, displayName: "X")
        do {
            _ = try await coordinator(rig).attachCanonicalSource(
                runID: created.run.id, request: req, actor: .system, at: t0.addingTimeInterval(30))
            Issue.record("Expected artifactDefinitionIsWorkProduct")
        } catch WorkflowAttachmentError.artifactDefinitionIsWorkProduct {
            // Expected
        }
    }

    @Test("Attaching on a terminal run fails")
    func terminalRunFails() async throws {
        let s = try await startedRun(suffix: "terminal")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let current = try await s.rig.repo.fetchRun(s.runID)
        _ = try await s.rig.repo.updateRunState(
            runID: s.runID, newStatus: .cancelled,
            currentStepDefinitionID: current.run.currentStepDefinitionID, currentStepRunID: nil,
            timestamps: WorkflowRunTimestampPatch(), cancellationReason: "test",
            expectedRevision: current.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0.addingTimeInterval(20))
        do {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
            Issue.record("Expected runTerminal")
        } catch WorkflowAttachmentError.runTerminal {
            // Expected
        }
    }

    @Test("An expected parent relation that does not exist is rejected")
    func relationMismatchFails() async throws {
        let s = try await startedRun(suffix: "relmismatch")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let parentFile = UUID()
        try await s.rig.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                                [.uuid(parentFile), .text("file://p2"), .text("eml")])
        // No source_relations edge seeded → the parent link cannot be verified.
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src, parent: parentFile, relation: "attachment"),
                actor: .system, at: t0.addingTimeInterval(30))
        }
    }

    // MARK: - Supersession (append-only correction)

    @Test("A superseding attachment is append-only: the prior artifact survives")
    func supersedeIsAppendOnly() async throws {
        let s = try await startedRun(suffix: "supersede")
        let src1 = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws, hashChar: "a")
        let src2 = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws, hashChar: "b")
        let coord = coordinator(s.rig)
        let v1 = try await coord.attachCanonicalSource(
            runID: s.runID, request: request(src1, name: "v1.pdf"), actor: .system, at: t0.addingTimeInterval(30))
        let firstArtifact = try #require(v1.artifacts.first).id
        let v2 = try await coord.attachCanonicalSource(
            runID: s.runID, request: request(src2, name: "v2.pdf"), supersedes: firstArtifact,
            actor: .system, at: t0.addingTimeInterval(40))
        #expect(v2.artifacts.count == 2)  // both artifacts persist
        #expect(v2.artifacts.contains { $0.id == firstArtifact })
    }

    @Test("Superseding a non-attachment artifact is rejected")
    func supersedeNonAttachmentFails() async throws {
        let s = try await startedRun(suffix: "supnonatt")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let current = try await s.rig.repo.fetchRun(s.runID)
        let withArtifact = try await s.rig.repo.recordArtifact(
            runID: s.runID, stepRunID: nil,
            artifactDefinitionID: "art.report", kind: .generatedProduct, label: "R",
            workProductRunID: nil, targetKind: nil, targetID: nil, referenceURI: nil,
            mediaType: nil, contentSHA256: nil, metadataJSON: "{}",
            supersedesArtifactID: nil, expectedRevision: current.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0.addingTimeInterval(20))
        let generated = try #require(withArtifact.artifacts.first).id
        do {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src), supersedes: generated,
                actor: .system, at: t0.addingTimeInterval(30))
            Issue.record("Expected artifactKindMismatch")
        } catch WorkflowProvenanceError.artifactKindMismatch {
            // Expected
        }
    }

    @Test("Superseding a nonexistent artifact is rejected")
    func supersedeMissingFails() async throws {
        let s = try await startedRun(suffix: "supmissing")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        await #expect(throws: WorkflowProvenanceError.self) {
            _ = try await coordinator(s.rig).attachCanonicalSource(
                runID: s.runID, request: request(src), supersedes: UUID(),
                actor: .system, at: t0.addingTimeInterval(30))
        }
    }

    // MARK: - Reopen & integrity

    @Test("Reopening over the same file returns the exact attachment binding")
    func reopenReturnsExactBinding() async throws {
        let url = PJE007Fixtures.newURL()
        let rig = try await PJE007Fixtures.makeRig(at: url)
        let ws = UUID()
        try await PJE007Fixtures.seedWorkspace(rig.db, id: ws)
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "reopen")
        let created = try await rig.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        _ = try await rig.engine.startRun(runID: created.run.id, actor: .system, now: t0)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: ws)
        let after = try await coordinator(rig).attachCanonicalSource(
            runID: created.run.id, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        let artifactID = try #require(after.artifacts.first).id
        let before = try #require(try await rig.repo.attachmentBinding(artifactID: artifactID))

        let rig2 = try await PJE007Fixtures.makeRig(at: url, migrate: false)
        _ = try await rig2.repo.fetchRun(created.run.id)
        let reopened = try #require(try await rig2.repo.attachmentBinding(artifactID: artifactID))
        #expect(reopened == before)
    }

    @Test("A superseding source version does not silently replace the bound version")
    func supersededSourceVersionNotReplaced() async throws {
        let s = try await startedRun(suffix: "svsuper")
        let src = try await PJE007Fixtures.seedSourceVersion(s.rig.db, in: s.ws)
        let after = try await coordinator(s.rig).attachCanonicalSource(
            runID: s.runID, request: request(src), actor: .system, at: t0.addingTimeInterval(30))
        let artifactID = try #require(after.artifacts.first).id
        // A newer version supersedes the bound one and marks it non-current.
        let newerSV = UUID()
        try await s.rig.db.exec("""
        INSERT INTO source_versions
            (id, logical_source_id, document_id, content_hash, supersedes, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,?,1,?);
        """, [.uuid(newerSV), .uuid(src.fileID), .uuid(src.docID),
              .text(String(repeating: "c", count: 64)), .uuid(src.svID), .real(1), .real(1)])
        try await s.rig.db.exec("UPDATE source_versions SET is_current = 0 WHERE id = ?;", [.uuid(src.svID)])
        // The binding still points at the exact version that was attached.
        let binding = try #require(try await s.rig.repo.attachmentBinding(artifactID: artifactID))
        #expect(binding.sourceVersionID == src.svID)
    }
}
