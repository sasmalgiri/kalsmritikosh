//
//  WorkProductHandoffModelTests.swift
//  KalsmritikoshTests
//
//  #146 (Handoff / Review). Proves the production handoff surface's model reads a matter's real handoff state
//  from the SHARED case authorities (findings approval + closure + custody) via the persona-neutral
//  WorkProductHandoffService, and records the HUMAN-ONLY decisions (build findings → approve/withdraw →
//  close/reopen) into the real services — the same production path the acceptance suites drive, now reachable
//  from the UI. Truth boundaries proven: approval and closure are never inferred; closure retains the accepted
//  unresolved items; reopening preserves the prior decision; a decision without a rationale fails closed.
//  Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@MainActor
@Suite("Handoff/Review model", .serialized)
struct WorkProductHandoffModelTests {

    private let t0 = Date(timeIntervalSince1970: 1_769_100_000)

    /// Build the handoff model over the shared authorities + a real open matter with one authorized source.
    private func makeModel() async throws -> (WorkProductHandoffModel, caseID: UUID, harness: PersonaAcceptanceHarness) {
        let h = try await PersonaAcceptanceHarness.make(seed: "handoff")
        // Seed one authorized source and a workspace holding it.
        // hashChar MUST be a hex digit — content hashes are validated as 64-char hex SHA-256, and the sealed
        // findings receipt fails closed on any authorized version lacking a valid custody hash. The distinctive
        // ACMESECRET token lets the export redaction test assert removal without a manifest false-positive.
        let a = try await h.seedFact(value: "ACMESECRET finding \(UUID().uuidString)", hashChar: "c")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Handoff Matter", template: .investigation))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        // Open a real matter and authorize the source into its scope.
        let created = try await h.cases.createCase(workspaceID: wsID, title: "Handoff Matter", actor: "me", at: t0)
        _ = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                            sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: "me", at: t0)
        // Build the persona-neutral handoff read-service + a fresh custody service over the same ledger.
        let store = EvidenceStore(database: h.db)
        let custody = InvestigationCustodyService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            evidence: store, custody: CustodyRepository(database: h.db), database: h.db)
        let handoff = WorkProductHandoffService(cases: h.cases, findings: h.findings, closure: h.closure, custody: custody)
        let model = WorkProductHandoffModel(handoff: handoff, findings: h.findings, closure: h.closure)
        return (model, created.id, h)
    }

    @Test("Loading a matter reads its real handoff snapshot from the shared authorities")
    func loadsSnapshot() async throws {
        let (model, caseID, _) = try await makeModel()
        await model.load(caseID: caseID)
        let snap = try #require(model.snapshot)
        #expect(snap.caseID == caseID)
        #expect(snap.status == .open && !snap.isClosed)
        #expect(!snap.isApproved)                 // approval is never inferred — nothing approved yet
        #expect(snap.approvalHistory.isEmpty)
        #expect(snap.closureHistory.isEmpty)
        #expect(snap.custody.count == 1)          // exactly the one authorized source version
        #expect(model.lastError == nil)
    }

    @Test("Build → approve → close (with unresolved) → reopen all route into the real services and are recorded")
    func approveCloseReopen() async throws {
        let (model, caseID, _) = try await makeModel()
        await model.load(caseID: caseID)
        // Build the findings work product (does not approve or close).
        await model.buildFindings(actor: "me", at: t0)
        #expect(model.built != nil)
        #expect(model.lastError == nil)
        // Approve: requires a rationale, then the snapshot reflects the recorded approval.
        model.rationale = "reviewed and ready"
        await model.approve(actor: "me", at: t0)
        #expect(model.lastError == nil)
        #expect(model.snapshot?.isApproved == true)
        #expect(model.snapshot?.approvalHistory.last?.decision == .approved)
        // Close honestly with a retained unresolved item.
        model.rationale = "closing after review"
        model.unresolvedText = "One document could not be authenticated"
        await model.close(actor: "me", at: t0)
        #expect(model.lastError == nil)
        #expect(model.snapshot?.isClosed == true)
        let closure = try #require(model.snapshot?.closureHistory.last)
        #expect(closure.decision == .closed)
        #expect(closure.unresolvedItems == ["One document could not be authenticated"])   // retained, not erased
        // Reopen preserves the prior closure (genealogy).
        model.rationale = "new material arrived"
        await model.reopen(actor: "me", at: t0)
        #expect(model.lastError == nil)
        #expect(model.snapshot?.isClosed == false)
        #expect(model.snapshot?.closureHistory.map(\.decision) == [.closed, .reopened])
    }

    @Test("Human decisions fail closed: approve-before-build and empty-rationale record nothing")
    func failsClosed() async throws {
        let (model, caseID, _) = try await makeModel()
        await model.load(caseID: caseID)
        // Approve before building findings → clear error, nothing recorded.
        await model.approve(actor: "me", at: t0)
        #expect(model.lastError != nil)
        #expect(model.snapshot?.approvalHistory.isEmpty == true)
        // Close with an empty rationale → clear error, still open.
        model.rationale = "   "
        await model.close(actor: "me", at: t0)
        #expect(model.lastError != nil)
        #expect(model.snapshot?.isClosed == false)
        #expect(model.snapshot?.closureHistory.isEmpty == true)
    }

    @Test("Built findings export to valid file bytes (DOCX/PDF) and honor optional redaction")
    func exportBuiltFindings() async throws {
        let (model, caseID, _) = try await makeModel()
        await model.load(caseID: caseID)
        await model.buildFindings(actor: "me", at: t0)
        try #require(model.built != nil)
        // DOCX is a ZIP package.
        model.exportFormat = .docx
        #expect(Array((try model.exportData()).prefix(4)) == [0x50, 0x4b, 0x03, 0x04])
        // PDF is a valid PDF.
        model.exportFormat = .pdf
        #expect(Array((try model.exportData()).prefix(5)) == Array("%PDF-".utf8))
        // Markdown carries the seeded finding token; redaction removes it and inserts the token.
        model.exportFormat = .markdown
        let plain = String(decoding: try model.exportData(), as: UTF8.self)
        #expect(plain.contains("ACMESECRET"))
        model.exportRedactionTerms = "ACMESECRET"
        let redacted = String(decoding: try model.exportData(), as: UTF8.self)
        #expect(!redacted.contains("ACMESECRET") && redacted.contains("[REDACTED]"))
    }
}
