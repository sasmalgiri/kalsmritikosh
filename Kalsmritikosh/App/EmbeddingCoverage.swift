//
//  EmbeddingCoverage.swift
//  Kalsmritikosh
//
//  U-3.1 (W-6) — the embedding bar as an HONEST four-state split instead
//  of a single "Chunks → Vectors" ratio. Every chunk is in exactly one
//  state, and the four states sum to the chunk total:
//
//    · embedded — has ≥1 vector in chunk_embeddings.
//    · excluded — the admit decision ruled it out (reason recorded); it is
//                 not a failure and not pending.
//    · failed   — embedding was attempted and errored (needs a retry).
//    · pending  — eligible, not yet embedded (the drain target → 0).
//
//  `pending` is DERIVED as the remainder so the invariant holds by
//  construction. Today the ingest path records no exclusions or failures,
//  so those two are honestly 0 and pending == total − embedded; the shape
//  is here for the moment ingest starts stamping an embedding status.
//  Pure and deterministic.
//

import Foundation

public struct EmbeddingCoverage: Sendable, Equatable {
    public let total: Int
    public let embedded: Int
    public let excluded: Int
    public let failed: Int

    /// Eligible-but-not-yet-embedded, derived so the four states always sum
    /// to `total` (clamped at 0 against dirty counts).
    public var pending: Int { max(0, total - embedded - excluded - failed) }

    /// True when the parts account for the whole — the health-panel
    /// invariant. Only false if a count is inconsistent (embedded > total).
    public var isConsistent: Bool {
        embedded >= 0 && excluded >= 0 && failed >= 0
            && embedded + excluded + failed <= total
    }

    public init(total: Int, embedded: Int, excluded: Int = 0, failed: Int = 0) {
        self.total = max(0, total)
        self.embedded = max(0, embedded)
        self.excluded = max(0, excluded)
        self.failed = max(0, failed)
    }

    /// Fraction embedded, for the bar fill. 1.0 when there are no chunks
    /// (nothing to embed is "complete", not "empty").
    public var embeddedFraction: Double {
        total == 0 ? 1.0 : Double(embedded) / Double(total)
    }
}
