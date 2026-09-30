//
//  SourceExecutionLeaseTests.swift
//  KalsmritikoshTests
//
//  F04/F15 (review of 070f2fe) — automatic continuation excluded only its own producer's jobs, so a
//  user's evidence upgrade and a continuation (or an explicit resume) could walk the same source at
//  the same time: both read the same cursor, and one run's record cleanup could roll back the other's
//  attempt. Every path that walks or rewrites a version's evidence now holds one per-source execution
//  lease, and the scheduler skips a source with ANY active structural / indexing job.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F04/F15 — one source is never walked by two runs at once; every record is processed exactly once", .serialized)
@MainActor
struct SourceExecutionLeaseTests {

    private struct Env { let db: Database; let dir: URL; let vault: EvidenceVault }

    private static func marker(_ i: Int) -> String { "mk-\(i)|" }

    private func env() async throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lease-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("ledger.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        return Env(db: db, dir: dir, vault: EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true)))
    }

    private func coordinator(_ e: Env) async throws -> IngestCoordinator {
        let c = IngestCoordinator(
            universalRegistry: try UniversalParserRegistryBuilder.standard(ocr: VisionOCR()),
            entityExtractor: NLEntityExtractor(), entityLinker: EntityLinker(), eventExtractor: RuleEventExtractor(),
            files: FilesRepository(database: e.db), objects: KnowledgeObjectRepository(database: e.db),
            chunks: ChunksRepository(database: e.db), evidenceStore: EvidenceStore(database: e.db),
            ingestAttempts: IngestAttemptsRepository(database: e.db), sourceRelations: SourceRelationsRepository(database: e.db),
            evidenceVault: e.vault, readiness: SourceReadinessRepository(database: e.db),
            containerInspection: ContainerInspectionRepository(database: e.db),
            intakeCoordinator: UniversalSourceIntakeCoordinator(repository: CanonicalSourceIntakeRepository(database: e.db, vault: e.vault)),
            custodyModeOverride: .managed)
        await c.configureUpgrades(database: e.db, jobs: SourceUpgradeJobRepository(database: e.db))
        await c.setMemoryBudget(IngestMemoryBudget(streamAboveBytes: 1 << 30, deferWholeFileAboveBytes: 1 << 31,
                                                   resumable: ResumableStreamBudget(unitsPerRun: 3, unitsPerRecord: 2)))
        return c
    }

    private func source(_ e: Env) throws -> URL {
        let url = e.dir.appendingPathComponent("rows.db")
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        sqlite3_exec(h, "CREATE TABLE t(id INTEGER PRIMARY KEY, body TEXT);", nil, nil, nil)
        for i in 0..<21 { sqlite3_exec(h, "INSERT INTO t VALUES(\(i + 1), '\(Self.marker(i))');", nil, nil, nil) }
        return url
    }

    /// Observes lease requests and holds the FIRST committed record until a second request for the
    /// same source has arrived (or 5 s passed) — so the two runs are guaranteed to be in flight together.
    private actor Barrier {
        var requests = 0
        var held = false
        var concurrentRuns = 0, maxConcurrentRuns = 0
        func note(_ event: IngestCoordinator.SourceWorkEvent) async {
            switch event {
            case .leaseRequested:
                requests += 1
            case .recordCommitted:
                guard !held else { return }
                held = true
                let deadline = Date().addingTimeInterval(5)
                while requests < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
            }
        }
    }

    @Test("Explicit resume, a foreground evidence upgrade and automatic continuation at once: exactly-once records")
    func simultaneousRequestsProcessEachRecordOnce() async throws {
        let e = try await env()
        defer { try? FileManager.default.removeItem(at: e.dir) }
        let c = try await coordinator(e)
        let sv = try #require(try await c.ingest(fileAt: try source(e)).sourceVersionID)
        let barrier = Barrier()
        await c.setSourceWorkHook { event in await barrier.note(event) }

        async let resume: Void = c.resumeStreamedIngest(sourceVersionID: sv)
        async let upgrade = c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .foreground)
        async let automatic: Int = { _ = await c.scheduleStreamContinuations(); return await c.drainUpgrades(max: 4) }()
        _ = try await (resume, upgrade, automatic)
        #expect(await barrier.requests >= 2, "fixture: a second run asked for the source while the first was mid-run")

        // Finish whatever is still deferred, sequentially.
        for _ in 0..<20 {
            guard !(await c.scheduleStreamContinuations()).isEmpty else { break }
            _ = await c.drainUpgrades(max: 4)
        }
        let outcomes = try await c.streamRecordOutcomes(sourceVersionID: sv)
        #expect(outcomes.allSatisfy { $0.state == .committed }, "no record left failed or interrupted")
        #expect(outcomes.allSatisfy { $0.attempts == 1 }, "no record was attempted twice: \(outcomes.map { ($0.position, $0.attempts) })")
        let file = try #require(try await e.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(sv)]).first?.uuid(0))
        let objects = try await e.db.query("SELECT content FROM knowledge_objects WHERE file_id = ?;", [.uuid(file)]).compactMap { $0.string(0) }
        #expect(objects.count == outcomes.count, "one object per committed record — nothing duplicated or orphaned")
        let text = objects.joined(separator: "\n")
        for i in 0..<21 { #expect(text.components(separatedBy: Self.marker(i)).count - 1 == 1, "row \(i) exactly once") }
        let coverage = try #require(try await StreamCursorRepository(database: e.db).coverage(sourceVersionID: sv))
        #expect(coverage.processed == 21 && coverage.deferred == 0)
    }

    @Test("The scheduler does not add a continuation while a user's structural upgrade is active for the source")
    func schedulerRespectsActiveUserUpgrade() async throws {
        let e = try await env()
        defer { try? FileManager.default.removeItem(at: e.dir) }
        let c = try await coordinator(e)
        let sv = try #require(try await c.ingest(fileAt: try source(e)).sourceVersionID)
        // A user-requested (usf-m3) evidence upgrade is pending for the source.
        _ = try await c.ensureUpgrade(sourceVersionID: sv, goal: .evidenceReady, execution: .background)
        let userJobs = try await e.db.query("""
            SELECT COUNT(*) FROM enrichment_jobs WHERE source_version_id = ? AND state = 'pending' AND producer_id != ?;
            """, [.uuid(sv), .text(IngestCoordinator.continuationProducer)]).first?.int(0) ?? 0
        try #require(userJobs >= 1, "fixture: a non-continuation structural job is pending")
        #expect(await c.scheduleStreamContinuations().isEmpty, "no second job for a source that already has one")
    }
}
