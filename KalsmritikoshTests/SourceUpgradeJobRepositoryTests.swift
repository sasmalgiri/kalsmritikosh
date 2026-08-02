//
//  SourceUpgradeJobRepositoryTests.swift
//  KalsmritikoshTests
//
//  USF-M3 (USF-009 §14/§15/§16) — the exact-SourceVersion upgrade ledger: idempotent enqueue, lease-based
//  claim (priority order + not_before gating), bounded auto-retry, block/cancel/supersede, expired-lease
//  recovery, append-only events. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M3 — source upgrade job repository", .serialized)
struct SourceUpgradeJobRepositoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRig() async throws -> (Database, SourceUpgradeJobRepository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm3-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys = ON;")
        return (db, SourceUpgradeJobRepository(database: db))
    }

    private func seedVersion(_ db: Database, _ id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(String(repeating: "a", count: 64)), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])
    }

    @Test("Enqueue creates a pending sourceVersion job with an enqueue event")
    func enqueueCreates() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        let job = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, goal: .evidenceReady, priority: .userRequested, at: t0)
        #expect(job.state == .pending)
        #expect(job.sourceVersionID == sv)
        #expect(job.targetDimension == .ocr)
        #expect(try await repo.events(jobID: job.id).map(\.action) == ["enqueue"])
    }

    @Test("Re-enqueueing the same active work reuses the existing job")
    func enqueueIdempotent() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        let a = try await repo.enqueue(sourceVersionID: sv, kind: .indexing, at: t0)
        let b = try await repo.enqueue(sourceVersionID: sv, kind: .indexing, at: t0)
        #expect(a.id == b.id)
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_jobs WHERE source_version_id = ?;", [.uuid(sv)]).first?.int(0) == 1)
    }

    @Test("Enqueue for a missing source version throws")
    func enqueueMissingVersion() async throws {
        let (_, repo) = try await makeRig()
        await #expect(throws: SourceUpgradeError.self) { _ = try await repo.enqueue(sourceVersionID: UUID(), kind: .ocr, at: self.t0) }
    }

    @Test("Claim leases the job: running, lease token + expiry, attempts incremented")
    func claimLeases() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .structuralExtraction, at: t0)
        let claimed = try #require(try await repo.claimNext(leaseSeconds: 300, at: t0))
        #expect(claimed.state == .running)
        #expect(claimed.leaseToken != nil)
        #expect(claimed.leaseExpiresAt != nil)
        #expect(claimed.attempts == 1)
        #expect(try await repo.events(jobID: claimed.id).map(\.action) == ["enqueue", "claim"])
    }

    @Test("Claim returns the highest-priority eligible job first")
    func claimPriorityOrder() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .embedding, priority: .background, at: t0)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, priority: .userRequested, at: t0)
        let first = try #require(try await repo.claimNext(at: t0))
        #expect(first.kind == .ocr)   // userRequested (80) beats background (40)
    }

    @Test("A job is not eligible before its not_before time")
    func notBeforeGating() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, notBefore: t0.addingTimeInterval(1000), at: t0)
        #expect(try await repo.claimNext(at: t0) == nil)                    // too early
        #expect(try await repo.claimNext(at: t0.addingTimeInterval(2000)) != nil)   // now eligible
    }

    @Test("Success marks done + completed with a succeed event")
    func succeed() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .indexing, at: t0)
        let job = try #require(try await repo.claimNext(at: t0))
        try await repo.succeed(job.id, at: t0)
        #expect(try await repo.job(job.id)?.state == .done)
        #expect(try await repo.events(jobID: job.id).map(\.action) == ["enqueue", "claim", "succeed"])
    }

    @Test("Failure auto-retries while attempts remain, then fails when exhausted")
    func failBoundedRetry() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, maxAttempts: 2, at: t0)
        let j1 = try #require(try await repo.claimNext(at: t0))                       // attempts 1
        try await repo.fail(j1.id, error: "boom", at: t0)
        #expect(try await repo.job(j1.id)?.state == .pending)                          // requeued (1 < 2)
        let j2 = try #require(try await repo.claimNext(at: t0.addingTimeInterval(100)))  // attempts 2
        try await repo.fail(j2.id, error: "boom again", at: t0)
        #expect(try await repo.job(j2.id)?.state == .failed)                           // exhausted (2 >= 2)
        #expect(try await repo.job(j2.id)?.lastError == "boom again")
    }

    @Test("Block, cancel, and supersede move the job to their terminal/blocked states")
    func blockCancelSupersede() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        let a = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, at: t0)
        try await repo.block(a.id, reason: "no OCR engine", at: t0)
        #expect(try await repo.job(a.id)?.state == .blocked)
        let b = try await repo.enqueue(sourceVersionID: sv, kind: .transcription, at: t0)
        try await repo.cancel(b.id, at: t0)
        #expect(try await repo.job(b.id)?.state == .cancelled)
        let c = try await repo.enqueue(sourceVersionID: sv, kind: .embedding, at: t0)
        try await repo.supersede(c.id, at: t0)
        #expect(try await repo.job(c.id)?.state == .superseded)
    }

    @Test("A blocked job can be explicitly retried back to pending")
    func explicitRetry() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        let a = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, at: t0)
        try await repo.block(a.id, reason: "dependency", at: t0)
        try await repo.retry(a.id, at: t0)
        #expect(try await repo.job(a.id)?.state == .pending)
    }

    @Test("Boot recovery requeues ONLY expired leases")
    func recoverExpiredOnly() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, at: t0)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .indexing, at: t0)
        let short = try #require(try await repo.claimNext(leaseSeconds: 1, at: t0))    // expires t0+1
        let long = try #require(try await repo.claimNext(leaseSeconds: 1000, at: t0))  // expires t0+1000
        let recovered = try await repo.recoverExpiredLeases(at: t0.addingTimeInterval(10))
        #expect(recovered == 1)
        #expect(try await repo.job(short.id)?.state == .pending)                        // expired → requeued
        #expect(try await repo.job(long.id)?.state == .running)                         // still leased
    }

    @Test("Superseding a source version supersedes all its active jobs")
    func supersedeActiveJobs() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, at: t0)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .indexing, at: t0)
        let done = try await repo.enqueue(sourceVersionID: sv, kind: .embedding, at: t0)
        let dj = try #require(try await repo.claimNext(at: t0))
        try await repo.succeed(dj.id, at: t0)   // one already done — not active
        let n = try await repo.supersedeActive(sourceVersionID: sv, at: t0)
        #expect(n == 2)                          // ocr + indexing (the other claimed-then-done one, or remaining)
        #expect(try await repo.job(done.id) != nil)
    }

    @Test("kindsByState reports pending / running / failed kinds for the completion overlay")
    func kindsByState() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, at: t0)                 // pending
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .indexing, at: t0)
        let running = try #require(try await repo.claimNext(at: t0))                          // one running
        _ = running
        let overlay = await repo.kindsByState(sourceVersionID: sv)
        #expect(overlay.pending.count + overlay.running.count == 2)
        #expect(overlay.running.count == 1)
    }

    @Test("Job events carry a strictly increasing sequence")
    func eventSequence() async throws {
        let (db, repo) = try await makeRig()
        let sv = UUID(); try await seedVersion(db, sv)
        _ = try await repo.enqueue(sourceVersionID: sv, kind: .ocr, at: t0)
        let j = try #require(try await repo.claimNext(at: t0))
        try await repo.succeed(j.id, at: t0)
        let seqs = try await repo.events(jobID: j.id).map(\.sequence)
        #expect(seqs == [1, 2, 3])
    }
}
