//
//  ChunkDigestProofTests.swift
//  KalsmritikoshTests
//
//  F15/F25 (review of 070f2fe) — a chunk without a derivation digest (written before v141, or by a
//  write path that did not supply its blocks) was given a "baseline" digest from its CURRENT state,
//  so corruption that happened before the baseline was certified as correct; and the chunk-reindex
//  paths wrote chunks without their blocks, so every rebuilt chunk was digest-less. Now every write
//  path records a digest from the blocks it used, and a digest-less chunk is proven against evidence
//  (re-derived by the chunker from committed blocks) or rebuilt — or, with no lineage to check,
//  stays explicitly unverified.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F15/F25 — a digest-less chunk is proven against evidence or rebuilt, never certified as it is", .serialized)
@MainActor
struct ChunkDigestProofTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let dir: URL }

    private func rig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("ledger.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault)),
            custodyModeOverride: .managed)
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db))
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 1 << 30, deferWholeFileAboveBytes: 1 << 31,
                                                   resumable: ResumableStreamBudget(unitsPerRun: 1_000, unitsPerRecord: 2)))
        return Rig(c: c, db: db, dir: dir)
    }

    /// Three rows → two objects (2 + 1 rows).
    private func ingest(_ r: Rig, rows: [String] = ["Alice approved the budget", "Bob filed the claim", "Carol signed the lease"]) async throws -> UUID {
        let url = r.dir.appendingPathComponent("notes-\(UUID().uuidString.prefix(6)).db")
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        sqlite3_exec(h, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);", nil, nil, nil)
        for (i, body) in rows.enumerated() { sqlite3_exec(h, "INSERT INTO notes VALUES(\(i + 1), '\(body)');", nil, nil, nil) }
        sqlite3_close(h)
        return try #require(try await r.c.ingest(fileAt: url).sourceVersionID)
    }

    /// What a ledger migrated from before v141 looks like: no digests, and proofs stamped under the old token.
    private func simulatePreV141(_ r: Rig, _ sv: UUID) async throws {
        try await r.db.exec("UPDATE chunks SET derivation_digest = NULL WHERE source_version_id = ?;", [.uuid(sv)])
        try await r.db.exec("UPDATE source_readiness_dimensions SET evidence_fingerprint = 'rev1|legacy' WHERE source_version_id = ?;", [.uuid(sv)])
    }

    private func search(_ r: Rig, _ term: String) async throws -> Bool {
        !(try await ChunksRepository(database: r.db).searchFTS(term, limit: 5)).isEmpty
    }

    private func activeChunks(_ r: Rig, _ sv: UUID) async throws -> [(id: UUID, object: UUID, digest: String?)] {
        try await r.db.query("SELECT id, object_id, derivation_digest FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;",
                             [.uuid(sv)]).compactMap { row in
            guard let id = row.uuid(0), let ko = row.uuid(1) else { return nil }
            return (id, ko, row.string(2))
        }
    }

    @Test("Pre-v141 corruption is not baselined: the corrupted object is rebuilt, the intact one proven without a rebuild")
    func legacyCorruptionIsNotCertified() async throws {
        let r = try await rig()
        let sv = try await ingest(r)
        let before = try await activeChunks(r, sv)
        let corrupted = try #require(try await r.db.query(
            "SELECT object_id FROM chunks WHERE source_version_id = ? AND text LIKE '%approved%' LIMIT 1;", [.uuid(sv)]).first?.uuid(0))
        // Corruption that predates the digest: equal-length edit, then the digest is absent.
        try await r.db.exec("UPDATE chunks SET text = replace(text, 'approved', 'rejected') WHERE source_version_id = ?;", [.uuid(sv)])
        try await simulatePreV141(r, sv)

        _ = try await r.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground)

        #expect(try await search(r, "approved"), "the corrupted chunk was re-derived from its evidence")
        #expect(try await !search(r, "rejected"), "the pre-baseline corruption was NOT certified")
        let after = try await activeChunks(r, sv)
        #expect(after.allSatisfy { $0.digest != nil }, "every active chunk now carries a proven digest")
        let intactBefore = Set(before.filter { $0.object != corrupted }.map(\.id))
        let intactAfter = Set(after.filter { $0.object != corrupted }.map(\.id))
        #expect(!intactBefore.isEmpty && intactBefore == intactAfter, "the intact object was proven, not rebuilt")
        #expect(try await ChunkDerivation.verify(r.db, sourceVersionID: sv).uncertifiable == 0)
        let snap = try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: sv)
        #expect(snap.dimension(.indexing)?.state == .ready)
    }

    @Test("A digest-less chunk with no evidence lineage stays explicitly unverified — never certified — and does not loop")
    func contentOnlyChunkStaysUnverified() async throws {
        let r = try await rig()
        let sv = try await ingest(r)
        let ko = try #require(try await activeChunks(r, sv).first?.object)
        try await r.db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id)
            VALUES (?, ?, 900, 'A legacy note with no evidence lineage', 0, 38, 0, ?);
            """, [.uuid(UUID()), .uuid(ko), .uuid(sv)])
        try await simulatePreV141(r, sv)
        // The lineage chunks are proven; the lineage-less one cannot be.
        try await r.db.exec("UPDATE chunks SET derivation_digest = NULL WHERE source_version_id = ?;", [.uuid(sv)])

        _ = try await r.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground)
        let readiness = SourceReadinessRepository(database: r.db)
        let indexing = try await readiness.snapshot(sourceVersionID: sv).dimension(.indexing)
        #expect(indexing?.state == .partial, "an unverifiable index entry keeps the index uncertified")
        #expect(indexing?.detail?.contains("unverified") == true, "\(indexing?.detail ?? "nil")")
        let check = try await ChunkDerivation.verify(r.db, sourceVersionID: sv)
        #expect(check.unverifiedChunks == 1 && check.needsRebuildOrProof == 0)

        // Stable: a further request finds the recorded state current and schedules nothing.
        let rev = try await readiness.snapshot(sourceVersionID: sv).aggregateRevision
        #expect(try await r.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground).isEmpty)
        #expect(try await readiness.snapshot(sourceVersionID: sv).aggregateRevision == rev)
    }

    @Test("Both chunk-reindex write paths (repack and split) record digests from the blocks they used")
    func reindexPathsWriteDigests() async throws {
        let r = try await rig()
        let sv = try await ingest(r)
        let chunks = try await activeChunks(r, sv)
        let koA = try #require(chunks.first?.object)
        // Repack path (P1.8): an object that owns blocks but has a lineage-less chunk is re-packed.
        try await r.db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id)
            VALUES (?, ?, 900, 'flattened legacy text', 0, 21, 0, ?);
            """, [.uuid(UUID()), .uuid(koA), .uuid(sv)])
        // Split path: another chunk with lineage becomes oversized.
        let para = String(repeating: "The claim was filed after review by the board. ", count: 28)
        let big = [para, para, para].joined(separator: "\n\n")
        let target = try #require(chunks.first { $0.object != koA }?.id)
        try await r.db.exec("UPDATE chunks SET text = ?, chunk_version = 0 WHERE id = ?;", [.text(big), .uuid(target)])

        let receipt = try await ChunkReindexCoordinator(database: r.db).run()
        #expect(receipt.oversizedSplit >= 1, "fixture: the split path ran")
        let nullDigests = try await r.db.query("""
            SELECT COUNT(*) FROM chunks c WHERE c.source_version_id = ? AND c.superseded_by_run IS NULL
               AND c.derivation_digest IS NULL AND EXISTS (SELECT 1 FROM chunk_blocks cb WHERE cb.chunk_id = c.id);
            """, [.uuid(sv)]).first?.int(0)
        #expect(nullDigests == 0, "a reindexed chunk that cites blocks must carry a digest")
        #expect(try await ChunkDerivation.verify(r.db, sourceVersionID: sv).mismatchedChunks == 0,
                "the recorded digests match the live chunks and blocks")
    }
}
