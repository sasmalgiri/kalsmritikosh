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
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
