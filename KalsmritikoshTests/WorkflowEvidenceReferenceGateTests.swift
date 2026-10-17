//
//  WorkflowEvidenceReferenceGateTests.swift
//  KalsmritikoshTests
//
//  PJE-006B — CanonicalWorkflowEvidenceReferenceGate against a real v75 database:
//  existence, workspace boundary, issue ownership, global objects, and
//  SensitiveScope enforcement. 10 tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-006B — WorkflowEvidenceReferenceGate")
struct WorkflowEvidenceReferenceGateTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_000_000)

    private struct Rig {
        let db: Database
        let gate: CanonicalWorkflowEvidenceReferenceGate
        let scopeRepo: SensitiveScopeRepository
        let workspaceA: UUID
        let workspaceB: UUID
    }

    private func makeRig(scope: SensitiveScope? = nil) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: 77)
        let wsA = UUID(), wsB = UUID()
        for (ws, title) in [(wsA, "WS A"), (wsB, "WS B")] {
            try await db.exec("""
            INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
            VALUES (?,?,?,?,?);
            """, [.uuid(ws), .text(title), .text("general"),
                  .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        }
        let scopeRepo = SensitiveScopeRepository(database: db)
        let gate = CanonicalWorkflowEvidenceReferenceGate(
            database: db, scopeRepository: scopeRepo, scope: scope)
        return Rig(db: db, gate: gate, scopeRepo: scopeRepo, workspaceA: wsA, workspaceB: wsB)
    }

    /// Seeds file → KO → entity and adds the entity to `workspace` membership.
    private func seedEntity(_ rig: Rig, in workspace: UUID?) async throws -> UUID {
        let fileID = UUID(), koID = UUID(), entityID = UUID()
        try await rig.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(fileID), .text("file://gate-\(fileID)"), .text("txt")])
        try await rig.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        try await rig.db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id) VALUES (?,?,?,?,?);
        """, [.uuid(entityID), .text("person"), .text("E"),
              .text(entityID.uuidString.lowercased()), .uuid(koID)])
        if let workspace = workspace {
            try await rig.db.exec("""
            INSERT INTO workspace_entities (workspace_id, entity_id, added_at) VALUES (?,?,?);
            """, [.uuid(workspace), .uuid(entityID), .real(t0.timeIntervalSince1970)])
        }
        return entityID
    }

    private func seedIssue(_ rig: Rig, in workspace: UUID) async throws -> UUID {
        let issueID = UUID()
        try await rig.db.exec("""
        INSERT INTO professional_issues
            (id, workspace_id, title, issue_type, status, priority, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(issueID), .uuid(workspace), .text("Issue"), .text("factualDispute"),
              .text("open"), .text("medium"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        return issueID
    }

    @Test("entity in the run's workspace is permitted")
    func entityInWorkspacePermitted() async throws {
        let rig = try await makeRig()
        let entityID = try await seedEntity(rig, in: rig.workspaceA)
        let verdict = await rig.gate.verdict(
            kind: .entity, canonicalObjectID: entityID, workspaceID: rig.workspaceA)
        #expect(verdict == .permitted)
    }

    @Test("entity belonging exclusively to another workspace is denied")
    func entityCrossWorkspaceDenied() async throws {
        let rig = try await makeRig()
        let entityID = try await seedEntity(rig, in: rig.workspaceB)
        let verdict = await rig.gate.verdict(
            kind: .entity, canonicalObjectID: entityID, workspaceID: rig.workspaceA)
        #expect(!verdict.isPermitted)
    }

    @Test("nonexistent object is denied")
    func nonexistentDenied() async throws {
        let rig = try await makeRig()
        let verdict = await rig.gate.verdict(
            kind: .entity, canonicalObjectID: UUID(), workspaceID: rig.workspaceA)
        #expect(!verdict.isPermitted)
    }

    @Test("issue in the run's workspace is permitted")
    func issueInWorkspacePermitted() async throws {
        let rig = try await makeRig()
        let issueID = try await seedIssue(rig, in: rig.workspaceA)
        let verdict = await rig.gate.verdict(
            kind: .issue, canonicalObjectID: issueID, workspaceID: rig.workspaceA)
        #expect(verdict == .permitted)
    }

    @Test("issue owned by another workspace is denied")
    func issueCrossWorkspaceDenied() async throws {
        let rig = try await makeRig()
        let issueID = try await seedIssue(rig, in: rig.workspaceB)
        let verdict = await rig.gate.verdict(
            kind: .issue, canonicalObjectID: issueID, workspaceID: rig.workspaceA)
        #expect(!verdict.isPermitted)
    }

    @Test("gap and contradiction are global — existence is enough")
    func gapAndContradictionGlobal() async throws {
        let rig = try await makeRig()
        let gapID = UUID(), contradictionID = UUID()
        try await rig.db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, detected_at) VALUES (?,?,?,?,?);
        """, [.uuid(gapID), .text("sequenceHole"), .text("d"), .text("r"),
              .real(t0.timeIntervalSince1970)])
        try await rig.db.exec("""
        INSERT INTO contradictions (id, description, claim_a, claim_b, detected_at) VALUES (?,?,?,?,?);
        """, [.uuid(contradictionID), .text("d"), .text("a"), .text("b"),
              .real(t0.timeIntervalSince1970)])
        let gapVerdict = await rig.gate.verdict(
            kind: .gap, canonicalObjectID: gapID, workspaceID: rig.workspaceA)
        let contraVerdict = await rig.gate.verdict(
            kind: .contradiction, canonicalObjectID: contradictionID, workspaceID: rig.workspaceA)
        #expect(gapVerdict == .permitted)
        #expect(contraVerdict == .permitted)
        // But nonexistent ones are still denied
        let missing = await rig.gate.verdict(
            kind: .gap, canonicalObjectID: UUID(), workspaceID: rig.workspaceA)
        #expect(!missing.isPermitted)
    }

    @Test("unlabelled entity passes the fail-closed default (internal, non-privileged)")
    func unlabelledEntityPassesDefault() async throws {
        let rig = try await makeRig() // no scope
        let entityID = try await seedEntity(rig, in: rig.workspaceA)
        let verdict = await rig.gate.verdict(
            kind: .entity, canonicalObjectID: entityID, workspaceID: rig.workspaceA)
        #expect(verdict == .permitted)
    }

    @Test("confidential-labelled entity is denied with no active scope")
    func confidentialDeniedWithoutScope() async throws {
        let rig = try await makeRig() // no scope
        let entityID = try await seedEntity(rig, in: rig.workspaceA)
        _ = try await rig.scopeRepo.assign(
            target: SensitiveScopeTarget(kind: .entity, id: entityID),
            sensitivity: .confidential,
            authority: .systemRule(tag: "pje006b-test"),
            reason: "test", at: t0)
        let verdict = await rig.gate.verdict(
            kind: .entity, canonicalObjectID: entityID, workspaceID: rig.workspaceA)
        #expect(!verdict.isPermitted)
    }

    @Test("confidential-labelled entity is denied under a publicLevel scope")
    func confidentialDeniedUnderPublicScope() async throws {
        let rig = try await makeRig()
        let entityID = try await seedEntity(rig, in: rig.workspaceA)
        _ = try await rig.scopeRepo.assign(
            target: SensitiveScopeTarget(kind: .entity, id: entityID),
            sensitivity: .confidential,
            authority: .systemRule(tag: "pje006b-test"),
            reason: "test", at: t0)
        let publicScope = SensitiveScope(
            workspaceID: rig.workspaceA, maximumSensitivity: .publicLevel,
            permitsPrivilegedMaterial: false, purpose: .retrieval)
        let scopedGate = CanonicalWorkflowEvidenceReferenceGate(
            database: rig.db, scopeRepository: rig.scopeRepo, scope: publicScope)
        let verdict = await scopedGate.verdict(
            kind: .entity, canonicalObjectID: entityID, workspaceID: rig.workspaceA)
        #expect(!verdict.isPermitted)
    }

    // MARK: - F29 — composite objects are checked through their evidence

    /// Seeds file → KO, with the file held by `workspace` (nil = no workspace).
    private func seedKO(_ rig: Rig, in workspace: UUID?) async throws -> UUID {
        let fileID = UUID(), koID = UUID()
        try await rig.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(fileID), .text("file://gate-\(fileID)"), .text("txt")])
        try await rig.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("c"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        if let workspace {
            try await rig.db.exec("INSERT INTO workspace_sources (workspace_id, file_id, added_at) VALUES (?,?,?);",
                                  [.uuid(workspace), .uuid(fileID), .real(t0.timeIntervalSince1970)])
        }
        return koID
    }

    private func seedContradiction(_ rig: Rig, evidenceA: UUID?, evidenceB: UUID?) async throws -> UUID {
        let id = UUID()
        try await rig.db.exec("""
        INSERT INTO contradictions (id, description, claim_a, claim_b, evidence_a, evidence_b, detected_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(id), .text("d"), .text("a"), .text("b"),
              evidenceA.map { .uuid($0) } ?? .null, evidenceB.map { .uuid($0) } ?? .null,
              .real(t0.timeIntervalSince1970)])
        return id
    }

    @Test("F29 — a contradiction whose opposing evidence lives in another workspace is denied")
    func contradictionCrossWorkspaceEvidenceDenied() async throws {
        let rig = try await makeRig()
        let own = try await seedKO(rig, in: rig.workspaceA)
        let foreign = try await seedKO(rig, in: rig.workspaceB)
        let mixed = try await seedContradiction(rig, evidenceA: own, evidenceB: foreign)
        let clean = try await seedContradiction(rig, evidenceA: own, evidenceB: nil)
        #expect(!(await rig.gate.verdict(kind: .contradiction, canonicalObjectID: mixed, workspaceID: rig.workspaceA)).isPermitted)
        #expect(await rig.gate.verdict(kind: .contradiction, canonicalObjectID: clean, workspaceID: rig.workspaceA) == .permitted)
    }

    @Test("F29 — a contradiction built on confidential evidence is denied without a covering scope")
    func contradictionSensitiveEvidenceDenied() async throws {
        let rig = try await makeRig()
        let secret = try await seedKO(rig, in: rig.workspaceA)
        _ = try await rig.scopeRepo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: secret),
            sensitivity: .confidential, authority: .systemRule(tag: "f29-test"), reason: "test", at: t0)
        let contradiction = try await seedContradiction(rig, evidenceA: secret, evidenceB: nil)
        #expect(!(await rig.gate.verdict(kind: .contradiction, canonicalObjectID: contradiction, workspaceID: rig.workspaceA)).isPermitted)
    }

    @Test("F29 — a gap anchored on another workspace's event is denied")
    func gapCrossWorkspaceEventDenied() async throws {
        let rig = try await makeRig()
        let foreignKO = try await seedKO(rig, in: rig.workspaceB)
        let eventID = UUID(), gapID = UUID()
        try await rig.db.exec("""
        INSERT INTO events (id, kind, date, title, source_object_id) VALUES (?,?,?,?,?);
        """, [.uuid(eventID), .text("meeting"), .real(t0.timeIntervalSince1970), .text("E"), .uuid(foreignKO)])
        try await rig.db.exec("""
        INSERT INTO gap_nodes (id, kind, description, reason, before_event, detected_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(gapID), .text("sequenceHole"), .text("d"), .text("r"), .uuid(eventID),
              .real(t0.timeIntervalSince1970)])
        #expect(!(await rig.gate.verdict(kind: .gap, canonicalObjectID: gapID, workspaceID: rig.workspaceA)).isPermitted)
    }

    @Test("F29 — an own-workspace issue linked to another workspace's evidence is denied")
    func issueLinkedToForeignEvidenceDenied() async throws {
        let rig = try await makeRig()
        let issueID = try await seedIssue(rig, in: rig.workspaceA)
        let foreignEntity = try await seedEntity(rig, in: rig.workspaceB)
        try await rig.db.exec("""
        INSERT INTO professional_issue_links (id, issue_id, target_kind, target_id, link_role, created_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(UUID()), .uuid(issueID), .text("entity"), .uuid(foreignEntity), .text("supports"),
              .real(t0.timeIntervalSince1970)])
        #expect(!(await rig.gate.verdict(kind: .issue, canonicalObjectID: issueID, workspaceID: rig.workspaceA)).isPermitted)
    }

    @Test("F29 — under an explicit scope, a global object with unknown evidence is denied")
    func unknownLineageDeniedUnderScope() async throws {
        let rig = try await makeRig()
        let contradiction = try await seedContradiction(rig, evidenceA: nil, evidenceB: nil)
        let scope = SensitiveScope(workspaceID: rig.workspaceA, maximumSensitivity: .restricted,
                                   permitsPrivilegedMaterial: false, purpose: .retrieval)
        let scopedGate = CanonicalWorkflowEvidenceReferenceGate(
            database: rig.db, scopeRepository: rig.scopeRepo, scope: scope)
        #expect(!(await scopedGate.verdict(kind: .contradiction, canonicalObjectID: contradiction, workspaceID: rig.workspaceA)).isPermitted)
        // The unscoped default keeps the documented global-object behaviour.
        #expect(await rig.gate.verdict(kind: .contradiction, canonicalObjectID: contradiction, workspaceID: rig.workspaceA) == .permitted)
    }

    @Test("confidential-labelled entity is permitted under a covering scope")
    func confidentialPermittedUnderCoveringScope() async throws {
        let rig = try await makeRig()
        let entityID = try await seedEntity(rig, in: rig.workspaceA)
        _ = try await rig.scopeRepo.assign(
            target: SensitiveScopeTarget(kind: .entity, id: entityID),
            sensitivity: .confidential,
            authority: .systemRule(tag: "pje006b-test"),
            reason: "test", at: t0)
        let coveringScope = SensitiveScope(
            workspaceID: rig.workspaceA, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .retrieval)
        let scopedGate = CanonicalWorkflowEvidenceReferenceGate(
            database: rig.db, scopeRepository: rig.scopeRepo, scope: coveringScope)
        let verdict = await scopedGate.verdict(
            kind: .entity, canonicalObjectID: entityID, workspaceID: rig.workspaceA)
        #expect(verdict == .permitted)
    }
}
