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
