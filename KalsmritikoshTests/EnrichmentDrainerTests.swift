//
//  EnrichmentDrainerTests.swift
//  KalsmritikoshTests
//
//  PERF.2 — the drainer loop over the durable enrichment-job ledger. Uses the
//  REAL repository against a fresh in-memory-style DB (no mocks), with a fake
//  handler that records which subjects it processed, so the claim→process→
//  done/fail lifecycle is verified deterministically. Also pins the two
//  safety-by-construction properties: an unhandled kind is never claimed, and a
//  throwing handler marks the job failed (not done).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PERF.2 EnrichmentDrainer")
struct EnrichmentDrainerTests {

    private func freshRepo() async throws -> EnrichmentJobRepository {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ed-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return EnrichmentJobRepository(database: db)
    }

    /// A Sendable recorder for what a handler saw (actor-isolated across the drain).
    private actor Recorder {
        private(set) var seen: [UUID] = []
        func record(_ id: UUID) { seen.append(id) }
    }

    @Test("Drains every pending job of a handled kind, marking each done")
    func drainsHandledKind() async throws {
        let repo = try await freshRepo()
        let s1 = UUID(), s2 = UUID()
        try await repo.enqueue(subjectID: s1, kind: .contradictionScan)
        try await repo.enqueue(subjectID: s2, kind: .contradictionScan)

        let recorder = Recorder()
        let drainer = EnrichmentDrainer(jobs: repo)
        await drainer.register(.contradictionScan) { subject in await recorder.record(subject) }

        let outcome = await drainer.drain(kind: .contradictionScan)
        #expect(outcome.done == 2)
        #expect(outcome.failed == 0)
        #expect(Set(await recorder.seen) == Set([s1, s2]))
        #expect(try await repo.pendingCount(kind: .contradictionScan) == 0)   // queue emptied
    }

    @Test("An unhandled kind is never claimed (no-op, jobs stay pending)")
    func unhandledKindUntouched() async throws {
        let repo = try await freshRepo()
        try await repo.enqueue(subjectID: UUID(), kind: .ocr)   // no handler registered for .ocr
        let drainer = EnrichmentDrainer(jobs: repo)
        await drainer.register(.embedding) { _ in }             // handler for a DIFFERENT kind

        let outcome = await drainer.drain(kind: .ocr)
        #expect(outcome.claimed == 0)
        #expect(try await repo.pendingCount(kind: .ocr) == 1)   // still pending, never touched
    }

    @Test("A throwing handler marks the job failed, not done")
    func failingHandlerMarksFailed() async throws {
        let repo = try await freshRepo()
        try await repo.enqueue(subjectID: UUID(), kind: .typedFacts)
        struct Boom: Error {}
        let drainer = EnrichmentDrainer(jobs: repo)
        await drainer.register(.typedFacts) { _ in throw Boom() }

        let outcome = await drainer.drain(kind: .typedFacts)
        #expect(outcome.done == 0)
        #expect(outcome.failed == 1)
        #expect(try await repo.pendingCount(kind: .typedFacts) == 0)   // not pending (it's failed, not requeued)
    }

    @Test("maxJobs caps the batch; the rest stay pending for the next pass")
    func respectsMaxJobs() async throws {
        let repo = try await freshRepo()
        for _ in 0..<5 { try await repo.enqueue(subjectID: UUID(), kind: .deepStudy) }
        let drainer = EnrichmentDrainer(jobs: repo)
        await drainer.register(.deepStudy) { _ in }

        let first = await drainer.drain(kind: .deepStudy, maxJobs: 2)
        #expect(first.done == 2)
        #expect(try await repo.pendingCount(kind: .deepStudy) == 3)

        let rest = await drainer.drain(kind: .deepStudy)   // no cap → finish
        #expect(rest.done == 3)
        #expect(try await repo.pendingCount(kind: .deepStudy) == 0)
    }

    @Test("drainAll processes only registered kinds")
    func drainAllOnlyRegistered() async throws {
        let repo = try await freshRepo()
        try await repo.enqueue(subjectID: UUID(), kind: .embedding)
        try await repo.enqueue(subjectID: UUID(), kind: .ocr)     // unregistered
        let drainer = EnrichmentDrainer(jobs: repo)
        await drainer.register(.embedding) { _ in }

        let outcome = await drainer.drainAll()
        #expect(outcome.done == 1)                                       // only .embedding
        #expect(try await repo.pendingCount(kind: .ocr) == 1)            // .ocr untouched
    }
}
