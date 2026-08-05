//
//  InvestigationFindingsServiceTests.swift
//  KalsmritikoshTests
//
//  INV-19 — Findings & export. Proves: findings are a case-scoped work product over the SHARED assembly/run/
//  receipt engines, restricted to `case-authorized ∩ SensitiveScope` (an unauthorized workspace source is
//  structurally absent from the findings, citations, and manifest — no workspace fallback, no widening);
//  building does NOT approve; approval is an explicit recorded human decision (blank rationale/actor/seal
//  refused); approval genealogy survives a withdrawal; the receipt is built from the SAME assembled product
//  as the report (report==receipt) and reopens deterministically. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("INV-19 — case findings & export", .serialized)
struct InvestigationFindingsServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_200_000)

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let cases: InvestigationCaseRepository
        let service: InvestigationFindingsService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("invfind-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let workspaces = WorkspaceRepository(database: db)
        let gf = GenericFactRepository(database: db)
        let events = EventsRepository(database: db)
        let store = EvidenceStore(database: db)
        let producer = ClaimProducer(
            genericFacts: gf, assertions: AssertionsRepository(database: db),
            temporalClaims: TemporalClaimRepository(database: db), events: events,
            claims: ClaimRepository(database: db), evidence: store)
        let assembly = try WorkProductAssemblyService(
            database: db, events: events, contradictions: ContradictionsRepository(database: db),
            gaps: GapNodeRepository(database: db), workspaces: workspaces)
        let cases = InvestigationCaseRepository(database: db)
        let service = InvestigationFindingsService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: store), workspaces: workspaces,
            assembly: assembly, runs: WorkProductRunRepository(database: db),
            approvals: InvestigationFindingsApprovalRepository(database: db))
        return Rig(db: db, workspaces: workspaces, genericFacts: gf, producer: producer, cases: cases, service: service)
    }

    /// Insert file + KO + source_version + block + block↔KO + GenericFact. Returns (fileID, koID, svID).
    @discardableResult
    private func seedFact(_ r: Rig, value: String) async throws -> (fileID: UUID, koID: UUID, svID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await r.db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value), .real(0), .real(0)])
        try await r.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
            VALUES (?,?,?,?,?,1,?);
            """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(String(repeating: "b", count: 64)), .real(0), .real(0)])
        try await r.db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(blockID), .uuid(docID), .uuid(svID), .integer(0), .text("paragraph"),
                  .text(value), .text(value), .text("native"), .real(1.0)])
        try await r.db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?,?,?);",
                            [.uuid(blockID), .uuid(koID), .real(0)])
        try await r.genericFacts.upsert(GenericFact(
            id: UUID(), subjectID: nil, subjectLabel: "Doc", field: "event", value: value,
            assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
            confidence: 0.9, sourceBlockIDs: [blockID]))
        return (fileID, koID, svID)
    }

    private func makeWorkspace(_ r: Rig, files: [UUID]) async throws -> Workspace {
        let wsID = UUID()
        let ws = Workspace(id: wsID, title: "Case WS", template: .general)
        try await r.workspaces.upsert(ws)
        for f in files { try await r.workspaces.addSource(f, to: wsID) }
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        return ws
    }

    private func exportAccess(_ wsID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
    }

    /// Build a case in `ws` authorizing exactly the given source versions (.sourceVersion drill-through).
    private func makeCase(_ r: Rig, ws: UUID, authorize: [UUID]) async throws -> InvestigationCase {
        var c = try await r.cases.createCase(workspaceID: ws, title: "Payment discrepancy", actor: "analyst", at: t0)
        for v in authorize {
            c = try await r.cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                                sourceRef: v.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)
        }
        return c
    }

    // MARK: - Tests

    @Test("Findings are case-scoped: an unauthorized workspace source is absent from findings, citations, and the manifest")
    func caseScopedFindingsExcludeUnauthorizedSource() async throws {
        let r = try await rig()
        let sentinelA = "AUTHORIZED-A-\(UUID().uuidString)"
        let sentinelB = "UNAUTHORIZED-B-\(UUID().uuidString)"
        let a = try await seedFact(r, value: sentinelA)
        let b = try await seedFact(r, value: sentinelB)
        let ws = try await makeWorkspace(r, files: [a.fileID, b.fileID])   // BOTH sources in the workspace
        _ = try await r.producer.backfill(at: t0)
        let c = try await makeCase(r, ws: ws.id, authorize: [a.svID])       // case authorizes ONLY A

        let findings = try await r.service.buildFindings(caseID: c.id, access: exportAccess(ws.id), actor: "lead", at: t0)

        // A is present; B is structurally absent from the manifest source versions.
        #expect(findings.manifest.sourceVersionIDs.contains(a.svID.uuidString))
        #expect(!findings.manifest.sourceVersionIDs.contains(b.svID.uuidString))
        #expect(findings.authorizedSourceVersionIDs == [a.svID])
        // B's text never reaches any section of the findings; A's does.
        let allText = (findings.assembled.workProduct.sections.flatMap(\.claims).map(\.text)
            + findings.assembled.workProduct.sections.flatMap(\.preamble)).joined(separator: "\n")
        #expect(allText.contains(sentinelA))
        #expect(!allText.contains(sentinelB))
        // No citation reopens the unauthorized version.
        let citedVersions = findings.assembled.workProduct.allCitations.compactMap(\.sourceVersionID)
        #expect(!citedVersions.contains(b.svID))
    }

    @Test("Approval is an explicit human decision (rationale + actor required); building findings never approves")
    func approvalRequiresHumanDecision() async throws {
        let r = try await rig()
        let a = try await seedFact(r, value: "fact \(UUID().uuidString)")
        let ws = try await makeWorkspace(r, files: [a.fileID])
        _ = try await r.producer.backfill(at: t0)
        let c = try await makeCase(r, ws: ws.id, authorize: [a.svID])
        let f = try await r.service.buildFindings(caseID: c.id, access: exportAccess(ws.id), actor: "lead", at: t0)

        // Building does NOT approve.
        #expect(try await r.service.latestApproval(caseID: c.id) == nil)
        // Blank rationale / actor are refused.
        await #expect(throws: InvestigationFindingsError.self) {
            _ = try await r.service.approveFindings(caseID: c.id, findings: f, rationale: "  ", actor: "lead", at: t0)
        }
        await #expect(throws: InvestigationFindingsError.self) {
            _ = try await r.service.approveFindings(caseID: c.id, findings: f, rationale: "approved", actor: " ", at: t0)
        }
        #expect(try await r.service.latestApproval(caseID: c.id) == nil)   // still not approved
    }

    @Test("Approval records the run + sealed receipt + scope fingerprint; a withdrawal preserves the genealogy")
    func approvalRecordsAndGenealogy() async throws {
        let r = try await rig()
        let a = try await seedFact(r, value: "fact \(UUID().uuidString)")
        let ws = try await makeWorkspace(r, files: [a.fileID])
        _ = try await r.producer.backfill(at: t0)
        let c = try await makeCase(r, ws: ws.id, authorize: [a.svID])
        let f = try await r.service.buildFindings(caseID: c.id, access: exportAccess(ws.id), actor: "lead", at: t0)

        let approved = try await r.service.approveFindings(caseID: c.id, findings: f, rationale: "objectives met", actor: "lead", at: t0)
        #expect(approved.decision == .approved)
        #expect(approved.workProductRunID == f.run.id)
        #expect(approved.receiptSeal == f.receipt.seal && !f.receipt.seal.isEmpty)
        #expect(approved.scopeFingerprint == f.scopeFingerprint && approved.scopeFingerprint.value.count == 64)

        let withdrawn = try await r.service.withdrawApproval(caseID: c.id, findings: f, rationale: "new evidence", actor: "lead", at: t0)
        #expect(withdrawn.decision == .withdrawn && withdrawn.sequence == approved.sequence + 1)
        let history = try await r.service.approvalHistory(caseID: c.id)
        #expect(history.map(\.decision) == [.approved, .withdrawn])
        #expect(history.first?.workProductRunID == f.run.id)   // the prior approval is intact
    }

    @Test("Report==receipt: the receipt is built from the SAME product, and the run reopens to the identical seal")
    func reportEqualsReceiptAndReopens() async throws {
        let r = try await rig()
        let a = try await seedFact(r, value: "fact \(UUID().uuidString)")
        let ws = try await makeWorkspace(r, files: [a.fileID])
        _ = try await r.producer.backfill(at: t0)
        let c = try await makeCase(r, ws: ws.id, authorize: [a.svID])
        let f = try await r.service.buildFindings(caseID: c.id, access: exportAccess(ws.id), actor: "lead", at: t0)

        // The reopened immutable run rebuilds to the identical sealed receipt (report==receipt integrity).
        let reopened = try await r.service.reopenFindings(runID: f.run.id)
        let rebuiltSeal = try WorkProductReceiptBuilder().build(from: reopened).seal
        #expect(rebuiltSeal == f.receipt.seal)
    }

    @Test("Building findings for export requires an export-purpose access; a non-export purpose is denied")
    func buildRequiresExportPurpose() async throws {
        let r = try await rig()
        let a = try await seedFact(r, value: "fact \(UUID().uuidString)")
        let ws = try await makeWorkspace(r, files: [a.fileID])
        _ = try await r.producer.backfill(at: t0)
        let c = try await makeCase(r, ws: ws.id, authorize: [a.svID])
        let screenAccess = SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: ws.id, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .screen))
        await #expect(throws: WorkProductAssemblyError.self) {
            _ = try await r.service.buildFindings(caseID: c.id, access: screenAccess, actor: "lead", at: t0)
        }
    }
}
