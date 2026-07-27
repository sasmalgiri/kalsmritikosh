//
//  WorkProductScopeEnforcementTests.swift
//  KalsmritikoshTests
//
//  OPS-003C — verifies that WorkProductAssemblyService.compose() enforces
//  SensitiveScope before ANY composer sees the WorkProductContext, so blocked
//  claims cannot leak through text, IDs, hashes, or the manifest.
//
//  OPS-003C.2 adds: access is now mandatory; wrong purpose or mismatched workspace → denied;
//  no-bypass test 5 removed; four architecture-guard + no-leak proofs added instead.
//
//  Eight tests:
//  1. scopedAccessDeniedWhenRepoNotWired         — nil sensitiveScopes + access → throws
//  2. privilegedEvidenceKOBlockedFromExport      — privileged KO → 0 findings
//  3. nonPrivilegedEvidenceKOPermittedForExport  — no SSA → claim passes through
//  4. sensitivityCeilingBlocksRestrictedClaim    — restricted KO + internal ceiling → 0 findings
//  5. exportWithWrongPurposeDenied               — .screen purpose → scopedAccessDenied
//  6. exportWithMismatchedWorkspaceIDDenied      — wrong workspace ID → scopedAccessDenied
//  7. blockedClaimProducesEmptyManifestAndHashes — privileged KO → 0 findings, no hashes
//  8. privilegedTextAbsentFromAllSections        — privileged text never reaches any section
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("OPS-003C WorkProductScopeEnforcement")
struct WorkProductScopeEnforcementTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let scopes: SensitiveScopeRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let assembly: WorkProductAssemblyService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wpscope-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let asrt = AssertionsRepository(database: db)
        let tcs = TemporalClaimRepository(database: db)
        let events = EventsRepository(database: db)
        let claims = ClaimRepository(database: db)
        let store = EvidenceStore(database: db)
        let producer = ClaimProducer(
            genericFacts: gf, assertions: asrt, temporalClaims: tcs,
            events: events, claims: claims, evidence: store)
        let assembly = try WorkProductAssemblyService(
            database: db, events: events,
            contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        return Rig(db: db, workspaces: workspaces,
                   scopes: SensitiveScopeRepository(database: db),
                   genericFacts: gf, producer: producer, assembly: assembly)
    }

    // MARK: - Seed helpers

    /// Insert file + KO + source_version + evidence_block + evidence_block_object + GenericFact.
    /// Returns (fileID, koID). Call producer.backfill() after to materialise the Claim.
    @discardableResult
    private func seedFact(_ r: Rig, value: String) async throws -> (fileID: UUID, koID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await r.db.exec("""
        INSERT INTO files (id, url, source_type) VALUES (?,?,?);
        """, [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
        VALUES (?,?,?,?,?,1,?);
        """, [.uuid(svID), .uuid(fileID), .uuid(docID),
              .text(String(repeating: "a", count: 64)), .real(0), .real(0)])
        try await r.db.exec("""
        INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind,
            raw_text, normalized_text, extraction_method, extraction_confidence)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(blockID), .uuid(docID), .uuid(svID), .integer(0), .text("paragraph"),
              .text(value), .text(value), .text("native"), .real(1.0)])
        try await r.db.exec("""
        INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at)
        VALUES (?,?,?);
        """, [.uuid(blockID), .uuid(koID), .real(0)])
        try await r.genericFacts.upsert(GenericFact(
            id: UUID(), subjectID: nil, subjectLabel: "Doc", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [blockID]))
        return (fileID, koID)
    }

    /// Create a workspace with `fileID` as its sole source, derive membership.
    private func makeWorkspace(_ r: Rig, fileID: UUID) async throws -> Workspace {
        let wsID = UUID()
        let ws = Workspace(id: wsID, title: "Scope-Test WS", template: .general)
        try await r.workspaces.upsert(ws)
        try await r.workspaces.addSource(fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces)
            .deriveMembership(for: wsID)
        return ws
    }

    private func exportScope(workspaceID: UUID,
                             max: SensitivityLevel = .restricted,
                             privileged: Bool = false) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: workspaceID,
            maximumSensitivity: max,
            permitsPrivilegedMaterial: privileged,
            purpose: .export))
    }

    // MARK: - Test 1: nil repo → throws scopedAccessDenied

    @Test("scopedAccessDenied thrown when SensitiveScopeRepository not wired and access is provided")
    func scopedAccessDeniedWhenRepoNotWired() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wpscope-nilrepo-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let wsID = UUID()
        let workspaces = WorkspaceRepository(database: db)
        try await workspaces.upsert(Workspace(id: wsID, title: "W", template: .general))

        let claims = ClaimRepository(database: db)
        let resolver = ClaimResolver(claims: claims, reviews: ClaimReviewRepository(database: db))
        let selection = ClaimSelectionService(
            claims: claims, resolver: resolver,
            temporalClaims: TemporalClaimRepository(database: db),
            events: EventsRepository(database: db))
        let disclosures = DisclosureSelectionService(
            contradictions: ContradictionsRepository(database: db),
            claimContradictions: ClaimContradictionRepository(database: db),
            gaps: GapNodeRepository(database: db))
        // Designated init WITHOUT sensitiveScopes — it defaults to nil.
        let service = WorkProductAssemblyService(
            workspaces: workspaces,
            knowledgeObjects: KnowledgeObjectRepository(database: db),
            evidence: EvidenceStore(database: db),
            selection: selection, disclosures: disclosures,
            registry: try WorkProductComposerRegistry.makeDefault())

        let ws = Workspace(id: wsID, title: "W", template: .general)
        let access = exportScope(workspaceID: wsID)
        await #expect(throws: WorkProductAssemblyError.scopedAccessDenied) {
            try await service.compose(workspace: ws, template: .chronology,
                                      subjectLabel: "W", corpusSnapshotID: nil, access: access)
        }
    }

    // MARK: - Test 2: privileged KO → claim blocked

    @Test("Claim with privileged evidence KO is blocked from export by scope filter")
    func privilegedEvidenceKOBlockedFromExport() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "confidential fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        // Mark the KO as privileged — scope filter denies claims whose evidence KO is privileged
        // when the scope does not permit privileged material.
        try await r.scopes.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let withAccess = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportScope(workspaceID: ws.id, privileged: false))
        #expect(withAccess.manifest.selectedFindingCount == 0,
                "Privileged evidence KO should block the claim from the report.")
    }

    // MARK: - Test 3: non-privileged KO → claim permitted

    @Test("Claim with non-privileged evidence KO passes through scope filter")
    func nonPrivilegedEvidenceKOPermittedForExport() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "permitted fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        // Assign a non-privileged restricted sensitivity — scope ceiling is also restricted,
        // so the claim should still be permitted.
        try await r.scopes.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let withAccess = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportScope(workspaceID: ws.id, max: .restricted, privileged: false))
        #expect(withAccess.manifest.selectedFindingCount >= 1,
                "Non-privileged KO within scope ceiling should appear in the report.")
    }

    // MARK: - Test 4: sensitivity ceiling blocks claim

    @Test("Claim blocked when evidence KO sensitivity exceeds the scope ceiling")
    func sensitivityCeilingBlocksRestrictedClaim() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "restricted fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        // Restricted sensitivity, non-privileged — but scope ceiling is only internalLevel.
        try await r.scopes.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: false),
            reason: nil, at: t0)

        let withAccess = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportScope(workspaceID: ws.id, max: .internalLevel, privileged: false))
        #expect(withAccess.manifest.selectedFindingCount == 0,
                "KO at restricted sensitivity must be blocked when scope ceiling is internalLevel.")
    }

    // MARK: - OPS-003C.2: architecture guards and no-leak proofs

    @Test("compose throws scopedAccessDenied when access purpose is not .export")
    func exportWithWrongPurposeDenied() async throws {
        let r = try await rig()
        let (fileID, _) = try await seedFact(r, value: "any fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        // Wrong purpose: .screen instead of .export.
        let wrongPurpose = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: ws.id, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .screen))
        await #expect(throws: WorkProductAssemblyError.scopedAccessDenied) {
            try await r.assembly.compose(workspace: ws, template: .chronology,
                                         subjectLabel: ws.title, corpusSnapshotID: nil,
                                         access: wrongPurpose)
        }
    }

    @Test("compose throws scopedAccessDenied when access.workspaceID does not match workspace.id")
    func exportWithMismatchedWorkspaceIDDenied() async throws {
        let r = try await rig()
        let (fileID, _) = try await seedFact(r, value: "any fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        // Access scoped to a DIFFERENT workspace.
        let wrongWS = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: UUID(), maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
        await #expect(throws: WorkProductAssemblyError.scopedAccessDenied) {
            try await r.assembly.compose(workspace: ws, template: .chronology,
                                         subjectLabel: ws.title, corpusSnapshotID: nil,
                                         access: wrongWS)
        }
    }

    @Test("Blocked claim produces zero findings and no source hashes in the manifest")
    func blockedClaimProducesEmptyManifestAndHashes() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "privileged content")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        try await r.scopes.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let result = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportScope(workspaceID: ws.id, privileged: false))
        #expect(result.manifest.selectedFindingCount == 0,
                "Blocked claim must produce zero findings in the manifest.")
        #expect(result.manifest.sourceVersionIDs.isEmpty,
                "Blocked claim must produce no source version IDs in the manifest.")
        #expect(result.manifest.sourceHashes.isEmpty,
                "Blocked claim must produce no source hashes in the manifest.")
    }

    @Test("Privileged claim text is absent from every work-product section")
    func privilegedTextAbsentFromAllSections() async throws {
        let r = try await rig()
        let sentinelText = "PRIVILEGED-SENTINEL-\(UUID().uuidString)"
        let (fileID, koID) = try await seedFact(r, value: sentinelText)
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)

        try await r.scopes.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let result = try await r.assembly.compose(
            workspace: ws, template: .generalSummary,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportScope(workspaceID: ws.id, privileged: false))
        let allText = (result.workProduct.sections.flatMap(\.claims).map(\.text)
            + result.workProduct.sections.flatMap(\.preamble)).joined(separator: "\n")
        #expect(!allText.contains(sentinelText),
                "Privileged claim sentinel text must not appear in any section of the work product.")
    }
}
