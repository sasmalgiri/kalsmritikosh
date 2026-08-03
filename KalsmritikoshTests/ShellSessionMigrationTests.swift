//
//  ShellSessionMigrationTests.swift
//  KalsmritikoshTests
//
//  SHELL-001 — schema v95 adds the shell navigation-session tables: app_navigation_sessions (one per
//  scope, with the cursor) + app_navigation_entries (the ordered location stack). Proves reach, v94→v95
//  preservation, self-heal, repeat + fault rollback, milestone, every integrity CHECK / FK / cascade.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SHELL-001 — v95 navigation-session migration")
struct ShellSessionMigrationTests {

    @discardableResult
    private func insertSession(_ db: Database, id: UUID = UUID(), scope: String = "default",
                               index: Int64 = 0, rev: Int64 = 1) async throws -> UUID {
        try await db.exec("""
            INSERT INTO app_navigation_sessions (id, scope_key, current_index, revision, updated_at)
            VALUES (?,?,?,?,?);
            """, [.uuid(id), .text(scope), .integer(index), .integer(rev), .real(100)])
        return id
    }

    private func insertEntry(_ db: Database, session: UUID, ordinal: Int64 = 0, destination: String = "home") async throws {
        try await db.exec("""
            INSERT INTO app_navigation_entries (id, session_id, ordinal, destination, context_kind, context_id)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(session), .integer(ordinal), .text(destination), .null, .null])
    }

    @Test("A fresh database reaches v95 with the two navigation-session tables")
    func freshV95() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        #expect(try await db.currentUserVersion() == 95)
        for t in ["app_navigation_sessions", "app_navigation_entries"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing at v95")
        }
        #expect(try await MigrationFixtureBuilder.columns(db, "app_navigation_sessions").isSuperset(of: ["scope_key", "current_index", "revision"]))
    }

    @Test("v94→v95 preserves existing workbench scenarios with no fabricated sessions")
    func v94ToV95Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        let ws = UUID(); let d = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(d), .uuid(ws), .text("D"), .text("advanced"), .integer(1), .real(1), .real(1)])
        try await db.exec("INSERT INTO workbench_scenarios (id, dataset_id, base_dataset_revision, title, status, current_op_seq, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(d), .integer(1), .text("S"), .text("active"), .integer(0), .integer(1), .text("u"), .real(1), .real(1)])
        try await SchemaMigrations.migrate(db, through: 95)
        #expect(try await db.currentUserVersion() == 95)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenarios;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM app_navigation_sessions;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v95 navigation tables")
    func selfHealRecognizesV95() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(92)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v95 database is a safe no-op")
    func v95Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        try await SchemaMigrations.migrate(db, through: 95)
        #expect(try await db.currentUserVersion() == 95)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v95 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 95, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 95)))
        }
        #expect(try await db.currentUserVersion() == 94)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='app_navigation_sessions';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v95 with a clean FK graph")
    func milestoneReachesV95() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 95)
        #expect(try await db.currentUserVersion() == 95)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Session scope must be non-blank, current_index >= -1, revision >= 1, and scope is unique")
    func sessionChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { _ = try await insertSession(db, scope: "  ") }
        await #expect(throws: (any Error).self) { _ = try await insertSession(db, index: -2) }
        await #expect(throws: (any Error).self) { _ = try await insertSession(db, rev: 0) }
        _ = try await insertSession(db, scope: "default")
        await #expect(throws: (any Error).self) { _ = try await insertSession(db, scope: "default") }   // unique scope
    }

    @Test("An empty session may carry current_index -1")
    func emptySessionIndex() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        _ = try await insertSession(db, index: -1)
        #expect(try await db.query("SELECT COUNT(*) FROM app_navigation_sessions;", []).first?.int(0) == 1)
    }

    @Test("Entry destination is a closed vocabulary with a unique per-session ordinal")
    func entryChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let s = try await insertSession(db)
        await #expect(throws: (any Error).self) { try await insertEntry(db, session: s, destination: "spaceship") }
        try await insertEntry(db, session: s, ordinal: 0, destination: "home")
        await #expect(throws: (any Error).self) { try await insertEntry(db, session: s, ordinal: 0, destination: "sources") }   // dup ordinal
        try await insertEntry(db, session: s, ordinal: 1, destination: "dataLab")
        #expect(try await db.query("SELECT COUNT(*) FROM app_navigation_entries;", []).first?.int(0) == 2)
    }

    @Test("An entry's session must exist; deleting a session cascades its entries")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertEntry(db, session: UUID()) }
        let s = try await insertSession(db)
        try await insertEntry(db, session: s, ordinal: 0)
        try await insertEntry(db, session: s, ordinal: 1, destination: "sources")
        try await db.exec("DELETE FROM app_navigation_sessions WHERE id = ?;", [.uuid(s)])
        #expect(try await db.query("SELECT COUNT(*) FROM app_navigation_entries;", []).first?.int(0) == 0)
    }
}
