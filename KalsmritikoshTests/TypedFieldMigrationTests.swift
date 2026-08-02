//
//  TypedFieldMigrationTests.swift
//  KalsmritikoshTests
//
//  MMI-FINAL — schema v90 adds the typed_fields table: deterministic identity/document fields
//  pinned to the exact EvidenceBlock + SourceVersion + locator they came from. Proves reach,
//  v89→v90 legacy preservation (no fabricated fields), self-heal, repeat + fault rollback, and
//  every integrity CHECK/FK: confidence + ocr_confidence bounds, nonblank type/value, block +
//  version FKs, and cascade on either parent delete. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MMI-FINAL — v90 typed_fields migration")
struct TypedFieldMigrationTests {

    private let hex = String(repeating: "a", count: 64)

    private func seedVersion(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(hex), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"), .text("referenceRecorded"), .real(100)])
    }
    @discardableResult
    private func seedBlock(_ db: Database, sv: UUID, id: UUID = UUID()) async throws -> UUID {
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, extraction_method, extraction_confidence)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(UUID()), .uuid(sv), .integer(0), .text("paragraph"), .text("Name: Jane Roe"), .text("Name: Jane Roe"), .text("native"), .real(1.0)])
        return id
    }
    private func insertField(_ db: Database, sv: UUID, block: UUID, type: String = "personName",
                             raw: String = "Jane Roe", conf: Double = 0.9, ocrConf: SQLValue = .null,
                             method: String = "native") async throws {
        try await db.exec("""
            INSERT INTO typed_fields (id, source_version_id, evidence_block_id, field_type, raw_value,
                normalized_value, confidence, extraction_method, ocr_confidence, producer_id, producer_version, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(sv), .uuid(block), .text(type), .text(raw), .text(raw.lowercased()),
                  .real(conf), .text(method), ocrConf, .text("mmi.typed-field"), .text("1"), .real(100)])
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v90 with the typed_fields table")
    func freshV90() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        #expect(try await db.currentUserVersion() == 90)
        #expect(try await MigrationFixtureBuilder.columns(db, "typed_fields").isSuperset(of: ["source_version_id", "evidence_block_id", "field_type", "normalized_value", "confidence", "locator", "bounding_box", "producer_version"]))
    }

    @Test("v89→v90 preserves legacy data with no fabricated typed fields")
    func v89ToV90Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        let a = UUID()
        try await db.exec("INSERT INTO answers (id, question, answer_state, body, confidence, created_at) VALUES (?,?,?,?,?,?);",
                         [.uuid(a), .text("q"), .text("supported"), .text("body"), .real(0.5), .real(1)])
        try await SchemaMigrations.migrate(db, through: 90)
        #expect(try await db.currentUserVersion() == 90)
        #expect(try await db.query("SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(a)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM typed_fields;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v90 typed_fields table")
    func selfHealRecognizesV90() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(88)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v90 database is a safe no-op")
    func v90Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await SchemaMigrations.migrate(db, through: 90)
        #expect(try await db.currentUserVersion() == 90)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v90 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 89)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 90, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 90)))
        }
        #expect(try await db.currentUserVersion() == 89)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='typed_fields';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v90 with a clean FK graph")
    func milestoneReachesV90() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 90)
        #expect(try await db.currentUserVersion() == 90)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - CHECKs + FKs

    @Test("confidence must be within [0,1]")
    func confidenceBounds() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        await #expect(throws: (any Error).self) { try await insertField(db, sv: sv, block: b, conf: 1.5) }
        await #expect(throws: (any Error).self) { try await insertField(db, sv: sv, block: b, conf: -0.1) }
        try await insertField(db, sv: sv, block: b, conf: 0.9)
        #expect(try await db.query("SELECT COUNT(*) FROM typed_fields;", []).first?.int(0) == 1)
    }

    @Test("field_type and raw_value must be nonblank")
    func nonblankFields() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        await #expect(throws: (any Error).self) { try await insertField(db, sv: sv, block: b, type: "  ") }
        await #expect(throws: (any Error).self) { try await insertField(db, sv: sv, block: b, raw: "") }
    }

    @Test("ocr_confidence is null or within [0,1]")
    func ocrConfidenceBounds() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        await #expect(throws: (any Error).self) { try await insertField(db, sv: sv, block: b, ocrConf: .real(2.0), method: "ocr") }
        try await insertField(db, sv: sv, block: b, ocrConf: .real(0.7), method: "ocr")
        try await insertField(db, sv: sv, block: b, ocrConf: .null)   // null is fine
    }

    @Test("A typed field's source_version_id must reference a real version")
    func versionFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        await #expect(throws: (any Error).self) { try await insertField(db, sv: UUID(), block: b) }   // no such version
    }

    @Test("A typed field's evidence_block_id must reference a real block")
    func blockFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); _ = try await seedBlock(db, sv: sv)
        await #expect(throws: (any Error).self) { try await insertField(db, sv: sv, block: UUID()) }   // no such block
    }

    @Test("Deleting a source version cascades its typed fields away")
    func cascadeOnVersionDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        try await insertField(db, sv: sv, block: b)
        try await db.exec("DELETE FROM source_versions WHERE id = ?;", [.uuid(sv)])
        #expect(try await db.query("SELECT COUNT(*) FROM typed_fields WHERE source_version_id = ?;", [.uuid(sv)]).first?.int(0) == 0)
    }

    @Test("Deleting an evidence block cascades its typed fields away")
    func cascadeOnBlockDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        try await insertField(db, sv: sv, block: b)
        try await db.exec("DELETE FROM evidence_blocks WHERE id = ?;", [.uuid(b)])
        #expect(try await db.query("SELECT COUNT(*) FROM typed_fields WHERE evidence_block_id = ?;", [.uuid(b)]).first?.int(0) == 0)
    }

    @Test("Multiple typed fields may belong to one version and block")
    func multipleFields() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv); let b = try await seedBlock(db, sv: sv)
        try await insertField(db, sv: sv, block: b, type: "personName", raw: "Jane Roe")
        try await insertField(db, sv: sv, block: b, type: "documentNumber", raw: "X123")
        #expect(try await db.query("SELECT COUNT(*) FROM typed_fields WHERE source_version_id = ?;", [.uuid(sv)]).first?.int(0) == 2)
    }
}
