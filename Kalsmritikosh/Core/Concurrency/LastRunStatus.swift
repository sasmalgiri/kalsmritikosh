//
//  LastRunStatus.swift
//  Kalsmritikosh
//
//  Phase J.13 — per-service runtime status surfaced to the Live tab.
//  Each background service can expose a `LastRunStatus` describing
//  when it last fired, how many rows it produced, and how long that
//  run took. The Live tab renders these alongside the per-service
//  health pill so the operator sees the actual state ("CausalDiscoverer
//  last ran 4m ago, emitted 12 links in 3.1s") instead of just a
//  green dot.
//

import Foundation

public struct LastRunStatus: Sendable, Hashable {
    public let serviceID: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let resultCount: Int
    public let runCount: Int
    public let lastError: String?

    public nonisolated init(
        serviceID: String,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        resultCount: Int = 0,
        runCount: Int = 0,
        lastError: String? = nil
    ) {
        self.serviceID = serviceID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resultCount = resultCount
        self.runCount = runCount
        self.lastError = lastError
    }

    public var durationSeconds: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    public var idle: Bool {
        guard let startedAt, let finishedAt else { return true }
        return finishedAt >= startedAt
    }
}
