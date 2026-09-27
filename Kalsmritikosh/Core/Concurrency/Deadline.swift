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
    // The work runs unstructured; the timer runs on a dispatch queue (no
    // cooperative-pool hop); whichever finishes first resumes the caller once.
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let gate = DeadlineGate(continuation)
        let work = Task { gate.resume(with: await operation()) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) {
            work.cancel()
            gate.resume(with: nil)
        }
    }
}

/// Resumes the waiting caller exactly once; the later result is dropped.
private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ c: CheckedContinuation<T?, Never>) { continuation = c }

    func resume(with value: T?) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
