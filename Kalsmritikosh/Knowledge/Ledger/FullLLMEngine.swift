//
//  FullLLMEngine.swift
//  Kalsmritikosh
//
//  System 1 — the original "most diligent" pipeline. Eager, deep
//  enrichment of EVERYTHING at ingest: per-subject memory distillation
//  plus a context-prefix on every chunk (re-embedded so the LLM work
//  improves retrieval). Deepest ledger up front, slowest + most
//  expensive ingest (~10 h / 100 MB).
//
//  Because all the enrichment happens eagerly during ingest — driven by
//  `ingestPolicy` (both flags on) through AppState's incremental updater
//  and context-prefix backfiller — there is nothing left to promote in
//  the background. This engine owns no idle maintenance engine; that is
//  the whole point of System 1 vs. Systems 2 & 3.
//

import Foundation
import OSLog

public actor FullLLMEngine: SystemEngine {
    public nonisolated var mode: SystemMode { .fullLLM }

    public nonisolated var ingestPolicy: SystemMode.EnrichmentPolicy {
        .init(eagerMemoryDistillation: true, contextPrefixBackfill: true)
    }

    public init() {}

    public func activate(_ context: SystemEngineContext) async {
        KalsmritikoshLog.knowledge.info("FullLLMEngine active — eager deep enrichment at ingest (memory distillation + context-prefix backfill); no idle promoter")
    }

    public func deactivate() async {}

    public func onAnswer(_ answer: VerifiedAnswer) async {}
}
