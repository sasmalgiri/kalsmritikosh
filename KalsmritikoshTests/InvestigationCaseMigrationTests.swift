//
//  InvestigationCaseMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-01-A — schema v96 adds the Investigator case-intake & scope tables: investigation_cases (the case
//  header + scope framing + status + soft confirmed-deadline ref), investigation_case_sources (the
//  in-scope/out-of-scope source dispositions — the HARD evidence boundary, UNIQUE per case+ref), and
//  investigation_case_events (append-only audit). Proves reach, v95→v96 preservation, self-heal, repeat +
//  fault rollback, milestone, and every integrity CHECK / FK / cascade / uniqueness. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-01-A — v96 investigation-case migration")
struct InvestigationCaseMigrationTests {

    @discardableResult
    private func insertWorkspace(_ db: Database, id: UUID = UUID()) async throws -> UUID {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(id), .text("W"), .real(1), .real(1)])
        return id
    }

    @discardableResult
    private func insertCase(_ db: Database, id: UUID = UUID(), workspace: UUID, title: String = "Case",
                            status: String = "open", revision: Int64 = 1, actor: String = "u") async throws -> UUID {
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(workspace), .text(title), .text(status), .integer(revision), .text(actor), .real(1), .real(1)])
        return id
    }

    private func insertSource(_ db: Database, id: UUID = UUID(), caseID: UUID, ref: String = "src-1",
                              kind: String = "logicalSource", inScope: Int64 = 1) async throws {
        try await db.exec("""
            INSERT INTO investigation_case_sources (id, case_id, source_ref, source_kind, in_scope, created_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(id), .uuid(caseID), .text(ref), .text(kind), .integer(inScope), .real(1)])
    }

    private func insertEvent(_ db: Database, caseID: UUID, sequence: Int64 = 1, revision: Int64 = 1,
                             action: String = "created", actor: String = "u") async throws {
        try await db.exec("""
            INSERT INTO investigation_case_events (id, case_id, sequence, case_revision, action, actor, occurred_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .integer(sequence), .integer(revision), .text(action), .text(actor), .real(1)])
    }

    @Test("A fresh database reaches v96 with the three investigation-case tables")
    func freshV96() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        #expect(try await db.currentUserVersion() == 96)
        for t in ["investigation_cases", "investigation_case_sources", "investigation_case_events"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing at v96")
        }
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_cases")
            .isSuperset(of: ["workspace_id", "scope_statement", "out_of_scope_statement", "status", "confirmed_deadline_id", "possible_deadline_note", "revision"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_case_sources").isSuperset(of: ["source_ref", "source_kind", "in_scope"]))
    }

    @Test("v95→v96 preserves an existing navigation session and fabricates no cases")
    func v95ToV96Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        try await db.exec("INSERT INTO app_navigation_sessions (id, scope_key, current_index, revision, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(UUID()), .text("default"), .integer(0), .integer(1), .real(1)])
        try await SchemaMigrations.migrate(db, through: 96)
        #expect(try await db.currentUserVersion() == 96)
        #expect(try await db.query("SELECT COUNT(*) FROM app_navigation_sessions;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v96 investigation-case tables")
    func selfHealRecognizesV96() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(93)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v96 database is a safe no-op")
    func v96Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        try await SchemaMigrations.migrate(db, through: 96)
        #expect(try await db.currentUserVersion() == 96)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v96 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 95)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 96, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 96)))
        }
        #expect(try await db.currentUserVersion() == 95)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_cases';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v96 with a clean FK graph")
    func milestoneReachesV96() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 96)
        #expect(try await db.currentUserVersion() == 96)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("A case requires a non-blank title/actor, a valid status, revision >= 1, and an existing workspace")
    func caseChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = try await insertWorkspace(db)
        await #expect(throws: (any Error).self) { _ = try await insertCase(db, workspace: ws, title: "  ") }
        await #expect(throws: (any Error).self) { _ = try await insertCase(db, workspace: ws, status: "bogus") }
        await #expect(throws: (any Error).self) { _ = try await insertCase(db, workspace: ws, revision: 0) }
        await #expect(throws: (any Error).self) { _ = try await insertCase(db, workspace: ws, actor: "  ") }
        await #expect(throws: (any Error).self) { _ = try await insertCase(db, workspace: UUID()) }   // missing workspace FK
        _ = try await insertCase(db, workspace: ws)   // valid
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
    }

    @Test("A source disposition uses a closed kind vocabulary, an in_scope flag of 0/1, a non-blank ref, and is unique per case+ref")
    func sourceChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        await #expect(throws: (any Error).self) { try await insertSource(db, caseID: c, kind: "telepathy") }
        await #expect(throws: (any Error).self) { try await insertSource(db, caseID: c, ref: "  ") }
        await #expect(throws: (any Error).self) { try await insertSource(db, caseID: c, inScope: 2) }
        try await insertSource(db, caseID: c, ref: "src-1", inScope: 1)
        await #expect(throws: (any Error).self) { try await insertSource(db, caseID: c, ref: "src-1", inScope: 0) }   // dup (case, ref)
        try await insertSource(db, caseID: c, ref: "src-2", inScope: 0)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_sources;", []).first?.int(0) == 2)
    }

    @Test("A case event uses a closed action vocabulary, sequence >= 1, and a unique per-case sequence")
    func eventChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        await #expect(throws: (any Error).self) { try await insertEvent(db, caseID: c, action: "vanished") }
        await #expect(throws: (any Error).self) { try await insertEvent(db, caseID: c, sequence: 0) }
        try await insertEvent(db, caseID: c, sequence: 1, action: "created")
        await #expect(throws: (any Error).self) { try await insertEvent(db, caseID: c, sequence: 1, action: "scopeSet") }   // dup sequence
        try await insertEvent(db, caseID: c, sequence: 2, action: "scopeConfirmed")
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_events;", []).first?.int(0) == 2)
    }

    @Test("Deleting a case cascades its sources and events; deleting a workspace cascades its cases")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 96)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertSource(db, caseID: UUID()) }   // source needs a real case
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        try await insertSource(db, caseID: c, ref: "src-1")
        try await insertEvent(db, caseID: c, sequence: 1)
        try await db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_sources;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_events;", []).first?.int(0) == 0)
        // Workspace cascade.
        let c2 = try await insertCase(db, workspace: ws)
        try await insertSource(db, caseID: c2, ref: "src-9")
        try await db.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(ws)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_case_sources;", []).first?.int(0) == 0)
    }
}
