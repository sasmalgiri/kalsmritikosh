//
//  InvestigationScopeArtifactMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-01-C4 — schema v97 adds investigation_scope_artifacts: the durable record of the case-scope
//  fingerprint each case-produced artifact (Ask / MethodRun / Workbench dataset / work product) was made
//  under. Proves reach, v96→v97 preservation, self-heal, repeat + fault rollback, milestone, and every
//  integrity CHECK / FK / cascade / uniqueness (64-hex fingerprint, closed kind vocab, revision ≥ 1,
//  one row per case+kind+artifact). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-C4 — v97 scope-artifact migration")
struct InvestigationScopeArtifactMigrationTests {

    private let hex = String(repeating: "a", count: 64)

    @discardableResult
    private func insertWorkspace(_ db: Database, id: UUID = UUID()) async throws -> UUID {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(id), .text("W"), .real(1), .real(1)])
        return id
    }
    @discardableResult
    private func insertCase(_ db: Database, id: UUID = UUID(), workspace: UUID) async throws -> UUID {
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(workspace), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        return id
    }
    private func insertArtifact(_ db: Database, caseID: UUID, kind: String = "ask", artifact: String = "a1",
                                fingerprint: String? = nil, revision: Int64 = 1) async throws {
        try await db.exec("""
            INSERT INTO investigation_scope_artifacts (id, case_id, artifact_kind, artifact_id, scope_fingerprint, case_revision, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text(kind), .text(artifact), .text(fingerprint ?? hex), .integer(revision), .real(1)])
    }

    @Test("A fresh database reaches v97 with the scope-artifact table")
    func freshV97() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 97)
        #expect(try await db.currentUserVersion() == 97)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_scope_artifacts"))
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_scope_artifacts")
            .isSuperset(of: ["case_id", "artifact_kind", "artifact_id", "scope_fingerprint", "case_revision"]))
    }

    @Test("v96→v97 preserves an existing case and fabricates no artifacts")
    func v96ToV97Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        let ws = try await insertWorkspace(db)
        _ = try await insertCase(db, workspace: ws)
        try await SchemaMigrations.migrate(db, through: 97)
        #expect(try await db.currentUserVersion() == 97)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_scope_artifacts;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v97 scope-artifact table")
    func selfHealRecognizesV97() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(94)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v97 database is a safe no-op")
    func v97Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 97)
        try await SchemaMigrations.migrate(db, through: 97)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v97 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 97, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 97)))
        }
        #expect(try await db.currentUserVersion() == 96)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_scope_artifacts';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v97 with a clean FK graph")
    func milestoneReachesV97() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 97)
        #expect(try await db.currentUserVersion() == 97)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("A scope artifact enforces closed kind, 64-hex fingerprint, revision ≥ 1, non-blank id, and uniqueness")
    func artifactChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 97)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: c, kind: "bogus") }
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: c, fingerprint: "tooshort") }
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: c, fingerprint: String(repeating: "z", count: 64)) }  // non-hex
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: c, artifact: "  ") }
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: c, revision: 0) }
        try await insertArtifact(db, caseID: c, kind: "ask", artifact: "a1")
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: c, kind: "ask", artifact: "a1") }   // dup (case,kind,artifact)
        try await insertArtifact(db, caseID: c, kind: "methodRun", artifact: "a1")   // same artifact id, different kind is fine
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_scope_artifacts;", []).first?.int(0) == 2)
    }

    @Test("An artifact requires a real case; deleting the case cascades its scope artifacts")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 97)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertArtifact(db, caseID: UUID()) }   // no such case
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        try await insertArtifact(db, caseID: c, artifact: "a1")
        try await db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_scope_artifacts;", []).first?.int(0) == 0)
    }
}
