//
//  IncrementalUpdater.swift
//  Kalsmritikosh
//
//  Subscribes to IngestCoordinator's SubjectInvalidation stream and
//  drives MemoryDistiller for only the affected subjects. Debounces so a
//  burst of file events collapses into one distillation pass per subject.
//

import Foundation
import OSLog

public actor IncrementalUpdater: BackgroundService {
    public let id = "kalsmritikosh.incremental.updater"
    private let stream: AsyncStream<SubjectInvalidation>
    private let distiller: MemoryDistiller
    private let debounceMs: UInt64
    private let notifier: MaturationNotifier?
    /// Ledger-first LLM-reduction gate. When false, the updater still
    /// DRAINS the invalidation stream (so it never backs up) but SKIPS
    /// the per-subject LLM distillation — memory becomes a hot-data /
    /// on-demand optimization instead of an eager per-ingest cost. The
    /// lower ledger layers (events, entities, timeline, FTS) still
    /// answer, so turning this off doesn't blind the app.
    private let distillationEnabled: Bool
    private var consumerTask: Task<Void, Never>?
    private var pending: [String: (subject: SubjectInvalidation.Subject, trigger: KnowledgeObject.ID)] = [:]
    private var debounceTask: Task<Void, Never>?
    /// Batch-mode counter. When > 0, `scheduleFlush()` is a no-op —
    /// subjects accumulate without firing the debounce. `endBatch()`
    /// decrements; when it reaches 0, a single deterministic flush
    /// fires with the full events table populated.
    ///
    /// This is the fix for the "memory_objects varies per run" race:
    /// without batch mode, the 1.5 s debounce can fire mid-ingest,
    /// calling `MemoryDistiller.distill()` with a partial events
    /// table — subjects whose evidence is in not-yet-ingested files
    /// hit the `recentEvents.isEmpty` guard and never get a row.
    private var batchDepth: Int = 0

    public init(
        stream: AsyncStream<SubjectInvalidation>,
        distiller: MemoryDistiller,
        debounceMilliseconds: UInt64 = 1_500,
        notifier: MaturationNotifier? = nil,
        distillationEnabled: Bool = true
    ) {
        self.stream = stream
        self.distiller = distiller
        self.debounceMs = debounceMilliseconds
        self.notifier = notifier
        self.distillationEnabled = distillationEnabled
    }

    public func start() async {
        guard consumerTask == nil else { return }
        let stream = self.stream
        consumerTask = Task { [weak self] in
            for await event in stream {
                await self?.enqueue(event)
            }
        }
    }

    public func stop() async {
        consumerTask?.cancel()
        consumerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        pending.removeAll()
    }

    private func enqueue(_ event: SubjectInvalidation) {
        for subject in event.subjects {
            let key = "\(subject.kind.rawValue)|\(subject.identifier)"
            pending[key] = (subject, event.triggeringObjectID)
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        // Batch mode — caller has explicitly opted into "accumulate
        // everything, distill once at the end." The debounce timer
        // is suppressed; subjects pile into `pending` and wait for
        // `endBatch()` to drain them.
        if batchDepth > 0 { return }
        debounceTask?.cancel()
        let waitNs = debounceMs * 1_000_000
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            await self?.flush()
        }
    }

    /// Open a batch. Pairs with `endBatch()`; counter-based so nested
    /// callers (smoke test inside an eval round inside an outer
    /// driver) all share one outer drain. While `batchDepth > 0` the
    /// debounce timer is suppressed and subjects accumulate.
    ///
    /// Eval / smoke / bulk-ingest callers wrap their workload:
    ///   await updater.beginBatch()
    ///   for url in files { try await ingest.ingest(fileAt: url) }
    ///   await updater.endBatch()
    ///   await updater.waitForIdle()  // catches late stream events
    ///
    /// Production (live folder watcher) does NOT call these — the
    /// debounce is correct for streaming user-driven activity.
    public func beginBatch() async {
        batchDepth += 1
        // Kill any in-flight debounce so a stale timer from a
        // previous burst doesn't fire mid-batch.
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Close a batch. When the outermost batch closes, one deterministic
    /// `flush()` runs inline with whatever's in `pending` — at this
    /// point the events / mentions tables are fully populated, so
    /// every subject sees the same global state and the
    /// `recentEvents.isEmpty` guard doesn't accidentally null-out
    /// subjects whose evidence was in not-yet-ingested files.
    public func endBatch() async {
        batchDepth = max(0, batchDepth - 1)
        guard batchDepth == 0 else { return }
        if !pending.isEmpty {
            await flush()
        }
    }

    /// Block until no distillation work is pending or running. Used
    /// by eval / smoke runs to wait deterministically for the memory
    /// layer to settle instead of guessing a sleep duration.
    ///
    /// Returns when ALL of these are true:
    ///   - the pending queue is empty
    ///   - no debounce task is in flight
    ///   - the most recent flush has completed
    ///
    /// Polled at 100 ms granularity, capped at `timeoutMilliseconds`
    /// (default 60 s) so a runaway distillation can't hang the test
    /// harness. Returns the elapsed wait duration in milliseconds.
    @discardableResult
    public func waitForIdle(timeoutMilliseconds: UInt64 = 60_000) async -> UInt64 {
        let start = Date()
        let timeoutSec = Double(timeoutMilliseconds) / 1000.0
        // Stability window: idle must persist across N consecutive
        // polls to be considered real. The SubjectInvalidation stream
        // is buffered between IngestCoordinator's continuation.yield
        // and the consumerTask actually processing the event into
        // `pending`. A naive "empty right now" check fires too soon
        // — the events are still in flight. Requiring 5 consecutive
        // empty polls (500 ms of stable idle) covers the buffer
        // drain + debounce-fire window with margin.
        let stabilityRequired = 5
        var stable = 0
        while Date().timeIntervalSince(start) < timeoutSec {
            let isIdle = pending.isEmpty && debounceTask == nil
            if isIdle {
                stable += 1
                if stable >= stabilityRequired {
                    return UInt64(Date().timeIntervalSince(start) * 1000)
                }
            } else {
                stable = 0
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        KalsmritikoshLog.knowledge.warning("IncrementalUpdater.waitForIdle hit timeout after \(timeoutMilliseconds, privacy: .public)ms; pending=\(self.pending.count, privacy: .public)")
        return timeoutMilliseconds
    }

    private func flush() async {
        let snapshot = pending
        pending.removeAll()
        // Clear the debounce task reference so waitForIdle can see
        // that no flush is scheduled. The task itself has already
        // completed (we're inside its body).
        debounceTask = nil

        // Ledger-first: when distillation is disabled we've still
        // drained the stream into `pending` (no backlog) but we skip
        // the LLM cost. Memory is warmed on demand instead.
        guard distillationEnabled else {
            if !snapshot.isEmpty {
                await LLMCallCounters.shared.recordSkip(purpose: "memoryDistill", count: snapshot.count)
            }
            return
        }
        for (_, entry) in snapshot {
            do {
                _ = try await distiller.distill(
                    .init(kind: entry.subject.kind, identifier: entry.subject.identifier),
                    triggeredBy: entry.trigger
                )
                KalsmritikoshLog.knowledge.info("Distilled memory for \(entry.subject.kind.rawValue, privacy: .public): \(entry.subject.identifier, privacy: .public)")
                // G2-misc — answer-matured notification: tell the
                // user iff they asked about this subject recently.
                // The notifier handles the gate + UNUserNotification
                // permission flow.
                await notifier?.notifyIfRelevant(
                    subjectKind: entry.subject.kind.rawValue,
                    subjectIdentifier: entry.subject.identifier
                )
            } catch {
                KalsmritikoshLog.knowledge.error("Memory distillation failed for \(entry.subject.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
