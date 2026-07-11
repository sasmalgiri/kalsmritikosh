//
//  LedgerEventDrivenEngine.swift
//  Kalsmritikosh
//
//  System 3 — ledger-first, event-driven. ZERO-LLM ingest (spec P0.4): rule
//  extractors + embeddings + FTS + ledger only — NO per-file document-card
//  call. Memory is warmed on demand at query time, and the LLM is reserved
//  entirely for query-time interpretation. Fastest ingest of the three.
//
//  The distinguishing background behaviour is `LedgerPromoter`: while the
//  Mac is idle it re-derives the rule-based "missing links" (gap) layer as
//  the corpus grows, so findings surface before the user asks — spending
//  no LLM budget. The gap scan itself (all three rules) lives in
//  AppState.scanForGaps and is handed in via the context.
//

import Foundation
import OSLog

public actor LedgerEventDrivenEngine: SystemEngine {
    public nonisolated var mode: SystemMode { .ledgerEventDriven }

    public nonisolated var ingestPolicy: SystemMode.EnrichmentPolicy {
        // ZERO generative LLM at ingest (spec P0.4): no memory distillation,
        // no context-prefix sweep, and NO per-file document-card call. This is
        // the authoritative policy AppState consumes — it must match the
        // documented minimum-LLM promise, not just FeatureFlags.policy.
        .init(eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: false)
    }

    private var promoter: LedgerPromoter?

    public init() {}

    public func activate(_ context: SystemEngineContext) async {
        // LedgerPromoter's init is main-actor-isolated under the module's
        // default isolation; construct it on the main actor.
        let promoter = await MainActor.run {
            LedgerPromoter(
                isActive: { true },   // this engine only exists in Ledger mode
                scan: context.scanForGaps,
                onScan: context.onGapScan
            )
        }
        await promoter.start()
        self.promoter = promoter
        KalsmritikoshLog.knowledge.info("LedgerEventDrivenEngine active — proactive rule-based gap maintenance; memory warmed on demand")
    }

    public func deactivate() async {
        await promoter?.stop()
        promoter = nil
    }

    public func onAnswer(_ answer: VerifiedAnswer) async {}
}
