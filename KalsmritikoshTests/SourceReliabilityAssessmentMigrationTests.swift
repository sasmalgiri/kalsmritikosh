//
//  SourceReliabilityAssessmentMigrationTests.swift
//  KalsmritikoshTests
//
//  OPS-006 — schema v74 (source_reliability_assessments). Locks:
//    1. A fresh database reaches v74 with the table and both indexes present.
//    2. A genuine v73→v74 migration preserves all pre-v74 rows and adds no SRA rows.
//    3. Hard-deleting a source_versions row cascades to its assessments.
//    4. v74 migration does not add or remove rows from the canonical claims table.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-006 — SourceReliabilityAssessment schema (v74)")
struct SourceReliabilityAssessmentMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

    // MARK: - Shared helpers

    private func insertSourceVersion(_ db: Database, id: String) async throws {
        try await db.exec("""
        INSERT INTO source_versions
            (id, logical_source_id, content_hash, valid_from, created_at)
        VALUES (?, ?, ?, ?, ?);
        """, [.text(id), .text(UUID().uuidString), .text("hash-\(id)"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func insertAssessment(
        _ db: Database, id: String, svID: String,
        reliability: String = "high", independence: String = "independent"
    ) async throws {
        try await db.exec("""
        INSERT INTO source_reliability_assessments
            (id, source_version_id, reliability, independence, assessed_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """, [.text(id), .text(svID), .text(reliability), .text(independence),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    // MARK: - Case 1: fresh v74

    @Test("A fresh database reaches v74 with the table and both indexes present")
    func freshV74HasTableAndIndexes() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        // Pinned `through: 74` — locks this step; MigrationMatrixTests covers head.
        try await SchemaMigrations.migrate(db, through: 74)
        #expect(try await db.currentUserVersion() == 74)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_reliability_assessments"),
                "source_reliability_assessments missing after v74")
        #expect(SchemaMigrations.migrationListIsConsistent)

        // Both named indexes must exist.
        let indexes = try await db.query("""
        SELECT name FROM sqlite_master
         WHERE type='index' AND tbl_name='source_reliability_assessments';
        """, [])
        let names = Set(indexes.compactMap { $0.string(0) })
        #expect(names.contains("idx_sra_source_version"), "idx_sra_source_version missing")
        #expect(names.contains("idx_sra_active"), "idx_sra_active missing")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - Case 2: v73→v74 preserves existing rows, adds no SRA rows

    @Test("A genuine v73→v74 migration preserves all pre-v74 rows and adds no SRA rows")
    func v73ToV74PreservesExistingRows() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 73)
        #expect(try await db.currentUserVersion() == 73)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 73)

        try await SchemaMigrations.migrate(db, through: 74)

        #expect(try await db.currentUserVersion() == 74)
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "Preserved rows lost after v73→v74: \(failures)")
        let sraCount = try await db.query(
            "SELECT COUNT(*) FROM source_reliability_assessments;", [])
        #expect(Int(sraCount.first?.int(0) ?? -1) == 0,
                "Expected 0 SRA rows after a clean v74 migration (no backfill)")
    }

    // MARK: - Case 3: CASCADE delete from source_versions

    @Test("Hard-deleting a source_versions row cascades to its assessments")
    func sourceVersionDeleteCascadesToAssessments() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 74)

        let svID = UUID().uuidString
        try await insertSourceVersion(db, id: svID)
        let aID = UUID().uuidString
        try await insertAssessment(db, id: aID, svID: svID)

        let before = try await db.query(
            "SELECT COUNT(*) FROM source_reliability_assessments WHERE source_version_id = ?;",
            [.text(svID)])
        #expect(Int(before.first?.int(0) ?? 0) == 1, "Assessment must exist before delete")

        try await db.exec("DELETE FROM source_versions WHERE id = ?;", [.text(svID)])

        let after = try await db.query(
            "SELECT COUNT(*) FROM source_reliability_assessments WHERE source_version_id = ?;",
            [.text(svID)])
        #expect(Int(after.first?.int(0) ?? -1) == 0,
                "SQL CASCADE must remove assessments when source_version is deleted")
    }

    // MARK: - Case 4: canonical isolation

    @Test("v74 migration does not add or remove rows from the canonical claims table")
    func v74DoesNotTouchCanonicalClaims() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 73)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 73)
        let before = try await db.query("SELECT COUNT(*) FROM claims;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)
        #expect(beforeCount > 0, "test assumption: seedPreservationRows seeds at least one claim at v73")

        try await SchemaMigrations.migrate(db, through: 74)

        let after = try await db.query("SELECT COUNT(*) FROM claims;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount,
                "v74 must not add or remove canonical claims during migration")
    }
}
