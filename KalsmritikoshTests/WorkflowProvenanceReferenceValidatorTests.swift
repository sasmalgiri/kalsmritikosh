//
//  WorkflowProvenanceReferenceValidatorTests.swift
//  KalsmritikoshTests
//
//  PJE-007 — WorkflowProvenanceReferenceValidator: defense-in-depth revalidation
//  of executor-produced references through the evidence gate, plus ownership
//  checks on workflow-output references. Fail closed on any mismatch.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — provenance reference validator")
@MainActor
struct WorkflowProvenanceReferenceValidatorTests {

    private let t0 = PJE007Fixtures.t0

    private struct Rig {
        let base: PJE007Rig
        let wsA: UUID
        let wsB: UUID
        var db: Database { base.db }
        var validator: WorkflowProvenanceReferenceValidator { base.validator }
    }

    private func makeRig() async throws -> Rig {
        let base = try await PJE007Fixtures.makeRig(at: PJE007Fixtures.newURL())
        let wsA = UUID(), wsB = UUID()
        try await PJE007Fixtures.seedWorkspace(base.db, id: wsA)
        try await PJE007Fixtures.seedWorkspace(base.db, id: wsB)
        return Rig(base: base, wsA: wsA, wsB: wsB)
    }

    private func ref(
        _ kind: WorkflowProvenanceReferenceKind, _ id: UUID,
        role: WorkflowProvenanceRole = .supporting,
        locator: String? = nil
    ) -> WorkflowProvenanceReference {
        WorkflowProvenanceReference(
            kind: kind, canonicalObjectID: id, role: role, locatorJSON: locator)
    }

