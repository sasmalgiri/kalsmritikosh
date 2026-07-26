//
//  SensitiveScopeMigrationTests.swift
//  KalsmritikoshTests
//
//  OPS-003A — schema v71 (SensitiveScope protection ledger). Locks:
//    1. A fresh database reaches v71 with both SSA tables and clean integrity.
//    2. A genuine v70→v71 migration preserves existing workflow rows (no SSA rows for
//       non-privileged objects).
//    3. A legacy knowledge_objects.privileged=1 row gets exactly one backfill
//       assignment row with origin='legacy_privileged_column'.
//    4. A non-privileged KO produces no assignment row.
//    5. A database with multiple privileged KOs gets one assignment per privileged KO.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-003A — SensitiveScope schema (v71)")
struct SensitiveScopeMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Case 1: fresh v71

    @Test("A fresh database reaches v71 with both SSA tables and clean state")
    func freshV71HasBothTablesAndCleanState() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        // Pinned `through: 71` — locks this step; MigrationMatrixTests covers head.
        try await SchemaMigrations.migrate(db, through: 71)
        #expect(try await db.currentUserVersion() == 71)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "sensitive_scope_assignments"),
                "sensitive_scope_assignments table missing after v71")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "sensitive_scope_reviews"),
                "sensitive_scope_reviews table missing after v71")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
        // SchemaMigrations.latestVersion must now be 71.
        #expect(SchemaMigrations.latestVersion == 71)
    }

    // MARK: - Case 2: v70→v71 preserves workflow rows, no SSA rows for non-privileged objects

    @Test("A genuine v70→v71 migration preserves existing Task/Issue/Deadline rows and adds no SSA rows")
    func v70ToV71PreservesExistingRows() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 70)
        #expect(try await db.currentUserVersion() == 70)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 70)

        // Seed a non-privileged KO so we can verify it gets no backfill row.
        let wsID = UUID()
        let fileID = UUID()
        let koID = UUID()
        try await db.exec(
            "INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
            [.uuid(wsID), .text("WS-70"), .text("general"), .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
        try await db.exec(
            "INSERT INTO files (id, url, source_type, size_bytes, modified_at) VALUES (?,?,?,?,?);",
            [.uuid(fileID), .text("/tmp/test.txt"), .text("text"), .integer(0), .real(t0.timeIntervalSince1970)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, privileged)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("content"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970), .integer(0)])

        try await SchemaMigrations.migrate(db)     // 70 → 71

        #expect(try await db.currentUserVersion() == 71)
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "v70→v71 lost canonical rows: \(failures)")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "sensitive_scope_assignments"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "sensitive_scope_reviews"))

        // Non-privileged KO must produce no SSA row.
        let ssaCount = Int(try await db.query(
            "SELECT COUNT(*) FROM sensitive_scope_assignments WHERE target_id = ?;",
            [.uuid(koID)]).first?.int(0) ?? 0)
        #expect(ssaCount == 0, "Non-privileged KO must not get a backfill assignment")

        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - Case 3: legacy privileged KO gets exactly one backfill assignment

    @Test("A legacy knowledge_objects.privileged=1 row gets one restricted+privileged backfill assignment")
    func legacyPrivilegedKOGetsMigratedToAssignment() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 70)
        let fileID = UUID()
        let koID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type, size_bytes, modified_at) VALUES (?,?,?,?,?);",
            [.uuid(fileID), .text("/tmp/priv.txt"), .text("text"), .integer(0), .real(t0.timeIntervalSince1970)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, privileged)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("secret content"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970), .integer(1)])

        try await SchemaMigrations.migrate(db)     // 70 → 71

        #expect(try await db.currentUserVersion() == 71)

        // Exactly one SSA row must exist for this KO.
        let rows = try await db.query("""
        SELECT target_kind, target_id, sensitivity, privileged, origin
          FROM sensitive_scope_assignments
         WHERE target_id = ?;
        """, [.uuid(koID)])
        #expect(rows.count == 1, "Expected 1 backfill assignment for privileged KO, got \(rows.count)")

        let row = try #require(rows.first)
        #expect(row.string(0) == "knowledgeObject")
        #expect(row.uuid(1) == koID)
        #expect(row.int(2) == 3,                             // SensitivityLevel.restricted.rawValue
                "Backfill sensitivity must be restricted (3)")
        #expect(row.int(3) == 1,                             // privileged = true
                "Backfill must preserve the privileged flag")
        #expect(row.string(4) == "legacy_privileged_column",
                "Backfill origin must be 'legacy_privileged_column'")

        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - Case 4: non-privileged KO produces no assignment row

    @Test("A knowledge_objects.privileged=0 row produces no SSA row")
    func nonPrivilegedKOProducesNoAssignmentRow() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 70)
        let fileID = UUID()
        let koID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type, size_bytes, modified_at) VALUES (?,?,?,?,?);",
            [.uuid(fileID), .text("/tmp/open.txt"), .text("text"), .integer(0), .real(t0.timeIntervalSince1970)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, privileged)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("text"), .text("open content"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970), .integer(0)])

        try await SchemaMigrations.migrate(db)

        let count = Int(try await db.query(
            "SELECT COUNT(*) FROM sensitive_scope_assignments;", []).first?.int(0) ?? 0)
        #expect(count == 0, "Non-privileged KO must produce no SSA rows")
    }

    // MARK: - Case 5: multiple privileged KOs get one assignment each

    @Test("Multiple privileged KOs each get exactly one backfill assignment row")
    func multiplePrivilegedKOsGetSeparateAssignments() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 70)
        let fileID = UUID()
        try await db.exec(
            "INSERT INTO files (id, url, source_type, size_bytes, modified_at) VALUES (?,?,?,?,?);",
            [.uuid(fileID), .text("/tmp/multi.txt"), .text("text"), .integer(0), .real(t0.timeIntervalSince1970)])

        // Seed 3 KOs: 2 privileged, 1 not.
        let privIDs = [UUID(), UUID()]
        let openID = UUID()
        for (i, kid) in privIDs.enumerated() {
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, privileged)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(kid), .uuid(fileID), .text("text"), .text("priv \(i)"),
                  .real(t0.timeIntervalSince1970 + Double(i)), .real(t0.timeIntervalSince1970), .integer(1)])
        }
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, privileged)
        VALUES (?,?,?,?,?,?,?);
        """, [.uuid(openID), .uuid(fileID), .text("text"), .text("open"),
              .real(t0.timeIntervalSince1970 + 10), .real(t0.timeIntervalSince1970), .integer(0)])

        try await SchemaMigrations.migrate(db)

        let totalSSA = Int(try await db.query(
            "SELECT COUNT(*) FROM sensitive_scope_assignments;", []).first?.int(0) ?? 0)
        #expect(totalSSA == 2, "Expected exactly 2 SSA rows (one per privileged KO), got \(totalSSA)")

        for kid in privIDs {
            let n = Int(try await db.query(
                "SELECT COUNT(*) FROM sensitive_scope_assignments WHERE target_id = ?;",
                [.uuid(kid)]).first?.int(0) ?? 0)
            #expect(n == 1, "Each privileged KO must have exactly 1 SSA row")
        }
        let openSSA = Int(try await db.query(
            "SELECT COUNT(*) FROM sensitive_scope_assignments WHERE target_id = ?;",
            [.uuid(openID)]).first?.int(0) ?? 0)
        #expect(openSSA == 0, "Non-privileged KO must have no SSA rows")
    }
}
