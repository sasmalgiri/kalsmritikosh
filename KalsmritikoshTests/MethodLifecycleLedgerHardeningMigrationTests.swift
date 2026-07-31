//
//  MethodLifecycleLedgerHardeningMigrationTests.swift
//  KalsmritikoshTests
//
//  PM-004.1 — schema v81 pushes the lifecycle invariants down into the ledger:
//  the reverse supersession CHECK on method_runs, the required review CHECKs, and
//  the required validation CHECKs. Also proves the migration-pass hardening: a
//  failing POST-PASS foreign_key_check rolls the whole pass back atomically, and
//  the self-heal sentinel recognises the v81 markers (which add no new column).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-004.1 — v81 lifecycle ledger hardening migration")
struct MethodLifecycleLedgerHardeningMigrationTests {

    private let methodTables = [
        "method_runs", "method_nodes", "method_edges", "method_evidence_links",
        "method_assumptions", "method_findings", "method_reviews", "method_validation_results",
        "method_run_events"
    ]

    private func seedWorkspace(_ db: Database, _ id: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(id), .text("WS"), .text("general"), .real(0), .real(0)])
    }

    private func insertRun(_ db: Database, id: UUID, ws: UUID, status: String = "draft",
                           completedAt: SQLValue = .null, superseded: SQLValue = .null) async throws {
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version,
                                     status, revision, content_revision, created_by, created_at, updated_at,
                                     completed_at, superseded_by_run_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(ws), .text("com.k.m.test"), .integer(1), .text(status), .integer(1),
                  .integer(1), .text("analyst"), .real(0), .real(0), completedAt, superseded])
    }

    private func methodRunsSQL(_ db: Database) async throws -> String {
        try await db.query("SELECT sql FROM sqlite_master WHERE type='table' AND name='method_runs';", [])
            .first?.string(0) ?? ""
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v81 with all nine method tables and the hardened CHECKs")
    func freshV81() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        #expect(try await db.currentUserVersion() == 81)
        for t in methodTables { #expect(try await MigrationFixtureBuilder.tableExists(db, t), "missing \(t)") }
        #expect(try await methodRunsSQL(db).contains("status = 'superseded'"))   // reverse supersession CHECK
    }

    @Test("v80→v81 preserves every row and every legacy value still satisfies the new CHECKs")
    func v80ToV81Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        // Legacy-shaped review + validation rows (as a forward v80 migration leaves them).
        try await db.exec("""
            INSERT INTO method_reviews (id, method_run_id, action, actor_kind, actor_identifier, reviewed_at, review_key, reviewed_content_revision)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(run), .text("comment"), .text("human"), .text("r"), .real(0),
                  .text("legacy.unkeyed"), .integer(0)])
        try await db.exec("""
            INSERT INTO method_validation_results (id, method_run_id, validator_id, validator_version, severity, code, message, subject_kind, created_at, validation_batch_id, evaluated_content_revision)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(run), .text("v"), .text("1"), .text("info"), .text("C"), .text("m"),
                  .text("run"), .real(0), .text("00000000-0000-0000-0000-000000000000"), .integer(0)])

        try await SchemaMigrations.migrate(db, through: 81)

        #expect(try await db.currentUserVersion() == 81)
        #expect(try await db.query("SELECT COUNT(*) FROM method_runs;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT review_key FROM method_reviews;", []).first?.string(0) == "legacy.unkeyed")
        #expect(try await db.query("SELECT validation_batch_id FROM method_validation_results;", []).first?.string(0) == "00000000-0000-0000-0000-000000000000")
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
    }

    // MARK: - Reverse supersession CHECK

    @Test("A non-superseded run cannot carry a supersession reference; a valid superseded run can")
    func reverseSupersessionCheckEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        let ws = UUID(); try await seedWorkspace(db, ws)
        // active run with a stray successor reference → rejected by the reverse CHECK.
        await #expect(throws: (any Error).self) {
            try await self.insertRun(db, id: UUID(), ws: ws, status: "active", superseded: .uuid(UUID()))
        }
        // a genuine superseded run (successor present) is accepted.
        try await insertRun(db, id: UUID(), ws: ws, status: "superseded", superseded: .uuid(UUID()))
    }

    // MARK: - Required review CHECKs

    @Test("method_reviews rejects a blank key, a negative revision, and both a node and a finding")
    func reviewChecksEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        func insertReview(reviewKey: String, rev: Int, nodeID: SQLValue, findingID: SQLValue) async throws {
            try await db.exec("""
                INSERT INTO method_reviews (id, method_run_id, node_id, finding_id, action, actor_kind, actor_identifier, reviewed_at, review_key, reviewed_content_revision)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(run), nodeID, findingID, .text("acceptForWorkflow"),
                      .text("human"), .text("r"), .real(0), .text(reviewKey), .integer(Int64(rev))])
        }
        // blank review key rejected
        await #expect(throws: (any Error).self) { try await insertReview(reviewKey: "  ", rev: 1, nodeID: .null, findingID: .null) }
        // negative reviewed_content_revision rejected
        await #expect(throws: (any Error).self) { try await insertReview(reviewKey: "final", rev: -1, nodeID: .null, findingID: .null) }
        // both node and finding present rejected (FK off isolates the CHECK from the composite FK)
        try await db.exec("PRAGMA foreign_keys = OFF;")
        await #expect(throws: (any Error).self) { try await insertReview(reviewKey: "final", rev: 1, nodeID: .uuid(UUID()), findingID: .uuid(UUID())) }
        // a single valid run-level review is accepted
        try await insertReview(reviewKey: "final", rev: 1, nodeID: .null, findingID: .null)
    }

    // MARK: - Required validation CHECKs

    @Test("method_validation_results rejects a blank batch id and a negative evaluated revision")
    func validationChecksEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        func insertValidation(batchID: String, rev: Int) async throws {
            try await db.exec("""
                INSERT INTO method_validation_results (id, method_run_id, validator_id, validator_version, severity, code, message, subject_kind, created_at, validation_batch_id, evaluated_content_revision)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(run), .text("v"), .text("1"), .text("info"), .text("C"), .text("m"),
                      .text("run"), .real(0), .text(batchID), .integer(Int64(rev))])
        }
        await #expect(throws: (any Error).self) { try await insertValidation(batchID: "  ", rev: 0) }
        await #expect(throws: (any Error).self) { try await insertValidation(batchID: "11111111-1111-1111-1111-111111111111", rev: -1) }
        // a valid non-legacy batch row is accepted
        try await insertValidation(batchID: "11111111-1111-1111-1111-111111111111", rev: 1)
    }

    // MARK: - Self-heal marker discrimination + genuine upgrade

    @Test("A genuine v80 schema upgrades to v81, applying the hardened CHECKs (the sentinel does not skip v81)")
    func v80SchemaGenuinelyUpgradesToV81() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        #expect(try await db.currentUserVersion() == 80)
        #expect(try await methodRunsSQL(db).contains("status = 'superseded'") == false)  // v80: no reverse CHECK yet
        try await SchemaMigrations.migrate(db, through: 81)   // must APPLY v81, not self-heal-skip
        #expect(try await db.currentUserVersion() == 81)
        #expect(try await methodRunsSQL(db).contains("status = 'superseded'"))            // v81 hardening applied
    }

    // MARK: - Atomic post-pass foreign_key_check (Gap 3)

    @Test("A failing POST-PASS foreign_key_check rolls the whole migration pass back atomically")
    func postPassForeignKeyCheckFailureRollsBackWholePass() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        // Introduce a dangling child row with enforcement OFF — a node referencing a
        // method_run that does not exist. The v81 pass applies cleanly, but the final
        // PRAGMA foreign_key_check finds this violation and must roll the WHOLE pass back.
        try await db.exec("PRAGMA foreign_keys = OFF;")
        try await db.exec("""
            INSERT INTO method_nodes (id, method_run_id, node_definition_key, node_kind, label, working_state, ordinal, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(UUID()), .text("k"), .text("cause"), .text("L"), .text("proposal"), .integer(0), .real(0), .real(0)])

        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db)     // v81 pass; post-pass FK check fails
        }
        // The whole pass rolled back: version still 80, and the v81 hardening is ABSENT.
        #expect(try await db.currentUserVersion() == 80)
        #expect(try await methodRunsSQL(db).contains("status = 'superseded'") == false)
    }

    // MARK: - Repeat + injected fault

    @Test("Re-running migrate through v81 over a v81 database is a safe no-op")
    func v81Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        try await SchemaMigrations.migrate(db, through: 81)
        #expect(try await db.currentUserVersion() == 81)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v81 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 80)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 81,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 81)))
        }
        #expect(try await db.currentUserVersion() == 80)
        #expect(try await methodRunsSQL(db).contains("status = 'superseded'") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
