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
            containerInspection: ContainerInspectionRepository(database: db), intakeCoordinator: intake)
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
