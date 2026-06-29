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
    private(set) public var bootTime: Date = Date()

    public init() {}

    public func bump(_ stage: Stage, by delta: Int = 1) {
        counters[stage, default: 0] += delta
    }

    public func snapshot() -> [Stage: Int] {
        counters
    }

    public func reset() {
        counters.removeAll()
        bootTime = Date()
    }
}
