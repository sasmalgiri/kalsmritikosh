//
//  HotWarmColdEngine.swift
//  Kalsmritikosh
//
//  System 2 — importance-tiered enrichment. Ingest is cheap (rule-based,
//  like System 3): `ingestPolicy` leaves eager LLM work off. The
//  distinguishing behaviour is a proactive, idle-time engine —
//  `TierPromoter` — that:
//
//    1. SCORES documents by importance from the ledger's own structure
//       (how many entities / events each object carries) PLUS usage
//       signals (citations, pins). This means hot documents surface
//       proactively, before the user has asked a single question — the
//       gap that made System 2 previously indistinguishable from System 3.
//    2. DEEP-ENRICHES the hot slice (memory distillation over its
//       entities), spending the LLM budget only where the archive is
//       structurally or behaviourally important.
//
//  Cold clutter stays rule-only. `onAnswer` folds each shipped answer's
//  citations back into importance as a strong usage vote.
//

import Foundation
import OSLog

public actor HotWarmColdEngine: SystemEngine {
    public nonisolated var mode: SystemMode { .hotWarmCold }

    public nonisolated var ingestPolicy: SystemMode.EnrichmentPolicy {
        // Cheap ingest + one document-card LLM call per file; deep LLM only
        // for the hot slice (TierPromoter).
        .init(eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: true)
    }

    private var promoter: TierPromoter?
    private var context: SystemEngineContext?

    public init() {}

    public func activate(_ context: SystemEngineContext) async {
        self.context = context
        guard
            let enrichment = context.enrichment,
            let objects = context.objects,
            let entities = context.entities
        else {
            AtlasLog.knowledge.error("HotWarmColdEngine missing repositories — tiering disabled")
            return
        }
        // TierPromoter's init is main-actor-isolated under the module's
        // default isolation; hop to the main actor to construct it, then
        // drive it from here (it's an actor, safe to hold).
        let promoter = await MainActor.run {
            TierPromoter(
                enrichment: enrichment,
                objects: objects,
                entities: entities,
                events: context.events,
                distiller: context.distiller,
                isActive: { true }   // this engine only exists in Hot/Warm/Cold mode
            )
        }
        await promoter.start()
        self.promoter = promoter
        AtlasLog.knowledge.info("HotWarmColdEngine active — proactive structural tiering + hot-slice deep enrichment")
    }

    public func deactivate() async {
        await promoter?.stop()
        promoter = nil
    }

    public func onAnswer(_ answer: VerifiedAnswer) async {
        let ids = answer.citations.map(\.objectID)
        guard !ids.isEmpty else { return }
        await context?.bumpCitations(ids)
    }
}
