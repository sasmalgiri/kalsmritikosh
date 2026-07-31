//
//  MethodLifecycleMigrationTests.swift
//  KalsmritikoshTests
//
//  PM-004 — schema v80 migration: reach, preservation through the method_runs
//  rebuild, content-revision backfill, paused status, the extended columns +
//  defaults, the method_run_events ledger, FK integrity, self-heal, repeat, and
//  injected-fault rollback.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004 — v80 method lifecycle migration")
struct MethodLifecycleMigrationTests {

    private let methodTables = [
        "method_runs", "method_nodes", "method_edges", "method_evidence_links",
        "method_assumptions", "method_findings", "method_reviews", "method_validation_results",
        "method_run_events"
    ]

    private func seedWorkspace(_ db: Database, _ id: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(id), .text("WS"), .text("general"), .real(0), .real(0)])
    }
    // v79-shape inserts (no content_revision / input_role / review_key / batch).
    private func insertRunV79(_ db: Database, id: UUID, ws: UUID, status: String = "draft") async throws {
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version,
                                     status, revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(ws), .text("com.k.m.test"), .integer(1), .text(status), .integer(1),
                  .text("analyst"), .real(0), .real(0)])
    }
    private func insertNodeV79(_ db: Database, id: UUID, run: UUID) async throws {
        try await db.exec("""
            INSERT INTO method_nodes (id, method_run_id, node_definition_key, node_kind, label,
                                      working_state, ordinal, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(run), .text("k"), .text("cause"), .text("L"), .text("proposal"), .integer(0), .real(0), .real(0)])
    }

    @Test("A fresh database reaches v80 with all nine method tables")
    func freshV80() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        #expect(try await db.currentUserVersion() == 80)
        for t in methodTables { #expect(try await MigrationFixtureBuilder.tableExists(db, t), "missing \(t)") }
    }

    @Test("v79→v80 preserves every run + child row and backfills content_revision = 1")
    func v79ToV80Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRunV79(db, id: run, ws: ws)
        let node = UUID(); try await insertNodeV79(db, id: node, run: run)
        try await db.exec("""
            INSERT INTO method_evidence_links (id, method_run_id, target_kind, target_id, role, ordinal, added_by, added_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(run), .text("entity"), .uuid(UUID()), .text("supporting"), .integer(0), .text("a"), .real(0)])
        try await db.exec("""
            INSERT INTO method_reviews (id, method_run_id, action, actor_kind, actor_identifier, reviewed_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(run), .text("comment"), .text("human"), .text("r"), .real(0)])
        try await db.exec("""
            INSERT INTO method_validation_results (id, method_run_id, validator_id, validator_version, severity, code, message, subject_kind, created_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(run), .text("v"), .text("1"), .text("info"), .text("C"), .text("m"), .text("run"), .real(0)])

        try await SchemaMigrations.migrate(db, through: 80)

        #expect(try await db.query("SELECT COUNT(*) FROM method_runs;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT content_revision FROM method_runs WHERE id = ?;", [.uuid(run)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT review_key FROM method_reviews;", []).first?.string(0) == "legacy.unkeyed")
        #expect(try await db.query("SELECT reviewed_content_revision FROM method_reviews;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT validation_batch_id FROM method_validation_results;", []).first?.string(0) == "00000000-0000-0000-0000-000000000000")
        #expect(try await db.query("SELECT input_role FROM method_evidence_links;", []).first?.isNull(0) == true)
        // Nine tables + clean FK graph.
        for t in methodTables { #expect(try await MigrationFixtureBuilder.tableExists(db, t)) }
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
    }

    @Test("The rebuilt method_runs accepts paused and rejects an unknown status")
    func pausedAcceptedInvalidRejected() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        let ws = UUID(); try await seedWorkspace(db, ws)
        // paused accepted
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(ws), .text("m"), .integer(1), .text("paused"), .integer(1), .integer(1), .text("a"), .real(0), .real(0)])
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(ws), .text("m"), .integer(1), .text("nonsense"), .integer(1), .integer(1), .text("a"), .real(0), .real(0)])
        }
    }

    @Test("completed and superseded status invariants are enforced both ways")
    func statusInvariants() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        let ws = UUID(); try await seedWorkspace(db, ws)
        func insert(status: String, completedAt: SQLValue, superseded: SQLValue) async throws {
            try await db.exec("""
                INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at, completed_at, superseded_by_run_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(ws), .text("m"), .integer(1), .text(status), .integer(1), .integer(1), .text("a"), .real(0), .real(0), completedAt, superseded])
        }
        await #expect(throws: (any Error).self) { try await insert(status: "completed", completedAt: .null, superseded: .null) }
        await #expect(throws: (any Error).self) { try await insert(status: "superseded", completedAt: .null, superseded: .null) }
        // valid completed
        try await insert(status: "completed", completedAt: .real(1), superseded: .null)
    }

    @Test("method_run_events enforces its constraints")
    func eventConstraints() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID()
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(run), .uuid(ws), .text("m"), .integer(1), .text("active"), .integer(2), .integer(1), .text("a"), .real(0), .real(0)])
        func insertEvent(runRevision: Int, actorKind: String, actorID: SQLValue, action: String = "start") async throws {
            try await db.exec("""
                INSERT INTO method_run_events (id, method_run_id, sequence, run_revision, content_revision, action, from_status, to_status, actor_kind, actor_identifier, occurred_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(run), .integer(1), .integer(Int64(runRevision)), .integer(1), .text(action), .text("draft"), .text("active"), .text(actorKind), actorID, .real(0)])
        }
        // run_revision < 2 rejected
        await #expect(throws: (any Error).self) { try await insertEvent(runRevision: 1, actorKind: "system", actorID: .null) }
        // human without identifier rejected
        await #expect(throws: (any Error).self) { try await insertEvent(runRevision: 2, actorKind: "human", actorID: .null) }
        // valid
        try await insertEvent(runRevision: 2, actorKind: "system", actorID: .null)
    }

    @Test("The composite ownership + workspace CASCADE survive the rebuild")
    func cascadeAndOwnershipSurviveRebuild() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID()
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(run), .uuid(ws), .text("m"), .integer(1), .text("draft"), .integer(1), .integer(1), .text("a"), .real(0), .real(0)])
        try await insertNodeV79(db, id: UUID(), run: run)   // node insert still valid post-rebuild
        try await db.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(ws)])
        #expect(try await db.query("SELECT COUNT(*) FROM method_runs;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM method_nodes;", []).first?.int(0) == 0)
    }

    @Test("Re-running migrate over a v80 database is a safe no-op")
    func v80Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        try await SchemaMigrations.migrate(db, through: 80)
        #expect(try await db.currentUserVersion() == 80)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("The self-heal sentinel reconciles a stale counter over the fully-applied latest schema")
    func selfHealReconcilesStaleCounterAtLatest() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(79)               // stale, but schema is fully applied
        try await SchemaMigrations.migrate(db)         // self-heal stamps latest, no destructive replay
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        for t in methodTables { #expect(try await MigrationFixtureBuilder.tableExists(db, t)) }
    }

    @Test("An injected failure inside the v80 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 80,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 80)))
        }
        #expect(try await db.currentUserVersion() == 79)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "method_run_events") == false)
        // The v79 method_runs shape is intact (no content_revision column).
        let cols = try await MigrationFixtureBuilder.columns(db, "method_runs")
        #expect(!cols.contains("content_revision"))
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An evidence link can carry an input_role after v80")
    func inputRoleUsable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID()
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(run), .uuid(ws), .text("m"), .integer(1), .text("draft"), .integer(1), .integer(1), .text("a"), .real(0), .real(0)])
        try await db.exec("""
            INSERT INTO method_evidence_links (id, method_run_id, target_kind, target_id, role, input_role, ordinal, added_by, added_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(run), .text("entity"), .uuid(UUID()), .text("supporting"), .text("problemStatement"), .integer(0), .text("a"), .real(0)])
        #expect(try await db.query("SELECT input_role FROM method_evidence_links;", []).first?.string(0) == "problemStatement")
    }

    @Test("v80 migration adds no method-definition table")
    func noDefinitionTable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        for t in ["professional_method_definitions", "method_definition_registry", "method_templates"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t) == false)
        }
    }

    @Test("Foreign-key integrity is clean on a fresh v80 database with seeded rows")
    func fkIntegrityClean() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID()
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version, status, revision, content_revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(run), .uuid(ws), .text("m"), .integer(1), .text("draft"), .integer(1), .integer(1), .text("a"), .real(0), .real(0)])
        try await insertNodeV79(db, id: UUID(), run: run)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
    }

    @Test("Milestone migration reaches v80 through v80")
    func milestoneReachesV80() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 80)
        #expect(try await db.currentUserVersion() == 80)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
