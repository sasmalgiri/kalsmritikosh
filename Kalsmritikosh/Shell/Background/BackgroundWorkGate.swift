//
//  BackgroundWorkGate.swift
//  Kalsmritikosh
//
//  SHELL-003 (product shell) — the ONE live gate every background worker consults, plus the cooperative
//  loop that fixes the idle-preemption defect (workers that checked idle only at startup and then kept
//  running when the user returned). The gate composes the EXISTING signals — SystemActivity idle time
//  and the QueryPriorityGate interactive flag — with the user preference and the set of active work
//  priorities, and answers the single BackgroundWorkPolicy decision. It forks no second scheduler.
//
//  The cooperative loop is the required execution shape: gate permits → run one bounded batch →
//  checkpoint → re-check the gate before the next batch → continue or pause. Because the gate is checked
//  BEFORE every batch, resumed user activity stops further work within one batch; abandoned work is
//  never silently resumed (the caller restarts it when the gate permits again). AtomicProjectionRefresh
//  guarantees a replaceable projection keeps its last valid result if the refresh is interrupted.
//

import Foundation

/// The gate abstraction workers depend on (so tests can inject a controllable gate).
public protocol BackgroundWorkGating: Sendable {
    func permits(_ priority: BackgroundWorkPriority) async -> Bool
}

/// The live gate: one authority composing the preference + SystemActivity idle + QueryPriorityGate.
public actor BackgroundWorkGate: BackgroundWorkGating {
    private var preference: BackgroundWorkPreference
    private let queryGate: QueryPriorityGate
    private let idleProvider: @Sendable () -> TimeInterval
    private let clock: @Sendable () -> Date
    private var activeCounts: [BackgroundWorkPriority: Int] = [:]

    public init(queryGate: QueryPriorityGate,
                preference: BackgroundWorkPreference = .default,
                idleProvider: @escaping @Sendable () -> TimeInterval = { SystemActivity.idleSeconds() },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.queryGate = queryGate
        self.preference = preference
        self.idleProvider = idleProvider
        self.clock = clock
    }

    public func setPreference(_ preference: BackgroundWorkPreference) { self.preference = preference }
    public func currentPreference() -> BackgroundWorkPreference { preference }

    /// Register / deregister an active work item so lower-priority work yields to it.
    public func beginWork(_ priority: BackgroundWorkPriority) { activeCounts[priority, default: 0] += 1 }
    public func endWork(_ priority: BackgroundWorkPriority) {
        guard let c = activeCounts[priority] else { return }
        if c <= 1 { activeCounts[priority] = nil } else { activeCounts[priority] = c - 1 }
    }

    /// The single permission decision, sampling the live signals and delegating to the pure policy.
    public func permits(_ priority: BackgroundWorkPriority) async -> Bool {
        let inputs = BackgroundWorkInputs(
            preference: preference,
            now: clock(),
            idleSeconds: idleProvider(),
            isInteractiveActive: await queryGate.isInteractiveActive,
            activeWorkPriorities: Set(activeCounts.filter { $0.value > 0 }.keys))
        return BackgroundWorkPolicy.permits(priority, inputs: inputs)
    }
}

public nonisolated enum BackgroundBatchOutcome: Sendable, Equatable {
    case moreWork
    case done
}

public nonisolated enum BackgroundLoopResult: Sendable, Equatable {
    case completed         // the batch signalled done
    case pausedByGate      // the gate denied further work
    case reachedBatchLimit // hit maxBatches without finishing (caller resumes later)
}

/// The cooperative bounded-batch loop. Re-checks the gate BEFORE every batch, so resumed user activity
/// pauses further work within one batch. It never resumes abandoned work by itself.
public nonisolated enum CooperativeBackgroundLoop {
    public nonisolated static func run(priority: BackgroundWorkPriority,
                                       gate: some BackgroundWorkGating,
                                       maxBatches: Int = Int.max,
                                       batch: @Sendable () async throws -> BackgroundBatchOutcome) async rethrows -> BackgroundLoopResult {
        var ran = 0
        while ran < maxBatches {
            guard await gate.permits(priority) else { return .pausedByGate }
            let outcome = try await batch()
            ran += 1
            if outcome == .done { return .completed }
            // Batch boundary = a safe checkpoint. The loop head re-checks the gate before continuing.
        }
        return .reachedBatchLimit
    }
}

/// Atomic replacement for a replaceable projection: the previous durable result survives unless the new
/// candidate is built successfully AND the gate still permits at replacement time. An interruption or a
/// build failure leaves the last valid result intact.
public nonisolated enum AtomicProjectionRefresh {
    public nonisolated static func refresh<T: Sendable>(current: T,
                                                        priority: BackgroundWorkPriority,
                                                        gate: some BackgroundWorkGating,
                                                        build: @Sendable () async throws -> T) async -> T {
        guard await gate.permits(priority) else { return current }
        do {
            let candidate = try await build()
            guard await gate.permits(priority) else { return current }   // re-check before atomic swap
            return candidate
        } catch {
            return current
        }
    }
}
