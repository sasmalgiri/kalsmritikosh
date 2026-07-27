//
//  WorkProductRunMigrationTests.swift
//  KalsmritikoshTests
//
//  OPS-004 — schema v72 (WorkProductRun persistence). Locks:
//    1. A fresh database reaches v72 with all four WPR tables and clean state.
//    2. A genuine v71→v72 migration preserves all pre-v72 rows and adds no WPR rows.
//    3. Deleting a work_product_runs row cascades to sections, claim occurrences, and manifest.
//    4. v72 migration does not add or remove rows from the canonical claims table.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-004 — WorkProductRun schema (v72)")
struct WorkProductRunMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Case 1: fresh v72

    @Test("A fresh database reaches v72 with all four WPR tables and clean state")
    func freshV72HasAllFourTablesAndCleanState() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        // Pinned `through: 72` — locks this step; MigrationMatrixTests covers head.
        try await SchemaMigrations.migrate(db, through: 72)
        #expect(try await db.currentUserVersion() == 72)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_product_runs"),
                "work_product_runs missing after v72")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_product_sections"),
                "work_product_sections missing after v72")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_product_claim_occurrences"),
                "work_product_claim_occurrences missing after v72")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_product_manifests"),
                "work_product_manifests missing after v72")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
        #expect(SchemaMigrations.latestVersion == 72)
        #expect(SchemaMigrations.migrationListIsConsistent)
    }

    // MARK: - Case 2: v71→v72 preserves existing rows, adds no WPR rows

    @Test("A genuine v71→v72 migration preserves all pre-v72 rows and adds no WPR rows")
    func v71ToV72PreservesExistingRows() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 71)
        #expect(try await db.currentUserVersion() == 71)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 71)
        try await SchemaMigrations.migrate(db, through: 72)
        #expect(try await db.currentUserVersion() == 72)
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "Preserved rows lost after v71→v72: \(failures)")
        let runCount = try await db.query("SELECT COUNT(*) FROM work_product_runs;", [])
        #expect(Int(runCount.first?.int(0) ?? -1) == 0,
                "Expected 0 WPR rows after a clean v72 migration (only new schema, no data seeded)")
    }

    // MARK: - Case 3: CASCADE delete

    @Test("Deleting a work_product_runs row cascades to sections, claim occurrences, and manifest")
    func runDeleteCascadesToAllChildren() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 72)

        let wsID = UUID()
        try await db.exec(
            "INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
            [.uuid(wsID), .text("CascadeWS"), .text("general"),
             .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])

        let runID = UUID()
        let sectionID = UUID()
        let claimID = UUID()
        try await db.exec("""
        INSERT INTO work_product_runs
            (id, workspace_id, template, title, subject_label,
             schema_version, app_version, composed_at, finding_count)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(runID), .uuid(wsID), .text("generalSummary"), .text("T"), .text("S"),
              .integer(72), .text("1.0"), .real(t0.timeIntervalSince1970), .integer(0)])
        try await db.exec(
            "INSERT INTO work_product_sections (id, run_id, ordinal, title) VALUES (?,?,?,?);",
            [.uuid(sectionID), .uuid(runID), .integer(0), .text("S")])
        try await db.exec("""
        INSERT INTO work_product_claim_occurrences
            (id, section_id, run_id, ordinal, text, epistemic_status)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(claimID), .uuid(sectionID), .uuid(runID), .integer(0),
              .text("A fact."), .text("directEvidence")])
        try await db.exec(
            "INSERT INTO work_product_manifests (run_id, exported_at, selected_finding_count) VALUES (?,?,?);",
            [.uuid(runID), .real(t0.timeIntervalSince1970), .integer(0)])

        try await db.exec("DELETE FROM work_product_runs WHERE id = ?;", [.uuid(runID)])

        let secs = try await db.query(
            "SELECT COUNT(*) FROM work_product_sections WHERE run_id = ?;", [.uuid(runID)])
        let claims = try await db.query(
            "SELECT COUNT(*) FROM work_product_claim_occurrences WHERE run_id = ?;", [.uuid(runID)])
        let mf = try await db.query(
            "SELECT COUNT(*) FROM work_product_manifests WHERE run_id = ?;", [.uuid(runID)])
        #expect(Int(secs.first?.int(0) ?? -1) == 0, "work_product_sections not cascade-deleted")
        #expect(Int(claims.first?.int(0) ?? -1) == 0, "work_product_claim_occurrences not cascade-deleted")
        #expect(Int(mf.first?.int(0) ?? -1) == 0, "work_product_manifests not cascade-deleted")
    }

    // MARK: - Case 4: canonical isolation

    @Test("v72 migration does not add or remove rows from the canonical claims table")
    func v72DoesNotTouchCanonicalClaimsCount() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 71)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 71)
        let before = try await db.query("SELECT COUNT(*) FROM claims;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)
        // Seed must include at least one claim at v71 (claims table present since v63).
        #expect(beforeCount > 0, "test assumption: seedPreservationRows seeds at least one claim at v71")

        try await SchemaMigrations.migrate(db, through: 72)

        let after = try await db.query("SELECT COUNT(*) FROM claims;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount,
                "v72 must not add or remove canonical claims during migration")
    }
}
