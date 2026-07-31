//
//  USF001SinglePathIntegrityTests.swift
//  KalsmritikoshTests
//
//  USF-001.1 — the single-path invariants at the repository / EvidenceStore / vault /
//  detector level: EvidenceStore is fail-closed attach-only, type detection has one
//  authority (path pattern over magic bytes), an existing alias URL re-intakes without a
//  new alias, the managed vault stores bytes that match their address, and no legacy ingest
//  path remains. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001.1 — single-path integrity", .serialized)
struct USF001SinglePathIntegrityTests {

    private let sha = String(repeating: "a", count: 64)

    private func freshDB() async throws -> Database {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usf11-\(UUID().uuidString).sqlite")
        let db = try await MigrationFixtureBuilder.database(atVersion: 83, at: url)
        try await db.exec("PRAGMA foreign_keys = ON;")
        return db
    }

    /// Insert a v83 source version (non-legacy, SHA hash) for a fresh logical source.
    private func seedVersion(_ db: Database, version: UUID, logical: UUID, hash: String, docID: SQLValue = .null) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///\(logical.uuidString).txt"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, document_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), docID, .text(hash), .real(0), .integer(1), .real(0),
                  .text("f.txt"), .text("txt"), .text("declaredExtension"), .integer(0), .text("referenced"),
                  .text("referenceRecorded"), .real(0)])
    }

    private func makeDoc(docID: UUID, logical: UUID, version: UUID, hash: String) -> ParsedDocument {
        ParsedDocument(id: docID, logicalSourceID: logical, sourceVersionID: version, filename: "f.txt",
                       detectedType: .txt, contentHash: hash,
                       blocks: [EvidenceBlock(documentID: docID, ordinal: 0, kind: .paragraph, rawText: "t")])
    }

    // MARK: - EvidenceStore attach-only

    @Test("Attaching to a nonexistent source version fails and writes nothing")
    func attachMissingVersionFailsClosed() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let doc = makeDoc(docID: UUID(), logical: UUID(), version: UUID(), hash: sha)
        await #expect(throws: SourceIntakeError.self) {
            try await store.persist(doc, parser: "p", parserVersion: "1", startedAt: Date())
        }
        #expect(try await db.query("SELECT COUNT(*) FROM source_documents;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM evidence_blocks;", []).first?.int(0) == 0)
    }

    @Test("Attaching a document whose content hash differs from the version is rejected atomically")
    func attachHashMismatchFailsClosed() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID()
        try await seedVersion(db, version: version, logical: logical, hash: sha)
        let doc = makeDoc(docID: UUID(), logical: logical, version: version, hash: String(repeating: "b", count: 64))
        await #expect(throws: SourceIntakeError.self) {
            try await store.persist(doc, parser: "p", parserVersion: "1", startedAt: Date())
        }
        #expect(try await db.query("SELECT COUNT(*) FROM source_documents;", []).first?.int(0) == 0)   // atomic: nothing written
        #expect(try await db.query("SELECT document_id FROM source_versions WHERE id = ?;", [.uuid(version)]).first?.isNull(0) == true)
    }

    @Test("Attaching a document whose logical source differs from the version is rejected")
    func attachLogicalMismatchFailsClosed() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID()
        try await seedVersion(db, version: version, logical: logical, hash: sha)
        let doc = makeDoc(docID: UUID(), logical: UUID(), version: version, hash: sha)   // wrong logical
        await #expect(throws: SourceIntakeError.self) {
            try await store.persist(doc, parser: "p", parserVersion: "1", startedAt: Date())
        }
    }

    @Test("A version that already carries a different document cannot be re-attached")
    func attachDifferentDocumentRejected() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID(), firstDoc = UUID()
        try await seedVersion(db, version: version, logical: logical, hash: sha, docID: .uuid(firstDoc))
        let doc = makeDoc(docID: UUID(), logical: logical, version: version, hash: sha)   // different doc id
        await #expect(throws: SourceIntakeError.self) {
            try await store.persist(doc, parser: "p", parserVersion: "1", startedAt: Date())
        }
    }

    @Test("A matching document attaches and sets the version's document_id")
    func attachMatchingSucceeds() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID(), docID = UUID()
        try await seedVersion(db, version: version, logical: logical, hash: sha)
        try await store.persist(makeDoc(docID: docID, logical: logical, version: version, hash: sha),
                                parser: "p", parserVersion: "1", startedAt: Date())
        #expect(try await db.query("SELECT document_id FROM source_versions WHERE id = ?;", [.uuid(version)]).first?.uuid(0) == docID)
        #expect(try await db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)   // never created another
    }

    @Test("A successful attach writes the document, blocks, profile and parser run together")
    func attachWritesAllArtifacts() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID(), docID = UUID()
        try await seedVersion(db, version: version, logical: logical, hash: sha)
        try await store.persist(makeDoc(docID: docID, logical: logical, version: version, hash: sha),
                                parser: "p", parserVersion: "1", startedAt: Date())
        #expect(try await db.query("SELECT COUNT(*) FROM source_documents WHERE id = ?;", [.uuid(docID)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(version)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM document_profiles WHERE source_version_id = ?;", [.uuid(version)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM parser_runs WHERE source_version_id = ?;", [.uuid(version)]).first?.int(0) == 1)
    }

    @Test("Re-attaching the SAME document to its version is idempotent")
    func attachSameDocumentIdempotent() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID(), docID = UUID()
        try await seedVersion(db, version: version, logical: logical, hash: sha)
        let doc = makeDoc(docID: docID, logical: logical, version: version, hash: sha)
        try await store.persist(doc, parser: "p", parserVersion: "1", startedAt: Date())
        try await store.persist(doc, parser: "p", parserVersion: "1", startedAt: Date())   // same doc → allowed
        #expect(try await db.query("SELECT COUNT(*) FROM source_documents;", []).first?.int(0) == 1)
    }

    // MARK: - One authoritative type detector

    @Test("A canonical filename pattern (chat.db) wins over SQLite magic bytes")
    func pathPatternWinsOverMagic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usf11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Real SQLite magic header ("SQLite format 3\0") under the canonical iMessage filename.
        let url = dir.appendingPathComponent("chat.db")
        try (Data("SQLite format 3\u{0}".utf8) + Data(repeating: 0, count: 32)).write(to: url)
        let captured = try SourceByteCapture.capture(url)
        #expect(captured.detectedType == .imessage)
        #expect(captured.detectionBasis == .pathPattern)
    }

    @Test("A magic-byte type is used when no canonical pattern matches")
    func magicUsedWithoutPattern() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usf11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image.bin")   // no pattern, no useful extension
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 16)).write(to: url)
        let captured = try SourceByteCapture.capture(url)
        #expect(captured.detectedType == .png)
        #expect(captured.detectionBasis == .magicBytes)
    }

    // MARK: - Alias re-intake

    @Test("Re-intaking an existing alias URL with unchanged bytes reuses the occurrence (no new alias)")
    func aliasReintakeReusesOccurrence() async throws {
        let rig = try await USF001Fixtures.makeRig()
        _ = try await USF001Fixtures.intake(rig, url: try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("dup")))
        let bURL = try USF001Fixtures.writeFile(rig, name: "b.txt", bytes: USF001Fixtures.bytes("dup"))
        let alias1 = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(1))
        #expect(alias1.outcome == .aliased)
        let filesAfterAlias = try await rig.db.query("SELECT COUNT(*) FROM files;", []).first?.int(0)
        // Re-intake the SAME alias URL with the SAME bytes → reuse, not a second alias file.
        let alias2 = try await USF001Fixtures.intake(rig, url: bURL, at: USF001Fixtures.t0.addingTimeInterval(2))
        #expect(alias2.occurrenceFileID == alias1.occurrenceFileID)
        #expect(alias2.sourceVersionID == alias1.sourceVersionID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM files;", []).first?.int(0) == filesAfterAlias)
    }

    // MARK: - Managed vault stores verified bytes

    @Test("A managed vault copy stores bytes whose content address equals the recorded version hash")
    func managedVaultBytesMatchAddress() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let bytes = USF001Fixtures.bytes("managed-integrity")
        let url = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: bytes)
        let h = try await USF001Fixtures.intake(rig, url: url, custody: .managed)
        #expect(h.preservationStatus == .managedCopyStored)
        #expect(h.vaultAddress == h.contentHash)
        // The vault blob under that address IS the original bytes.
        let stored = await rig.vault.data(for: h.contentHash)
        #expect(stored == bytes)
    }

    @Test("A legacy version's hash is still checked on attach (doc hash must equal it)")
    func attachLegacyVersionHashChecked() async throws {
        let db = try await freshDB(); let store = EvidenceStore(database: db)
        let logical = UUID(), version = UUID()
        // A legacy-imported version may hold any hash; the doc must still match it.
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(logical), .text("file:///leg.txt"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(version), .uuid(logical), .text("legacy-hash"), .real(0), .integer(1), .real(0),
                  .text("f.txt"), .text("txt"), .text("declaredExtension"), .integer(0), .text("referenced"),
                  .text("legacyImported"), .real(0)])
        await #expect(throws: SourceIntakeError.self) {
            try await store.persist(self.makeDoc(docID: UUID(), logical: logical, version: version, hash: "other"),
                                    parser: "p", parserVersion: "1", startedAt: Date())
        }
        try await store.persist(makeDoc(docID: UUID(), logical: logical, version: version, hash: "legacy-hash"),
                                parser: "p", parserVersion: "1", startedAt: Date())   // matching → OK
    }

    @Test("A declared extension is the detection basis when no pattern or magic applies")
    func declaredExtensionBasis() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usf11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notes.txt")
        try Data("plain text with no magic".utf8).write(to: url)
        let captured = try SourceByteCapture.capture(url)
        #expect(captured.detectedType == .txt)
        #expect(captured.detectionBasis == .declaredExtension)
    }

    @Test("A managed copy with no vault fails visibly and stores no blob")
    func managedFailureNoBlob() async throws {
        let rig = try await USF001Fixtures.makeRig(withVault: false)
        let url = try USF001Fixtures.writeFile(rig, name: "m.txt", bytes: USF001Fixtures.bytes("x"))
        let h = try await USF001Fixtures.intake(rig, url: url, custody: .managed)
        #expect(h.preservationStatus == .managedCopyFailed)
        #expect(h.vaultAddress == nil)
        #expect(await rig.vault.contains(h.contentHash) == false)
    }

    @Test("A new-version intake writes a receipt whose content hash equals the version's hash")
    func receiptHashPinnedToVersion() async throws {
        let rig = try await USF001Fixtures.makeRig()
        let h = try await USF001Fixtures.intake(rig, url: try USF001Fixtures.writeFile(rig, name: "a.txt", bytes: USF001Fixtures.bytes("x")))
        let receiptHash = try await rig.db.query("SELECT content_hash FROM source_intake_receipts WHERE source_version_id = ?;",
                                                 [.uuid(h.sourceVersionID)]).first?.string(0)
        let versionHash = try await rig.db.query("SELECT content_hash FROM source_versions WHERE id = ?;",
                                                 [.uuid(h.sourceVersionID)]).first?.string(0)
        #expect(receiptHash == versionHash)
        #expect(receiptHash == h.contentHash)
    }

    // MARK: - No legacy path remains

    @Test("No legacy ingest path (ingestCoreLegacy) remains in the coordinator")
    func noLegacyIngestPath() throws {
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: repoRoot.appendingPathComponent("Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift"), encoding: .utf8)
        #expect(!src.contains("ingestCoreLegacy"))
        #expect(!src.contains("intakeCoordinator?"))          // no optional intake
        #expect(src.contains("intakeCoordinator: UniversalSourceIntakeCoordinator"))  // mandatory
    }
}
