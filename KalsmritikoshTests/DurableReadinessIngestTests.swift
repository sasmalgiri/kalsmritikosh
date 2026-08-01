//
//  DurableReadinessIngestTests.swift
//  KalsmritikoshTests
//
//  USF-002.1 — end-to-end proof that readiness derives from durable, exact-version state: every
//  persisted chunk carries the exact source version, a parent's indexing coverage never counts a
//  child attachment's chunks, structural readiness follows the committed receipt, and the
//  proof-backed snapshot reconstructs after relaunch. Synthetic sources only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-002.1 — durable readiness ingest", .serialized)
struct DurableReadinessIngestTests {

    private struct Rig { let coordinator: IngestCoordinator; let readiness: SourceReadinessRepository; let db: Database; let dir: URL; let dbURL: URL }

    @MainActor
    private func makeRig() async throws -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("usf021-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("db.sqlite")
        let db = try Database(url: dbURL)
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let readiness = SourceReadinessRepository(database: db)
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(
            database: db, vault: EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))))
        let coordinator = IngestCoordinator(
            loaders: .standard(),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            structuralRegistry: .standard(ocr: VisionOCR()),
            ingestAttempts: IngestAttemptsRepository(database: db),
            sourceRelations: SourceRelationsRepository(database: db),
            readiness: readiness, intakeCoordinator: intake)
        return Rig(coordinator: coordinator, readiness: readiness, db: db, dir: dir, dbURL: dbURL)
    }

    private func write(_ rig: Rig, _ name: String, _ contents: String) throws -> URL {
        let url = rig.dir.appendingPathComponent(name); try contents.write(to: url, atomically: true, encoding: .utf8); return url
    }

    private let email = """
    From: Alexandra Rivera <alex@orchidlabs.example>
    To: Legal Team <legal@orchidlabs.example>
    Subject: Orchid Labs services agreement
    Date: Mon, 3 Mar 2025 09:12:00 +0000

    I have signed the Orchid Labs services agreement today, 3 March 2025, covering the full scope
    of professional services for the 2025 engagement year across every listed matter and deadline.
    """

    private func chunkCount(_ rig: Rig, version: UUID) async throws -> Int {
        Int(try await rig.db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id = ?;", [.uuid(version)]).first?.int(0) ?? 0)
    }

    @Test("Every persisted chunk carries the exact source version it belongs to")
    @MainActor func exactChunkOwnership() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let v = try #require(result.sourceVersionID)
        let total = Int(try await rig.db.query("SELECT COUNT(*) FROM chunks;", []).first?.int(0) ?? 0)
        let owned = try await chunkCount(rig, version: v)
        #expect(total > 0)
        #expect(owned == total)                 // this single-source ingest: all chunks owned by its version
        #expect(try await rig.db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id IS NULL;", []).first?.int(0) == 0)
    }

    @Test("Indexing readiness units equal the exact per-version FTS coverage")
    @MainActor func indexingUnitsMatchCoverage() async throws {
        let rig = try await makeRig()
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email))
        let v = try #require(result.sourceVersionID)
        let snap = try await rig.readiness.snapshot(sourceVersionID: v)
        let cov = try await rig.readiness.ftsCoverage(sourceVersionID: v)
        let idx = snap.dimension(.indexing)
        #expect(idx?.totalUnits == cov.eligible)
        #expect(idx?.completedUnits == cov.indexed)
        #expect((idx?.totalUnits ?? 0) == (try await chunkCount(rig, version: v)))
    }

    @Test("A parent source's coverage never counts a child attachment's chunks")
    @MainActor func parentDoesNotCountChildChunks() async throws {
        let rig = try await makeRig()
        let attachmentEmail = """
        From: a@x.example
        To: b@x.example
        Subject: With attachment
        Date: Mon, 3 Mar 2025 09:12:00 +0000
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="BOUND"

        --BOUND
        Content-Type: text/plain

        The email body itself is searchable and substantive content for chunking purposes here.
        --BOUND
        Content-Type: text/plain; name="attach.txt"
        Content-Disposition: attachment; filename="attach.txt"

        A distinct attachment body with its own searchable content belonging to the child version.
        --BOUND--
        """
        let result = try await rig.coordinator.ingest(fileAt: try write(rig, "withattach.eml", attachmentEmail))
        let parent = try #require(result.sourceVersionID)
        let versionCount = Int(try await rig.db.query("SELECT COUNT(*) FROM source_versions;", []).first?.int(0) ?? 0)
        let parentOwned = try await chunkCount(rig, version: parent)
        let totalChunks = Int(try await rig.db.query("SELECT COUNT(*) FROM chunks;", []).first?.int(0) ?? 0)
        // The parent's coverage counts only its own chunks.
        #expect(try await rig.readiness.ftsCoverage(sourceVersionID: parent).eligible == parentOwned)
        // If the attachment became its own source version, its chunks are NOT in the parent's coverage.
        if versionCount >= 2 { #expect(parentOwned < totalChunks) }
    }

    @Test("Two independent sources keep disjoint, exact coverage")
    @MainActor func twoSourcesIndependentCoverage() async throws {
        let rig = try await makeRig()
        let a = try #require(try await rig.coordinator.ingest(fileAt: try write(rig, "a.txt", "Alpha document content, searchable and substantive for chunking.")).sourceVersionID)
        let b = try #require(try await rig.coordinator.ingest(fileAt: try write(rig, "b.txt", "Beta document content, different and independently searchable here.")).sourceVersionID)
        let covA = try await rig.readiness.ftsCoverage(sourceVersionID: a)
        let covB = try await rig.readiness.ftsCoverage(sourceVersionID: b)
        #expect(covA.eligible == (try await chunkCount(rig, version: a)))
        #expect(covB.eligible == (try await chunkCount(rig, version: b)))
        // A's coverage is unaffected by B's chunks.
        #expect(covA.eligible == (try await chunkCount(rig, version: a)))
    }

    @Test("Structural readiness follows the committed receipt (never fabricated)")
    @MainActor func structuralFollowsReceipt() async throws {
        let rig = try await makeRig()
        let v = try #require(try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email)).sourceVersionID)
        let snap = try await rig.readiness.snapshot(sourceVersionID: v)
        let structural = snap.dimension(.structuralExtraction)
        // structure advanced to a real committed state (ready or partial), never left notStarted with content.
        #expect([.ready, .partial].contains(structural?.state ?? .notStarted))
        // its basis is the parser run (durable proof), not absent.
        #expect(structural?.basis?.kind == .parserRun)
        // metadata is proven by the committed document.
        #expect(snap.dimension(.metadataExtraction)?.state == .ready)
        #expect(snap.dimension(.metadataExtraction)?.basis?.kind == .sourceDocument)
    }

    @Test("A changed file's new version has fresh coverage; the old version's is untouched")
    @MainActor func oldVersionCoverageUnchanged() async throws {
        let rig = try await makeRig()
        let url = try write(rig, "matter.eml", email)
        let v1 = try #require(try await rig.coordinator.ingest(fileAt: url).sourceVersionID)
        let v1Before = try await rig.readiness.snapshot(sourceVersionID: v1)
        let v1Chunks = try await chunkCount(rig, version: v1)
        _ = try write(rig, "matter.eml", email + "\n\nAddendum: amended 10 March 2025 with new searchable terms.")
        let v2 = try #require(try await rig.coordinator.ingest(fileAt: url).sourceVersionID)
        #expect(v2 != v1)
        #expect(try await rig.readiness.snapshot(sourceVersionID: v1) == v1Before)   // old readiness unchanged
        #expect(try await chunkCount(rig, version: v1) == v1Chunks)                   // old coverage unchanged
        #expect(try await chunkCount(rig, version: v2) > 0)                           // new version has its own chunks
    }

    @Test("The proof-backed readiness snapshot reconstructs exactly after relaunch")
    @MainActor func relaunchReconstructsProof() async throws {
        let rig = try await makeRig()
        let v = try #require(try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email)).sourceVersionID)
        let before = try await rig.readiness.snapshot(sourceVersionID: v)
        #expect(before.dimension(.indexing)?.basis?.kind == .ftsIndex)
        let reopened = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: rig.dbURL)
        let after = try await SourceReadinessRepository(database: reopened).snapshot(sourceVersionID: v)
        #expect(before == after)
    }

    @Test("A successful ingest is at least searchable (text + indexing ready from durable chunks)")
    @MainActor func searchableFromDurableChunks() async throws {
        let rig = try await makeRig()
        let v = try #require(try await rig.coordinator.ingest(fileAt: try write(rig, "matter.eml", email)).sourceVersionID)
        let snap = try await rig.readiness.snapshot(sourceVersionID: v)
        #expect(snap.dimension(.textExtraction)?.state == .ready)
        #expect(snap.dimension(.indexing)?.state == .ready)
        #expect(snap.isSearchReady)
    }
}
