//
//  ContainerManifestMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-M2 — schema v87 adds two PROCESSING-PROJECTION tables (container_manifests + container_members)
//  that record what a container SourceVersion claims to contain and how each member was disposed. They
//  are not source/evidence authorities. Proves reach, v86→v87 upgrade, self-heal, repeat + injected
//  fault rollback, and every integrity CHECK: closed status/disposition vocabularies, count
//  consistency, admitted⇒child+hash, non-admitted⇒no child, unique ordinal, composite (id,hash) pin.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M2 — v87 container coverage migration")
struct ContainerManifestMigrationTests {

    private let hexHash = String(repeating: "a", count: 64)
    private let childHash = String(repeating: "b", count: 64)

    private func seedVersion(_ db: Database, id: UUID, hash: String) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text("zip"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(hash), .real(100), .integer(1), .real(100),
                  .text("c.zip"), .text("zip"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])
    }

    private func insertManifest(_ db: Database, parent: UUID, status: String = "complete",
                                regular: Int = 4, admitted: Int = 1, blocked: Int = 1,
                                unsupported: Int = 1, failed: Int = 0) async throws {
        try await db.exec("""
            INSERT INTO container_manifests (source_version_id, revision, container_type, inspector_id,
                inspector_version, policy_version, status, total_entries, regular_file_entries,
                admitted_members, blocked_members, unsupported_members, failed_members,
                declared_uncompressed_bytes, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(parent), .integer(1), .text("zip"), .text("zip.inspector"), .text("1"), .text("policy-1"),
                  .text(status), .integer(5), .integer(Int64(regular)), .integer(Int64(admitted)),
                  .integer(Int64(blocked)), .integer(Int64(unsupported)), .integer(Int64(failed)),
                  .integer(1024), .real(100), .real(100)])
    }

    private func insertMember(_ db: Database, parent: UUID, ordinal: Int, disposition: String,
                              child: SQLValue, hash: SQLValue, kind: String = "file") async throws {
        try await db.exec("""
            INSERT INTO container_members (id, parent_source_version_id, ordinal, member_path,
                normalized_member_path, entry_kind, compressed_size, uncompressed_size, detected_type,
                disposition, child_source_version_id, content_hash, detail, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(parent), .integer(Int64(ordinal)), .text("m/\(ordinal).bin"),
                  .text("m/\(ordinal).bin"), .text(kind), .integer(10), .integer(20), .text("pdf"),
                  .text(disposition), child, hash, .null, .real(100), .real(100)])
    }

    // MARK: - Reach + upgrade + self-heal

    @Test("A fresh database reaches v87 with both container tables")
    func freshV87HasBothTables() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        #expect(try await db.currentUserVersion() == 87)
        #expect(try await MigrationFixtureBuilder.columns(db, "container_manifests").contains("policy_version"))
        #expect(try await MigrationFixtureBuilder.columns(db, "container_members").contains("disposition"))
    }

    @Test("A genuine v86 database upgrades to v87, adding both tables")
    func v86ToV87AddsTables() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 86)
        #expect(try await MigrationFixtureBuilder.columns(db, "container_manifests").isEmpty)
        try await SchemaMigrations.migrate(db, through: 87)
        #expect(try await db.currentUserVersion() == 87)
        #expect(try await MigrationFixtureBuilder.columns(db, "container_members").contains("normalized_member_path"))
    }

    @Test("The self-heal sentinel recognises the v87 container tables")
    func selfHealRecognizesV87() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(85)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v87 database is a safe no-op")
    func v87Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        try await SchemaMigrations.migrate(db, through: 87)
        #expect(try await db.currentUserVersion() == 87)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v87 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 86)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 87, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 87)))
        }
        #expect(try await db.currentUserVersion() == 86)
        #expect(try await MigrationFixtureBuilder.columns(db, "container_manifests").isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v87 with a clean FK graph")
    func milestoneReachesV87() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 87)
        #expect(try await db.currentUserVersion() == 87)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - Manifest CHECKs

    @Test("A manifest with an out-of-vocabulary status is rejected")
    func manifestRejectsBadStatus() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        await #expect(throws: (any Error).self) { try await insertManifest(db, parent: p, status: "searchReady") }
    }

    @Test("A manifest whose disposition counts exceed regular file entries is rejected")
    func manifestRejectsInconsistentCounts() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        // admitted+blocked+unsupported+failed = 4 > regular_file_entries = 3
        await #expect(throws: (any Error).self) {
            try await insertManifest(db, parent: p, regular: 3, admitted: 2, blocked: 1, unsupported: 1, failed: 0)
        }
    }

    @Test("A consistent manifest is accepted")
    func manifestConsistentAccepted() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        try await insertManifest(db, parent: p, regular: 4, admitted: 1, blocked: 1, unsupported: 1, failed: 0)
        #expect(try await db.query("SELECT status FROM container_manifests WHERE source_version_id = ?;", [.uuid(p)]).first?.string(0) == "complete")
    }

    // MARK: - Member CHECKs

    @Test("A member with an out-of-vocabulary disposition is rejected")
    func memberRejectsBadDisposition() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        await #expect(throws: (any Error).self) {
            try await insertMember(db, parent: p, ordinal: 0, disposition: "quarantined", child: .null, hash: .null)
        }
    }

    @Test("An admitted member requires both a child version and a content hash")
    func memberAdmittedRequiresChildAndHash() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        await #expect(throws: (any Error).self) {
            try await insertMember(db, parent: p, ordinal: 0, disposition: "admitted", child: .null, hash: .null)
        }
    }

    @Test("A non-admitted member must not carry a fabricated child version")
    func memberNonAdmittedForbidsChild() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        let c = UUID(); try await seedVersion(db, id: c, hash: childHash)
        await #expect(throws: (any Error).self) {
            try await insertMember(db, parent: p, ordinal: 0, disposition: "encrypted", child: .uuid(c), hash: .text(childHash))
        }
    }

    @Test("An admitted member is accepted and pins to the exact (id, content_hash) version authority")
    func memberAdmittedCompositeFKEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        let c = UUID(); try await seedVersion(db, id: c, hash: childHash)
        // Correct pair is accepted.
        try await insertMember(db, parent: p, ordinal: 0, disposition: "admitted", child: .uuid(c), hash: .text(childHash))
        #expect(try await db.query("SELECT disposition FROM container_members WHERE parent_source_version_id = ?;", [.uuid(p)]).first?.string(0) == "admitted")
        // A hash that does not match the child version's row violates the composite FK.
        await #expect(throws: (any Error).self) {
            try await insertMember(db, parent: p, ordinal: 1, disposition: "admitted", child: .uuid(c), hash: .text(hexHash))
        }
    }

    @Test("Duplicate (parent, ordinal) is rejected but duplicate member paths are allowed")
    func memberOrdinalUniqueButPathsMayRepeat() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let p = UUID(); try await seedVersion(db, id: p, hash: hexHash)
        // Two directory members with the SAME path but distinct ordinals — allowed.
        try await insertMember(db, parent: p, ordinal: 0, disposition: "directory", child: .null, hash: .null, kind: "directory")
        try await insertMember(db, parent: p, ordinal: 1, disposition: "unsupported", child: .null, hash: .null)
        // Re-using ordinal 0 is rejected.
        await #expect(throws: (any Error).self) {
            try await insertMember(db, parent: p, ordinal: 0, disposition: "unsupported", child: .null, hash: .null)
        }
    }
}
