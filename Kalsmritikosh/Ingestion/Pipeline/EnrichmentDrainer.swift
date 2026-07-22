//
//  EnrichmentDrainer.swift
//  Kalsmritikosh
//
//  PERF.2 — the consumer side of the deferred deep-enrichment ledger. The
//  EnrichmentJobRepository is the durable queue (enqueue / claim / done / fail,
//  crash-safe requeue); this is the background loop that drains it: claim the
//  oldest pending job of a kind, run its registered handler, mark it done or
//  failed, repeat.
//
//  SAFE BY CONSTRUCTION — no duplication risk:
//    • A kind is drained ONLY if a handler is registered for it. With no handlers
//      registered the drainer is a strict no-op, so wiring it into boot before the
//      per-kind engines exist changes nothing in production.
//    • It never claims a job it cannot process (so an unhandled job is never
//      wrongly marked failed).
//    • Interactive work pre-empts: it awaits the QueryPriorityGate before each
//      claim, so a user's question is never starved by background enrichment
//      (ING-006).
//
//  The per-kind handlers (embedding / typedFacts / entityReconciliation /
//  contradictionScan / ocr / deepStudy) and the ingest-time PRODUCER that enqueues
//  jobs are wired separately once each engine is runtime-verified against a real
//  corpus — this type is the reusable, deterministic mechanism they plug into.
//

import Foundation

public actor EnrichmentDrainer {
    /// Process one job, identified by its subject id. Throwing marks the job
    /// `failed` (with the error recorded); returning normally marks it `done`.
    public typealias Handler = @Sendable (UUID) async throws -> Void

    private let jobs: EnrichmentJobRepository
    private let priorityGate: QueryPriorityGate?
    private var handlers: [EnrichmentJobKind: Handler] = [:]

    public init(jobs: EnrichmentJobRepository, priorityGate: QueryPriorityGate? = nil) {
        self.jobs = jobs
        self.priorityGate = priorityGate
    }

    /// Register the processor for a kind. Kinds without a handler are never drained.
    public func register(_ kind: EnrichmentJobKind, handler: @escaping Handler) {
        handlers[kind] = handler
    }

    public func handledKinds() -> Set<EnrichmentJobKind> { Set(handlers.keys) }

    public struct Outcome: Sendable, Equatable {
        public var done: Int = 0
        public var failed: Int = 0
        public var claimed: Int { done + failed }
    }

    /// Drain pending jobs of `kind` until the queue is empty or `maxJobs` is
    /// reached. No-op (returns zero) when the kind has no registered handler.
    @discardableResult
    public func drain(kind: EnrichmentJobKind, maxJobs: Int = .max) async -> Outcome {
        guard let handler = handlers[kind], maxJobs > 0 else { return Outcome() }
        var outcome = Outcome()
        while outcome.claimed < maxJobs {
            // Interactive work pre-empts background enrichment (ING-006).
            await priorityGate?.awaitClearance()
            guard let job = try? await jobs.claimNext(kind: kind) else { break }
            do {
                try await handler(job.subjectID)
                try? await jobs.markDone(job.id)
                outcome.done += 1
            } catch {
                try? await jobs.markFailed(job.id, error: String(describing: error))
                outcome.failed += 1
            }
        }
        return outcome
    }

    /// Drain every registered kind once. Kinds are processed in a stable order
    /// (by raw value) so the pass is deterministic.
    @discardableResult
    public func drainAll(maxPerKind: Int = .max) async -> Outcome {
        var total = Outcome()
        for kind in handlers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let r = await drain(kind: kind, maxJobs: maxPerKind)
            total.done += r.done
            total.failed += r.failed
        }
        return total
    }
}
