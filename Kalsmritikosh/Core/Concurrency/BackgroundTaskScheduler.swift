//
//  BackgroundTaskScheduler.swift
//  Kalsmritikosh
//
//  Wakes registered BackgroundServices on a periodic interval. Used
//  by the nightly compression scheduler and the ingestion retry queue.
//

import Foundation

public actor BackgroundTaskScheduler {
    public struct Job: Sendable {
        public let id: String
        public let interval: TimeInterval
        public let body: @Sendable () async -> Void
        public init(id: String, interval: TimeInterval, body: @Sendable @escaping () async -> Void) {
            self.id = id
            self.interval = interval
            self.body = body
        }
    }

    private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public func schedule(_ job: Job) {
        cancel(job.id)
        let task = Task { [job] in
            while !Task.isCancelled {
                await job.body()
                try? await Task.sleep(nanoseconds: UInt64(job.interval * 1_000_000_000))
            }
        }
        tasks[job.id] = task
    }

    public func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
    }

    public func cancelAll() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }
}
