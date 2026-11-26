//
//  WorkerPool.swift
//  Kalsmritikosh
//
//  Bounded-concurrency dispatcher. The Master Brain hands a list of
//  ExpertTasks to the pool, it runs them through a TaskGroup with a
//  worker cap, and returns merged findings.
//

import Foundation

public actor WorkerPool {
    public let maxConcurrentWorkers: Int

    public init(maxConcurrentWorkers: Int = 4) {
        self.maxConcurrentWorkers = max(1, maxConcurrentWorkers)
    }

    public func run<TaskResult: Sendable>(
        _ tasks: [@Sendable () async throws -> TaskResult]
    ) async -> [Result<TaskResult, Error>] {
        guard !tasks.isEmpty else { return [] }
        let cap = max(1, min(tasks.count, maxConcurrentWorkers))
        // Speed PERF-32 (owner 2026-11-23) — not tested yet: a SLIDING WINDOW — a new task starts the moment
        // any running one finishes (fixed batches waited for the slowest of each batch). UNIT E is kept:
        // results are INDEX-SLOTTED, returned in SUBMISSION order whoever finishes first.
        let collected = await withTaskGroup(
            of: (Int, Result<TaskResult, Error>).self,
            returning: [Result<TaskResult, Error>?].self
        ) { group in
            var slots = [Result<TaskResult, Error>?](repeating: nil, count: tasks.count)
            var next = 0
            func submit(_ i: Int) {
                let task = tasks[i]
                group.addTask {
                    do { return (i, .success(try await task())) }
                    catch { return (i, .failure(error)) }
                }
            }
            while next < cap { submit(next); next += 1 }
            for await (i, r) in group {
                slots[i] = r
                if next < tasks.count { submit(next); next += 1 }
            }
            return slots
        }
        return collected.compactMap { $0 }
    }
}
