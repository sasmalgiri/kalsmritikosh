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
        let cap = min(tasks.count, maxConcurrentWorkers)
        var results: [Result<TaskResult, Error>] = []
        results.reserveCapacity(tasks.count)

        var index = 0
        while index < tasks.count {
            let batchEnd = min(index + cap, tasks.count)
            let batch = Array(tasks[index..<batchEnd])
            // UNIT E (the taxonomy's last site): results were collected in
            // COMPLETION order — whichever task finished first went first,
            // so thread scheduling reordered expert findings per ask and a
            // membership-sensitive merge downstream flipped ±1 boundary
            // source (the Q2/Q7 confidence flicker). Collection is now
            // INDEX-SLOTTED: results return in SUBMISSION order regardless
            // of who finishes first. Execution stays fully concurrent —
            // only the collection became lawful.
            let batchResults = await withTaskGroup(
                of: (Int, Result<TaskResult, Error>).self,
                returning: [Result<TaskResult, Error>].self
            ) { group in
                for (i, task) in batch.enumerated() {
                    group.addTask {
                        do { return (i, .success(try await task())) }
                        catch { return (i, .failure(error)) }
                    }
                }
                var collected = [Result<TaskResult, Error>?](repeating: nil, count: batch.count)
                for await (i, r) in group { collected[i] = r }
                return collected.compactMap { $0 }
            }
            results.append(contentsOf: batchResults)
            index = batchEnd
        }

        return results
    }
}
