//
//  Summarizer.swift
//  Kalsmritikosh
//
//  Hierarchical summarization across 6 levels (document, folder, project,
//  organization, timeline, knowledge-base). Summaries are persisted; the
//  CompressionScheduler refreshes them nightly so queries never re-summarize.
//

import Foundation

public protocol Summarizer: Sendable {
    func summarize(
        scope: Summary.Scope,
        level: Summary.Level,
        length: Summary.Length
    ) async throws -> Summary
}

public protocol CompressionScheduler: Sendable {
    /// Walk every scope that has new evidence since its last summary
    /// and produce fresh summaries. Long-running; cancel safely.
    func runNightlyCompression() async throws
}
