//
//  LedgerEventDrivenEngine.swift
//  Kalsmritikosh
//
//  System 3 — ledger-first, event-driven. Near-zero-LLM ingest: rule
//  extractors fill the ledger, plus exactly ONE document-card LLM call per
//  file (the first chunk → a doc-level gist, re-embedded). Memory is warmed
//  on demand at query time, and the LLM is otherwise reserved for query-time
//  interpretation. Fastest ingest of the three.
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
        // Rules + one document-card LLM call per file (first chunk); all
        // other LLM work is reserved for query time.
        .init(eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: true)
    }

    private var promoter: LedgerPromoter?

    public init() {}

    public func activate(_ context: SystemEngineContext) async {
        let promoter = LedgerPromoter(
            isActive: { true },   // this engine only exists in Ledger mode
            scan: context.scanForGaps,
            onScan: context.onGapScan
        )
        await promoter.start()
        self.promoter = promoter
        AtlasLog.knowledge.info("LedgerEventDrivenEngine active — proactive rule-based gap maintenance; memory warmed on demand")
    }

    public func deactivate() async {
        await promoter?.stop()
        promoter = nil
    }

    public func onAnswer(_ answer: VerifiedAnswer) async {}
}
