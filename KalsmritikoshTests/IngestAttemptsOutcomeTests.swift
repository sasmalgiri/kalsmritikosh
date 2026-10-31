//
//  IngestAttemptsOutcomeTests.swift
//  KalsmritikoshTests
//
//  UI journey run d (2026-10-30, D-1): a later ingest pass that finds a file unchanged records a
//  skip; the file's last real processing outcome stands. A file that failed once and was then
//  skipped as unchanged still counts as failed (and is still listed under "Needs attention"), so the
//  live indicator reaches its terminal state. On a throwaway migrated ledger.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Ingest attempts — the latest processing outcome, not the latest skip")
struct IngestAttemptsOutcomeTests {

    @Test("failed → unchanged stays failed; passCompleted → unchanged stays clean; a started marker never hides a failure")
    func skipsDoNotChangeTheOutcome() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let attempts = IngestAttemptsRepository(database: db)
        let bad = URL(fileURLWithPath: "/case/scan-receipt-unreadable.pdf")
        let good = URL(fileURLWithPath: "/case/bank-statement.md")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await attempts.record(url: bad, status: .started, stage: "ingest", at: t0)
        await attempts.record(url: bad, status: .failed, stage: "parser", detail: "empty", at: t0.addingTimeInterval(1))
        await attempts.record(url: good, status: .started, stage: "ingest", at: t0)
        await attempts.record(url: good, status: .passCompleted, stage: nil, at: t0.addingTimeInterval(1))
        #expect(await attempts.failedCount() == 1)
        #expect(await attempts.recentFailures().map(\.url) == [bad.absoluteString])
        // The second pass: both files unchanged by hash — skips, not outcomes.
        await attempts.record(url: bad, status: .started, stage: "ingest", at: t0.addingTimeInterval(60))
        await attempts.record(url: bad, status: .unchanged, stage: nil, at: t0.addingTimeInterval(61))
        await attempts.record(url: good, status: .started, stage: "ingest", at: t0.addingTimeInterval(60))
        await attempts.record(url: good, status: .unchanged, stage: nil, at: t0.addingTimeInterval(61))
        #expect(await attempts.failedCount() == 1, "the unreadable file is still a failure after being skipped as unchanged")
        #expect(await attempts.recentFailures().map(\.url) == [bad.absoluteString])
        #expect(await attempts.failedURLs(matchingExtensions: ["pdf"]) == [bad])
        // A readable copy that later succeeds clears it.
        await attempts.record(url: bad, status: .passCompleted, stage: nil, at: t0.addingTimeInterval(120))
        #expect(await attempts.failedCount() == 0)
        // An interrupted pass (only a 'started' marker) is not counted as a failure either way.
        await attempts.record(url: good, status: .started, stage: "ingest", at: t0.addingTimeInterval(180))
        #expect(await attempts.failedCount() == 0)
        #expect(await attempts.interruptedURLs() == [good])
    }
}
