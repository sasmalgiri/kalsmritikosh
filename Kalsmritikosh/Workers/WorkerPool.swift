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
            let batchResults = await withTaskGroup(
                of: Result<TaskResult, Error>.self,
                returning: [Result<TaskResult, Error>].self
            ) { group in
                for task in batch {
                    group.addTask {
                        do { return .success(try await task()) }
                        catch { return .failure(error) }
                    }
                }
                var collected: [Result<TaskResult, Error>] = []
                for await r in group { collected.append(r) }
                return collected
            }
            results.append(contentsOf: batchResults)
            index = batchEnd
        }

        return results
    }
}
