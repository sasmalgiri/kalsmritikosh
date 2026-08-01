//
//  ExactByteBindingMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-001.2 — schema v84 closes the last content-hash gap: v83 accepted ANY 64-char
//  lowercase string as a non-legacy custody hash (e.g. 64 'z'), so a value that was never a
//  real SHA-256 could satisfy the CHECK. v84 adds `content_hash NOT GLOB '*[^0-9a-f]*'` to the
//  non-legacy branch (a genuine SHA-256 hex digest is 64 chars drawn only from [0-9a-f]) and
//  demotes any existing non-hex custody row to legacyImported. Proves reach, v83→v84
//  preservation + demotion, the new hex rule, self-heal, repeat and injected-fault rollback.
//  Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001.2 — v84 exact-byte binding migration")
struct ExactByteBindingMigrationTests {

    private let sha = String(repeating: "a", count: 64)          // valid lowercase hex SHA-256
    private let nonHex = String(repeating: "z", count: 64)       // 64 chars, lowercase, but NOT hex

    private func seedFile(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString).pdf"), .text("pdf"), .text("available")])
    }

    private func insertVersion(_ db: Database, id: UUID, logical: UUID, hash: String,
                               preservation: String = "referenceRecorded") async throws {
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(logical), .text(hash), .real(100), .integer(1), .real(100),
                  .text("f.pdf"), .text("pdf"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text(preservation), .real(100)])
    }

    private func versionSQL(_ db: Database) async throws -> String {
        try await db.query("SELECT sql FROM sqlite_master WHERE type='table' AND name='source_versions';", []).first?.string(0) ?? ""
    }

    // MARK: - Reach

    @Test("A fresh database reaches v84 with hexadecimal SHA-256 enforcement")
    func freshV84() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        #expect(try await db.currentUserVersion() == 84)
        #expect(try await versionSQL(db).contains("content_hash NOT GLOB '*[^0-9a-f]*'"))
        // the v83 SHA-256 length/case rule is retained under v84
        #expect(try await versionSQL(db).contains("length(content_hash) = 64"))
    }

    // MARK: - Hex rule

    @Test("A non-legacy custody version must be hexadecimal; 64 non-hex chars are rejected, legacy is exempt")
    func nonLegacyRequiresHex() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let file = UUID(); try await seedFile(db, id: file)
        // 64-char lowercase but non-hex (z) → rejected at v84 (would have passed at v83).
        await #expect(throws: (any Error).self) {
            try await self.insertVersion(db, id: UUID(), logical: file, hash: self.nonHex, preservation: "referenceRecorded")
        }
        // legacyImported + non-hex → accepted (legacy is exempt).
        try await insertVersion(db, id: UUID(), logical: file, hash: nonHex, preservation: "legacyImported")
        // referenceRecorded + valid hex SHA → accepted.
        let f2 = UUID(); try await seedFile(db, id: f2)
        try await insertVersion(db, id: UUID(), logical: f2, hash: sha, preservation: "referenceRecorded")
    }

    // MARK: - v83 → v84 preservation + demotion

    @Test("v83→v84 preserves rows and demotes a non-hex custody version to legacy-imported")
    func v83ToV84DemotesNonHex() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let file = UUID(); try await seedFile(db, id: file)
        // A v83 non-legacy row with a 64-char NON-hex hash — legal at v83, must be demoted at v84.
        try await insertVersion(db, id: UUID(), logical: file, hash: nonHex, preservation: "referenceRecorded")

        try await SchemaMigrations.migrate(db, through: 84)

        #expect(try await db.currentUserVersion() == 84)
        #expect(try await db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT preservation_status FROM source_versions;", []).first?.string(0) == "legacyImported")
        #expect(try await db.query("SELECT content_hash FROM source_versions;", []).first?.string(0) == nonHex)   // bytes preserved
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
    }

    @Test("v83→v84 leaves a valid-hex custody version untouched")
    func v83ToV84PreservesHex() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let file = UUID(); try await seedFile(db, id: file)
        try await insertVersion(db, id: UUID(), logical: file, hash: sha, preservation: "referenceRecorded")

        try await SchemaMigrations.migrate(db, through: 84)

        let row = try #require(try await db.query("SELECT content_hash, preservation_status FROM source_versions;", []).first)
        #expect(row.string(0) == sha)                            // hash unchanged
        #expect(row.string(1) == "referenceRecorded")            // NOT demoted
    }

    // MARK: - self-heal / repeat / genuine upgrade / fault

    @Test("The self-heal sentinel recognises the v84 hexadecimal marker")
    func selfHealRecognizesV84() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(82)                          // stale, but schema is fully applied at latest
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("A genuine v83 schema upgrades to v84, applying the hexadecimal rule")
    func v83GenuinelyUpgrades() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        #expect(try await versionSQL(db).contains("content_hash NOT GLOB") == false)
        try await SchemaMigrations.migrate(db, through: 84)
        #expect(try await db.currentUserVersion() == 84)
        #expect(try await versionSQL(db).contains("content_hash NOT GLOB '*[^0-9a-f]*'"))
    }

    @Test("An injected failure inside the v84 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 83)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 84,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 84)))
        }
        #expect(try await db.currentUserVersion() == 83)
        #expect(try await versionSQL(db).contains("content_hash NOT GLOB") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Re-running migrate over a v84 database is a safe no-op")
    func v84Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        try await SchemaMigrations.migrate(db, through: 84)
        #expect(try await db.currentUserVersion() == 84)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from an early version reaches v84 with a clean FK graph")
    func milestoneReachesV84() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 84)
        #expect(try await db.currentUserVersion() == 84)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
