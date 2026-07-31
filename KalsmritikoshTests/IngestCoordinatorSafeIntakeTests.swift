//
//  IngestCoordinatorSafeIntakeTests.swift
//  KalsmritikoshTests
//
//  USF-001 — with universal intake wired, the IngestCoordinator registers canonical
//  source + source-version custody BEFORE any loader/parser. Unchanged/moved/aliased skip
//  parsing; loader/parser absence keeps custody; deferred media keeps custody; the parsed
//  document attaches to the pre-created version; attempts carry exact version ids; a parent
//  relation survives a child that never parses. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-001 — IngestCoordinator safe intake", .serialized)
struct IngestCoordinatorSafeIntakeTests {

    private struct Rig {
        let coordinator: IngestCoordinator
        let db: Database
        let dir: URL
    }

    @MainActor
    private func makeRig() async throws -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usf-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let files = FilesRepository(database: db)
        let objects = KnowledgeObjectRepository(database: db)
        let chunks = ChunksRepository(database: db)
        let store = EvidenceStore(database: db)
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let coordinator = IngestCoordinator(
            loaders: .standard(),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: files, objects: objects, chunks: chunks,
            evidenceStore: store, structuralRegistry: .standard(ocr: VisionOCR()),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            intakeCoordinator: intake)
        return Rig(coordinator: coordinator, db: db, dir: dir)
    }

    private func write(_ rig: Rig, _ name: String, _ contents: String) throws -> URL {
        let url = rig.dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeData(_ rig: Rig, _ name: String, _ data: Data) throws -> URL {
        let url = rig.dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private let email = """
    From: Alexandra Rivera <alex@orchidlabs.example>
    To: Legal Team <legal@orchidlabs.example>
    Subject: Orchid Labs services agreement
    Date: Mon, 3 Mar 2025 09:12:00 +0000

    I have signed the Orchid Labs services agreement today, 3 March 2025.
    """

    // MARK: - Custody before parsing

    @Test("Intake registers a source version + receipt before any loader output exists")
    @MainActor func intakeBeforeLoader() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "matter.eml", email)
        let result = try await rig.coordinator.ingest(fileAt: url)
        #expect(result.sourceVersionID != nil)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_intake_receipts WHERE outcome='newLogicalSource';", []).first?.int(0) == 1)
        // custody metadata present
        let custody = try await rig.db.query("SELECT custody_mode, preservation_status FROM source_versions;", []).first
        #expect(custody?.string(0) == "referenced")
    }

    @Test("An unknown-type input that produces no parse still receives custody (loader/parser absence is visible)")
    @MainActor func unknownInputKeepsCustody() async throws {
        let rig = try await makeRig()
        let url = try writeData(rig, "mystery.zzz", Data([0x01, 0x02, 0x03, 0x04]))
        _ = try await rig.coordinator.ingest(fileAt: url)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        #expect(try await rig.db.query("SELECT detected_type FROM source_versions;", []).first?.string(0) == "unknown")
    }

    @Test("Deferred audio receives custody and is recorded as deferred, not failed")
    @MainActor func deferredAudioKeepsCustody() async throws {
        let rig = try await makeRig()
        let url = try writeData(rig, "voice.mp3", Data(repeating: 0x11, count: 64))
        let result = try await rig.coordinator.ingest(fileAt: url)
        #expect(result.chunkCount == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        let attempt = try await rig.db.query("SELECT status, source_version_id FROM ingest_file_attempts WHERE stage='media-deferred';", []).first
        #expect(attempt?.string(0) == "deferred")
        #expect(attempt?.uuid(1) != nil)
    }

    @Test("Deferred video receives custody")
    @MainActor func deferredVideoKeepsCustody() async throws {
        let rig = try await makeRig()
        let url = try writeData(rig, "clip.mp4", Data(repeating: 0x22, count: 64))
        _ = try await rig.coordinator.ingest(fileAt: url)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
    }

    // MARK: - Outcome gating

    @Test("An unchanged file does not reparse (no new version, no new chunks)")
    @MainActor func unchangedBypassesParser() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "matter.eml", email)
        _ = try await rig.coordinator.ingest(fileAt: url)
        let versionsAfterFirst = try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0)
        let second = try await rig.coordinator.ingest(fileAt: url)
        #expect(second.intakeOutcome == .unchanged)
        #expect(second.chunkCount == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == versionsAfterFirst)
    }

    @Test("An alias (same bytes, new URL, old present) does not reparse")
    @MainActor func aliasBypassesParser() async throws {
        let rig = try await makeRig()
        _ = try await rig.coordinator.ingest(fileAt: try write(rig, "a.eml", email))
        let aliased = try await rig.coordinator.ingest(fileAt: try write(rig, "b.eml", email))
        #expect(aliased.intakeOutcome == .aliased)
        #expect(aliased.chunkCount == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
    }

    @Test("A move (same bytes, new URL, old gone) does not reparse")
    @MainActor func moveBypassesParser() async throws {
        let rig = try await makeRig()
        let a = try write(rig, "a.eml", email)
        _ = try await rig.coordinator.ingest(fileAt: a)
        try FileManager.default.removeItem(at: a)
        let moved = try await rig.coordinator.ingest(fileAt: try write(rig, "b.eml", email))
        #expect(moved.intakeOutcome == .moved)
        #expect(moved.chunkCount == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
    }

    // MARK: - Attach + preservation

    @Test("A parsed document attaches to the pre-created source version (one version, document_id set)")
    @MainActor func parsedDocumentAttaches() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let versionID = try #require(result.sourceVersionID)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 1)
        let docID = try await rig.db.query("SELECT document_id FROM source_versions WHERE id = ?;", [.uuid(versionID)]).first
        #expect(docID?.isNull(0) == false)     // parsed document attached
    }

    @Test("Changed content creates a new version and preserves the old version + its EvidenceBlocks")
    @MainActor func changedContentPreservesOldBlocks() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "matter.eml", email)
        let first = try await rig.coordinator.ingest(fileAt: url)
        let firstVersion = try #require(first.sourceVersionID)
        let oldBlockCount = try await rig.db.query("SELECT COUNT(*) FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(firstVersion)]).first?.int(0) ?? 0
        // change bytes at the same URL
        _ = try write(rig, "matter.eml", email + "\n\nAddendum: second version.")
        let second = try await rig.coordinator.ingest(fileAt: url)
        #expect(second.intakeOutcome == .newVersion)
        #expect(second.sourceVersionID != firstVersion)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) == 2)      // old preserved
        #expect(try await rig.db.query("SELECT is_current FROM source_versions WHERE id = ?;", [.uuid(firstVersion)]).first?.int(0) == 0)
        #expect(try await rig.db.query("SELECT COUNT(*) FROM evidence_blocks WHERE source_version_id = ?;", [.uuid(firstVersion)]).first?.int(0) == oldBlockCount)
    }

    @Test("The ingest attempt row carries the exact logical-source and source-version ids")
    @MainActor func attemptCarriesVersionIDs() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let row = try #require(try await rig.db.query("""
            SELECT logical_source_id, source_version_id FROM ingest_file_attempts
              WHERE status='queryable' ORDER BY attempted_at DESC LIMIT 1;
            """, []).first)
        #expect(row.uuid(0) == result.logicalSourceID)
        #expect(row.uuid(1) == result.sourceVersionID)
    }

    @Test("An empty accessible file still receives custody even when the loader rejects empty content")
    @MainActor func emptyFileKeepsCustody() async throws {
        let rig = try await makeRig()
        let url = try writeData(rig, "empty.txt", Data())
        // Custody is registered BEFORE the loader; the text loader may reject empty content
        // (extraction outcome "empty"), but the source version must persist regardless.
        _ = try? await rig.coordinator.ingest(fileAt: url)
        let row = try #require(try await rig.db.query("SELECT size_bytes, content_hash FROM source_versions;", []).first)
        #expect(row.int(0) == 0)
        #expect(row.string(1) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        // The failure is recorded against the exact version (retriable), custody intact.
        let attempt = try await rig.db.query("SELECT status, source_version_id FROM ingest_file_attempts WHERE stage='loader';", []).first
        #expect(attempt?.uuid(1) != nil)
    }

    @Test("An alias occurrence is a distinct file row pointing at the canonical source")
    @MainActor func aliasFileRowPointsAtCanonical() async throws {
        let rig = try await makeRig()
        let first = try await rig.coordinator.ingest(fileAt: try write(rig, "a.eml", email))
        let aliased = try await rig.coordinator.ingest(fileAt: try write(rig, "b.eml", email))
        #expect(aliased.fileRecord.id != first.logicalSourceID)
        let aliasOf = try await rig.db.query("SELECT alias_of FROM files WHERE id = ?;", [.uuid(aliased.fileRecord.id)]).first
        #expect(aliasOf?.uuid(0) == first.logicalSourceID)
    }

    // MARK: - Parent relation survives a child that never parses

    @Test("A version-level parent relation is recorded even when the child never parses")
    @MainActor func parentRelationSurvivesChildParseFailure() async throws {
        let rig = try await makeRig()
        let parent = try await rig.coordinator.ingest(fileAt: try write(rig, "email.eml", email))
        let parentVersion = try #require(parent.sourceVersionID)
        // A child of an unknown type — it will not parse, but intake records the relation first.
        let childURL = try writeData(rig, "attach.zzz", Data([0x09, 0x08, 0x07, 0x06]))
        let ref = SourceParentReference(parentSourceVersionID: parentVersion, relation: .attachment)
        let child = try await rig.coordinator.runIngest(fileAt: childURL, parentVersion: ref)
        let childVersion = try #require(child.sourceVersionID)
        let rel = try #require(try await rig.db.query("""
            SELECT parent_source_version_id, child_source_version_id, relation FROM source_version_relations;
            """, []).first)
        #expect(rel.uuid(0) == parentVersion)
        #expect(rel.uuid(1) == childVersion)
        #expect(rel.string(2) == "attachment")
    }
}
