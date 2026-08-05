//
//  InvestigationClosureMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-20 — schema v101 adds investigation_case_closures: the durable, append-only human closure/reopen
//  decision log. Proves reach, v100→v101 preservation, self-heal, repeat + fault rollback, milestone, and the
//  integrity CHECKs (decision vocab, nonblank rationale/actor, 64-hex scope fingerprint, sequence, one row per
//  (case,sequence), FK/cascade). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-20 — v101 closure-decision migration")
struct InvestigationClosureMigrationTests {

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
    private func insertClosure(_ db: Database, caseID: UUID, seq: Int64 = 1, decision: String = "closed",
                               rationale: String = "done", fingerprint: String? = nil, actor: String = "u") async throws {
        try await db.exec("""
            INSERT INTO investigation_case_closures (id, case_id, sequence, decision, rationale, work_product_run_id,
                scope_fingerprint, unresolved_json, receipt_seal, actor, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .integer(seq), .text(decision), .text(rationale), .null,
                  .text(fingerprint ?? hex), .text("[]"), .null, .text(actor), .real(1)])
    }

    @Test("A fresh database reaches v101 with the closure table")
    func freshV101() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 101)
        #expect(try await db.currentUserVersion() == 101)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_case_closures"))
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_case_closures")
            .isSuperset(of: ["case_id", "sequence", "decision", "rationale", "scope_fingerprint", "unresolved_json"]))
    }

    @Test("v100→v101 preserves an existing case and fabricates no closures")
    func v100ToV101Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 100)
        _ = try await insertWorkspaceAndCase(db)
        try await SchemaMigrations.migrate(db, through: 101)
        #expect(try await db.currentUserVersion() == 101)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_closures;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v101 table")
    func selfHealRecognizesV101() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(98)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v101 database is a safe no-op")
    func v101Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 101)
        try await SchemaMigrations.migrate(db, through: 101)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v101 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 100)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 101, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 101)))
        }
        #expect(try await db.currentUserVersion() == 100)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_case_closures';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v101 with a clean FK graph")
    func milestoneReachesV101() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 101)
        #expect(try await db.currentUserVersion() == 101)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("A closure enforces decision vocab, nonblank rationale/actor, 64-hex fingerprint, and (case,sequence) uniqueness")
    func closureChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 101)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let c = try await insertWorkspaceAndCase(db)
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: c, decision: "bogus") }
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: c, rationale: "  ") }
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: c, fingerprint: "short") }
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: c, fingerprint: String(repeating: "z", count: 64)) }  // non-hex
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: c, actor: " ") }
        try await insertClosure(db, caseID: c, seq: 1, decision: "closed")
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: c, seq: 1) }   // dup (case, sequence)
        try await insertClosure(db, caseID: c, seq: 2, decision: "reopened")
    }

    @Test("A closure requires a real case; deleting the case cascades its closures")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 101)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertClosure(db, caseID: UUID()) }
        let c = try await insertWorkspaceAndCase(db)
        try await insertClosure(db, caseID: c)
        try await db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_closures;", []).first?.int(0) == 0)
    }
}
