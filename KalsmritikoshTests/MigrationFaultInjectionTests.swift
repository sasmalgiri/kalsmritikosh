//
//  MigrationFaultInjectionTests.swift
//  KalsmritikoshTests
//
//  MIG-001B — migration failure atomicity. Proves that a failure at every boundary of the
//  per-version SAVEPOINT (before it, after it, after the SQL, after the version stamp) rolls the
//  whole migration back — no partial DDL, no partial backfill, the previous version retained — and
//  that a normal second launch then migrates successfully. Also covers a genuine SQLite write/space
//  failure and malformed partial schemas (fail-closed, never falsely stamped latest, data retained).
//
//  Uses the test-only fault hook threaded EXPLICITLY into SchemaMigrations (production passes nil).
//  Does not add a migration runner and does not duplicate the existing v61→v62 rollback test.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MIG-001B — migration fault atomicity")
struct MigrationFaultInjectionTests {

    private func hasScope(_ db: Database) async throws -> Bool {
        try await MigrationFixtureBuilder.columns(db, "claims").isSuperset(of: ["scope_kind", "scope_id"])
    }

    // MARK: - Injected faults at each SAVEPOINT boundary (v66 → v67)

    @Test("A fault at any migration boundary rolls back v67 and a second launch recovers",
          arguments: [
            MigrationFaultPoint.beforeSavepoint(version: 67),
            .afterSavepoint(version: 67),
            .afterSQLBeforeVersionStamp(version: 67),
            .afterVersionStampBeforeRelease(version: 67),
          ])
    func faultAtBoundaryRollsBack(_ point: MigrationFaultPoint) async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 66)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 66)
        #expect(try await db.currentUserVersion() == 66)
        #expect(try await hasScope(db) == false)

        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 67,
                                               fault: MigrationFaultHarness.hook(throwingAt: point))
        }

        // Rolled back / never applied: previous version retained, v67 DDL absent, rows + integrity intact.
        #expect(try await db.currentUserVersion() == 66, "version changed after a \(point) fault")
        #expect(try await hasScope(db) == false, "v67 scope columns present after a rolled-back \(point) fault")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect((try await snap.failures(in: db)).isEmpty)

        // Second launch migrates cleanly (all the way to the current latest).
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await hasScope(db) == true)
        #expect((try await snap.failures(in: db)).isEmpty)
    }

    // MARK: - Genuine SQLite failure during DDL

    @Test("A failure during DDL rolls back the earlier DDL; retry with valid SQL succeeds")
    func ddlFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 67)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 67)
        let uv0 = try await db.currentUserVersion()

        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.applyOne(db, version: 99, sql: MigrationFaultHarness.ddlFaultBatch)
        }
        #expect(try await MigrationFixtureBuilder.tableExists(db, "mig_fault_probe") == false)
        #expect(try await db.currentUserVersion() == uv0)
        #expect((try await snap.failures(in: db)).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))

        try await SchemaMigrations.applyOne(db, version: 99, sql: MigrationFaultHarness.ddlValidBatch)   // synthetic version 99: never collides with a real migration
        #expect(try await MigrationFixtureBuilder.tableExists(db, "mig_fault_probe") == true)
    }

    // MARK: - Genuine SQLite failure during backfill

    @Test("A failure during backfill rolls updated values back to their originals; retry applies once")
    func backfillFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 67)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 67)
        let original = try await db.query("SELECT url FROM files LIMIT 1;", []).first?.string(0)
        #expect(original != nil)

        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.applyOne(db, version: 99, sql: MigrationFaultHarness.backfillFaultBatch(newURL: "mutated://x"))
        }
        // Updated value rolled back; no partial backfill survives.
        #expect(try await db.query("SELECT url FROM files LIMIT 1;", []).first?.string(0) == original)
        #expect(Int(try await db.query("SELECT COUNT(*) FROM files WHERE url='mutated://x';", []).first?.int(0) ?? -1) == 0)
        #expect(try await db.currentUserVersion() == 67)

        try await SchemaMigrations.applyOne(db, version: 99, sql: MigrationFaultHarness.backfillValidBatch(newURL: "done://y"))
        #expect(Int(try await db.query("SELECT COUNT(*) FROM files WHERE url='done://y';", []).first?.int(0) ?? -1) == 1)
    }

    // MARK: - Genuine SQLite write/space failure (SQLITE_FULL via max_page_count)

    @Test("A real SQLITE_FULL write failure rolls back with no partial schema; retry after lifting the limit succeeds")
    func writeSpaceFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 67)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 67)
        // DELETE journal so max_page_count is enforced on the write immediately (not deferred to a
        // WAL checkpoint), then cap the file just above current usage.
        try await db.exec("PRAGMA journal_mode = DELETE;")
        let cap = try await MigrationFaultHarness.pageCount(db) + 2
        try await db.exec("PRAGMA max_page_count = \(cap);")

        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.applyOne(db, version: 99,
                sql: "CREATE TABLE big_blob (x BLOB); INSERT INTO big_blob (x) VALUES (zeroblob(8000000));")
        }
        #expect(try await MigrationFixtureBuilder.tableExists(db, "big_blob") == false)
        #expect(try await db.currentUserVersion() == 67)
        #expect((try await snap.failures(in: db)).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))

        // Lift the limit and retry a normal (small) migration.
        try await db.exec("PRAGMA max_page_count = 2147483646;")
        try await SchemaMigrations.applyOne(db, version: 99, sql: "CREATE TABLE big_blob (x BLOB);")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "big_blob") == true)
    }

    // MARK: - Malformed partial schemas (fail-closed, never falsely stamped latest)

    @Test("A partial v67 schema (scope_id dropped) is not falsely accepted — migrate fails closed, data retained")
    func partialV67FailsClosed() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 67)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 67)
        // Remove one of the two v67 columns (drop its index first — SQLite forbids dropping an
        // indexed column). The schema is now a PARTIAL v67.
        try await db.exec("DROP INDEX IF EXISTS idx_claims_scope; ALTER TABLE claims DROP COLUMN scope_id;")
        try await db.setUserVersion(66)

        await #expect(throws: (any Error).self) { try await SchemaMigrations.migrate(db) }
        #expect(try await db.currentUserVersion() != 67, "a partial v67 was falsely stamped latest")
        #expect(try await MigrationFixtureBuilder.columns(db, "claims").contains("scope_kind"))   // no data/columns deleted
        #expect((try await snap.failures(in: db)).isEmpty)                                        // rows retained
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("The self-heal does not falsely accept a schema missing a required table (evidence_block_objects)")
    func selfHealRejectsMissingMarker() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 67)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 67)
        try await db.exec("DROP TABLE evidence_block_objects;")   // remove a v66 marker
        try await db.setUserVersion(66)

        // isSchemaFullyApplied must return false (marker missing) → no self-heal stamp → the pending
        // v67 migration then fails closed (duplicate scope column).
        await #expect(throws: (any Error).self) { try await SchemaMigrations.migrate(db) }
        #expect(try await db.currentUserVersion() != 67, "self-heal falsely stamped a partial schema")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "evidence_block_objects") == false)
        #expect((try await snap.failures(in: db)).isEmpty)
    }

    @Test("A user_version AHEAD of the physical schema never deletes data (documented limitation)")
    func versionAheadOfSchemaIsNonDestructive() async throws {
        // KNOWN LIMITATION (MIGRATION_MATRIX.md): migrate() trusts user_version and does not detect
        // a counter AHEAD of the physical schema. With later real migrations registered (v68+),
        // the pending ones APPLY while the skipped one (here v67) never runs — the counter advances
        // to latest but the skipped DDL stays missing. It must at least never corrupt or delete
        // data; detection/repair remains a documented follow-up (a startup schema-shape verifier).
        // This test pins the SAFE part of that behaviour.
        let db = try await MigrationFixtureBuilder.database(atVersion: 66)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 66)
        #expect(try await hasScope(db) == false)
        try await db.setUserVersion(67)              // counter ahead of the real (v66) schema

        try await SchemaMigrations.migrate(db)       // applies v68+; v67 is silently skipped

        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await hasScope(db) == false, "migrate silently invented the skipped columns")  // not repaired
        #expect(try await MigrationFixtureBuilder.tableExists(db, "professional_issues"))          // v68 applied
        #expect((try await snap.failures(in: db)).isEmpty)                                         // not deleted
    }
}
