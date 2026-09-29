//
//  EvidenceContentVerificationTests.swift
//  KalsmritikoshTests
//
//  F15/F25 (remaining fixes, 2026-09-29 review of 39e64d6).
//  Repair 1 — citation lineage (`chunk_blocks`) and the block fields `language` / `extraction_confidence`
//  were outside the evidence revisions, so a lost or swapped citation left every proof "current" and the
//  reconciliation fast path never looked.
//  Repair 2 — reconciliation reaffirmed indexing from counts and links; an equal-length edit of chunk
//  text ("approved" → "rejected") kept every count and link, so stale derived text stayed certified.
//  Both are exercised through the REAL upgrade path (ensureUpgrade, foreground).
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F15/F25 — lineage and derived content are verified against evidence before readiness is reaffirmed", .serialized)
@MainActor
struct EvidenceContentVerificationTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let dir: URL; let vault: EvidenceVault }

    private func rig(hook: (@Sendable (UUID) async -> Void)? = nil, reuse: Rig? = nil) async throws -> Rig {
        let dir: URL, db: Database, vault: EvidenceVault
        if let reuse { dir = reuse.dir; db = reuse.db; vault = reuse.vault } else {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("evcv-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            db = try Database(url: dir.appendingPathComponent("ledger.sqlite"))
            try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
            vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        }
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
        await c.configureUpgrades(database: db, jobs: SourceUpgradeJobRepository(database: db), reconcileHook: hook)
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 1 << 30, deferWholeFileAboveBytes: 1 << 31,
                                                   resumable: ResumableStreamBudget(unitsPerRun: 1_000, unitsPerRecord: 2)))
        return Rig(c: c, db: db, dir: dir, vault: vault)
    }

    /// Three rows → two records (2 + 1 rows), so one chunk cites two blocks and another cites one.
    private func source(_ r: Rig, _ name: String, rows: [String]) throws -> URL {
        let url = r.dir.appendingPathComponent(name)
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        sqlite3_exec(h, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT);", nil, nil, nil)
        for (i, body) in rows.enumerated() { sqlite3_exec(h, "INSERT INTO notes VALUES(\(i + 1), '\(body)');", nil, nil, nil) }
        return url
    }

    private let rowsA = ["Alice approved the budget", "Bob filed the claim", "Carol signed the lease"]

    private func current(_ r: Rig, _ sv: UUID, _ d: SourceReadinessDimension) async throws -> Bool {
        try await SourceReadinessRepository(database: r.db).proofIsCurrent(sourceVersionID: sv, dimension: d)
    }

    private func state(_ r: Rig, _ sv: UUID, _ d: SourceReadinessDimension) async throws -> SourceReadinessDimensionState? {
        try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: sv).dimension(d)?.state
    }

    private func lineage(_ r: Rig, _ sv: UUID) async throws -> [(chunk: UUID, block: UUID, ordinal: Int)] {
        try await r.db.query("""
            SELECT cb.chunk_id, cb.evidence_block_id, cb.ordinal FROM chunk_blocks cb JOIN chunks c ON c.id = cb.chunk_id
             WHERE c.source_version_id = ? AND c.superseded_by_run IS NULL ORDER BY c.rowid, cb.ordinal;
            """, [.uuid(sv)]).compactMap { row in
            guard let c = row.uuid(0), let b = row.uuid(1) else { return nil }
            return (c, b, Int(row.int(2) ?? 0))
        }
    }

    private func repaired(_ r: Rig, _ sv: UUID) async throws {
        _ = try await r.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground)
        #expect(try await ChunkDerivation.verify(r.db, sourceVersionID: sv).mismatchedChunks == 0, "every active chunk matches its evidence")
        #expect(try await state(r, sv, .indexing) == .ready)
        #expect(try await current(r, sv, .indexing), "the repaired index carries a current proof")
    }

    private func search(_ r: Rig, _ term: String) async throws -> Bool {
        !(try await ChunksRepository(database: r.db).searchFTS(term, limit: 5)).isEmpty
    }

    // MARK: - Repair 1 — revision coverage

    @Test("Deleting one lineage row (text, counts and ownership unchanged) stales indexing; the real upgrade restores it")
    func lineageDeleteDetectedAndRepaired() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        #expect(try await current(r, sv, .indexing))
        #expect(try await current(r, sv, .textExtraction))
        let before = try await lineage(r, sv)
        let victim = try #require(before.first)
        try await r.db.exec("DELETE FROM chunk_blocks WHERE chunk_id = ? AND evidence_block_id = ?;", [.uuid(victim.chunk), .uuid(victim.block)])
        #expect(try await !current(r, sv, .indexing), "lost citation lineage must stale the index proof")
        #expect(try await current(r, sv, .textExtraction), "text depends on chunks only — not staled needlessly")
        try await repaired(r, sv)
        #expect(Set(try await lineage(r, sv).map(\.block)) == Set(before.map(\.block)), "every block is cited again")
    }

    @Test("Swapping two lineage targets across chunks, and re-ordering lineage within a chunk, are both detected and repaired")
    func lineageSwapAndReorder() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        let rows = try await lineage(r, sv)
        let chunks = Array(Set(rows.map(\.chunk)))
        try #require(chunks.count >= 2)
        let a = try #require(rows.first { $0.chunk == chunks[0] }), b = try #require(rows.first { $0.chunk == chunks[1] })
        // Swap targets — row count and every block's citation count stay the same.
        let tmp = UUID()
        try await r.db.exec("UPDATE chunk_blocks SET evidence_block_id = ? WHERE chunk_id = ? AND evidence_block_id = ?;", [.uuid(tmp), .uuid(a.chunk), .uuid(a.block)])
        try await r.db.exec("UPDATE chunk_blocks SET evidence_block_id = ? WHERE chunk_id = ? AND evidence_block_id = ?;", [.uuid(a.block), .uuid(b.chunk), .uuid(b.block)])
        try await r.db.exec("UPDATE chunk_blocks SET evidence_block_id = ? WHERE chunk_id = ? AND evidence_block_id = ?;", [.uuid(b.block), .uuid(a.chunk), .uuid(tmp)])
        #expect(try await lineage(r, sv).count == rows.count)
        #expect(try await !current(r, sv, .indexing), "a swap preserving counts must stale the proof")
        try await repaired(r, sv)

        // Re-order within the chunk that cites two blocks.
        let now = try await lineage(r, sv)
        let multi = try #require(Dictionary(grouping: now, by: \.chunk).first { $0.value.count >= 2 })
        try await r.db.exec("UPDATE chunk_blocks SET ordinal = 1 - ordinal WHERE chunk_id = ?;", [.uuid(multi.key)])
        #expect(try await !current(r, sv, .indexing), "re-ordered lineage must stale the proof")
        try await repaired(r, sv)
    }

    @Test("Changing only a block's language, then only its confidence, stales the block-dependent proofs (not text)")
    func languageAndConfidenceTracked() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        let block = try #require(try await r.db.query("SELECT id FROM evidence_blocks WHERE source_version_id = ? AND kind = 'tableRow' LIMIT 1;", [.uuid(sv)]).first?.uuid(0))
        for sql in ["UPDATE evidence_blocks SET language = 'fr' WHERE id = ?;",
                    "UPDATE evidence_blocks SET extraction_confidence = 0.42 WHERE id = ?;"] {
            _ = try await r.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
            #expect(try await current(r, sv, .structuralExtraction))
            #expect(try await current(r, sv, .indexing))
            try await r.db.exec(sql, [.uuid(block)])
            #expect(try await !current(r, sv, .structuralExtraction), "\(sql) must stale structure")
            #expect(try await !current(r, sv, .indexing), "\(sql) must stale indexing")
            #expect(try await current(r, sv, .textExtraction), "text is not derived from these fields")
        }
        // Neither field changes chunk text: re-verification reaffirms without a rebuild.
        let ids = Set(try await r.db.query("SELECT id FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(sv)]).compactMap { $0.uuid(0) })
        _ = try await r.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
        #expect(try await current(r, sv, .indexing))
        #expect(try await current(r, sv, .structuralExtraction))
        #expect(Set(try await r.db.query("SELECT id FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(sv)]).compactMap { $0.uuid(0) }) == ids)
    }

    @Test("Deleting a chunk cascades its lineage without trigger errors, stales the proof, and the upgrade re-indexes it")
    func chunkDeleteCascade() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        let chunk = try #require(try await r.db.query("SELECT id FROM chunks WHERE source_version_id = ? AND text LIKE '%Carol%' LIMIT 1;", [.uuid(sv)]).first?.uuid(0))
        try await r.db.exec("DELETE FROM chunks WHERE id = ?;", [.uuid(chunk)])
        #expect(try await r.db.query("SELECT COUNT(*) FROM chunk_blocks WHERE chunk_id = ?;", [.uuid(chunk)]).first?.int(0) == 0, "lineage cascaded")
        #expect(try await !current(r, sv, .indexing))
        try await repaired(r, sv)
        #expect(try await search(r, "Carol"))
    }

    @Test("A mutation to source A never stales source B; an unchanged source keeps the fast path")
    func sourceIsolation() async throws {
        let r = try await rig()
        let a = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        let b = try #require(try await r.c.ingest(fileAt: try source(r, "b.db", rows: ["Dana logged the call", "Evan closed the file"])).sourceVersionID)
        let bRevision = try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: b).aggregateRevision
        let victim = try #require(try await lineage(r, a).first)
        try await r.db.exec("DELETE FROM chunk_blocks WHERE chunk_id = ? AND evidence_block_id = ?;", [.uuid(victim.chunk), .uuid(victim.block)])
        try await r.db.exec("UPDATE evidence_blocks SET language = 'de' WHERE source_version_id = ?;", [.uuid(a)])
        for d in [SourceReadinessDimension.indexing, .structuralExtraction, .textExtraction] {
            #expect(try await current(r, b, d), "source B's \(d) proof must not move")
        }
        #expect(try await r.c.ensureUpgrade(sourceVersionID: b, goal: .searchReady, execution: .foreground).isEmpty)
        #expect(try await SourceReadinessRepository(database: r.db).snapshot(sourceVersionID: b).aggregateRevision == bRevision,
                "fast path: no readiness write for the unchanged source")
    }

    // MARK: - Repair 2 — content verified before reaffirming

    @Test("An equal-length chunk text edit ('approved' → 'rejected') is repaired from evidence by the real upgrade")
    func equalLengthTextEditRepaired() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        #expect(try await search(r, "approved"))
        try await r.db.exec("UPDATE chunks SET text = replace(text, 'approved', 'rejected') WHERE source_version_id = ?;", [.uuid(sv)])
        #expect(try await search(r, "rejected"), "fixture: the derived text now disagrees with its evidence")
        #expect(try await !search(r, "approved"))
        try await repaired(r, sv)
        #expect(try await search(r, "approved"), "the chunk is re-derived from the evidence block")
        #expect(try await !search(r, "rejected"), "the stale text no longer serves as current output")
        #expect(try await r.db.query("SELECT COUNT(*) FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NOT NULL AND text LIKE '%rejected%';",
                                     [.uuid(sv)]).first?.int(0) ?? 0 >= 1, "the replaced chunk is superseded, not deleted (historical ids resolve)")
    }

    @Test("Changed block content (same identity and counts) is not certified with the old derived chunks")
    func blockContentChangeRebuilds() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        try await r.db.exec("""
            UPDATE evidence_blocks SET raw_text = replace(raw_text, 'Bob filed', 'Bob voided'),
                   normalized_text = replace(normalized_text, 'Bob filed', 'Bob voided')
             WHERE source_version_id = ? AND raw_text LIKE '%Bob filed%';
            """, [.uuid(sv)])
        try await repaired(r, sv)
        #expect(try await search(r, "voided"), "the index now derives from the active block content")
    }

    @Test("A locator-only correction re-verifies without rebuilding text; citations read the new locator")
    func locatorOnlyNoRebuild() async throws {
        let r = try await rig()
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        let chunkIDs = Set(try await r.db.query("SELECT id FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(sv)]).compactMap { $0.uuid(0) })
        let block = try #require(try await r.db.query("SELECT id FROM evidence_blocks WHERE source_version_id = ? AND kind = 'tableRow' LIMIT 1;", [.uuid(sv)]).first?.uuid(0))
        let moved = SourceLocator(sectionPath: ["a.db", "notes", "corrected-key"])
        let json = String(data: try JSONEncoder().encode(moved), encoding: .utf8)!
        try await r.db.exec("UPDATE evidence_blocks SET locator = ? WHERE id = ?;", [.text(json), .uuid(block)])
        #expect(try await !current(r, sv, .indexing))
        try await repaired(r, sv)
        #expect(Set(try await r.db.query("SELECT id FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(sv)]).compactMap { $0.uuid(0) }) == chunkIDs,
                "no text rebuild for a locator-only change")
        #expect(try await EvidenceStore(database: r.db).blocks(ids: [block]).first?.locator == moved)
    }

    @Test("Interrupted rebuild (one object switched): a fresh coordinator converges with nothing stale certified")
    func interruptedRebuildConverges() async throws {
        let first = try await rig()
        let sv = try #require(try await first.c.ingest(fileAt: try source(first, "a.db", rows: rowsA)).sourceVersionID)
        try await first.db.exec("UPDATE chunks SET text = replace(replace(text, 'approved', 'rejected'), 'signed', 'burned') WHERE source_version_id = ?;", [.uuid(sv)])
        let objects = try await first.db.query("SELECT DISTINCT object_id FROM chunks WHERE source_version_id = ? AND superseded_by_run IS NULL;", [.uuid(sv)]).compactMap { $0.uuid(0) }
        try #require(objects.count == 2)
        // Rebuild ONE object only, then "crash" (no readiness update).
        try await first.c.rebuildIndex(sourceVersionID: sv, objects: [objects[0]])
        #expect(try await ChunkDerivation.verify(first.db, sourceVersionID: sv).mismatchedChunks > 0, "the other object is still stale")
        #expect(try await !current(first, sv, .indexing), "a half-finished rebuild is never certified")
        // Reopen and resume.
        let second = try await rig(reuse: first)
        try await repaired(second, sv)
        #expect(try await !search(second, "rejected"))
        #expect(try await !search(second, "burned"))
    }

    private actor Counter { var n = 0; func next() -> Int { n += 1; return n } }

    @Test("Evidence mutated between measurement and stamping: re-measured to an honest result; persistent churn is reported pending")
    func mutationDuringMeasurement() async throws {
        // Once: the stamp is refused, the next measurement sees the new state and invalidates it.
        let once = Counter()
        let dbBox = DatabaseBox()
        let r = try await rig(hook: { sv in
            guard await once.next() == 1, let db = await dbBox.db else { return }
            try? await db.exec("UPDATE chunks SET text = replace(text, 'filed', 'faked') WHERE source_version_id = ?;", [.uuid(sv)])
        })
        await dbBox.set(r.db)
        let sv = try #require(try await r.c.ingest(fileAt: try source(r, "a.db", rows: rowsA)).sourceVersionID)
        try await r.db.exec("UPDATE evidence_blocks SET language = 'fr' WHERE source_version_id = ?;", [.uuid(sv)])   // forces a measurement
        try await repaired(r, sv)
        #expect(try await !search(r, "faked"), "the mid-measurement edit was caught, not stamped over")

        // Always: never stamped, reported as retryable pending.
        let always = DatabaseBox()
        let churn = try await rig(hook: { sv in
            guard let db = await always.db else { return }
            try? await db.exec("UPDATE chunks SET text = text || ' ' WHERE source_version_id = ?;", [.uuid(sv)])
        })
        await always.set(churn.db)
        let sv2 = try #require(try await churn.c.ingest(fileAt: try source(churn, "c.db", rows: rowsA)).sourceVersionID)
        try await churn.db.exec("UPDATE evidence_blocks SET language = 'fr' WHERE source_version_id = ?;", [.uuid(sv2)])
        await #expect(throws: SourceUpgradeError.evidenceChanging(sv2)) {
            _ = try await churn.c.ensureUpgrade(sourceVersionID: sv2, goal: .searchReady, execution: .foreground)
        }
        #expect(try await !current(churn, sv2, .indexing), "a refused stamp is never treated as satisfied")
    }

    private actor DatabaseBox { var db: Database?; func set(_ d: Database) { db = d } }
}
