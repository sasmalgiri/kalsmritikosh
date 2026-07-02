//
//  CompressionScheduler.swift
//  Kalsmritikosh
//
//  Idle-driven maintenance. Hierarchical summarization + Memory
//  distillation are expensive, so instead of a fixed nightly slot we
//  run them ONLY while the machine is idle, and pause the instant the
//  user comes back. Each transition (started / completed / paused) is
//  reported so the UI can tell the user what's happening.
//
//  Behaviour:
//    - A watch loop polls `SystemActivity.idleSeconds()` every
//      `pollInterval`.
//    - When idle ≥ `idleThreshold` AND at least `minGapBetweenRuns`
//      has passed since the last pass → start a pass; report `.started`.
//    - While the pass runs, a monitor watches for user activity. If
//      idle drops below `resumeThreshold` the pass is cancelled and
//      `.paused` is reported (it resumes on the next idle window).
//    - When a pass finishes cleanly, `.completed` is reported.
//

import Foundation
import OSLog

/// Lifecycle events emitted by idle maintenance so the UI can inform
/// the user in real time.
public enum MaintenanceEvent: Sendable, Equatable {
    /// A maintenance pass began (machine went idle).
    case started
    /// A pass finished on its own.
    case completed(memoryRows: Int)
    /// A pass was interrupted because the user resumed activity.
    case paused
}

public actor NightlyCompressionScheduler: CompressionScheduler, BackgroundService {
    public let id = "atlas.compression.idle"

    private let summarizer: Summarizer
    private let memoryRepo: MemoryRepository

    /// Live provider for the idle threshold (seconds). Read on every
    /// tick so a Settings change takes effect without a relaunch.
    private let idleThresholdProvider: @Sendable () -> TimeInterval
    /// If idle drops below this while a pass runs, it's interrupted.
    private let resumeThreshold: TimeInterval
    /// Minimum spacing between passes so we don't churn every idle blip.
    private let minGapBetweenRuns: TimeInterval
    /// How often the watch loop samples idle state.
    private let pollInterval: TimeInterval

    /// Policy gate — returns whether a pass may run right now. Handles
    /// Off (false), Ask (prompt + await), Automatic/Notify (true).
    private let gate: @Sendable () async -> Bool
    /// Reports lifecycle transitions to the app (UI banner + log).
    private let report: @Sendable (MaintenanceEvent) -> Void

    private var watchTask: Task<Void, Never>?
    private var currentPass: Task<Void, Never>?
    private var wasInterrupted = false
    private var lastRunAt: Date = .distantPast

    public init(
        summarizer: Summarizer,
        memoryRepo: MemoryRepository,
        idleThreshold: @escaping @Sendable () -> TimeInterval = { 120 },
        resumeThreshold: TimeInterval = 5,      // <5s idle == user is back
        minGapBetweenRuns: TimeInterval = 30 * 60,  // at most every 30 min
        pollInterval: TimeInterval = 10,
        gate: @escaping @Sendable () async -> Bool = { true },
        onEvent: @escaping @Sendable (MaintenanceEvent) -> Void = { _ in }
    ) {
        self.summarizer = summarizer
        self.memoryRepo = memoryRepo
        self.idleThresholdProvider = idleThreshold
        self.resumeThreshold = resumeThreshold
        self.minGapBetweenRuns = minGapBetweenRuns
        self.pollInterval = pollInterval
        self.gate = gate
        self.report = onEvent
    }

    public func start() async {
        guard watchTask == nil else { return }
        AtlasLog.knowledge.info("Idle maintenance watching (idleThreshold=\(self.idleThresholdProvider(), privacy: .public)s)")
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let ns = await UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
        currentPass?.cancel()
        currentPass = nil
    }

    /// One watch tick — decide whether to launch a pass.
    private func tick() async {
        guard currentPass == nil else { return }               // already running
        guard SystemActivity.isIdle(threshold: idleThresholdProvider()) else { return }
        let sinceLast = Date().timeIntervalSince(lastRunAt)
        guard sinceLast >= minGapBetweenRuns else { return }    // cooldown
        // Policy gate: Off → skip; Ask → prompt the user and wait for a
        // Yes. A confirmed Ask runs even though answering it counts as
        // activity — the user explicitly consented.
        guard await gate() else {
            // Set the cooldown clock so we don't re-prompt immediately.
            lastRunAt = Date()
            return
        }
        await runIdlePass()
    }

    /// Run one maintenance pass, interrupting it if the user returns.
    private func runIdlePass() async {
        wasInterrupted = false
        report(.started)
        AtlasLog.knowledge.info("Idle maintenance STARTED (machine idle)")

        let summarizer = self.summarizer
        let memoryRepo = self.memoryRepo
        let pass = Task {
            await Self.runOnce(summarizer: summarizer, memoryRepo: memoryRepo)
        }
        currentPass = pass

        // Monitor for the user coming back while the pass runs. A short
        // grace period first so an Ask-confirmed run (answering the
        // prompt counts as activity) isn't interrupted the instant it
        // starts — it gives the user time to step away.
        let resume = self.resumeThreshold
        let monitor = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)  // 15s grace
            while !Task.isCancelled {
                if !SystemActivity.isIdle(threshold: resume) {
                    await self?.interruptPass()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        await pass.value          // returns when done OR cancelled by interrupt
        monitor.cancel()
        currentPass = nil
        lastRunAt = Date()

        if wasInterrupted {
            report(.paused)
            AtlasLog.knowledge.info("Idle maintenance PAUSED (user active)")
        } else {
            let rows = (try? await memoryRepo.count()) ?? -1
            report(.completed(memoryRows: rows))
            AtlasLog.knowledge.info("Idle maintenance COMPLETED (memory rows: \(rows, privacy: .public))")
        }
    }

    private func interruptPass() {
        guard currentPass != nil else { return }
        wasInterrupted = true
        currentPass?.cancel()
    }

    /// Legacy manual entry point — kept so callers / tests can force a
    /// pass regardless of idle state.
    public func runNightlyCompression() async throws {
        await Self.runOnce(summarizer: summarizer, memoryRepo: memoryRepo)
    }

    private static func runOnce(summarizer: Summarizer, memoryRepo: MemoryRepository) async {
        let now = Date()
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let range = Summary.Scope.Range(start: yearAgo, end: now)
        do {
            try Task.checkCancellation()
            _ = try await summarizer.summarize(
                scope: .knowledgeBase,
                level: .knowledgeBase,
                length: .executive
            )
            try Task.checkCancellation()
            _ = try await summarizer.summarize(
                scope: .timeline(range),
                level: .timeline,
                length: .medium
            )
        } catch is CancellationError {
            // Interrupted by user activity — clean exit, no error log.
            return
        } catch {
            AtlasLog.knowledge.error("Idle maintenance failed: \(String(describing: error), privacy: .public)")
        }
    }
}
