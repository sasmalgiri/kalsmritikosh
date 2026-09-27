//
//  Deadline.swift
//  Kalsmritikosh
//
//  P2.7 (2026-09-27) — an OPTIONAL step must never block an answer. Races an
//  operation against a deadline; returns nil when the deadline wins (the
//  operation is cancelled cooperatively). Use only for steps the caller can
//  honestly do without (query expansion, polish) — never for evidence.
//

import Foundation

public nonisolated func withDeadline<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async -> T?
) async -> T? {
    // NOT a task group: a group waits for every child before it returns, so an
    // operation that ignores cancellation (a model call mid-generation) held
    // the caller for its full duration and the "deadline" bounded nothing.
    // The work runs unstructured; whichever of it and the timer finishes first
    // resumes the caller exactly once, and the loser is cancelled.
    let gate = DeadlineGate<T>()
    let work = Task { await operation() }
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        Task {
            await gate.arm(continuation)
            Task {
                let value = await work.value
                await gate.resume(with: value)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                work.cancel()
                await gate.resume(with: nil)
            }
        }
    }
}

/// Resumes the waiting caller once; later results are dropped. `arm` always
/// runs before either racer starts (they are launched after it).
private actor DeadlineGate<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?

    func arm(_ c: CheckedContinuation<T?, Never>) { continuation = c }

    func resume(with value: T?) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: value)
    }
}
