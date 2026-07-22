//
//  IngestFailureLog.swift
//  Kalsmritikosh
//
//  ING-002 (collected-failures half) — a batch ingest must not silently swallow the
//  files it couldn't process. The per-document KO+chunks commit is ALREADY atomic
//  (v54 cascade-rollback), and we deliberately do NOT hold a write transaction across
//  the pipeline's mid-write LLM calls (that would cause SQLITE_BUSY storms). What was
//  missing was surfacing WHICH files failed: `enumerateAndIngest` only logged them.
//
//  This collects per-file failures/timeouts during a batch so the caller can report
//  "N of M ingested; these K didn't" instead of a bare success count. Durable per-file
//  outcomes still live in `ingest_attempts` (IngestAttemptsRepository); this is the
//  in-memory batch view for the current run.
//

import Foundation

/// One file that did not become queryable in a batch ingest, with why.
public struct IngestFailure: Sendable, Hashable, Codable {
    public enum Stage: String, Sendable, Codable {
        case timeout    // exceeded the per-file wall-clock budget
        case failed     // threw during ingest
    }
    public let fileName: String
    public let stage: Stage
    public let reason: String

    public nonisolated init(fileName: String, stage: Stage, reason: String) {
        self.fileName = fileName
        self.stage = stage
        self.reason = reason
    }
}

/// Actor-safe collector shared across the parallel bulk-ingest task group.
public actor IngestFailureLog {
    private var items: [IngestFailure] = []
    public init() {}
    public func record(_ f: IngestFailure) { items.append(f) }
    public func all() -> [IngestFailure] { items }
    public var count: Int { items.count }
}

/// The outcome of a batch ingest: how many became queryable and which files didn't.
public struct IngestBatchSummary: Sendable, Hashable {
    public let succeeded: Int
    public let failures: [IngestFailure]

    public nonisolated init(succeeded: Int, failures: [IngestFailure]) {
        self.succeeded = succeeded
        self.failures = failures
    }

    public var failedCount: Int { failures.count }
    public var total: Int { succeeded + failures.count }
    public var timedOut: [IngestFailure] { failures.filter { $0.stage == .timeout } }

    /// A neutral one-line summary for the UI / logs.
    public var headline: String {
        failures.isEmpty
            ? "Ingested \(succeeded) file(s), all succeeded."
            : "Ingested \(succeeded) of \(total) file(s); \(failedCount) could not be processed."
    }
}
