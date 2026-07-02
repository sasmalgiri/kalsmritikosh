//
//  LLMCallCounters.swift
//  Kalsmritikosh
//
//  Process-wide counters that make the ledger-first LLM-reduction
//  visible: how many LLM calls actually ran, how many were SKIPPED by
//  the reduction policy (ingest-time distillation off, cooldown), how
//  many timed out, and embedding-cache hit rate. LiveMetrics reads a
//  snapshot each poll and the Live dashboard renders it, so "70-95%
//  fewer LLM calls" is a number you can watch, not a claim.
//
//  Deliberately global + tiny: call sites on any actor increment
//  without threading a dependency through every layer.
//

import Foundation

public actor LLMCallCounters {
    public static let shared = LLMCallCounters()

    public struct Snapshot: Sendable, Equatable {
        public var callsRun: Int = 0
        public var callsSkipped: Int = 0
        public var timeouts: Int = 0
        public var embedCacheHits: Int = 0
        public var embedCacheMisses: Int = 0
        public var byPurpose: [String: Int] = [:]

        /// Fraction of would-be LLM work that was skipped by policy.
        public var skipRate: Double {
            let total = callsRun + callsSkipped
            return total > 0 ? Double(callsSkipped) / Double(total) : 0
        }
        /// Embedding-cache hit rate.
        public var embedHitRate: Double {
            let total = embedCacheHits + embedCacheMisses
            return total > 0 ? Double(embedCacheHits) / Double(total) : 0
        }
    }

    private var snap = Snapshot()
    // Throughput window for self-calibration: first + last call time.
    private var firstCallAt: Date?
    private var lastCallAt: Date?

    public func recordCall(purpose: String) {
        snap.callsRun += 1
        snap.byPurpose[purpose, default: 0] += 1

        // Measure effective throughput (wall-seconds per call over the
        // active window — folds in provider parallelism) and persist it
        // so the ingest estimator can calibrate to this machine.
        let now = Date()
        if firstCallAt == nil { firstCallAt = now }
        lastCallAt = now
        if snap.callsRun >= CalibrationStore.minSamples,
           let first = firstCallAt {
            let window = now.timeIntervalSince(first)
            let effective = window / Double(max(1, snap.callsRun - 1))
            if effective > 0, effective < 300 {   // ignore idle-gapped windows
                CalibrationStore.record(effectiveSecondsPerCall: effective, samples: snap.callsRun)
            }
        }
    }

    public func recordSkip(purpose: String, count: Int = 1) {
        snap.callsSkipped += count
    }

    public func recordTimeout() { snap.timeouts += 1 }
    public func recordEmbedCacheHit(_ n: Int = 1) { snap.embedCacheHits += n }
    public func recordEmbedCacheMiss(_ n: Int = 1) { snap.embedCacheMisses += n }

    public func snapshot() -> Snapshot { snap }
    public func reset() { snap = Snapshot() }
}
