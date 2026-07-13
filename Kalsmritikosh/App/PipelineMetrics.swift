//
//  PipelineMetrics.swift
//  Kalsmritikosh
//
//  Phase J.13 — live observability. Per-stage counters the ingest
//  pipeline increments as files move through it. The Live tab reads
//  these to render the workflow strip:
//
//     file detected → loaded → chunked → embedded → entities/events
//
//  Counters are monotonic since boot. The dashboard subtracts the
//  previous sample's value to render throughput (per-stage rate).
//
//  Light-touch instrumentation: each stage calls a single `bump()`
//  on the actor. No coupling to any specific loader or extractor —
//  the call sites just identify which stage they belong to.
//

import Foundation

public actor PipelineMetrics {
    public enum Stage: String, Sendable, CaseIterable, Hashable {
        case discovered    // file showed up on disk / via watcher
        case parse         // structural parse (+ OCR for images) — PERF.0 timing
        case loaded        // bytes -> KnowledgeObject content
        case chunked       // KO chunked
        case embedded      // chunk embedding generated
        case entities      // entities extracted from this KO
        case events        // events extracted from this KO
        case relationships // relationships extracted
        case bonds         // typed bonds inserted

        public var humanLabel: String {
            switch self {
            case .discovered:    return "Discovered"
            case .parse:         return "Parse/OCR"
            case .loaded:        return "Loaded"
            case .chunked:       return "Chunked"
            case .embedded:      return "Embedded"
            case .entities:      return "Entities"
            case .events:        return "Events"
            case .relationships: return "Relationships"
            case .bonds:         return "Bonds"
            }
        }
    }

    private var counters: [Stage: Int] = [:]
    /// PERF.0 — cumulative wall-clock seconds spent in each stage, so we can
    /// measure the real ingest cost order instead of guessing it.
    private var durations: [Stage: Double] = [:]
    private(set) public var bootTime: Date = Date()

    public init() {}

    public func bump(_ stage: Stage, by delta: Int = 1) {
        counters[stage, default: 0] += delta
    }

    /// Add elapsed seconds to a stage's running total (PERF.0 instrumentation).
    public func record(_ stage: Stage, seconds: Double) {
        durations[stage, default: 0] += seconds
    }

    public func snapshot() -> [Stage: Int] {
        counters
    }

    /// Cumulative seconds per stage since boot/reset. Pairs with `snapshot()`
    /// counts to give average cost per item.
    public func durationsSnapshot() -> [Stage: Double] {
        durations
    }

    /// One-line cost profile, highest-total-time stage first. For the log.
    public func costProfile() -> String {
        let rows = durations.sorted { $0.value > $1.value }
        return rows.map { "\($0.key.humanLabel) \(String(format: "%.1f", $0.value))s (\(counters[$0.key] ?? 0))" }
            .joined(separator: " · ")
    }

    public func reset() {
        counters.removeAll()
        durations.removeAll()
        bootTime = Date()
    }
}
