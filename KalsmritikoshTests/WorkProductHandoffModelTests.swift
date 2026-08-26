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
import CryptoKit
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

    /// PHASE C — approval, sealed assessment and governance event commit in
    /// ONE savepoint: when the composite cannot write, the approval is
    /// REFUSED and NOTHING exists afterward — not even a withdrawn pair.
    /// (Compensation is gone; no partial state can be observed.)
    @Test("Atomic approval: a failing composite refuses — nothing is written")
    func atomicApprovalRefusesOnFailure() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "handoff-comp")
        let a = try await h.seedFact(value: "COMP finding \(UUID().uuidString)", hashChar: "d")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Comp Matter", template: .investigation))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        var created = try await h.cases.createCase(workspaceID: wsID, title: "Comp Matter", actor: "me", at: t0)
        created = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                                  sourceRef: a.svID.uuidString, sourceKind: .sourceVersion,
                                                  actor: "me", at: t0)
        // The intake decision the doctrine requires: scope explicitly confirmed.
        _ = try await h.cases.confirmScope(caseID: created.id, expectedRevision: created.revision, actor: "me", at: t0)
        let store = EvidenceStore(database: h.db)
        let custody = InvestigationCustodyService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            evidence: store, custody: CustodyRepository(database: h.db), database: h.db)
        let handoff = WorkProductHandoffService(cases: h.cases, findings: h.findings, closure: h.closure, custody: custody)
        // BROKEN assessments repository: a database with NO schema, so the
        // conformance insert throws while everything else works.
        let brokenDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("comp-broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        let brokenDB = try Database(url: brokenDir.appendingPathComponent("empty.sqlite"))
        let brokenRepo = ConformanceAssessmentRepository(database: brokenDB)
        let brokenTxn = ApprovalTransactionRepository(database: brokenDB)
        let model = WorkProductHandoffModel(handoff: handoff, findings: h.findings, closure: h.closure,
                                            assessments: brokenRepo, approvalTxn: brokenTxn)
        model.sealingKeyOverride = P256.Signing.PrivateKey()
        await model.load(caseID: created.id)
        await model.buildFindings(actor: "me", at: t0)
        #expect(model.built != nil)
        // Satisfy the conformance GATE: attest every rule of the reached phases.
        let frozen = try #require(model.frozenSutra)
        let reached = model.conformanceFacts().completedPhaseKinds
        for rule in SutraRuleCompiler.rules(for: frozen)
        where rule.phaseKind.map(reached.contains) ?? true {
            model.ruleAttestations[rule.id] = RuleAttestation(
                actor: "me", role: "reviewer", rationale: "verified for the compensation test", at: t0)
        }
        model.rationale = "reviewed and ready"
        model.proofStandard = .preponderance
        if model.hasOpenItems { model.acknowledgedOpenItems = true }
        await model.approve(actor: "me", at: t0)
        // The composite failed → the approval was REFUSED; nothing exists.
        #expect(model.lastError != nil, "the failure must surface, never read as success")
        #expect(model.snapshot?.isApproved == false, "an approval must never stand without its assessment")
        #expect(model.snapshot?.approvalHistory.isEmpty == true,
                "atomicity means NO partial state — not even an approval+withdrawal pair")
        #expect(model.storedAssessment == nil)
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
        // Approve: requires a rationale AND a declared standard of proof (INV-19 gap fix).
        model.rationale = "reviewed and ready"
        model.proofStandard = .preponderance
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

    @Test("Open contradictions are surfaced and block approval until the approver acknowledges them")
    func openItemsGateApproval() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "handoff-open")
        let a = try await h.seedFact(value: "OPEN finding \(UUID().uuidString)", hashChar: "c")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Open Items Matter", template: .investigation))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        let created = try await h.cases.createCase(workspaceID: wsID, title: "Open Items Matter", actor: "me", at: t0)
        _ = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                            sourceRef: a.svID.uuidString, sourceKind: .sourceVersion, actor: "me", at: t0)
        let store = EvidenceStore(database: h.db)
        let custody = InvestigationCustodyService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            evidence: store, custody: CustodyRepository(database: h.db), database: h.db)
        let handoff = WorkProductHandoffService(cases: h.cases, findings: h.findings, closure: h.closure, custody: custody)
        let desk = InvestigationContradictionGapService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store), evidence: store,
            contradictions: ContradictionsRepository(database: h.db), gaps: GapNodeRepository(database: h.db),
            reviews: InvestigationDeskReviewRepository(database: h.db))
        let model = WorkProductHandoffModel(handoff: handoff, findings: h.findings, closure: h.closure,
                                            contradictionGap: desk)

        // Seed one UNDECIDED in-scope contradiction on the authorized source's KO.
        let koRows = try await h.db.query("SELECT id FROM knowledge_objects WHERE file_id = ? LIMIT 1;", [.uuid(a.fileID)])
        let koID = try #require(koRows.first?.uuid(0))
        try await h.db.exec("""
            INSERT INTO contradictions (id, description, claim_a, claim_b, evidence_a, evidence_b, severity, status, detected_at, kind)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .text("Amounts disagree"), .text("paid 500"), .text("paid 600"),
                  .uuid(koID), .null, .text("high"), .text("open"), .real(1), .text("amount")])

        await model.load(caseID: created.id)
        #expect(model.openContradictionCount >= 1)
        #expect(model.hasOpenItems)

        await model.buildFindings(actor: "me", at: t0)
        try #require(model.built != nil)
        model.rationale = "reviewed"
        model.proofStandard = .preponderance

        // Not acknowledged → approval is blocked (fail-closed), nothing recorded.
        await model.approve(actor: "me", at: t0)
        #expect(model.lastError != nil)
        #expect(model.snapshot?.isApproved != true)

        // Acknowledge → approval proceeds and the recorded rationale notes the open items.
        model.acknowledgedOpenItems = true
        await model.approve(actor: "me", at: t0)
        #expect(model.lastError == nil)
        #expect(model.snapshot?.isApproved == true)
        #expect(model.snapshot?.approvalHistory.last?.rationale.contains("acknowledged") == true)
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

    @Test("Switching matters starts a clean slate: reviewer inputs and built findings never carry across")
    func switchingMattersResetsState() async throws {
        let (model, caseA, h) = try await makeModel()
        await model.load(caseID: caseA)
        // Dirty the reviewer state on matter A.
        await model.buildFindings(actor: "me", at: t0)
        try #require(model.built != nil)
        model.rationale = "A rationale"
        model.unresolvedText = "A unresolved"
        model.exportRedactionTerms = "A-SECRET"
        model.exportFormat = .docx
        // Open a DIFFERENT matter — inputs from A must not leak into B.
        let wsB = UUID()
        try await h.workspaces.upsert(Workspace(id: wsB, title: "Matter B", template: .investigation))
        let caseB = try await h.cases.createCase(workspaceID: wsB, title: "Matter B", actor: "me", at: t0)
        await model.load(caseID: caseB.id)
        #expect(model.snapshot?.caseID == caseB.id)
        #expect(model.built == nil)
        #expect(model.rationale.isEmpty)
        #expect(model.unresolvedText.isEmpty)
        #expect(model.exportRedactionTerms.isEmpty)
        #expect(model.exportFormat == .pdf)
    }

    /// PHASE C — the positive atomic path: approval decision + SEALED
    /// assessment + governance event land together; the assessment row
    /// carries approval_state = 'approved'.
    @Test("Atomic approval commits approval, sealed assessment and governance event together")
    func atomicApprovalCommitsAllThree() async throws {
        let h = try await PersonaAcceptanceHarness.make(seed: "handoff-atomic")
        let a = try await h.seedFact(value: "ATOMIC finding \(UUID().uuidString)", hashChar: "e")
        let wsID = UUID()
        try await h.workspaces.upsert(Workspace(id: wsID, title: "Atomic Matter", template: .investigation))
        try await h.workspaces.addSource(a.fileID, to: wsID)
        try await WorkspaceMembershipDeriver(database: h.db, workspaces: h.workspaces).deriveMembership(for: wsID)
        _ = try await h.producer.backfill(at: t0)
        var created = try await h.cases.createCase(workspaceID: wsID, title: "Atomic Matter", actor: "me", at: t0)
        created = try await h.cases.includeSource(caseID: created.id, expectedRevision: created.revision,
                                                  sourceRef: a.svID.uuidString, sourceKind: .sourceVersion,
                                                  actor: "me", at: t0)
        _ = try await h.cases.confirmScope(caseID: created.id, expectedRevision: created.revision, actor: "me", at: t0)
        let store = EvidenceStore(database: h.db)
        let custody = InvestigationCustodyService(
            cases: h.cases, resolver: CaseRetrievalScopeResolver(evidence: store),
            evidence: store, custody: CustodyRepository(database: h.db), database: h.db)
        let handoff = WorkProductHandoffService(cases: h.cases, findings: h.findings, closure: h.closure, custody: custody)
        // EIGHTH AUDIT — strict approval REFUSES without an audit chain, so
        // the success path must wire one (fresh ledger: heads at genesis).
        let governanceRepo = GovernanceEventsRepository(database: h.db)
        let chain = AuditChainService(database: h.db, secret: Data("test-secret".utf8),
                                      eventProvider: { try await governanceRepo.auditChainEvents() })
        let model = WorkProductHandoffModel(handoff: handoff, findings: h.findings, closure: h.closure,
                                            assessments: ConformanceAssessmentRepository(database: h.db),
                                            auditChain: chain,
                                            governance: governanceRepo,
                                            approvalTxn: ApprovalTransactionRepository(database: h.db))
        model.sealingKeyOverride = P256.Signing.PrivateKey()
        await model.load(caseID: created.id)
        await model.buildFindings(actor: "me", at: t0)
        #expect(model.built != nil)
        let frozen = try #require(model.frozenSutra)
        let reached = model.conformanceFacts().completedPhaseKinds
        for rule in SutraRuleCompiler.rules(for: frozen)
        where rule.phaseKind.map(reached.contains) ?? true {
            model.ruleAttestations[rule.id] = RuleAttestation(
                actor: "me", role: "reviewer", rationale: "verified for the atomic test", at: t0)
        }
        model.rationale = "reviewed and ready"
        model.proofStandard = .preponderance
        if model.hasOpenItems { model.acknowledgedOpenItems = true }
        await model.approve(actor: "me", at: t0)
        #expect(model.lastError == nil, "\(model.lastError ?? "nil")")
        // 1 — the approval decision exists.
        #expect(model.snapshot?.isApproved == true)
        #expect(model.snapshot?.approvalHistory.count == 1)
        // 2 — the SEALED assessment exists, at revision 1, marked 'approved'.
        let stored = try #require(model.storedAssessment)
        #expect(stored.seal != nil, "strict mode never approves unsealed")
        #expect(stored.runRevision == 1)
        let state = try await h.db.query(
            "SELECT approval_state FROM conformance_assessments WHERE id = ?;",
            [.uuid(stored.id)]).first?.string(0)
        #expect(state == "approved")
        // 3 — the governance event landed in the SAME atom.
        let events = try await h.db.query(
            "SELECT kind FROM governance_events WHERE case_id = ? AND kind = 'findings.approved';",
            [.uuid(created.id)])
        #expect(events.count == 1)
    }
}
