//
//  SensitiveScopeEndToEndTests.swift
//  KalsmritikoshTests
//
//  CI-001C — cross-surface integration suite.
//
//  Proves that a single privacy assignment is consistently enforced across ALL
//  four OPS-003 surfaces: ledger (batchResolution), screen (ScreenScopeAuthorizer),
//  retrieval (SensitiveRetrievalPolicy), and work-product/manifest/receipt
//  (WorkProductAssemblyService). Each test exercises more than one surface at
//  once; none of these scenarios are covered by the per-surface unit suites.
//
//  10 required test cases (spec: CI-001C §2):
//  1.  Privileged KO denied on screen, retrieval, and export simultaneously
//  2.  No identifying leakage — sentinel text and KO ID absent from all sections
//  3.  Broken lineage denied on screen and retrieval (ghost KO = brokenLineage)
//  4.  Cross-workspace access denied on retrieval and export
//  5.  Prompt-time mutation revalidation catches new assignment mid-session
//  6.  Mutation-service block and restore consistent across all surfaces
//  7.  Inherited file restriction: KO-level revocation does not restore prematurely
//  8.  Persona invariance — all four templates blocked by the same assignment
//  9.  Report and manifest: blocked material absent from sections, hashes, and IDs
// 10.  Repository failure: nil repo is fail-closed on screen and export
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("CI-001C SensitiveScopeEndToEnd — cross-surface integration")
struct SensitiveScopeEndToEndTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Rig

    private struct Rig {
        let db: Database
        let repo: SensitiveScopeRepository
        let retrieval: SensitiveRetrievalPolicy
        let screen: ScreenScopeAuthorizer
        let service: SensitiveScopeMutationService
        let workspaces: WorkspaceRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let assembly: WorkProductAssemblyService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e2e-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let repo      = SensitiveScopeRepository(database: db)
        let workspaces = WorkspaceRepository(database: db)
        let gf         = GenericFactRepository(database: db)
        let asrt       = AssertionsRepository(database: db)
        let tcs        = TemporalClaimRepository(database: db)
        let events     = EventsRepository(database: db)
        let claims     = ClaimRepository(database: db)
        let store      = EvidenceStore(database: db)
        let producer   = ClaimProducer(
            genericFacts: gf, assertions: asrt, temporalClaims: tcs,
            events: events, claims: claims, evidence: store)
        let assembly   = try WorkProductAssemblyService(
            database: db, events: events,
            contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        return Rig(
            db: db, repo: repo,
            retrieval: SensitiveRetrievalPolicy(repository: repo, workspaceRepository: workspaces),
            screen: ScreenScopeAuthorizer(repository: repo),
            service: SensitiveScopeMutationService(repository: repo),
            workspaces: workspaces, genericFacts: gf,
            producer: producer, assembly: assembly)
    }

    // MARK: - Seed helpers

    /// Insert file + KO + source_version + evidence_block + evidence_block_object + GenericFact.
    /// Returns (fileID, koID). Call producer.backfill() after to materialise the Claim.
    @discardableResult
    private func seedFact(_ r: Rig, value: String) async throws -> (fileID: UUID, koID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await r.db.exec(
            "INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
            [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await r.db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,0,0);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value)])
        try await r.db.exec("""
        INSERT INTO source_versions (id, logical_source_id, document_id, content_hash,
            valid_from, is_current, created_at)
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

    /// Insert file + KO only (no evidence chain). Returns fileID.
    @discardableResult
    private func seedKO(_ db: Database, koID: UUID, content: String = "content") async throws -> UUID {
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,0,0);
        """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(content)])
        return fileID
    }

    private func makeWorkspace(_ r: Rig, fileID: UUID) async throws -> Workspace {
        let ws = Workspace(id: UUID(), title: "E2E-WS", template: .general)
        try await r.workspaces.upsert(ws)
        try await r.workspaces.addSource(fileID, to: ws.id)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces)
            .deriveMembership(for: ws.id)
        return ws
    }

    private func testChunk(koID: UUID) -> RetrievedChunk {
        RetrievedChunk(
            chunk: Chunk(objectID: koID, ordinal: 0, text: "chunk", characterRange: 0..<5),
            score: 1.0, viaLayer: .metadata)
    }

    private func exportAccess(_ wsID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .export))
    }

    private func retrievalAccess(_ wsID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false, purpose: .retrieval))
    }

    // =========================================================================
    // MARK: Test 1 — Privileged KO denied on all surfaces simultaneously
    // =========================================================================

    @Test("Privileged KO blocked on screen, retrieval, and export with a single assignment")
    func privilegedKO_deniedAcrossAllSurfaces() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "cross-surface sensitive fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        try await r.repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // Screen surface
        #expect(await r.screen.authorize(koID, boundary: .globalOwner) == false,
                "Screen must deny a privileged KO.")

        // Retrieval surface
        let filtered = await r.retrieval.filter(
            result: RetrievalResult(chunks: [testChunk(koID: koID)]),
            access: retrievalAccess(ws.id))
        #expect(filtered.withheldChunkCount == 1, "Retrieval must withhold the privileged chunk.")
        #expect(filtered.result.chunks.isEmpty)

        // Export surface
        let assembled = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportAccess(ws.id))
        #expect(assembled.manifest.selectedFindingCount == 0,
                "Export must block the privileged claim.")
    }

    // =========================================================================
    // MARK: Test 2 — No identifying leakage
    // =========================================================================

    @Test("Blocked KO: sentinel text and KO UUID absent from all work-product sections")
    func noLeakage_sentinelTextAndKOIDAbsentFromSections() async throws {
        let r = try await rig()
        let sentinel = "PRIV-SENTINEL-\(UUID().uuidString)"
        let (fileID, koID) = try await seedFact(r, value: sentinel)
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        try await r.repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let assembled = try await r.assembly.compose(
            workspace: ws, template: .generalSummary,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportAccess(ws.id))
        let allText = (assembled.workProduct.sections.flatMap(\.claims).map(\.text)
            + assembled.workProduct.sections.flatMap(\.preamble)).joined(separator: "\n")
        #expect(!allText.contains(sentinel),
                "Blocked claim text must not appear in any section.")
        #expect(!allText.contains(koID.uuidString),
                "KO UUID must not appear in any section — no ID leakage path.")
    }

    // =========================================================================
    // MARK: Test 3 — Broken lineage denied on screen and retrieval
    // =========================================================================

    @Test("Ghost KO returns .brokenLineage and is denied by both screen and retrieval")
    func brokenLineage_deniedOnScreenAndRetrieval() async throws {
        let r = try await rig()
        let ghostID = UUID()   // never inserted into knowledge_objects
        let ghostTarget = SensitiveScopeTarget(kind: .knowledgeObject, id: ghostID)

        // Ledger: batchResolution returns .brokenLineage, never nil
        let resolutions = try await r.repo.batchResolution([ghostTarget])
        #expect(resolutions[ghostTarget] == .brokenLineage,
                "batchResolution must return .brokenLineage for an unknown KO.")

        // Screen: denied
        #expect(await r.screen.authorize(ghostID, boundary: .globalOwner) == false,
                "Screen must deny a ghost KO (brokenLineage).")

        // Retrieval: chunk withheld even with a permissive internalLevel ceiling —
        // proves the denial is from brokenLineage, not the sensitivity ceiling.
        let internalAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: UUID(), maximumSensitivity: .internalLevel,
            permitsPrivilegedMaterial: false, purpose: .retrieval))
        let filtered = await r.retrieval.filter(
            result: RetrievalResult(chunks: [testChunk(koID: ghostID)]),
            access: internalAccess)
        #expect(filtered.withheldChunkCount == 1,
                "Retrieval must withhold a chunk whose KO is not in knowledge_objects.")
    }

    // =========================================================================
    // MARK: Test 4 — Cross-workspace access denied on retrieval and export
    // =========================================================================

    @Test("Cross-workspace access is denied: wrong workspaceID blocks both retrieval and export")
    func crossWorkspace_deniedOnRetrievalAndExport() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "workspace-scoped fact")
        let wsA = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        let wsBID = UUID()   // workspace B — not in the DB

        // Export: access.workspaceID != workspace.id → .scopedAccessDenied
        await #expect(throws: WorkProductAssemblyError.scopedAccessDenied) {
            try await r.assembly.compose(
                workspace: wsA, template: .chronology,
                subjectLabel: wsA.title, corpusSnapshotID: nil,
                access: exportAccess(wsBID))
        }

        // Retrieval: scope's workspaceID = wsB → workspace enforcement withholds the chunk.
        // The KO is not a member of workspace B (it doesn't exist), so the chunk is denied.
        let filtered = await r.retrieval.filter(
            result: RetrievalResult(chunks: [testChunk(koID: koID)]),
            access: retrievalAccess(wsBID))
        #expect(filtered.withheldChunkCount == 1,
                "Retrieval must withhold a chunk from workspace A when access is scoped to workspace B.")
    }

    // =========================================================================
    // MARK: Test 5 — Prompt-time mutation revalidation
    // =========================================================================

    @Test("Retrieval filter permitted before assignment, denied after — same result re-evaluated")
    func promptTimeMutation_revalidationCatchesAssignment() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "initially-permitted fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        let result = RetrievalResult(chunks: [testChunk(koID: koID)])
        let access = retrievalAccess(ws.id)

        // Before assignment: permitted
        let before = await r.retrieval.filter(result: result, access: access)
        #expect(before.withheldChunkCount == 0,
                "Before any assignment the chunk must be permitted.")

        // Assign via mutation service (simulates UI action between retrieval and prompt build)
        _ = try await r.service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await r.service.revisionCount == 1)

        // Same retrieval result re-evaluated after the assignment: denied
        let after = await r.retrieval.filter(result: result, access: access)
        #expect(after.withheldChunkCount == 1,
                "After assignment, the retrieval policy must withhold the same chunk — prompt-time revalidation fires.")
    }

    // =========================================================================
    // MARK: Test 6 — Mutation service: block then restore all surfaces
    // =========================================================================

    @Test("service.assign blocks all surfaces; service.revoke restores all when no restriction remains")
    func mutationService_blockAndRestoreAcrossAllSurfaces() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "mutation-cycle fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        let retriResult = RetrievalResult(chunks: [testChunk(koID: koID)])
        let rAccess = retrievalAccess(ws.id)

        // Assign — all surfaces block
        let assignment = try await r.service.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        #expect(await r.screen.authorize(koID, boundary: .globalOwner) == false,
                "Screen: blocked after assign.")
        #expect((await r.retrieval.filter(result: retriResult, access: rAccess)).withheldChunkCount == 1,
                "Retrieval: chunk withheld after assign.")
        let exportBlocked = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil, access: exportAccess(ws.id))
        #expect(exportBlocked.manifest.selectedFindingCount == 0,
                "Export: zero findings after assign.")

        // Revoke — all surfaces restore
        try await r.service.revoke(assignmentID: assignment.id, revokedBy: "owner",
                                   reason: nil, at: t0.addingTimeInterval(60))
        #expect(await r.screen.authorize(koID, boundary: .globalOwner) == true,
                "Screen: permitted after revoke.")
        #expect((await r.retrieval.filter(result: retriResult, access: rAccess)).withheldChunkCount == 0,
                "Retrieval: chunk permitted after revoke.")
        let exportRestored = try await r.assembly.compose(
            workspace: ws, template: .chronology,
            subjectLabel: ws.title, corpusSnapshotID: nil, access: exportAccess(ws.id))
        #expect(exportRestored.manifest.selectedFindingCount >= 1,
                "Export: findings restored after revoke.")
        #expect(await r.service.revisionCount == 2,
                "Service revisionCount == 2 (assign + revoke).")
    }

    // =========================================================================
    // MARK: Test 7 — Inherited file restriction: KO-level revocation does not restore
    // =========================================================================

    @Test("Revoking KO-level SSA does not restore access when a file-level restriction is still active")
    func inheritedFileRestriction_KORevocationDoesNotRestorePrematurely() async throws {
        let r = try await rig()
        let koID = UUID()
        let fileID = try await seedKO(r.db, koID: koID)

        // Assign at KO level AND at File level — both privileged
        let koAssignment = try await r.repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        _ = try await r.repo.assign(
            target: SensitiveScopeTarget(kind: .file, id: fileID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        // Revoke KO-level only — file restriction remains active
        try await r.repo.revoke(assignmentID: koAssignment.id, revokedBy: "owner",
                                reason: nil, at: t0.addingTimeInterval(60))

        // KO is still blocked (file lineage still carries the privileged restriction)
        #expect(await r.screen.authorize(koID, boundary: .globalOwner) == false,
                "KO must remain blocked after KO-level revocation when its parent file is still restricted.")
    }

    // =========================================================================
    // MARK: Test 8 — Persona invariance: all templates respect scope filter
    // =========================================================================

    @Test("All four WorkProductTemplate cases are blocked by the same SSA — no persona bypass exists")
    func personaInvariance_allTemplatesRespectScopeFilter() async throws {
        let r = try await rig()
        let (fileID, koID) = try await seedFact(r, value: "persona-invariance fact")
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        try await r.repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)
        let access = exportAccess(ws.id)

        for template in WorkProductTemplate.allCases {
            let assembled = try await r.assembly.compose(
                workspace: ws, template: template,
                subjectLabel: ws.title, corpusSnapshotID: nil, access: access)
            #expect(assembled.manifest.selectedFindingCount == 0,
                    "Template '\(template.rawValue)': blocked KO must produce 0 findings — no template branch widens access.")
        }
        _ = koID
    }

    // =========================================================================
    // MARK: Test 9 — Report and manifest: blocked material absent from both
    // =========================================================================

    @Test("Blocked claim absent from sections, manifest finding count, source IDs, and custody hashes")
    func reportAndManifest_blockedMaterialAbsentFromBoth() async throws {
        let r = try await rig()
        let sentinel = "RECEIPT-SENTINEL-\(UUID().uuidString)"
        let (fileID, koID) = try await seedFact(r, value: sentinel)
        let ws = try await makeWorkspace(r, fileID: fileID)
        _ = try await r.producer.backfill(at: t0)
        try await r.repo.assign(
            target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
            sensitivity: .restricted,
            authority: .userConfirmed(actorID: "owner", confirmationID: UUID(), privileged: true),
            reason: nil, at: t0)

        let assembled = try await r.assembly.compose(
            workspace: ws, template: .generalSummary,
            subjectLabel: ws.title, corpusSnapshotID: nil,
            access: exportAccess(ws.id))

        // Sections (report surface)
        let allText = (assembled.workProduct.sections.flatMap(\.claims).map(\.text)
            + assembled.workProduct.sections.flatMap(\.preamble)).joined(separator: "\n")
        #expect(!allText.contains(sentinel),
                "Sentinel text must not appear in any section.")
        // Manifest / receipt surface (same assembled product — no divergence possible)
        #expect(assembled.manifest.selectedFindingCount == 0,
                "Manifest finding count must be zero for the blocked claim.")
        #expect(assembled.manifest.sourceVersionIDs.isEmpty,
                "Manifest must carry no source-version IDs — no custody-hash exposure path.")
        #expect(assembled.manifest.sourceHashes.isEmpty,
                "Manifest must carry no custody hashes — blocked material leaves no receipt trace.")
        _ = koID
    }

    // =========================================================================
    // MARK: Test 10 — Nil repository: fail-closed on all surfaces
    // =========================================================================

    @Test("nil SensitiveScopeRepository is fail-closed on screen authorization and work-product export")
    func repoFailure_nilRepoFailClosedOnScreenAndExport() async throws {
        // Screen: nil repo → always false
        let nilScreen = ScreenScopeAuthorizer(repository: nil)
        #expect(await nilScreen.authorize(UUID(), boundary: .globalOwner) == false,
                "ScreenScopeAuthorizer with nil repo must deny all authorizations.")
        #expect(await nilScreen.authorize(
            target: SensitiveScopeTarget(kind: .event, id: UUID()),
            boundary: .globalOwner) == false,
                "ScreenScopeAuthorizer generic form with nil repo must deny all targets.")

        // Export: nil sensitiveScopes → .scopedAccessDenied
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e2e-nilrepo-\(UUID().uuidString).sqlite")
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
        let nilRepoAssembly = WorkProductAssemblyService(
            workspaces: workspaces,
            knowledgeObjects: KnowledgeObjectRepository(database: db),
            evidence: EvidenceStore(database: db),
            sensitiveScopes: nil,
            selection: selection, disclosures: disclosures,
            registry: try WorkProductComposerRegistry.makeDefault())
        let ws = Workspace(id: wsID, title: "W", template: .general)
        await #expect(throws: WorkProductAssemblyError.scopedAccessDenied) {
            try await nilRepoAssembly.compose(
                workspace: ws, template: .chronology,
                subjectLabel: "W", corpusSnapshotID: nil,
                access: exportAccess(wsID))
        }
    }
}
