//
//  SourceReadinessMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-002 — schema v85 gives every EXACT source version one readiness aggregate and exactly
//  ten independent dimension rows, plus an append-only event ledger. This proves reach, the
//  conservative v84→v85 backfill from canonical evidence (preservation / metadata / text /
//  structural / media / OCR), the CHECK/FK constraints, event initialization, self-heal, repeat
//  and injected-fault rollback. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002 — v85 source readiness migration")
struct SourceReadinessMigrationTests {

    private let hexHash = String(repeating: "a", count: 64)

    private func seedVersion(_ db: Database, id: UUID, type: String, preservation: String = "referenceRecorded",
                             documentID: SQLValue = .null, hash: String? = nil) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text(type), .text("available")])
        // managedCopyStored requires managed custody + a vault address (v82/v84 CHECK).
        let managed = preservation == "managedCopyStored"
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, vault_address, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), documentID, .text(hash ?? hexHash), .real(100), .integer(1), .real(100),
                  .text("f.\(type)"), .text(type), .text("magicBytes"), .integer(1),
                  .text(managed ? "managed" : "referenced"), .text(preservation),
                  managed ? .text(hash ?? hexHash) : .null, .real(100)])
    }

    private func seedDocument(_ db: Database, docID: UUID, logicalID: UUID, status: String) async throws {
        try await db.exec("""
            INSERT INTO source_documents (id, logical_source_id, filename, detected_type, content_hash, extraction_status, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(docID), .uuid(logicalID), .text("f.txt"), .text("txt"), .text(hexHash), .text(status), .real(100)])
    }

    private func seedBlock(_ db: Database, docID: UUID, versionID: UUID) async throws {
        try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text,
                extraction_method, extraction_confidence) VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(docID), .uuid(versionID), .integer(0), .text("paragraph"),
                  .text("substantive text"), .text("substantive text"), .text("native"), .real(1.0)])
    }

    private func dim(_ db: Database, _ versionID: UUID, _ dimension: String) async throws -> (state: String, applicability: String, condition: String?)? {
        guard let r = try await db.query("""
            SELECT state, applicability, condition FROM source_readiness_dimensions WHERE source_version_id = ? AND dimension = ?;
            """, [.uuid(versionID), .text(dimension)]).first else { return nil }
        return (r.string(0) ?? "", r.string(1) ?? "", r.string(2))
    }

    // MARK: - Reach

    @Test("A fresh database reaches v85 with the three readiness tables")
    func freshV85() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        #expect(try await db.currentUserVersion() == 85)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_readiness_aggregates"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_readiness_dimensions"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_readiness_events"))
    }

    @Test("A genuine v84 database upgrades to v85")
    func v84ToV85() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_readiness_dimensions") == false)
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await db.currentUserVersion() == 85)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_readiness_dimensions"))
    }

    // MARK: - Backfill shape

    @Test("Every source version receives exactly one aggregate and ten dimensions")
    func oneAggregateTenDimensions() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let a = UUID(), b = UUID()
        try await seedVersion(db, id: a, type: "txt")
        try await seedVersion(db, id: b, type: "pdf")
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await db.query("SELECT COUNT(*) FROM source_readiness_aggregates;", []).first?.int(0) == 2)
        for v in [a, b] {
            #expect(try await db.query("SELECT COUNT(*) FROM source_readiness_dimensions WHERE source_version_id = ?;", [.uuid(v)]).first?.int(0) == 10)
        }
    }

    @Test("An alias file (no source version) does not receive its own aggregate")
    func aliasNoIndependentAggregate() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let canonical = UUID()
        try await seedVersion(db, id: canonical, type: "txt")
        // an alias occurrence: a files row pointing at the canonical, with NO source_versions row.
        try await db.exec("INSERT INTO files (id, url, source_type, availability, alias_of) VALUES (?,?,?,?,?);",
                          [.uuid(UUID()), .text("file:///alias.txt"), .text("txt"), .text("available"), .uuid(canonical)])
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await db.query("SELECT COUNT(*) FROM source_readiness_aggregates;", []).first?.int(0) == 1)
    }

    // MARK: - Dimension backfill mappings

    @Test("Preservation backfill maps custody status to ready or partial")
    func preservationBackfill() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let ref = UUID(), stored = UUID(), failed = UUID(), legacy = UUID()
        try await seedVersion(db, id: ref, type: "txt", preservation: "referenceRecorded")
        try await seedVersion(db, id: stored, type: "txt", preservation: "managedCopyStored")
        try await seedVersion(db, id: failed, type: "txt", preservation: "managedCopyFailed")
        try await seedVersion(db, id: legacy, type: "txt", preservation: "legacyImported", hash: "legacy-nonhex")
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await dim(db, ref, "preservation")?.state == "ready")
        #expect(try await dim(db, stored, "preservation")?.state == "ready")
        #expect(try await dim(db, failed, "preservation")?.state == "partial")
        #expect(try await dim(db, legacy, "preservation")?.state == "partial")
    }

    @Test("Metadata backfill is ready with a parsed document, partial with custody only")
    func metadataBackfill() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let withDoc = UUID(), doc = UUID(), custodyOnly = UUID()
        try await seedVersion(db, id: withDoc, type: "txt", documentID: .uuid(doc))
        try await seedDocument(db, docID: doc, logicalID: withDoc, status: "complete")
        try await seedVersion(db, id: custodyOnly, type: "txt")
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await dim(db, withDoc, "metadataExtraction")?.state == "ready")
        #expect(try await dim(db, custodyOnly, "metadataExtraction")?.state == "partial")
    }

    @Test("Complete structural backfill with blocks yields ready text and structure")
    func completeStructuralBackfill() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let v = UUID(), doc = UUID()
        try await seedVersion(db, id: v, type: "txt", documentID: .uuid(doc))
        try await seedDocument(db, docID: doc, logicalID: v, status: "complete")
        try await seedBlock(db, docID: doc, versionID: v)
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await dim(db, v, "textExtraction")?.state == "ready")
        #expect(try await dim(db, v, "structuralExtraction")?.state == "ready")
    }

    @Test("Partial structural backfill yields partial text and structure")
    func partialStructuralBackfill() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let v = UUID(), doc = UUID()
        try await seedVersion(db, id: v, type: "txt", documentID: .uuid(doc))
        try await seedDocument(db, docID: doc, logicalID: v, status: "partial")
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await dim(db, v, "textExtraction")?.state == "partial")
        #expect(try await dim(db, v, "structuralExtraction")?.state == "partial")
    }

    @Test("Deferred media backfill blocks text/structure/transcription and marks OCR notApplicable")
    func deferredMediaBackfill() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let v = UUID()
        try await seedVersion(db, id: v, type: "mp3")
        try await SchemaMigrations.migrate(db, through: 85)
        let text = try await dim(db, v, "textExtraction")
        #expect(text?.state == "blocked" && text?.applicability == "required" && text?.condition == "deferred")
        #expect(try await dim(db, v, "structuralExtraction")?.condition == "deferred")
        let tr = try await dim(db, v, "transcription")
        #expect(tr?.state == "blocked" && tr?.applicability == "required" && tr?.condition == "deferred")
        let ocr = try await dim(db, v, "ocr")
        #expect(ocr?.state == "ready" && ocr?.applicability == "notApplicable")
    }

    @Test("Encrypted, corrupt and failed documents map to distinct text states")
    func encryptedCorruptFailedMapping() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let enc = UUID(), encDoc = UUID(), cor = UUID(), corDoc = UUID(), fail = UUID(), failDoc = UUID()
        try await seedVersion(db, id: enc, type: "pdf", documentID: .uuid(encDoc)); try await seedDocument(db, docID: encDoc, logicalID: enc, status: "encrypted")
        try await seedVersion(db, id: cor, type: "pdf", documentID: .uuid(corDoc)); try await seedDocument(db, docID: corDoc, logicalID: cor, status: "corrupt")
        try await seedVersion(db, id: fail, type: "pdf", documentID: .uuid(failDoc)); try await seedDocument(db, docID: failDoc, logicalID: fail, status: "failed")
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await dim(db, enc, "textExtraction")?.condition == "encrypted")
        #expect(try await dim(db, cor, "textExtraction")?.condition == "corrupt")
        #expect(try await dim(db, fail, "textExtraction")?.state == "failed")
    }

    @Test("OCR is conditional for image/PDF and notApplicable for text")
    func ocrConditionalForImage() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let png = UUID(), txt = UUID()
        try await seedVersion(db, id: png, type: "png")
        try await seedVersion(db, id: txt, type: "txt")
        try await SchemaMigrations.migrate(db, through: 85)
        let pngOCR = try await dim(db, png, "ocr")
        #expect(pngOCR?.state == "notStarted" && pngOCR?.applicability == "conditional")
        let txtOCR = try await dim(db, txt, "ocr")
        #expect(txtOCR?.state == "ready" && txtOCR?.applicability == "notApplicable")
    }

    // MARK: - Constraints + events

    @Test("The dimension CHECKs reject illegal rows")
    func dimensionChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        let v = UUID(); try await seedVersion(db, id: v, type: "txt")
        try await db.exec("INSERT INTO source_readiness_aggregates (source_version_id, revision, event_sequence, created_at, updated_at) VALUES (?,1,0,0,0);", [.uuid(v)])
        func insert(state: String, appl: String, condition: SQLValue, completed: SQLValue, total: SQLValue) async throws {
            try await db.exec("""
                INSERT INTO source_readiness_dimensions (source_version_id, dimension, state, applicability, condition,
                    completed_units, total_units, producer_id, producer_version, revision, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(v), .text("indexing"), .text(state), .text(appl), condition, completed, total, .text("p"), .text("1"), .integer(1), .real(0)])
        }
        // blocked without condition → rejected
        await #expect(throws: (any Error).self) { try await insert(state: "blocked", appl: "required", condition: .null, completed: .null, total: .null) }
        // notApplicable but not ready → rejected
        await #expect(throws: (any Error).self) { try await insert(state: "partial", appl: "notApplicable", condition: .null, completed: .null, total: .null) }
        // completed > total → rejected
        await #expect(throws: (any Error).self) { try await insert(state: "partial", appl: "required", condition: .null, completed: .integer(5), total: .integer(2)) }
        // unsupported + notApplicable → rejected
        await #expect(throws: (any Error).self) { try await insert(state: "unsupported", appl: "notApplicable", condition: .null, completed: .null, total: .null) }
        // a legal row → accepted
        try await insert(state: "ready", appl: "required", condition: .null, completed: .integer(3), total: .integer(3))
    }

    @Test("Backfill writes one initialize event per dimension with contiguous sequences")
    func eventInitialization() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let v = UUID(); try await seedVersion(db, id: v, type: "txt")
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await db.query("SELECT COUNT(*) FROM source_readiness_events WHERE source_version_id = ?;", [.uuid(v)]).first?.int(0) == 10)
        #expect(try await db.query("SELECT COUNT(*) FROM source_readiness_events WHERE source_version_id = ? AND action = 'initialize';", [.uuid(v)]).first?.int(0) == 10)
        let seqs = try await db.query("SELECT sequence FROM source_readiness_events WHERE source_version_id = ? ORDER BY sequence;", [.uuid(v)])
        #expect(seqs.compactMap { $0.int(0).map(Int.init) } == Array(0..<10))
        #expect(try await db.query("SELECT event_sequence FROM source_readiness_aggregates WHERE source_version_id = ?;", [.uuid(v)]).first?.int(0) == 10)
    }

    // MARK: - self-heal / repeat / fault

    @Test("The self-heal sentinel recognises the v85 readiness tables")
    func selfHealRecognizesV85() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(83)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v85 database is a safe no-op")
    func v85Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 85)
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await db.currentUserVersion() == 85)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v85 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 84)
        let v = UUID(); try await seedVersion(db, id: v, type: "txt")
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 85, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 85)))
        }
        #expect(try await db.currentUserVersion() == 84)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_readiness_dimensions") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from an early version reaches v85 with a clean FK graph")
    func milestoneReachesV85() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 85)
        #expect(try await db.currentUserVersion() == 85)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
