//
//  UniversalSourceIntakeMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-001 — schema v82: source_versions gains intake custody metadata (a rebuild),
//  the append-only source_intake_receipts ledger and exact source_version_relations
//  are added, and ingest_file_attempts gains version-linked columns. Proves reach,
//  genuine v81→v82 upgrade, preservation + backfill, one-current repair, every CHECK,
//  self-heal, repeat, and injected-fault rollback.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001 — v82 universal safe intake migration")
struct UniversalSourceIntakeMigrationTests {

    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)

    private func seedFile(_ db: Database, id: UUID, url: String = "file:///x/report.pdf",
                          type: String = "pdf", size: Int64 = 10, hash: String? = nil) async throws {
        try await db.exec("""
            INSERT INTO files (id, url, source_type, size_bytes, modified_at, content_hash, availability)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(id), .text(url), .text(type), .integer(size), .real(100), .optionalText(hash), .text("available")])
    }

    /// A v37-shape source_versions row (no custody columns), for pre-v82 seeding.
    private func seedVersionV81(_ db: Database, id: UUID, logical: UUID, hash: String,
                                documentID: UUID? = nil, isCurrent: Int = 1, validFrom: Double = 100) async throws {
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, original_url, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), documentID.map(SQLValue.uuid) ?? .null, .text(hash),
                  .real(validFrom), .integer(Int64(isCurrent)), .text("file:///x/report.pdf"), .real(50)])
    }

    private func sourceVersionsSQL(_ db: Database) async throws -> String {
        try await db.query("SELECT sql FROM sqlite_master WHERE type='table' AND name='source_versions';", [])
            .first?.string(0) ?? ""
    }

    // MARK: - Reach + upgrade + preservation

    @Test("A fresh database reaches v82 with the intake tables and custody columns")
    func freshV82() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        #expect(try await db.currentUserVersion() == 82)
        for t in ["source_versions", "source_intake_receipts", "source_version_relations", "ingest_file_attempts"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "missing \(t)")
        }
        let cols = try await MigrationFixtureBuilder.columns(db, "source_versions")
        #expect(cols.isSuperset(of: ["custody_mode", "preservation_status", "intake_recorded_at",
                                     "detection_basis", "filename", "detected_type", "size_bytes"]))
        let attemptCols = try await MigrationFixtureBuilder.columns(db, "ingest_file_attempts")
        #expect(attemptCols.isSuperset(of: ["logical_source_id", "source_version_id"]))
    }

    @Test("A genuine v81 database upgrades to v82, preserving source versions and backfilling custody")
    func v81ToV82PreservesAndBackfills() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let fileID = UUID(); try await seedFile(db, id: fileID, hash: hashA)
        let docID = UUID()
        try await db.exec("""
            INSERT INTO source_documents (id, logical_source_id, filename, detected_type, mime_type, content_hash, extraction_status, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(docID), .uuid(fileID), .text("report.pdf"), .text("pdf"), .text("application/pdf"),
                  .text(hashA), .text("complete"), .real(50)])
        let versionID = UUID()
        try await seedVersionV81(db, id: versionID, logical: fileID, hash: hashA, documentID: docID)

        try await SchemaMigrations.migrate(db, through: 82)

        #expect(try await db.currentUserVersion() == 82)
        #expect(try await db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        let row = try #require(try await db.query("""
            SELECT filename, detected_type, custody_mode, preservation_status, detection_basis, intake_recorded_at
              FROM source_versions WHERE id = ?;
            """, [.uuid(versionID)]).first)
        #expect(row.string(0) == "report.pdf")
        #expect(row.string(1) == "pdf")
        #expect(row.string(2) == "referenced")
        #expect(row.string(3) == "legacyImported")
        #expect(row.string(4) == "unknown")
        #expect(row.double(5) == 50)                        // intake_recorded_at = created_at
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
    }

    @Test("Backfill falls back to a legacy filename when no source document or file is present")
    func backfillLegacyFilename() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        let orphanLogical = UUID()
        let versionID = UUID()
        try await seedVersionV81(db, id: versionID, logical: orphanLogical, hash: hashA)  // no file, no doc
        try await SchemaMigrations.migrate(db, through: 82)
        let filename = try await db.query("SELECT filename FROM source_versions WHERE id = ?;", [.uuid(versionID)]).first?.string(0)
        #expect(filename?.hasPrefix("legacy-source-") == true)
        #expect((filename?.isEmpty ?? true) == false)
    }

    @Test("Legacy multiple-current rows for one logical source are repaired to exactly one current")
    func oneCurrentVersionRepair() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        let logical = UUID(); try await seedFile(db, id: logical, hash: hashB)
        let older = UUID(); try await seedVersionV81(db, id: older, logical: logical, hash: hashA, isCurrent: 1, validFrom: 100)
        let newer = UUID(); try await seedVersionV81(db, id: newer, logical: logical, hash: hashB, isCurrent: 1, validFrom: 200)

        try await SchemaMigrations.migrate(db, through: 82)   // partial unique index would reject 2 current rows

        #expect(try await db.query("SELECT COUNT(*) FROM source_versions WHERE logical_source_id = ? AND is_current = 1;",
                                   [.uuid(logical)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT is_current FROM source_versions WHERE id = ?;", [.uuid(newer)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT is_current FROM source_versions WHERE id = ?;", [.uuid(older)]).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 2)   // nothing deleted
    }

    @Test("The partial unique index enforces exactly one current version per logical source")
    func oneCurrentPartialUniqueIndex() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        let logical = UUID(); try await seedFile(db, id: logical, hash: hashA)
        func insertCurrent(_ id: UUID, hash: String) async throws {
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(logical), .text(hash), .real(100), .integer(1), .real(100),
                      .text("f.pdf"), .text("pdf"), .text("magicBytes"), .integer(1), .text("referenced"),
                      .text("referenceRecorded"), .real(100)])
        }
        try await insertCurrent(UUID(), hash: hashA)
        await #expect(throws: (any Error).self) { try await insertCurrent(UUID(), hash: hashB) }
    }

    // MARK: - source_versions CHECKs

    @Test("source_versions rejects blank filename/type, bad detection basis, and negative size")
    func sourceVersionChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        let logical = UUID(); try await seedFile(db, id: logical, hash: hashA)
        func insert(filename: String = "f.pdf", type: String = "pdf", basis: String = "magicBytes",
                    hash: String, size: Int64 = 1, custody: String = "referenced",
                    preservation: String = "referenceRecorded", vault: SQLValue = .null) async throws {
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, vault_address, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(logical), .text(hash), .real(100), .integer(0), .real(100),
                      .text(filename), .text(type), .text(basis), .integer(size), .text(custody),
                      .text(preservation), vault, .real(100)])
        }
        await #expect(throws: (any Error).self) { try await insert(filename: "  ", hash: self.hashA) }
        await #expect(throws: (any Error).self) { try await insert(type: "  ", hash: self.hashA) }
        await #expect(throws: (any Error).self) { try await insert(basis: "guess", hash: self.hashA) }
        await #expect(throws: (any Error).self) { try await insert(hash: self.hashA, size: -1) }
        // a valid referenced row is accepted
        try await insert(hash: hashA)
    }

    @Test("managedCopyStored requires managed custody and a vault address")
    func managedCopyConsistencyCheck() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        let logical = UUID(); try await seedFile(db, id: logical, hash: hashA)
        func insert(custody: String, preservation: String, vault: SQLValue) async throws {
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, vault_address, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(logical), .text(hashA), .real(100), .integer(0), .real(100),
                      .text("f.pdf"), .text("pdf"), .text("magicBytes"), .integer(1), .text(custody),
                      .text(preservation), vault, .real(100)])
        }
        // referenced source claiming a stored managed copy → rejected
        await #expect(throws: (any Error).self) { try await insert(custody: "referenced", preservation: "managedCopyStored", vault: .text(self.hashA)) }
        // managed + managedCopyStored but no vault address → rejected
        await #expect(throws: (any Error).self) { try await insert(custody: "managed", preservation: "managedCopyStored", vault: .null) }
        // managed copy FAILURE remains a valid version with a visible failed state
        try await insert(custody: "managed", preservation: "managedCopyFailed", vault: .null)
        // managed + stored + vault → accepted
        try await insert(custody: "managed", preservation: "managedCopyStored", vault: .text(hashA))
    }

    // MARK: - receipts + relations constraints

    @Test("source_intake_receipts enforces its closed vocabularies and hash normalization")
    func intakeReceiptConstraints() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let fileID = UUID(); try await seedFile(db, id: fileID, hash: hashA)
        let versionID = UUID()
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(versionID), .uuid(fileID), .text(hashA), .real(100), .integer(1), .real(100),
                  .text("f.pdf"), .text("pdf"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])
        func insert(outcome: String, hash: String) async throws {
            try await db.exec("""
                INSERT INTO source_intake_receipts (id, occurrence_file_id, logical_source_id, source_version_id, outcome, content_hash, custody_mode, preservation_status, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(fileID), .uuid(fileID), .uuid(versionID), .text(outcome),
                      .text(hash), .text("referenced"), .text("referenceRecorded"), .real(100)])
        }
        await #expect(throws: (any Error).self) { try await insert(outcome: "invented", hash: self.hashA) }
        await #expect(throws: (any Error).self) { try await insert(outcome: "unchanged", hash: self.hashA.uppercased()) }
        try await insert(outcome: "newLogicalSource", hash: hashA)
    }

    @Test("source_version_relations rejects self-relations, unknown relations, and duplicates")
    func versionRelationConstraints() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let fileID = UUID(); try await seedFile(db, id: fileID, hash: hashA)
        func insertVersion(_ id: UUID, hash: String, current: Int) async throws {
            try await db.exec("""
                INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                    filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(fileID), .text(hash), .real(100), .integer(Int64(current)), .real(100),
                      .text("f"), .text("pdf"), .text("magicBytes"), .integer(1), .text("referenced"),
                      .text("referenceRecorded"), .real(100)])
        }
        let parent = UUID(); try await insertVersion(parent, hash: hashA, current: 1)
        let child = UUID(); try await insertVersion(child, hash: hashB, current: 0)
        func relate(_ p: UUID, _ c: UUID, _ relation: String) async throws {
            try await db.exec("""
                INSERT INTO source_version_relations (id, parent_source_version_id, child_source_version_id, relation, created_at)
                VALUES (?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(p), .uuid(c), .text(relation), .real(100)])
        }
        await #expect(throws: (any Error).self) { try await relate(parent, parent, "attachment") }   // self
        await #expect(throws: (any Error).self) { try await relate(parent, child, "sibling") }        // unknown
        try await relate(parent, child, "attachment")
        await #expect(throws: (any Error).self) { try await relate(parent, child, "attachment") }      // duplicate
    }

    // MARK: - repeat / self-heal / injected fault

    @Test("Re-running migrate over a v82 database is a safe no-op")
    func v82Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 82)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("The self-heal sentinel recognises the v82 markers and reconciles a stale counter")
    func selfHealRecognizesV82() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        try await db.setUserVersion(80)               // stale, but schema is fully v82
        try await SchemaMigrations.migrate(db)         // self-heal stamps 82, no destructive replay
        #expect(try await db.currentUserVersion() == 82)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_intake_receipts"))
    }

    @Test("A genuine v81 schema upgrades to v82, applying the custody columns (the sentinel does not skip v82)")
    func v81SchemaGenuinelyUpgrades() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        #expect(try await MigrationFixtureBuilder.columns(db, "source_versions").contains("custody_mode") == false)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 82)
        #expect(try await MigrationFixtureBuilder.columns(db, "source_versions").contains("custody_mode"))
    }

    @Test("An injected failure inside the v82 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 81)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 82,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 82)))
        }
        #expect(try await db.currentUserVersion() == 81)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_intake_receipts") == false)
        #expect(try await MigrationFixtureBuilder.columns(db, "source_versions").contains("custody_mode") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from an early version reaches v82 with a clean FK graph")
    func milestoneReachesV82() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 82)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
