//
//  ProgressiveIngestIntegrationTests.swift
//  KalsmritikoshTests
//
//  USF-M3 (§38/§39) — the progressive model end-to-end: a fast initial pass returns SEARCHABLE (not
//  evidence-ready); an on-demand evidence upgrade reopens the EXACT bytes, re-parses through the ONE
//  registry, commits structure, and advances readiness (postcondition-verified) so the job is done;
//  duplicate requests reuse the active job; background execution defers; a changed referenced file cannot
//  mutate the old version; a handler that changes no readiness fails its postcondition. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M3 — progressive ingest integration", .serialized)
@MainActor
struct ProgressiveIngestIntegrationTests {

    private struct Rig { let c: IngestCoordinator; let db: Database; let jobs: SourceUpgradeJobRepository; let dir: URL }

    private func makeRig() async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm3-prog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        let vault = EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true))
        let intake = UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: db, vault: vault))
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: db), objects: KnowledgeObjectRepository(database: db),
            chunks: ChunksRepository(database: db), evidenceStore: EvidenceStore(database: db),
            ingestAttempts: IngestAttemptsRepository(database: db), sourceRelations: SourceRelationsRepository(database: db),
            evidenceVault: vault, readiness: SourceReadinessRepository(database: db),
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake,
            custodyModeOverride: .referenced)
        let jobs = SourceUpgradeJobRepository(database: db)
        await c.configureUpgrades(database: db, jobs: jobs)
        return Rig(c: c, db: db, jobs: jobs, dir: dir)
    }

    private func writeTxt(_ rig: Rig, _ name: String, _ body: String) throws -> URL {
        let url = rig.dir.appendingPathComponent(name); try body.write(to: url, atomically: true, encoding: .utf8); return url
    }

    // MARK: - Fast core + evidence upgrade (the flagship loop)

    @Test("A fast initial pass returns SEARCHABLE, not evidence-ready, and schedules the evidence upgrade")
    func fastInitialReturnsSearchable() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "doc.txt", "Synthetic body with several searchable words here.")
        let result = try await rig.c.ingest(fileAt: url, intent: .initialFast)
        let c = try #require(result.completionSnapshot)
        #expect(c.isSearchReady)
        #expect(!c.isEvidenceReady)
        #expect(c.completionState == .searchablePartial)
        #expect(result.workScheduled.contains(.structuralExtraction))   // evidence upgrade scheduled
    }

    @Test("A foreground evidence upgrade reopens exact bytes, commits structure, and reaches evidence-ready")
    func evidenceUpgradeReachesEvidenceReady() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "e.txt", "Evidence upgrade body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        #expect(try await rig.c.completion(sourceVersionID: sv)?.completionState == .searchablePartial)
        let kinds = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
        #expect(kinds.contains(.structuralExtraction))
        let after = try #require(try await rig.c.completion(sourceVersionID: sv))
        #expect(after.isEvidenceReady)
        #expect(after.completionState == .evidenceReady)
    }

    @Test("An already-satisfied goal schedules no work")
    func alreadyEvidenceReadyNoWork() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "full.txt", "Full pass body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .fullAvailable).sourceVersionID)   // evidence now
        let kinds = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
        #expect(kinds.isEmpty)
    }

    // MARK: - Background vs foreground + idempotency

    @Test("Background ensure plans without executing; a drain then advances readiness")
    func backgroundThenDrain() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "b.txt", "Background body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        // Clear the auto-scheduled job so we control it, then schedule evidence in the background.
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .background)
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == false)   // not run yet
        let ran = await rig.c.drainUpgrades()
        #expect(ran >= 1)
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == true)
    }

    @Test("F20 — the supervised background drainer completes scheduled work with no foreground call")
    func supervisedDrainerCompletesWork() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "s.txt", "Supervised body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .background)
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == false)
        await rig.c.startUpgradeDrain(idleSeconds: 0.2, shouldRun: { true })   // independent of the app's power mode
        defer { Task { await rig.c.stopUpgradeDrain() } }
        var ready = false
        for _ in 0..<100 where !ready {                       // up to ~10 s
            try await Task.sleep(nanoseconds: 100_000_000)
            ready = try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == true
        }
        #expect(ready, "background drainer never completed the scheduled upgrade")
    }

    @Test("F25 — an indexing upgrade rebuilds a deleted index from committed blocks; search finds the text again")
    func indexingUpgradeRebuildsIndex() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "idx.txt", "Quartermaster ledger mentions the zephyrine consignment twice.")
        let sv = try #require(try await rig.c.ingest(fileAt: url).sourceVersionID)
        let chunks = ChunksRepository(database: rig.db)
        #expect(!(try await chunks.searchFTS("zephyrine", limit: 5)).isEmpty)
        // Lose ONLY the derived index; the evidence blocks stay.
        try await rig.db.exec("DELETE FROM chunks WHERE source_version_id = ?;", [.uuid(sv)])
        #expect(try await chunks.searchFTS("zephyrine", limit: 5).isEmpty)
        #expect(!(try await EvidenceStore(database: rig.db).blocks(forVersion: sv)).isEmpty)

        _ = try await rig.jobs.enqueue(sourceVersionID: sv, kind: .indexing, priority: .userRequested, at: Date())
        #expect(await rig.c.drainUpgrades() >= 1)
        let hits = try await chunks.searchFTS("zephyrine", limit: 5)
        #expect(!hits.isEmpty, "the rebuilt index must find the known text")
        // Per-version coverage proves the rebuilt chunks carry THIS exact version and are all in FTS.
        let coverage = try await SourceReadinessRepository(database: rig.db).ftsCoverage(sourceVersionID: sv)
        #expect(coverage.eligible > 0 && coverage.indexed == coverage.eligible)
    }

    @Test("F15 — a lost index behind a 'ready' record is detected on request and rebuilt")
    func lostIndexDetectedAndRepaired() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "lost.txt", "Harbourmaster notes record the velmoraine shipment arriving late.")
        let sv = try #require(try await rig.c.ingest(fileAt: url).sourceVersionID)
        let chunks = ChunksRepository(database: rig.db)
        try await rig.db.exec("DELETE FROM chunks WHERE source_version_id = ?;", [.uuid(sv)])
        #expect(try await chunks.searchFTS("velmoraine", limit: 5).isEmpty)
        // The stored record still claims the index is there; asking for search readiness must not trust it.
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground)
        #expect(!(try await chunks.searchFTS("velmoraine", limit: 5)).isEmpty, "the lost index was not detected + rebuilt")
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isSearchReady == true)
    }

    @Test("F15 — one object's index removed while another's grows (same total) is detected and repaired")
    func swappedDerivationDetected() async throws {
        let rig = try await makeRig()
        var mbox = ""
        for (i, word) in ["quillbright", "marrowfen"].enumerated() {
            mbox += "From a\(i)@x.example Mon Jan  1 00:00:00 2024\nFrom: A\(i) <a\(i)@x.example>\nSubject: Note \(i)\n"
            mbox += "Date: Mon, 1 Jan 2024 10:0\(i):00 +0000\n\nThe \(word) ledger entry was reconciled today by the team.\n\n"
        }
        let url = rig.dir.appendingPathComponent("two.mbox"); try mbox.write(to: url, atomically: true, encoding: .utf8)
        let sv = try #require(try await rig.c.ingest(fileAt: url).sourceVersionID)
        let chunks = ChunksRepository(database: rig.db)
        let hit = try #require(try await chunks.searchFTS("quillbright", limit: 5).first)
        let lostKO = try #require(try await rig.db.query("SELECT object_id FROM chunks WHERE id = ?;", [.uuid(hit.id)]).first?.uuid(0))
        let lostCount = Int(try await rig.db.query("SELECT COUNT(*) FROM chunks WHERE object_id = ?;", [.uuid(lostKO)]).first?.int(0) ?? 0)
        let total = try await SourceReadinessRepository(database: rig.db).ftsCoverage(sourceVersionID: sv).indexed
        // Swap: drop the lost object's chunks, add the same number of copies to the other object.
        try await rig.db.exec("DELETE FROM chunks WHERE object_id = ?;", [.uuid(lostKO)])
        for n in 0..<lostCount {
            try await rig.db.exec("""
                INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id)
                SELECT ?, object_id, ordinal + \(1000 + n), text, char_start, char_end, created_at, source_version_id
                  FROM chunks WHERE source_version_id = ? AND object_id != ? LIMIT 1;
                """, [.uuid(UUID()), .uuid(sv), .uuid(lostKO)])
        }
        #expect(try await SourceReadinessRepository(database: rig.db).ftsCoverage(sourceVersionID: sv).indexed == total,
                "the swap keeps the total count — a count check cannot see it")
        #expect(try await chunks.searchFTS("quillbright", limit: 5).isEmpty)
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground)
        #expect(!(try await chunks.searchFTS("quillbright", limit: 5)).isEmpty, "the swapped-out object was not re-indexed")
    }

    @Test("F15 — blocks lost behind a 'ready' structure record are detected and restored")
    func lostStructureRestored() async throws {
        let rig = try await makeRig()
        let body = (1...6).map { "Paragraph \($0) records the harbour survey of section \($0) in detail." }.joined(separator: "\n\n")
        let url = try writeTxt(rig, "survey.txt", body)
        let sv = try #require(try await rig.c.ingest(fileAt: url).sourceVersionID)
        let readiness = SourceReadinessRepository(database: rig.db)
        let store = EvidenceStore(database: rig.db)
        let before = try await store.liveStructuralCounts(forVersion: sv)
        try #require(before.substantive >= 2)
        #expect(try await readiness.measuredEvidenceRevision(sourceVersionID: sv, dimension: .structuralExtraction)
                == (try await readiness.evidenceRevision(sourceVersionID: sv)), "ingest records the revision it measured")
        // Lose the last block (and its ownership row) behind the ready record.
        let lost = try #require(try await rig.db.query(
            "SELECT id FROM evidence_blocks WHERE source_version_id = ? ORDER BY ordinal DESC LIMIT 1;", [.uuid(sv)]).first?.uuid(0))
        let revBefore = try await readiness.evidenceRevision(sourceVersionID: sv)
        try await rig.db.exec("DELETE FROM evidence_block_objects WHERE evidence_block_id = ?;", [.uuid(lost)])
        try await rig.db.exec("DELETE FROM evidence_blocks WHERE id = ?;", [.uuid(lost)])
        #expect(try await readiness.evidenceRevision(sourceVersionID: sv) != revBefore, "a block change moves the fingerprint")
        #expect(try await readiness.snapshot(sourceVersionID: sv).dimension(.structuralExtraction)?.state == .ready,
                "the stored record still claims ready")

        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
        let after = try await store.liveStructuralCounts(forVersion: sv)
        #expect(after.substantive == before.substantive, "the lost block was restored")
        #expect(after.located == before.located)
        #expect(try await readiness.snapshot(sourceVersionID: sv).dimension(.structuralExtraction)?.state == .ready)
        let unowned = try await rig.db.query("""
            SELECT COUNT(*) FROM evidence_blocks b WHERE b.source_version_id = ?
               AND NOT EXISTS (SELECT 1 FROM evidence_block_objects o WHERE o.evidence_block_id = b.id);
            """, [.uuid(sv)]).first?.int(0)
        #expect(unowned == 0, "the restored block is linked to the version's single owner")
    }

    @Test("F15 — an unchanged revision skips re-measurement; nothing is invalidated")
    func unchangedRevisionIsTrusted() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "steady.txt", "A steady document whose evidence never changes after ingest.")
        let sv = try #require(try await rig.c.ingest(fileAt: url).sourceVersionID)
        let readiness = SourceReadinessRepository(database: rig.db)
        let rev = try await readiness.snapshot(sourceVersionID: sv).aggregateRevision
        #expect(try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .searchReady, execution: .foreground).isEmpty)
        #expect(try await readiness.snapshot(sourceVersionID: sv).aggregateRevision == rev, "no readiness write when nothing moved")
    }

    @Test("A duplicate upgrade request reuses the active job")
    func duplicateRequestReusesJob() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "d.txt", "Dup body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .background)
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .background)
        let n = try await rig.db.query("SELECT COUNT(*) FROM enrichment_jobs WHERE source_version_id = ? AND kind = 'structuralExtraction';", [.uuid(sv)]).first?.int(0)
        #expect(n == 1)
    }

    @Test("A rerun of the evidence upgrade is idempotent — readiness stays evidence-ready")
    func upgradeRerunIdempotent() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "i.txt", "Idempotent body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        try await rig.c.upgradeStructure(sourceVersionID: sv)
        try await rig.c.upgradeStructure(sourceVersionID: sv)   // rerun
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == true)
    }

    // MARK: - Exact-byte safety

    @Test("A changed referenced file cannot upgrade the old version — the job is blocked")
    func changedReferencedBlocksUpgrade() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "c.txt", "Original v1 body — synthetic, several words.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        try "Mutated v2 body — different content entirely.".write(to: url, atomically: true, encoding: .utf8)
        await #expect(throws: SourceUpgradeError.self) {
            _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
        }
        // The old version stayed searchable-only (never mutated with unverified bytes).
        #expect(try await rig.c.completion(sourceVersionID: sv)?.isEvidenceReady == false)
        let job = try await rig.jobs.activeJob(sourceVersionID: sv, kind: .structuralExtraction)
        #expect(job == nil)   // no longer active (blocked)
    }

    // MARK: - Postcondition + attempt-status

    @Test("A handler that advances no readiness fails its postcondition (never silently done)")
    func postconditionFailsWithoutReadinessChange() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "p.txt", "Postcondition body — synthetic.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        // A coordinator whose handler does nothing durable.
        let noop = SourceUpgradeExecutor(handlers: [.structuralExtraction: { _ in }])
        let coord = SourceUpgradeCoordinator(database: rig.db, jobs: rig.jobs, readiness: SourceReadinessRepository(database: rig.db),
                                             container: ContainerInspectionRepository(database: rig.db), executor: noop)
        await #expect(throws: SourceUpgradeError.self) {
            _ = try await coord.ensure(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground, at: Date())
        }
        // The job for structuralExtraction ended failed (not done).
        let state = try await rig.db.query("SELECT state FROM enrichment_jobs WHERE source_version_id = ? AND kind = 'structuralExtraction' ORDER BY updated_at DESC LIMIT 1;", [.uuid(sv)]).first?.string(0)
        #expect(state == "failed")
    }

    @Test("The ingest attempt records passCompleted, while completion reflects readiness")
    func attemptPassCompletedNotCompletion() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "a.txt", "Attempt body — synthetic, several words.")
        let result = try await rig.c.ingest(fileAt: url, intent: .initialFast)
        let status = try await rig.db.query("SELECT status FROM ingest_file_attempts WHERE url = ? ORDER BY attempted_at DESC LIMIT 1;", [.text(url.absoluteString)]).first?.string(0)
        #expect(status == "passCompleted")
        #expect(result.completionSnapshot?.completionState == .searchablePartial)
    }

    @Test("Superseding a source version's upgrade jobs marks them superseded")
    func supersedeUpgradeJobs() async throws {
        let rig = try await makeRig()
        let url = try writeTxt(rig, "s.txt", "Supersede body — synthetic.")
        let sv = try #require(try await rig.c.ingest(fileAt: url, intent: .initialFast).sourceVersionID)
        _ = try await rig.c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .background)
        let n = try await rig.jobs.supersedeActive(sourceVersionID: sv, at: Date())
        #expect(n >= 1)
        #expect(try await rig.jobs.activeJob(sourceVersionID: sv, kind: .structuralExtraction) == nil)
    }
}
