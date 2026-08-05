//
//  InvestigationClosureServiceTests.swift
//  KalsmritikoshTests
//
//  INV-20 — Closure. Proves: a case is CLOSED only by an explicit recorded human decision (no auto-close);
//  closure is HONEST (accepted unresolved items are retained + visible); the closure carries the case scope
//  fingerprint; the closure + case status transition are atomic; reopening requires a closed case, is a NEW
//  decision that preserves the prior closure (genealogy), and swings status back to open; double-close and a
//  stale revision are refused; the log reopens. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-20 — case closure & reopen", .serialized)
struct InvestigationClosureServiceTests {

    private let t0 = Date(timeIntervalSince1970: 1_768_100_000)

    private struct Rig {
        let db: Database
        let cases: InvestigationCaseRepository
        let service: InvestigationClosureService
        let closures: InvestigationClosureRepository
        let caseID: UUID
        let revision: Int
    }

    private func rig() async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("Matter"), .real(1), .real(1)])
        let cases = InvestigationCaseRepository(database: db)
        let closures = InvestigationClosureRepository(database: db)
        let service = InvestigationClosureService(cases: cases, resolver: CaseRetrievalScopeResolver(evidence: EvidenceStore(database: db)), closures: closures)
        let c = try await cases.createCase(workspaceID: ws, title: "Process deviation", actor: "analyst", at: t0)
        return Rig(db: db, cases: cases, service: service, closures: closures, caseID: c.id, revision: c.revision)
    }

    private func status(_ db: Database, _ caseID: UUID) async throws -> String? {
        try await db.query("SELECT status FROM investigation_cases WHERE id = ? LIMIT 1;", [.uuid(caseID)]).first?.string(0)
    }

    @Test("A case is closed only by a recorded human decision (rationale + actor required); the case has no auto-close path")
    func closureRequiresHumanDecision() async throws {
        let rig = try await rig()
        // The case starts open; nothing has closed it.
        #expect(try await status(rig.db, rig.caseID) == "open")
        #expect(try await rig.service.latestClosure(caseID: rig.caseID) == nil)
        // A blank rationale/actor is refused (a closure must carry a human decision).
        await #expect(throws: InvestigationClosureError.self) {
            _ = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: rig.revision, rationale: "  ", unresolvedItems: [], workProductRunID: nil, receiptSeal: nil, actor: "lead", at: t0)
        }
        await #expect(throws: InvestigationClosureError.self) {
            _ = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: rig.revision, rationale: "done", unresolvedItems: [], workProductRunID: nil, receiptSeal: nil, actor: " ", at: t0)
        }
        #expect(try await status(rig.db, rig.caseID) == "open")   // still open — no partial close
    }

    @Test("Closing records the human decision + scope fingerprint and atomically swings the case to closed")
    func closeRecordsAndTransitions() async throws {
        let rig = try await rig()
        let decision = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: rig.revision,
                                                       rationale: "objectives met; residual risk accepted", unresolvedItems: [],
                                                       workProductRunID: UUID(), receiptSeal: "seal-abc", actor: "lead", at: t0)
        #expect(decision.decision == .closed && decision.actor == "lead")
        #expect(decision.scopeFingerprint.value.count == 64)
        #expect(decision.receiptSeal == "seal-abc" && decision.workProductRunID != nil)
        #expect(try await status(rig.db, rig.caseID) == "closed")
        // Double-close is refused.
        await #expect(throws: InvestigationClosureError.self) {
            _ = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: rig.revision + 1, rationale: "again", unresolvedItems: [], workProductRunID: nil, receiptSeal: nil, actor: "lead", at: t0)
        }
    }

    @Test("Closure is HONEST: a case may be closed WITH known unresolved items, which remain visible")
    func honestClosureRetainsUnresolved() async throws {
        let rig = try await rig()
        let unresolved = ["Vendor contract never obtained", "Contradiction between the two approval emails unresolved", "Residual fraud risk: low but non-zero"]
        let decision = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: rig.revision,
                                                       rationale: "closing with documented limitations", unresolvedItems: unresolved,
                                                       workProductRunID: nil, receiptSeal: nil, actor: "lead", at: t0)
        #expect(decision.unresolvedItems == unresolved)                       // retained on the decision
        #expect(try await status(rig.db, rig.caseID) == "closed")
        // The unresolved items survive reopen through a fresh repository (never erased).
        let reopened = InvestigationClosureRepository(database: rig.db)
        #expect(try await reopened.latest(caseID: rig.caseID)?.unresolvedItems == unresolved)
    }

    @Test("Reopening requires a closed case, is a NEW decision preserving the prior closure, and swings status back to open")
    func reopenPreservesGenealogy() async throws {
        let rig = try await rig()
        // Cannot reopen an open case.
        await #expect(throws: InvestigationClosureError.self) {
            _ = try await rig.service.reopenCase(caseID: rig.caseID, expectedRevision: rig.revision, rationale: "x", actor: "lead", at: t0)
        }
        let closed = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: rig.revision, rationale: "closing", unresolvedItems: ["gap A"], workProductRunID: nil, receiptSeal: nil, actor: "lead", at: t0)
        let reopened = try await rig.service.reopenCase(caseID: rig.caseID, expectedRevision: rig.revision + 1, rationale: "new evidence surfaced", actor: "lead", at: t0)
        #expect(reopened.decision == .reopened && reopened.sequence == closed.sequence + 1)
        #expect(try await status(rig.db, rig.caseID) == "open")
        // The genealogy is preserved: both decisions remain, the closure's unresolved items intact.
        let history = try await rig.service.closureHistory(caseID: rig.caseID)
        #expect(history.map(\.decision) == [.closed, .reopened])
        #expect(history.first?.unresolvedItems == ["gap A"])
        // A stale revision is refused.
        await #expect(throws: InvestigationClosureError.self) {
            _ = try await rig.service.closeCase(caseID: rig.caseID, expectedRevision: 999, rationale: "x", unresolvedItems: [], workProductRunID: nil, receiptSeal: nil, actor: "lead", at: t0)
        }
    }
}
