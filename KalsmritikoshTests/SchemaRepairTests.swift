//
//  SchemaRepairTests.swift
//  KalsmritikoshTests
//
//  2026-10-23 — the self-heal check stopped tracking new migrations after v118, so a ledger one
//  version behind could be stamped "latest" without running the newest migration. These pin the
//  derived sentinel and the idempotent repair pass.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Schema self-heal sentinel and repair pass")
struct SchemaRepairTests {

    @Test("A ledger one version behind runs the newest migration instead of being stamped over it")
    func upgradeRunsNewest() async throws {
        // Pinned to v150 (the last version before the case file), not "latest - n", which drifts.
        let db = try await MigrationFixtureBuilder.database(atVersion: 150)
        #expect(try await !MigrationFixtureBuilder.tableExists(db, "case_profiles"))
        try await SchemaMigrations.migrate(db, through: SchemaMigrations.latestVersion)
        for table in ["case_profiles", "case_allegations", "case_actions", "ach_analyses", "case_action_seal_boundaries",
                      "investigation_hypothesis_decisions", "investigation_hypothesis_evidence_assessments"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, table), "\(table) missing after upgrade")
        }
    }

    @Test("A mis-stamped ledger gets its missing tables back")
    func repairRecreatesMissing() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        // Simulate the old bug: v151 tables never created, counter already at latest.
        try await db.exec("DROP TABLE case_profiles;")
        try await db.exec("DROP TABLE case_exhibits;")
        try await SchemaMigrations.migrate(db, through: SchemaMigrations.latestVersion)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "case_profiles"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "case_exhibits"))
    }

    @Test("Conformance adds back tables and ALTER-added columns an old upgrade left out")
    func conformanceRepairs() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let cols = try await db.query("PRAGMA table_info(chunks);", []).compactMap { $0.string(1) }
        let column = try #require(cols.first { $0 == "derivation_digest" } ?? cols.last)
        try await db.exec("ALTER TABLE chunks DROP COLUMN \(column);")
        try await db.exec("DROP TABLE case_hold_notices;")
        let report = try await SchemaConformance.repair(db)
        #expect(report.added.contains("table case_hold_notices"))
        #expect(report.added.contains("column chunks.\(column)"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "case_hold_notices"))
        let after = try await db.query("PRAGMA table_info(chunks);", []).compactMap { $0.string(1) }
        #expect(after.contains(column))
        // A conformant ledger needs nothing.
        #expect(try await SchemaConformance.repair(db).isClean)
    }

    @Test("Only create-if-missing migrations are re-run")
    func idempotencyClassifier() {
        for v in [148, 149, 150, 151, 152] {
            #expect(SchemaMigrations.migrationSQL(for: v).map(SchemaMigrations.isIdempotent) == true, "v\(v) should be re-runnable")
        }
        #expect(!SchemaMigrations.isIdempotent("ALTER TABLE chunks ADD COLUMN x TEXT;"))
        #expect(!SchemaMigrations.isIdempotent("CREATE TABLE t (id TEXT);"))
        #expect(!SchemaMigrations.isIdempotent("CREATE TABLE IF NOT EXISTS t (id TEXT); UPDATE t SET id = 'a';"))
        #expect(SchemaMigrations.isIdempotent("""
            CREATE TABLE IF NOT EXISTS t (id TEXT);
            CREATE TRIGGER IF NOT EXISTS tr AFTER INSERT ON t BEGIN INSERT INTO u (id) VALUES (NEW.id); END;
            """))
    }

    @Test("The sentinel names the newest migration's tables")
    func sentinelDerived() {
        let tables = SchemaMigrations.createdTables(inMigration: SchemaMigrations.latestVersion)
        #expect(!tables.isEmpty)
        #expect(SchemaMigrations.createdTables(inMigration: 151).contains("case_profiles"))
    }
}
