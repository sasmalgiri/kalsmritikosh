//
//  StreamContinuationSchedulerTests.swift
//  KalsmritikoshTests
//
//  F04 follow-up (remaining fixes, 2026-09-29 review of 39e64d6) — a paused SQLite source only
//  continued on an explicit resume call or an evidence-ready upgrade request. Continuation is now
//  scheduled automatically from durable state (stream cursors + the persisted job queue) and run by
//  the upgrade drain, one bounded run at a time, surviving restarts; a failed record or a failed job
//  without progress never turns into a hot retry loop.
//

import Foundation
import SQLite3
import Testing
@testable import Kalsmritikosh

@Suite("F04 — deferred SQLite work continues automatically, bounded, restart-safe and without hot loops", .serialized)
@MainActor
struct StreamContinuationSchedulerTests {

    private struct Env { let db: Database; let dir: URL; let vault: EvidenceVault }

    private static func marker(_ table: String, _ i: Int) -> String { "mk-\(table)-\(i)|" }

    private func env() async throws -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scont-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("ledger.sqlite"))
        try await SchemaMigrations.migrate(db); try await db.exec("PRAGMA foreign_keys = ON;")
        return Env(db: db, dir: dir, vault: EvidenceVault(root: dir.appendingPathComponent("vault", isDirectory: true)))
    }

    /// Three 11-row tables = 33 rows.
    private func source(_ e: Env) throws -> URL {
        let url = e.dir.appendingPathComponent("auto.db")
        var h: OpaquePointer?
        #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
        defer { sqlite3_close(h) }
        var sql = ["CREATE TABLE a(id INTEGER PRIMARY KEY, body TEXT);", "CREATE TABLE b(id INTEGER PRIMARY KEY, body TEXT);",
                   "CREATE TABLE c(k TEXT NOT NULL, n INTEGER NOT NULL, body TEXT, PRIMARY KEY (k, n)) WITHOUT ROWID;", "BEGIN;"]
        for i in 0..<11 {
            sql.append("INSERT INTO a VALUES(\(i - 2), '\(Self.marker("a", i))');")
            sql.append("INSERT INTO b VALUES(\(i + 1), '\(Self.marker("b", i))');")
            sql.append("INSERT INTO c VALUES('k', \(i), '\(Self.marker("c", i))');")
        }
        sql.append("COMMIT;")
        for s in sql { #expect(sqlite3_exec(h, s, nil, nil, nil) == SQLITE_OK, "\(s)") }
        return url
    }

    /// A fresh coordinator over the same ledger — a restart.
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

    private func coverage(_ e: Env, _ sv: UUID) async throws -> StreamCoverage {
        try #require(try await StreamCursorRepository(database: e.db).coverage(sourceVersionID: sv))
    }

    private func objectText(_ e: Env, _ sv: UUID) async throws -> String {
        let file = try #require(try await e.db.query("SELECT logical_source_id FROM source_versions WHERE id = ?;", [.uuid(sv)]).first?.uuid(0))
        return try await e.db.query("SELECT content FROM knowledge_objects WHERE file_id = ?;", [.uuid(file)])
            .compactMap { $0.string(0) }.joined(separator: "\n")
    }

    /// Scheduler + drain, restarting the coordinator between runs, until nothing is scheduled. Returns
    /// the number of continuation runs executed. (Ingest may also have scheduled an evidence upgrade of
    /// the same version, which continues the walk the same way; the drain runs it too.)
    private func driveAutomatically(_ e: Env, _ sv: UUID, maxRounds: Int = 30) async throws -> Int {
        var runs = 0
        for _ in 0..<maxRounds {
            let c = try await coordinator(e)
            let before = try await coverage(e, sv).processed
            let scheduled = await c.scheduleStreamContinuations()
            #expect(await c.scheduleStreamContinuations().isEmpty, "single flight: a scheduled version is not scheduled twice")
            let ran = await c.drainUpgrades(max: 4)
            if scheduled.isEmpty && ran == 0 { break }
            #expect(try await coverage(e, sv).processed > before, "every run makes progress")
            runs += ran
        }
        return runs
    }

    @Test("33 rows at a 3-row budget finish automatically across restarts: exact coverage, no duplicates, ready")
    func finishesUnattended() async throws {
        let e = try await env()
        defer { try? FileManager.default.removeItem(at: e.dir) }
        let sv = try #require(try await coordinator(e).ingest(fileAt: try source(e)).sourceVersionID)
        #expect(try await coverage(e, sv).processed == 3)
        let runs = try await driveAutomatically(e, sv)
        #expect(runs == 10, "the ten remaining bounded runs ran without any resume call")
        let c = try await coverage(e, sv)
        #expect(c.discovered == 33 && c.processed == 33 && c.deferred == 0)
        let text = try await objectText(e, sv)
        for t in ["a", "b", "c"] {
            for i in 0..<11 { #expect(text.components(separatedBy: Self.marker(t, i)).count - 1 == 1, "\(t)\(i) exactly once") }
        }
        let snap = try await SourceReadinessRepository(database: e.db).snapshot(sourceVersionID: sv)
        #expect(snap.dimension(.textExtraction)?.state == .ready)
        #expect(snap.dimension(.structuralExtraction)?.state == .ready)
        #expect(await (try coordinator(e)).scheduleStreamContinuations().isEmpty, "a complete source is never rescheduled")
    }

    @Test("A record that fails to commit stops automatic continuation (no hot loop) until it is retried explicitly")
    func failedRecordIsNotRetriedHot() async throws {
        let e = try await env()
        defer { try? FileManager.default.removeItem(at: e.dir) }
        try await e.db.exec("""
            CREATE TRIGGER test_poison BEFORE INSERT ON chunks WHEN NEW.text LIKE '%\(Self.marker("a", 5))%'
            BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END;
            """)
        let sv = try #require(try await coordinator(e).ingest(fileAt: try source(e)).sourceVersionID)
        _ = try await driveAutomatically(e, sv)
        let stuck = try await coverage(e, sv)
        #expect(stuck.deferred > 0, "the run stopped at the failing record")
        for _ in 0..<3 {
            let c = try await coordinator(e)
            #expect(await c.scheduleStreamContinuations().isEmpty, "a failed record is never rescheduled on its own")
            #expect(await c.drainUpgrades(max: 4) == 0)
        }
        #expect(try await coverage(e, sv) == stuck, "no progress, and no retry storm")
        let detail = try await SourceReadinessRepository(database: e.db).snapshot(sourceVersionID: sv).dimension(.textExtraction)?.detail
        #expect(detail?.contains("injected persistence failure") == true, "the failure stays visible: \(detail ?? "nil")")

        // Fix the cause and retry explicitly once; automatic continuation then finishes the source.
        try await e.db.exec("DROP TRIGGER test_poison;")
        try await coordinator(e).resumeStreamedIngest(sourceVersionID: sv)
        _ = try await driveAutomatically(e, sv)
        #expect(try await coverage(e, sv).deferred == 0)
    }

    @Test("A continuation job that failed is not rescheduled until the cursor advances (no-progress backoff)")
    func failedJobWithoutProgressIsNotRescheduled() async throws {
        let e = try await env()
        defer { try? FileManager.default.removeItem(at: e.dir) }
        let sv = try #require(try await coordinator(e).ingest(fileAt: try source(e)).sourceVersionID)
        let c = try await coordinator(e)
        // Ingest scheduled its own evidence upgrade; while that is pending no continuation is added.
        #expect(await c.scheduleStreamContinuations().isEmpty, "a source with an active structural job gets no second job")
        _ = await c.drainUpgrades(max: 4)
        #expect(await c.scheduleStreamContinuations() == [sv])
        let jobs = SourceUpgradeJobRepository(database: e.db)
        let jobID = try #require(try await e.db.query(
            "SELECT id FROM enrichment_jobs WHERE source_version_id = ? AND producer_id = ? AND state = 'pending';",
            [.uuid(sv), .text(IngestCoordinator.continuationProducer)]).first?.uuid(0))
        let claimed = try #require(try await jobs.claim(jobID: jobID, at: Date()))
        try await jobs.failTerminal(claimed, error: "injected failure", at: Date())
        #expect(await c.scheduleStreamContinuations().isEmpty, "a failed job with no progress since is not retried")
        // Progress (here an explicit resume) re-enables automatic continuation.
        try await c.resumeStreamedIngest(sourceVersionID: sv)
        #expect(await c.scheduleStreamContinuations() == [sv])
    }
}
