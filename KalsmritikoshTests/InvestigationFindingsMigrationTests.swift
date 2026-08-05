//
//  InvestigationFindingsMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-19 — schema v102 adds investigation_findings_approvals: the durable, append-only human approval /
//  withdrawal decision log for a case's findings work product. Proves reach, v101→v102 preservation, self-heal,
//  repeat + fault rollback, milestone, and the integrity CHECKs (decision vocab, nonblank run/seal/rationale/
//  actor, 64-hex scope fingerprint, sequence, one row per (case,sequence), FK/cascade). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-19 — v102 findings-approval migration")
struct InvestigationFindingsMigrationTests {

    private let hex = String(repeating: "a", count: 64)

    @discardableResult
    private func insertWorkspaceAndCase(_ db: Database) async throws -> UUID {
        let ws = UUID(), c = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(c), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        return c
    }
    private func insertApproval(_ db: Database, caseID: UUID, seq: Int64 = 1, decision: String = "approved",
                                runID: String? = nil, seal: String = "seal-1", fingerprint: String? = nil,
                                rationale: String = "reviewed", actor: String = "u") async throws {
        try await db.exec("""
            INSERT INTO investigation_findings_approvals (id, case_id, sequence, decision, work_product_run_id,
                receipt_seal, scope_fingerprint, rationale, actor, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .integer(seq), .text(decision), .text(runID ?? UUID().uuidString),
                  .text(seal), .text(fingerprint ?? hex), .text(rationale), .text(actor), .real(1)])
    }

    @Test("A fresh database reaches v102 with the approvals table")
    func freshV102() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 102)
        #expect(try await db.currentUserVersion() == 102)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_findings_approvals"))
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_findings_approvals")
            .isSuperset(of: ["case_id", "sequence", "decision", "work_product_run_id", "receipt_seal", "scope_fingerprint"]))
    }

    @Test("v101→v102 preserves an existing case and fabricates no approvals")
    func v101ToV102Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 101)
        _ = try await insertWorkspaceAndCase(db)
        try await SchemaMigrations.migrate(db, through: 102)
        #expect(try await db.currentUserVersion() == 102)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_findings_approvals;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v102 table")
    func selfHealRecognizesV102() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(99)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v102 database is a safe no-op")
    func v102Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 102)
        try await SchemaMigrations.migrate(db, through: 102)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v102 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 101)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 102, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 102)))
        }
        #expect(try await db.currentUserVersion() == 101)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_findings_approvals';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v102 with a clean FK graph")
    func milestoneReachesV102() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 102)
        #expect(try await db.currentUserVersion() == 102)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An approval enforces decision vocab, nonblank run/seal/rationale/actor, 64-hex fingerprint, and (case,sequence) uniqueness")
    func approvalChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 102)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let c = try await insertWorkspaceAndCase(db)
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, decision: "bogus") }
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, runID: "  ") }
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, seal: "  ") }
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, fingerprint: "short") }
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, fingerprint: String(repeating: "z", count: 64)) }  // non-hex
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, rationale: "  ") }
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, actor: " ") }
        try await insertApproval(db, caseID: c, seq: 1, decision: "approved")
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: c, seq: 1) }   // dup (case, sequence)
        try await insertApproval(db, caseID: c, seq: 2, decision: "withdrawn")
    }

    @Test("An approval requires a real case; deleting the case cascades its approvals")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 102)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertApproval(db, caseID: UUID()) }
        let c = try await insertWorkspaceAndCase(db)
        try await insertApproval(db, caseID: c)
        try await db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_findings_approvals;", []).first?.int(0) == 0)
    }
}
