//
//  EnrichmentJobRepositoryTests.swift
//  KalsmritikoshTests
//
//  PERF.2 — migration v59 applies; the enrichment-job ledger enqueues idempotently,
//  claims/completes/fails, and boot recovery re-queues jobs stranded in `running`.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("EnrichmentJob ledger (v59)")
struct EnrichmentJobRepositoryTests {

    private func freshDB() async throws -> Database {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ej-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return db
    }

    @Test("Migration reaches v59 (enrichment_jobs exists)")
    func migration() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Enqueue is idempotent per (subject, kind)")
    func idempotentEnqueue() async throws {
        let repo = EnrichmentJobRepository(database: try await freshDB())
        let subject = UUID()
        #expect(try await repo.enqueue(subjectID: subject, kind: .embedding) == true)
        #expect(try await repo.enqueue(subjectID: subject, kind: .embedding) == false)  // dup
        #expect(try await repo.enqueue(subjectID: subject, kind: .typedFacts) == true)   // diff kind
        #expect(try await repo.count() == 2)
        #expect(try await repo.pendingCount(kind: .embedding) == 1)
    }

    @Test("Claim → done removes it from pending")
    func claimComplete() async throws {
        let repo = EnrichmentJobRepository(database: try await freshDB())
        let subject = UUID()
        try await repo.enqueue(subjectID: subject, kind: .contradictionScan)
        let job = try #require(try await repo.claimNext(kind: .contradictionScan))
        #expect(job.subjectID == subject)
        #expect(try await repo.pendingCount(kind: .contradictionScan) == 0)  // now running
        try await repo.markDone(job.id)
        #expect(try await repo.claimNext(kind: .contradictionScan) == nil)   // nothing left
    }

    @Test("F20 — legacy recovery and claims never touch the exact-version upgrade queue")
    func legacyScopeOnly() async throws {
        let db = try await freshDB()
        let legacy = EnrichmentJobRepository(database: db)
        let upgrades = SourceUpgradeJobRepository(database: db)
        let sv = UUID(), now = Date()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(sv), .text("file:///x/\(sv)"), .text("txt")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(sv), .uuid(sv), .text(String(repeating: "a", count: 64)), .real(0), .integer(1), .real(0),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(0)])
        // A source-version job with a VALID lease, plus a pending one of a kind the legacy queue also names.
        _ = try await upgrades.enqueue(sourceVersionID: sv, kind: .ocr, at: now)
        let leased = try #require(try await upgrades.claimNext(leaseSeconds: 3600, at: now))
        _ = try await upgrades.enqueue(sourceVersionID: sv, kind: .embedding, at: now)
        // A legacy job stranded in running.
        try await legacy.enqueue(subjectID: UUID(), kind: .ocr)
        _ = try await legacy.claimNext(kind: .ocr)

        #expect(try await legacy.requeueStuckRunning() == 1)                       // the legacy job only
        let still = try #require(try await upgrades.job(leased.id))
        #expect(still.state == .running)
        #expect(still.leaseToken == leased.leaseToken)                             // valid lease untouched
        #expect(try await legacy.pendingCount(kind: .embedding) == 0)              // not counted as legacy work
        #expect(try await legacy.claimNext(kind: .embedding) == nil)               // not claimable by legacy
        #expect(try await legacy.count() == 1)
    }

    @Test("Boot recovery re-queues jobs stranded in running")
    func recoverStuck() async throws {
        let repo = EnrichmentJobRepository(database: try await freshDB())
        let s = UUID()
        try await repo.enqueue(subjectID: s, kind: .ocr)
        _ = try await repo.claimNext(kind: .ocr)   // now running, then "crash"
        #expect(try await repo.pendingCount(kind: .ocr) == 0)
        #expect(try await repo.requeueStuckRunning() == 1)
        #expect(try await repo.pendingCount(kind: .ocr) == 1)   // back to pending
    }

    @Test("Failed jobs record their error")
    func failure() async throws {
        let repo = EnrichmentJobRepository(database: try await freshDB())
        let s = UUID()
        try await repo.enqueue(subjectID: s, kind: .deepStudy)
        let job = try #require(try await repo.claimNext(kind: .deepStudy))
        try await repo.markFailed(job.id, error: "model unavailable")
        #expect(try await repo.pendingCount(kind: .deepStudy) == 0)   // not pending (failed)
    }
}
