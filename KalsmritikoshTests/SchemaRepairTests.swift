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
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion - 2)
        #expect(try await !MigrationFixtureBuilder.tableExists(db, "case_profiles"))
        try await SchemaMigrations.migrate(db, through: SchemaMigrations.latestVersion)
        for table in ["case_profiles", "case_allegations", "case_actions", "ach_analyses"] {
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
