//
//  QueryPriorityGate.swift
//  Kalsmritikosh
//
//  ING-006 — query-priority scheduling: interactive work (answering a question) pre-empts
//  background work (embedding drain, deep enrichment). Background loops call
//  `awaitClearance()` at a safe yield point (between batches); while any interactive query
//  is in flight they suspend, so the user's question always gets CPU/DB priority. When the
//  last interactive query finishes, suspended background work resumes.
//
//  This complements `LaneScheduler` (which isolates hardware lanes): the gate adds the
//  cross-cutting "the human is waiting — pause the background" rule, deterministically.
//

import Foundation

public actor QueryPriorityGate {
    private var interactiveCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// True while at least one interactive query holds priority.
    public var isInteractiveActive: Bool { interactiveCount > 0 }

    /// Mark that an interactive query has started (background yields to it).
    public func beginInteractive() { interactiveCount += 1 }

    /// Mark an interactive query finished; when the last one ends, release any
    /// background work that parked in `awaitClearance()`.
    public func endInteractive() {
        interactiveCount = max(0, interactiveCount - 1)
        guard interactiveCount == 0 else { return }
        let resume = waiters
        waiters = []
        for w in resume { w.resume() }
    }

    /// Bracket an interactive operation so background pauses for its duration.
    public func interactive<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        beginInteractive()
        defer { let box = self; Task { await box.endInteractive() } }
        return try await body()
    }

    /// A background yield point: returns immediately when no interactive query is active,
    /// otherwise suspends until the last one finishes. Call between background batches.
    public func awaitClearance() async {
        guard interactiveCount > 0 else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }
}
