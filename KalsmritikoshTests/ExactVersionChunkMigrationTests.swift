//
//  ExactVersionChunkMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-002.1 — schema v86 gives each chunk the EXACT source version it belongs to (a retrieval
//  projection field). The v85→v86 backfill sets it ONLY where provable (chunk → its EvidenceBlock →
//  that block's source_version_id); legacy/fallback chunks stay NULL rather than guessing. Proves
//  reach, provable + unprovable backfill, self-heal, repeat and injected-fault rollback.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002.1 — v86 exact-version chunk ownership migration")
struct ExactVersionChunkMigrationTests {

    private let hexHash = String(repeating: "a", count: 64)

    private func seedVersion(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(hexHash), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])
    }
    private func seedKO(_ db: Database, id: UUID, fileID: UUID) async throws {
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(id), .uuid(fileID), .text("txt"), .text("body"), .real(0), .real(0)])
    }
    private func seedBlock(_ db: Database, id: UUID, docID: UUID, versionID: SQLValue) async throws {
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(docID), versionID, .integer(0), .text("paragraph"), .text("t"), .text("t"), .text("native"), .real(1.0)])
    }
    /// Insert a chunk at v85 (no source_version_id column yet).
    private func seedChunkV85(_ db: Database, koID: UUID, evidenceBlockID: SQLValue) async throws {
        try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, evidence_block_id)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(koID), .integer(0), .text("chunk text"), .integer(0), .integer(10), .real(0), evidenceBlockID])
    }
    private func chunkVersion(_ db: Database) async throws -> SQLValue? {
        try await db.query("SELECT source_version_id FROM chunks LIMIT 1;", []).first.map { $0.isNull(0) ? SQLValue.null : .uuid($0.uuid(0) ?? UUID()) }
    }

    @Test("A fresh database reaches v86 with the chunks.source_version_id column")
    func freshV86() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 86)
        #expect(try await db.currentUserVersion() == 86)
        #expect(try await MigrationFixtureBuilder.columns(db, "chunks").contains("source_version_id"))
    }

    @Test("A genuine v85 database upgrades to v86, adding the column")
    func v85ToV86() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        #expect(try await MigrationFixtureBuilder.columns(db, "chunks").contains("source_version_id") == false)
        try await SchemaMigrations.migrate(db, through: 86)
        #expect(try await db.currentUserVersion() == 86)
        #expect(try await MigrationFixtureBuilder.columns(db, "chunks").contains("source_version_id"))
    }

    @Test("Backfill sets exact ownership from a chunk's evidence block")
    func backfillProvable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let v = UUID(); try await seedVersion(db, id: v)
        let doc = UUID(); let block = UUID(); try await seedBlock(db, id: block, docID: doc, versionID: .uuid(v))
        let ko = UUID(); try await seedKO(db, id: ko, fileID: v)
        try await seedChunkV85(db, koID: ko, evidenceBlockID: .uuid(block))
        try await SchemaMigrations.migrate(db, through: 86)
        #expect(try await db.query("SELECT source_version_id FROM chunks;", []).first?.uuid(0) == v)
    }

    @Test("Backfill leaves a chunk with no evidence block unowned (legacy stays NULL)")
    func backfillUnprovableNoBlock() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let v = UUID(); try await seedVersion(db, id: v)
        let ko = UUID(); try await seedKO(db, id: ko, fileID: v)
        try await seedChunkV85(db, koID: ko, evidenceBlockID: .null)   // no block → unprovable
        try await SchemaMigrations.migrate(db, through: 86)
        #expect(try await db.query("SELECT source_version_id FROM chunks;", []).first?.isNull(0) == true)
    }

    @Test("Backfill leaves a chunk unowned when its block has no source version")
    func backfillUnprovableNullBlockVersion() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let v = UUID(); try await seedVersion(db, id: v)
        let doc = UUID(); let block = UUID(); try await seedBlock(db, id: block, docID: doc, versionID: .null)   // block version NULL
        let ko = UUID(); try await seedKO(db, id: ko, fileID: v)
        try await seedChunkV85(db, koID: ko, evidenceBlockID: .uuid(block))
        try await SchemaMigrations.migrate(db, through: 86)
        #expect(try await db.query("SELECT source_version_id FROM chunks;", []).first?.isNull(0) == true)
    }

    @Test("The self-heal sentinel recognises the v86 chunk column")
    func selfHealRecognizesV86() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(84)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v86 database is a safe no-op")
    func v86Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 86)
        try await SchemaMigrations.migrate(db, through: 86)
        #expect(try await db.currentUserVersion() == 86)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v86 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 86, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 86)))
        }
        #expect(try await db.currentUserVersion() == 85)
        #expect(try await MigrationFixtureBuilder.columns(db, "chunks").contains("source_version_id") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from an early version reaches v86 with a clean FK graph")
    func milestoneReachesV86() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 86)
        #expect(try await db.currentUserVersion() == 86)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
