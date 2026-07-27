//
//  EmailParticipantMigrationTests.swift
//  KalsmritikoshTests
//
//  OPS-005 — schema v73 (email_participant_occurrences). Locks:
//    1. A fresh database reaches v73 with the table and all four indexes.
//    2. A genuine v72→v73 migration preserves all pre-v73 rows and adds no occurrence rows.
//    3. Deleting a knowledge_objects row cascades to its occurrence rows.
//    4. v73 migration does not add or remove rows from the canonical claims table.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-005 — email_participant_occurrences schema (v73)")
struct EmailParticipantMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_500_000)

    // MARK: - Case 1: fresh v73

    @Test("A fresh database reaches v73 with the table and all four indexes")
    func freshV73HasTableAndIndexes() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        // Pinned `through: 73` — locks this step; MigrationMatrixTests covers head.
        try await SchemaMigrations.migrate(db, through: 73)
        #expect(try await db.currentUserVersion() == 73)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "email_participant_occurrences"),
                "email_participant_occurrences missing after v73")
        // Verify all four indexes exist via sqlite_master.
        let idxRows = try await db.query("""
        SELECT name FROM sqlite_master
         WHERE type = 'index'
           AND tbl_name = 'email_participant_occurrences';
        """, [])
        let idxNames = Set(idxRows.compactMap { $0.string(0) })
        #expect(idxNames.contains("idx_epo_source_ko"),   "idx_epo_source_ko missing")
        #expect(idxNames.contains("idx_epo_entity"),      "idx_epo_entity missing")
        #expect(idxNames.contains("idx_epo_entity_role"), "idx_epo_entity_role missing")
        #expect(idxNames.contains("idx_epo_ko_role"),     "idx_epo_ko_role missing")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
        #expect(SchemaMigrations.migrationListIsConsistent)
    }

    // MARK: - Case 2: v72→v73 preserves existing rows

    @Test("A genuine v72→v73 migration preserves all pre-v73 rows and adds no occurrence rows")
    func v72ToV73PreservesExistingRows() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 72)
        #expect(try await db.currentUserVersion() == 72)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 72)
        try await SchemaMigrations.migrate(db, through: 73)
        #expect(try await db.currentUserVersion() == 73)
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "Preserved rows lost after v72→v73: \(failures)")
        let occCount = try await db.query(
            "SELECT COUNT(*) FROM email_participant_occurrences;", [])
        #expect(Int(occCount.first?.int(0) ?? -1) == 0,
                "Expected 0 occurrence rows after clean v73 migration")
    }

    // MARK: - Case 3: CASCADE delete from knowledge_objects

    @Test("Deleting a knowledge_objects row cascades to its occurrence rows")
    func koDeleteCascadesToOccurrences() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 73)

        let fileID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
            [.uuid(fileID), .text("file://\(fileID)"), .text("eml")])

        let koID = UUID()
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("eml"), .text("test"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])

        let entityID = UUID()
        let occID = UUID()
        try await db.exec("""
        INSERT INTO email_participant_occurrences
            (id, source_ko_id, entity_id, role, raw_address, display_name, created_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(occID), .uuid(koID), .uuid(entityID), .text("from"),
              .text("sender@example.com"), .null, .real(t0.timeIntervalSince1970)])

        // Deleting the KO must cascade.
        try await db.exec("DELETE FROM knowledge_objects WHERE id = ?;", [.uuid(koID)])

        let remaining = try await db.query(
            "SELECT COUNT(*) FROM email_participant_occurrences WHERE id = ?;", [.uuid(occID)])
        #expect(Int(remaining.first?.int(0) ?? -1) == 0,
                "Occurrence row not cascade-deleted when KO is removed")
    }

    // MARK: - Case 4: canonical isolation

    @Test("v73 migration does not add or remove rows from the canonical claims table")
    func v73DoesNotTouchCanonicalClaims() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 72)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 72)
        let before = try await db.query("SELECT COUNT(*) FROM claims;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)
        #expect(beforeCount > 0, "test assumption: seedPreservationRows seeds at least one claim at v72")

        try await SchemaMigrations.migrate(db, through: 73)

        let after = try await db.query("SELECT COUNT(*) FROM claims;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount,
                "v73 must not add or remove canonical claims during migration")
    }
}