    private func seedContradiction(_ db: Database) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
        INSERT INTO contradictions (id, description, claim_a, claim_b, detected_at) VALUES (?,?,?,?,?);
        """, [.uuid(id), .text("d"), .text("a"), .text("b"), .real(t0.timeIntervalSince1970)])
        return id
    }

    private func seedIssue(_ db: Database, in ws: UUID) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
        INSERT INTO professional_issues
            (id, workspace_id, title, issue_type, status, priority, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(id), .uuid(ws), .text("Issue"), .text("factualDispute"),
              .text("open"), .text("medium"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        return id
    }

    private func seedWorkProductRun(_ db: Database, in ws: UUID) async throws -> UUID {
        let id = UUID()
        try await db.exec("""
        INSERT INTO work_product_runs
            (id, workspace_id, template, title, subject_label,
             schema_version, app_version, composed_at, finding_count)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(id), .uuid(ws), .text("chronology"), .text("WP"),
              .text("Subject"), .integer(1), .text("1.0"),
              .real(t0.timeIntervalSince1970), .integer(0)])
        return id
    }

    private func makeArtifact(_ rig: Rig, in ws: UUID) async throws -> (runID: UUID, artifactID: UUID) {
        let (pkg, wfID) = try PJE007Fixtures.attachmentPackage(suffix: "val-\(UUID().uuidString.prefix(8))")
        let created = try await rig.base.repo.createRun(
            package: pkg, selectedWorkflowID: wfID, workspaceID: ws,
            title: nil, parentRunID: nil, actorKind: .system, actorIdentifier: nil, now: t0)
        let agg = try await rig.base.repo.recordArtifact(
            runID: created.run.id, stepRunID: nil,
            artifactDefinitionID: "art.x", kind: .attachment, label: "A",
            workProductRunID: nil, targetKind: nil, targetID: nil, referenceURI: nil,
            mediaType: nil, contentSHA256: nil, metadataJSON: "{}",
            supersedesArtifactID: nil, expectedRevision: created.run.revision,
            actorKind: .system, actorIdentifier: nil, now: t0)
        return (created.run.id, try #require(agg.artifacts.first).id)
    }

    // MARK: - Canonical references

    @Test("Valid same-workspace canonical references pass")
    func sameWorkspacePasses() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.entity, entity, role: .selected)],
            workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("A missing canonical target fails closed")
    func missingTargetFails() async throws {
        let rig = try await makeRig()
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.entity, UUID())], workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }

    @Test("A cross-workspace canonical source fails closed")
    func crossWorkspaceFails() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsB)
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.entity, entity)], workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }

    @Test("A SensitiveScope-denied evidence reference fails closed")
    func scopeDeniedFails() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsA)
        _ = try await rig.base.scopes.assign(
            target: SensitiveScopeTarget(kind: .entity, id: entity),
            sensitivity: .confidential, authority: .systemRule(tag: "pje007-test"),
            reason: "test", at: t0)
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.entity, entity)], workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }

    @Test("A reference whose kind disagrees with the target type fails closed")
    func wrongKindFails() async throws {
        let rig = try await makeRig()
        let gap = try await PJE007Fixtures.seedGap(rig.db)
        // Claim the gap is an entity — the entity existence check fails.
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.entity, gap)], workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }

    @Test("A reference with malformed locator JSON is rejected")
    func malformedLocatorFails() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsA)
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.entity, entity, locator: "{not json")],
                workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }

    @Test("Empty references are accepted (a valid empty snapshot)")
    func emptyReferencesAccepted() async throws {
        let rig = try await makeRig()
        try await rig.validator.validate([], workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("A gap reference is global — existence is enough")
    func gapGlobalPasses() async throws {
        let rig = try await makeRig()
        let gap = try await PJE007Fixtures.seedGap(rig.db)
        try await rig.validator.validate(
            [ref(.gap, gap)], workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("A contradiction reference is global — existence is enough")
    func contradictionGlobalPasses() async throws {
        let rig = try await makeRig()
        let contra = try await seedContradiction(rig.db)
        try await rig.validator.validate(
            [ref(.contradiction, contra)], workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("An issue in the run's workspace passes")
    func issueInWorkspacePasses() async throws {
        let rig = try await makeRig()
        let issue = try await seedIssue(rig.db, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.issue, issue)], workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("An issue owned by another workspace fails closed")
    func issueCrossWorkspaceFails() async throws {
        let rig = try await makeRig()
        let issue = try await seedIssue(rig.db, in: rig.wsB)
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.issue, issue)], workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }

    @Test("A source version admitted to the workspace passes")
    func sourceVersionInWorkspacePasses() async throws {
        let rig = try await makeRig()
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.sourceVersion, src.svID, role: .attachmentSource)],
            workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    // MARK: - Workflow-output references (ownership, not evidence)

    @Test("A workflow artifact owned by the same run passes")
    func workflowArtifactSameRunPasses() async throws {
        let rig = try await makeRig()
        let (runID, artifactID) = try await makeArtifact(rig, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.workflowArtifact, artifactID, role: .generatedFrom)],
            workflowRunID: runID, workspaceID: rig.wsA)
    }

    @Test("A missing workflow artifact fails as canonicalTargetNotFound")
    func workflowArtifactMissingFails() async throws {
        let rig = try await makeRig()
        do {
            try await rig.validator.validate(
                [ref(.workflowArtifact, UUID(), role: .generatedFrom)],
                workflowRunID: UUID(), workspaceID: rig.wsA)
            Issue.record("Expected canonicalTargetNotFound")
        } catch WorkflowProvenanceError.canonicalTargetNotFound(let kind, _) {
            #expect(kind == .workflowArtifact)
        }
    }

    @Test("A workflow artifact owned by another run fails as cross-workspace")
    func workflowArtifactCrossRunFails() async throws {
        let rig = try await makeRig()
        let (_, artifactID) = try await makeArtifact(rig, in: rig.wsA)
        let (otherRun, _) = try await makeArtifact(rig, in: rig.wsA)
        do {
            try await rig.validator.validate(
                [ref(.workflowArtifact, artifactID, role: .generatedFrom)],
                workflowRunID: otherRun, workspaceID: rig.wsA)
            Issue.record("Expected crossWorkspaceReference")
        } catch WorkflowProvenanceError.crossWorkspaceReference(let kind, _) {
            #expect(kind == .workflowArtifact)
        }
    }

    @Test("A work-product run in the same workspace passes")
    func workProductRunSameWorkspacePasses() async throws {
        let rig = try await makeRig()
        let wprID = try await seedWorkProductRun(rig.db, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.workProductRun, wprID, role: .generatedFrom)],
            workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("A work-product run in another workspace fails as cross-workspace")
    func workProductRunCrossWorkspaceFails() async throws {
        let rig = try await makeRig()
        let wprID = try await seedWorkProductRun(rig.db, in: rig.wsB)
        do {
            try await rig.validator.validate(
                [ref(.workProductRun, wprID, role: .generatedFrom)],
                workflowRunID: UUID(), workspaceID: rig.wsA)
            Issue.record("Expected crossWorkspaceReference")
        } catch WorkflowProvenanceError.crossWorkspaceReference(let kind, _) {
            #expect(kind == .workProductRun)
        }
    }

    // MARK: - Multiple references / duplicates

    @Test("A mixed batch of valid references across kinds passes")
    func mixedValidBatchPasses() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsA)
        let gap = try await PJE007Fixtures.seedGap(rig.db)
        let issue = try await seedIssue(rig.db, in: rig.wsA)
        let src = try await PJE007Fixtures.seedSourceVersion(rig.db, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.entity, entity), ref(.gap, gap), ref(.issue, issue),
             ref(.sourceVersion, src.svID, role: .attachmentSource)],
            workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("Duplicate references are each validated (order preserved, no dedup)")
    func duplicateReferencesEachValidated() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsA)
        try await rig.validator.validate(
            [ref(.entity, entity), ref(.entity, entity)],
            workflowRunID: UUID(), workspaceID: rig.wsA)
    }

    @Test("One invalid reference in a batch fails the whole batch closed")
    func oneInvalidFailsBatch() async throws {
        let rig = try await makeRig()
        let entity = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsA)
        let foreign = try await PJE007Fixtures.seedEntity(rig.db, in: rig.wsB)
        await #expect(throws: WorkflowProvenanceError.self) {
            try await rig.validator.validate(
                [ref(.entity, entity), ref(.entity, foreign)],
                workflowRunID: UUID(), workspaceID: rig.wsA)
        }
    }
}
