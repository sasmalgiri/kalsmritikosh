//
//  SinglePathIntakeIntegrityMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-001.1 — schema v83 hardens the intake ledger: a non-legacy source version must
//  carry a normalized SHA-256, `supersedes` must stay within the logical source, intake
//  receipts are pinned to the exact version hash + logical source by composite FK, and
//  ingest attempts carry both custody ids or neither. Proves reach, v82→v83 preservation +
//  demotion, every new constraint, self-heal, repeat and injected-fault rollback.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001.1 — v83 intake ledger integrity migration")
struct SinglePathIntakeIntegrityMigrationTests {

    private let sha = String(repeating: "a", count: 64)
    private let sha2 = String(repeating: "b", count: 64)

    private func seedFile(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString).pdf"), .text("pdf"), .text("available")])
    }

    /// Insert a source version at v83 with all custody columns.
    private func insertVersion(_ db: Database, id: UUID, logical: UUID, hash: String, current: Int = 1,
                               preservation: String = "referenceRecorded", supersedes: SQLValue = .null,
                               validFrom: Double = 100) async throws {
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, supersedes, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), .text(hash), supersedes, .real(validFrom), .integer(Int64(current)), .real(100),
                  .text("f.pdf"), .text("pdf"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text(preservation), .real(100)])
    }

    private func versionSQL(_ db: Database) async throws -> String {
        try await db.query("SELECT sql FROM sqlite_master WHERE type='table' AND name='source_versions';", []).first?.string(0) ?? ""
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v83 with the hardened intake ledger")
    func freshV83() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        #expect(try await db.currentUserVersion() == 83)
        #expect(try await versionSQL(db).contains("length(content_hash) = 64"))
        let receiptsSQL = try await db.query("SELECT sql FROM sqlite_master WHERE name='source_intake_receipts';", []).first?.string(0) ?? ""
        #expect(receiptsSQL.contains("source_versions(id, content_hash)"))
        let attemptsSQL = try await db.query("SELECT sql FROM sqlite_master WHERE name='ingest_file_attempts';", []).first?.string(0) ?? ""
        #expect(attemptsSQL.contains("(logical_source_id IS NULL) = (source_version_id IS NULL)"))
    }

    @Test("v82→v83 preserves rows and demotes any non-SHA custody version to legacy-imported")
    func v82ToV83PreservesAndDemotes() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let file = UUID(); try await seedFile(db, id: file)
        // A v82 custody row (referenceRecorded) with a NON-SHA hash — legal at v82, must be demoted at v83.
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(file), .text("short-hash"), .real(100), .integer(1), .real(100),
                  .text("f.pdf"), .text("pdf"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])

        try await SchemaMigrations.migrate(db, through: 83)

        #expect(try await db.currentUserVersion() == 83)
        #expect(try await db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        // demoted: preservation is now legacyImported (so the SHA rule does not reject it)
        #expect(try await db.query("SELECT preservation_status FROM source_versions;", []).first?.string(0) == "legacyImported")
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
    }

    // MARK: - SHA-256 rule

    @Test("A non-legacy custody version requires a normalized SHA-256; legacy is exempt")
    func nonLegacyRequiresSHA() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        let file = UUID(); try await seedFile(db, id: file)
        // referenceRecorded (non-legacy) + short hash → rejected
        await #expect(throws: (any Error).self) {
            try await self.insertVersion(db, id: UUID(), logical: file, hash: "short", preservation: "referenceRecorded")
        }
        // referenceRecorded + uppercase SHA → rejected (must be lowercase)
        await #expect(throws: (any Error).self) {
            try await self.insertVersion(db, id: UUID(), logical: file, hash: self.sha.uppercased(), preservation: "referenceRecorded")
        }
        // legacyImported + any hash → accepted
        try await insertVersion(db, id: UUID(), logical: file, hash: "anything", preservation: "legacyImported")
        // referenceRecorded + proper SHA → accepted
        let f2 = UUID(); try await seedFile(db, id: f2)
        try await insertVersion(db, id: UUID(), logical: f2, hash: sha, preservation: "referenceRecorded")
    }

    // MARK: - supersedes stays within the logical source

    @Test("supersedes must reference a version of the same logical source")
    func supersedesStaysWithinLogicalSource() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let fileA = UUID(); try await seedFile(db, id: fileA)
        let fileB = UUID(); try await seedFile(db, id: fileB)
        let vA = UUID(); try await insertVersion(db, id: vA, logical: fileA, hash: sha, current: 0)
        // A version of fileB claiming to supersede fileA's version → cross-source, rejected.
        await #expect(throws: (any Error).self) {
            try await self.insertVersion(db, id: UUID(), logical: fileB, hash: self.sha2, supersedes: .uuid(vA))
        }
        // Same-logical supersession is accepted.
        try await insertVersion(db, id: UUID(), logical: fileA, hash: sha2, supersedes: .uuid(vA))
    }

    // MARK: - Receipt hash pin

    @Test("An intake receipt whose hash differs from its source version is rejected by the composite FK")
    func receiptHashMustMatchVersion() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let file = UUID(); try await seedFile(db, id: file)
        let version = UUID(); try await insertVersion(db, id: version, logical: file, hash: sha)
        func insertReceipt(hash: String) async throws {
            try await db.exec("""
                INSERT INTO source_intake_receipts (id, occurrence_file_id, logical_source_id, source_version_id, outcome, content_hash, custody_mode, preservation_status, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(file), .uuid(file), .uuid(version), .text("newLogicalSource"),
                      .text(hash), .text("referenced"), .text("referenceRecorded"), .real(100)])
        }
        await #expect(throws: (any Error).self) { try await insertReceipt(hash: self.sha2) }   // hash mismatch
        try await insertReceipt(hash: sha)                                                     // matching hash OK
    }

    // MARK: - Attempts both-or-neither

    @Test("An ingest attempt must carry both custody ids or neither, matching a real version")
    func attemptBothOrNeither() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let file = UUID(); try await seedFile(db, id: file)
        let version = UUID(); try await insertVersion(db, id: version, logical: file, hash: sha)
        func insertAttempt(logical: SQLValue, version sv: SQLValue) async throws {
            try await db.exec("""
                INSERT INTO ingest_file_attempts (id, url, status, attempted_at, logical_source_id, source_version_id)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .text("file:///x.pdf"), .text("queryable"), .real(100), logical, sv])
        }
        // only one present → rejected
        await #expect(throws: (any Error).self) { try await insertAttempt(logical: .uuid(file), version: .null) }
        await #expect(throws: (any Error).self) { try await insertAttempt(logical: .null, version: .uuid(version)) }
        // both null (pre-intake) → accepted
        try await insertAttempt(logical: .null, version: .null)
        // both present + matching a real version → accepted
        try await insertAttempt(logical: .uuid(file), version: .uuid(version))
        // both present but NOT a real (version, logical) pair → rejected by composite FK
        await #expect(throws: (any Error).self) { try await insertAttempt(logical: .uuid(UUID()), version: .uuid(UUID())) }
    }

    // MARK: - self-heal / repeat / fault

    @Test("A genuine v83 database migrates forward to the latest schema without destructive replay")
    func v83MigratesToLatest() async throws {
        // A real v83 database carries userVersion 83; migrate() runs only the pending
        // migration(s) after it (v84+), never re-applying an already-present version.
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("A genuine v82 schema upgrades to v83, applying the SHA rule")
    func v82GenuinelyUpgrades() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        #expect(try await versionSQL(db).contains("length(content_hash) = 64") == false)
        try await SchemaMigrations.migrate(db, through: 83)
        #expect(try await db.currentUserVersion() == 83)
        #expect(try await versionSQL(db).contains("length(content_hash) = 64"))
    }

    @Test("Re-running migrate over a v83 database is a safe no-op")
    func v83Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await SchemaMigrations.migrate(db, through: 83)
        #expect(try await db.currentUserVersion() == 83)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v83 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 82)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 83,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 83)))
        }
        #expect(try await db.currentUserVersion() == 82)
        #expect(try await versionSQL(db).contains("length(content_hash) = 64") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from an early version reaches v83 with a clean FK graph")
    func milestoneReachesV83() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 83)
        #expect(try await db.currentUserVersion() == 83)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
