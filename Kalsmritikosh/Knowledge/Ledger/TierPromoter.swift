//
//  TierPromoter.swift
//  Kalsmritikosh
//
//  System 2 (Hot / Warm / Cold) — the proactive enrichment engine.
//
//  Two idle-time passes, in order:
//
//    1. SCORE — walk the corpus in rolling batches and score each object's
//       importance from the ledger's own structure (entity + event counts)
//       plus persisted usage signals (citations, pins). Re-tier cold /
//       warm / hot. This is what makes hot documents surface PROACTIVELY,
//       before any question is asked — the fix for System 2 previously
//       being indistinguishable from System 3 until the user had cited
//       enough documents.
//
//    2. ENRICH — deep-enrich the un-enriched HOT slice (memory distillation
//       over its entities). The LLM budget flows only to the important
//       documents; cold clutter stays rule-only.
//
//  Self-gates to idle so it never competes with the user. Mode-gating is
//  the engine's job now (only HotWarmColdEngine ever constructs this), so
//  `isActive` is passed `{ true }` in production.
//

import Foundation
import OSLog

public actor TierPromoter: BackgroundService {
    public let id = "atlas.tier.promoter"

    private let enrichment: EnrichmentStatusRepository
    private let objects: KnowledgeObjectRepository
    private let entities: EntitiesRepository
    private let events: EventsRepository?
    private let distiller: MemoryDistiller
    private let scorer: ImportanceScorer
    private let isActive: @Sendable () -> Bool
    private let idleThreshold: TimeInterval
    private let interval: TimeInterval
    private let pollInterval: TimeInterval
    /// How many HOT docs to deep-enrich per pass.
    private let enrichBatch: Int
    /// How many objects to (re)score per pass. Rolls through the corpus.
    private let scoreBatch: Int

    private var watchTask: Task<Void, Never>?
    private var lastRunAt: Date = .distantPast
    /// Rolling cursor into the object list for the scoring pass, so a large
    /// corpus is covered across many idle passes without a huge per-pass cost.
    private var scoreOffset: Int = 0

    public init(
        enrichment: EnrichmentStatusRepository,
        objects: KnowledgeObjectRepository,
        entities: EntitiesRepository,
        events: EventsRepository?,
        distiller: MemoryDistiller,
        isActive: @escaping @Sendable () -> Bool,
        scorer: ImportanceScorer = ImportanceScorer(),
        idleThreshold: TimeInterval = 90,
        interval: TimeInterval = 10 * 60,
        pollInterval: TimeInterval = 15,
        enrichBatch: Int = 5,
        scoreBatch: Int = 60
    ) {
        self.enrichment = enrichment
        self.objects = objects
        self.entities = entities
        self.events = events
        self.distiller = distiller
        self.isActive = isActive
        self.scorer = scorer
        self.idleThreshold = idleThreshold
        self.interval = interval
        self.pollInterval = pollInterval
        self.enrichBatch = enrichBatch
        self.scoreBatch = scoreBatch
    }

    public func start() async {
        guard watchTask == nil else { return }
        AtlasLog.knowledge.info("TierPromoter watching (System 2 proactive tiering + hot-slice enrichment)")
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let ns = await UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
    }

    private func tick() async {
        guard isActive() else { return }
        guard SystemActivity.isIdle(threshold: idleThreshold) else { return }
        guard Date().timeIntervalSince(lastRunAt) >= interval else { return }
        lastRunAt = Date()

        await scorePass()
        await enrichPass()
    }

    // MARK: Pass 1 — proactive importance scoring / re-tiering

    /// Score a rolling batch of objects from the ledger's structure + usage
    /// and re-tier them. No LLM — pure DB reads + arithmetic.
    private func scorePass() async {
        let total = (try? await objects.count()) ?? 0
        guard total > 0 else { return }
        if scoreOffset >= total { scoreOffset = 0 }

        let ids = (try? await objects.allIDs(offset: scoreOffset, pageSize: scoreBatch)) ?? []
        guard !ids.isEmpty else { scoreOffset = 0; return }

        var scored = 0
        for id in ids {
            // Yield the machine back the instant the user returns.
            if !SystemActivity.isIdle(threshold: 5) { break }

            let entityCount = ((try? await entities.findByMentionSource(id)) ?? []).count
            var eventCount = 0
            if let events {
                eventCount = ((try? await events.findBySourceObject(id)) ?? []).count
            }

            let existing = await enrichment.status(id)
            let ageDays = existing.map { Date().timeIntervalSince($0.updatedAt) / 86_400 } ?? 0
            let importance = scorer.score(
                citationCount: existing?.citationCount ?? 0,
                queryHits: existing?.queryHits ?? 0,
                pinned: existing?.pinned ?? false,
                ageDays: max(0, ageDays),
                entityCount: entityCount,
                eventCount: eventCount
            )
            await enrichment.setImportance(id, importance)
            await enrichment.setTier(id, scorer.tier(forImportance: importance))
            scored += 1
        }
        scoreOffset += ids.count
        if scored > 0 {
            AtlasLog.knowledge.info("TierPromoter scored \(scored, privacy: .public) object(s) [offset now \(self.scoreOffset, privacy: .public)/\(total, privacy: .public)]")
        }
    }

    // MARK: Pass 2 — deep-enrich the hot slice

    private func enrichPass() async {
        let hot = await enrichment.needingEnrichment(tier: .hot, limit: enrichBatch)
        guard !hot.isEmpty else { return }
        AtlasLog.knowledge.info("TierPromoter: deep-enriching \(hot.count, privacy: .public) hot document(s)")

        for record in hot {
            if !SystemActivity.isIdle(threshold: 5) { break }
            let ents = (try? await entities.findByMentionSource(record.objectID)) ?? []
            let values = Array(Set(ents.map(\.value))).filter { !$0.isEmpty }
            if !values.isEmpty {
                _ = try? await distiller.distillSubjects(forEntities: values)
            }
            await enrichment.markEnriched(record.objectID)
        }
    }
}
