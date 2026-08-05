//
//  InvestigationFindingsGoldClosureTests.swift
//  KalsmritikoshTests
//
//  INV-19 + INV-20 — the GOLD closure test (§16). One synthetic case with an authorized source A and an
//  UNauthorized source B, driven only through the real shared services, proves the whole findings→approval→
//  closure→export→reopen chain honours every truth boundary:
//    finding ≠ confirmed fact · closure ≠ absence of unresolved issues · export ≠ permission to widen scope ·
//    case complete ≠ professional correctness.
//  Sequence: build case-scoped findings (B absent from findings/citations/manifest) → human approve →
//  the case is NOT auto-closed by building/approving/exporting (no ClosureDecision ⇒ still open) → record a
//  human ClosureDecision WITH a documented unresolved limitation → the sealed receipt exports, the limitation
//  stays visible, B stays absent, and the custody hashes align across persistence → reopen preserves the
//  findings revision, the closure genealogy, and the identical receipt. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("INV-19+20 — gold findings→closure→export→reopen", .serialized)
struct InvestigationFindingsGoldClosureTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_300_000)

    private struct Rig {
        let db: Database
        let workspaces: WorkspaceRepository
        let genericFacts: GenericFactRepository
        let producer: ClaimProducer
        let cases: InvestigationCaseRepository
        let findings: InvestigationFindingsService
        let closure: InvestigationClosureService
    }

    private func rig() async throws -> Rig {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("invgold-\(UUID().uuidString).sqlite")
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
        let findings = InvestigationFindingsService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: store), workspaces: workspaces,
            assembly: assembly, runs: WorkProductRunRepository(database: db),
            approvals: InvestigationFindingsApprovalRepository(database: db))
        let closure = InvestigationClosureService(
            cases: cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            closures: InvestigationClosureRepository(database: db))
        return Rig(db: db, workspaces: workspaces, genericFacts: gf, producer: producer, cases: cases,
                   findings: findings, closure: closure)
    }

    @discardableResult
    private func seedFact(_ r: Rig, value: String) async throws -> (fileID: UUID, svID: UUID) {
        let fileID = UUID(), koID = UUID(), svID = UUID(), blockID = UUID(), docID = UUID()
        try await r.db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                            [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await r.db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(value), .real(0), .real(0)])
        try await r.db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at)
            VALUES (?,?,?,?,?,1,?);
            """, [.uuid(svID), .uuid(fileID), .uuid(docID), .text(String(repeating: "c", count: 64)), .real(0), .real(0)])
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
        return (fileID, svID)
    }

    private func exportAccess(_ wsID: UUID) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: wsID, maximumSensitivity: .restricted, permitsPrivilegedMaterial: false, purpose: .export))
    }

    private func status(_ db: Database, _ caseID: UUID) async throws -> String? {
        try await db.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first?.string(0)
    }

    @Test("Gold: findings→approve→(no auto-close)→close-with-limitation→sealed export→reopen, scope never widened")
    func goldFindingsClosureExportReopen() async throws {
        let r = try await rig()
        let sentinelA = "AUTHORIZED-A-\(UUID().uuidString)"
        let sentinelB = "UNAUTHORIZED-B-\(UUID().uuidString)"
        let a = try await seedFact(r, value: sentinelA)
        let b = try await seedFact(r, value: sentinelB)

        // Workspace holds BOTH sources; the case authorizes ONLY A.
        let wsID = UUID()
        try await r.workspaces.upsert(Workspace(id: wsID, title: "Matter", template: .general))
        try await r.workspaces.addSource(a.fileID, to: wsID)
        try await r.workspaces.addSource(b.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: r.db, workspaces: r.workspaces).deriveMembership(for: wsID)
        _ = try await r.producer.backfill(at: t0)
        var c = try await r.cases.createCase(workspaceID: wsID, title: "Payment discrepancy", actor: "analyst", at: t0)
        c = try await r.cases.includeSource(caseID: c.id, expectedRevision: c.revision,
                                            sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: "analyst", at: t0)

        // 1) Build case-scoped findings. B is structurally absent from findings, citations, and the manifest.
        let f = try await r.findings.buildFindings(caseID: c.id, access: exportAccess(wsID), actor: "lead", at: t0)
        let text0 = f.assembled.workProduct.sections.flatMap(\.claims).map(\.text).joined(separator: "\n")
        #expect(text0.contains(sentinelA) && !text0.contains(sentinelB))
        #expect(f.manifest.sourceVersionIDs.contains(a.svID.uuidString))
        #expect(!f.manifest.sourceVersionIDs.contains(b.svID.uuidString))
        #expect(!f.assembled.workProduct.allCitations.compactMap(\.sourceVersionID).contains(b.svID))
        #expect(!f.manifest.sourceHashes.isEmpty)     // A's custody hash is pinned

        // 2) Human approves the findings.
        let approval = try await r.findings.approveFindings(caseID: c.id, findings: f, rationale: "objectives met for the authorized scope", actor: "lead", at: t0)
        #expect(approval.workProductRunID == f.run.id && approval.receiptSeal == f.receipt.seal)

        // 3) Building + approving + producing a sealed receipt did NOT close the case — closure is never
        //    inferred. There is no ClosureDecision yet, so the case is still open.
        #expect(try await status(r.db, c.id) == "open")
        #expect(try await r.closure.latestClosure(caseID: c.id) == nil)

        // 4) Record the durable human ClosureDecision WITH a documented unresolved limitation (honest closure),
        //    referencing the approved run + the sealed receipt.
        let limitation = "Source B was outside the authorized case scope and was not reviewed"
        let closed = try await r.closure.closeCase(
            caseID: c.id, expectedRevision: c.revision, rationale: "closing with documented limitations",
            unresolvedItems: [limitation], workProductRunID: f.run.id, receiptSeal: f.receipt.seal, actor: "lead", at: t0)
        #expect(closed.decision == .closed)
        #expect(try await status(r.db, c.id) == "closed")

        // 5) The sealed export: the limitation stays visible in the durable closure record; the receipt seal is
        //    pinned; B is still absent when the immutable run is reopened; the custody hashes align.
        let latest = try await r.closure.latestClosure(caseID: c.id)
        #expect(latest?.unresolvedItems == [limitation])
        #expect(latest?.receiptSeal == f.receipt.seal && latest?.workProductRunID == f.run.id)
        let reopenedRun = try await r.findings.reopenFindings(runID: f.run.id)
        #expect(!reopenedRun.workProduct.allCitations.compactMap(\.sourceVersionID).contains(b.svID))
        #expect(reopenedRun.manifest.sourceVersionIDs == f.manifest.sourceVersionIDs)
        #expect(reopenedRun.manifest.sourceHashes == f.manifest.sourceHashes)                 // hashes align
        #expect(try WorkProductReceiptBuilder().build(from: reopenedRun).seal == f.receipt.seal) // report==receipt

        // 6) Reopen the CASE (INV-20): the genealogy is preserved, the findings revision + receipt are identical.
        let reopened = try await r.closure.reopenCase(caseID: c.id, expectedRevision: c.revision + 1,
                                                      rationale: "new evidence surfaced", actor: "lead", at: t0)
        #expect(reopened.decision == .reopened)
        #expect(try await status(r.db, c.id) == "open")
        let history = try await r.closure.closureHistory(caseID: c.id)
        #expect(history.map(\.decision) == [.closed, .reopened])
        #expect(history.first?.unresolvedItems == [limitation])          // the closure's limitation is never erased
        #expect(history.first?.workProductRunID == f.run.id)             // still references the same findings run
    }
}
