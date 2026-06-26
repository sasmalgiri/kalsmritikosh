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
    public let id = "atlas.incremental.updater"
    private let stream: AsyncStream<SubjectInvalidation>
    private let distiller: MemoryDistiller
    private let debounceMs: UInt64
    private let notifier: MaturationNotifier?
    private var consumerTask: Task<Void, Never>?
    private var pending: [String: (subject: SubjectInvalidation.Subject, trigger: KnowledgeObject.ID)] = [:]
    private var debounceTask: Task<Void, Never>?

    public init(
        stream: AsyncStream<SubjectInvalidation>,
        distiller: MemoryDistiller,
        debounceMilliseconds: UInt64 = 1_500,
        notifier: MaturationNotifier? = nil
    ) {
        self.stream = stream
        self.distiller = distiller
        self.debounceMs = debounceMilliseconds
        self.notifier = notifier
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
        debounceTask?.cancel()
        let waitNs = debounceMs * 1_000_000
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: waitNs)
            await self?.flush()
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
        // First, wait for the debounce task to fire by waiting for
        // it to clear. Then wait for pending to drain.
        while Date().timeIntervalSince(start) < timeoutSec {
            if pending.isEmpty && debounceTask == nil {
                return UInt64(Date().timeIntervalSince(start) * 1000)
            }
            // Yield + sleep 100ms. We can't await the debounceTask
            // directly because it's a fire-and-forget Task; polling
            // is the simplest reliable signal.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        AtlasLog.knowledge.warning("IncrementalUpdater.waitForIdle hit timeout after \(timeoutMilliseconds, privacy: .public)ms; pending=\(self.pending.count, privacy: .public)")
        return timeoutMilliseconds
    }

    private func flush() async {
        let snapshot = pending
        pending.removeAll()
        // Clear the debounce task reference so waitForIdle can see
        // that no flush is scheduled. The task itself has already
        // completed (we're inside its body).
        debounceTask = nil
        for (_, entry) in snapshot {
            do {
                _ = try await distiller.distill(
                    .init(kind: entry.subject.kind, identifier: entry.subject.identifier),
                    triggeredBy: entry.trigger
                )
                AtlasLog.knowledge.info("Distilled memory for \(entry.subject.kind.rawValue, privacy: .public): \(entry.subject.identifier, privacy: .public)")
                // G2-misc — answer-matured notification: tell the
                // user iff they asked about this subject recently.
                // The notifier handles the gate + UNUserNotification
                // permission flow.
                await notifier?.notifyIfRelevant(
                    subjectKind: entry.subject.kind.rawValue,
                    subjectIdentifier: entry.subject.identifier
                )
            } catch {
                AtlasLog.knowledge.error("Memory distillation failed for \(entry.subject.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
