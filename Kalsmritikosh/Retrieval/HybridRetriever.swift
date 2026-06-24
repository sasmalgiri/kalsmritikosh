//
//  HybridRetriever.swift
//  Kalsmritikosh
//
//  Priority-ordered retrieval per the locked architecture:
//      Memory → Timeline → Entity → Metadata → Summary → Graph → Vector
//
//  Each layer is asked in order; if it returns enough confident hits the
//  retriever short-circuits and returns. Vector search is the final
//  fallback — never the entry point. Memory always leads.
//

import Foundation

public actor HybridRetriever: Retriever {
    /// How many vector hits the vector layer asks for. Held as a property
    /// so a future Settings toggle can change it without touching the
    /// retrieval call site. UPDATE_06 Item 2.
    public nonisolated static let defaultVectorLayerLimit = 20

    private let memory: MemoryRepository
    private let events: EventsRepository
    private let entities: EntitiesRepository
    private let chunks: ChunksRepository
    private let summaries: SummariesRepository
    private let graph: GraphStore
    private let vectors: VectorStore
    private let embedder: Embedder
    private let vectorLayerLimit: Int
    /// G2-SYNTHETIC-QUESTIONS — optional. When present, the metadata
    /// (FTS) layer also queries the synthetic-questions FTS view and
    /// unions chunk hits derived from synthetic-question matches.
    private let syntheticQuestions: SyntheticQuestionsRepository?
    /// G2-QA-PAIRS — optional. When present, the metadata (FTS) layer
    /// also searches the qa_pairs FTS view; matches hydrate the
    /// answer-side KO's top chunk and append it to the retrieved set.
    private let qaPairs: QAPairsRepository?
    /// In-memory caches for the three SQL-heavy retrieval layers.
    /// When wired AND warm, the layer prefers the cache lookup over
    /// SQL. Each cache exposes isWarm() so the warm-up window stays
    /// safe (SQL fallback).
    private let memoryCache: MemoryHashCache?
    private let entityTrie: EntityTrie?
    private let entityTimeline: EntityTimeline?
    /// G3.17 — optional typed-graph walker. When wired, the graph
    /// layer enriches entity seeds with chunks pulled from KOs
    /// reached via fact_bonds (up to 2 hops). Schema-aware multi-hop
    /// without changing the layer ordering or public API.
    private let bondWalker: BondWalker?
    /// G3.20 — optional explainer that translates raw bond steps
    /// into typed [WalkStep] for the "Why this answer?" UI. Wired
    /// alongside the walker; both nil = bond-walk features disabled.
    private let walkExplainer: WalkExplainer?
    /// G3.17 — how many bond walks per retrieve() call. Capped so a
    /// dense graph doesn't blow up the query budget. 0 = walks
    /// disabled even if a walker is wired.
    private let bondWalkSeedLimit: Int
    /// G3.17 — how many chunks the bond walks contribute.
    private let bondWalkChunkLimit: Int

    public init(
        memory: MemoryRepository,
        events: EventsRepository,
        entities: EntitiesRepository,
        chunks: ChunksRepository,
        summaries: SummariesRepository,
        graph: GraphStore,
        vectors: VectorStore,
        embedder: Embedder,
        vectorLayerLimit: Int = HybridRetriever.defaultVectorLayerLimit,
        syntheticQuestions: SyntheticQuestionsRepository? = nil,
        qaPairs: QAPairsRepository? = nil,
        bondWalker: BondWalker? = nil,
        walkExplainer: WalkExplainer? = nil,
        memoryCache: MemoryHashCache? = nil,
        entityTrie: EntityTrie? = nil,
        entityTimeline: EntityTimeline? = nil,
        bondWalkSeedLimit: Int = 3,
        bondWalkChunkLimit: Int = 10
    ) {
        self.memory = memory
        self.events = events
        self.entities = entities
        self.chunks = chunks
        self.summaries = summaries
        self.graph = graph
        self.vectors = vectors
        self.embedder = embedder
        self.vectorLayerLimit = vectorLayerLimit
        self.syntheticQuestions = syntheticQuestions
        self.qaPairs = qaPairs
        self.bondWalker = bondWalker
        self.walkExplainer = walkExplainer
        self.memoryCache = memoryCache
        self.entityTrie = entityTrie
        self.entityTimeline = entityTimeline
        self.bondWalkSeedLimit = bondWalkSeedLimit
        self.bondWalkChunkLimit = bondWalkChunkLimit
    }

    public func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> RetrievalResult {
        let ordering = layers.isEmpty ? RetrievalLayer.priorityOrder : layers

        var usedLayers: [RetrievalLayer] = []
        var collectedEvents: [Event] = []
        var collectedEntities: [Entity] = []
        var collectedChunks: [RetrievedChunk] = []
        var collectedSummaries: [Summary] = []
        var collectedRelationships: [Relationship] = []
        var collectedMemoryNarratives: [String] = []
        // G3.20 — raw bond steps collected from each seed walk; the
        // WalkExplainer translates them to typed WalkSteps once the
        // graph layer finishes.
        var collectedBondSteps: [BondWalker.WalkResult.Step] = []

        for layer in ordering {
            usedLayers.append(layer)
            switch layer {
            case .memory:
                let memoryHits = try await memoryLayer(intent)
                collectedMemoryNarratives.append(contentsOf: memoryHits.map(\.narrative))
                // Hydrate the events behind the memory hits so downstream
                // experts have grounded evidence. Don't short-circuit
                // entirely — the brain wants both the narrative and the
                // raw events the experts can reason over.
                if !memoryHits.isEmpty {
                    collectedSummaries.append(contentsOf: memoryHits.map(memoryAsSummary))
                    let allEventIDs = memoryHits.flatMap(\.keyEventIDs)
                    if !allEventIDs.isEmpty {
                        let hydrated = try await events.findByIDs(allEventIDs)
                        collectedEvents.append(contentsOf: hydrated)
                    }
                }
            case .timeline:
                // Always let subsequent layers contribute. Even when a
                // healthy event set exists, entity hydration matters for
                // surfacing named subjects in the answer body.
                collectedEvents.append(contentsOf: try await timelineLayer(intent))
            case .entity:
                collectedEntities.append(contentsOf: try await entityLayer(intent))
            case .metadata:
                collectedChunks.append(contentsOf: try await metadataLayer(intent))
            case .summary:
                collectedSummaries.append(contentsOf: try await summaryLayer(intent))
            case .graph:
                if !collectedEntities.isEmpty {
                    let edges = try await graphLayer(seeds: collectedEntities)
                    collectedRelationships.append(contentsOf: edges)
                    // G3.17/G3.18 — typed bond walks, biased by intent.
                    // Reconstruction-shaped questions get more seeds and
                    // hops; flat factual lookups get a tight budget so
                    // the schema-aware layer doesn't tax simple queries.
                    let existingObjectIDs = Set(collectedChunks.map(\.chunk.objectID))
                    let bondOutcome = try await bondLayer(
                        intent: intent,
                        seeds: collectedEntities,
                        excludeObjectIDs: existingObjectIDs
                    )
                    collectedChunks.append(contentsOf: bondOutcome.chunks)
                    collectedBondSteps.append(contentsOf: bondOutcome.steps)
                }
            case .vector:
                // UPDATE_06 Item 2 — prefer a prefiltered scan over the
                // pre-collected chunk set; fall back to full scan only if
                // no earlier layer produced candidates. Keeps query latency
                // flat as the corpus grows.
                let candidateIDs = collectedChunks.map(\.chunk.id)
                let prefilter: [Chunk.ID]? = candidateIDs.isEmpty ? nil : candidateIDs
                collectedChunks.append(contentsOf: try await vectorLayer(intent, candidateChunkIDs: prefilter))
            }
        }

        // G3.20 — translate raw bond steps into typed [WalkStep] for
        // the "Why this answer?" UI. Skipped when no explainer is
        // wired or no steps were produced.
        let walkSteps: [WalkStep]
        if let explainer = walkExplainer, !collectedBondSteps.isEmpty {
            walkSteps = await explainer.explain(collectedBondSteps)
        } else {
            walkSteps = []
        }

        return assemble(
            chunks: collectedChunks,
            events: collectedEvents,
            entities: collectedEntities,
            relationships: collectedRelationships,
            summaries: collectedSummaries,
            layers: usedLayers,
            shortCircuit: nil,
            walkSteps: walkSteps
        )
    }

    // MARK: - Layers

    private func memoryLayer(_ intent: UserIntent) async throws -> [MemoryObject] {
        var seen = Set<MemoryObject.ID>()
        var hits: [MemoryObject] = []

        // Subject identifiers worth looking up: scope + each entity hint.
        var candidates: [String] = intent.entityHints
        switch intent.scope {
        case .project(let name), .person(let name), .organization(let name), .folder(let name):
            candidates.append(name)
        case .global:
            break
        }

        // Hot path: hashmap lookups via MemoryHashCache.
        let cacheReady = await memoryCache?.isWarm() ?? false
        if let cache = memoryCache, cacheReady {
            for candidate in Set(candidates) where !candidate.isEmpty {
                for kind in MemoryObject.SubjectKind.allCases {
                    if let current = await cache.lookup(kind: kind, identifier: candidate),
                       seen.insert(current.id).inserted {
                        hits.append(current)
                    }
                }
            }
        } else {
            for candidate in Set(candidates) where !candidate.isEmpty {
                for kind in MemoryObject.SubjectKind.allCases {
                    if let current = try? await memory.current(forSubject: kind, identifier: candidate),
                       seen.insert(current.id).inserted {
                        hits.append(current)
                    }
                }
            }
        }

        // Fall back to full-text-ish search over narratives when no hint
        // matched directly.
        if hits.isEmpty {
            let trimmed = intent.rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let searchHits = (try? await memory.search(trimmed, limit: 5)) ?? []
                for hit in searchHits where seen.insert(hit.id).inserted {
                    hits.append(hit)
                }
            }
        }

        return hits
    }

    private func timelineLayer(_ intent: UserIntent) async throws -> [Event] {
        // Hot path: when entity hints + a timeframe both narrow the
        // result, fan out per-entity via the EntityTimeline cache —
        // binary search + memcpy instead of SQL intersection of
        // (entity_id, date BETWEEN). Falls back to the global SQL
        // path when no hint anchors the query.
        let timelineReady = await entityTimeline?.isWarm() ?? false
        let trieReady = await entityTrie?.isWarm() ?? false
        if let timeline = entityTimeline, timelineReady,
           let trie = entityTrie, trieReady,
           !intent.entityHints.isEmpty {
            var seenEventIDs = Set<Event.ID>()
            var collectedIDs: [Event.ID] = []
            for hint in intent.entityHints.prefix(4) {
                let entityIDs = await trie.resolve(hint)
                for entityID in entityIDs {
                    let slots = await timeline.slots(
                        forEntity: entityID,
                        from: intent.timeframe?.start,
                        to: intent.timeframe?.end
                    )
                    for slot in slots where seenEventIDs.insert(slot.eventID).inserted {
                        collectedIDs.append(slot.eventID)
                        if collectedIDs.count >= 200 { break }
                    }
                    if collectedIDs.count >= 200 { break }
                }
                if collectedIDs.count >= 200 { break }
            }
            if !collectedIDs.isEmpty {
                return try await events.findByIDs(collectedIDs)
            }
            // No entity matches — fall through to the SQL timeline path
            // so the brain still gets globally-recent context.
        }
        if let timeframe = intent.timeframe,
           let start = timeframe.start,
           let end = timeframe.end {
            return try await events.between(start: start, end: end, limit: 200)
        }
        if let timeframe = intent.timeframe {
            return try await events.between(
                start: timeframe.start ?? .distantPast,
                end: timeframe.end ?? .distantFuture,
                limit: 200
            )
        }
        return try await events.recent(limit: 100)
    }

    private func entityLayer(_ intent: UserIntent) async throws -> [Entity] {
        var results: [Entity] = []
        var seen = Set<Entity.ID>()
        let trieReady = await entityTrie?.isWarm() ?? false
        for hint in intent.entityHints.prefix(6) {
            // Hot path: Trie resolves the hint in O(|hint|) to a set
            // of candidate ids, then a single `WHERE id IN (...)` SQL
            // hydrates them. Replaces `LIKE '%hint%'` full scan.
            if let trie = entityTrie, trieReady {
                let candidateIDs = Array(await trie.resolve(hint))
                if !candidateIDs.isEmpty {
                    let hydrated = (try? await entities.findByIDs(candidateIDs, limit: 15)) ?? []
                    for entity in hydrated where seen.insert(entity.id).inserted {
                        results.append(entity)
                    }
                    continue
                }
            }
            // Fallback: SQL LIKE scan.
            let rows = try await entities.find(byValue: hint, limit: 15)
            for entity in rows where seen.insert(entity.id).inserted {
                results.append(entity)
            }
        }
        // Pull a handful of high-signal entities — emails, orgs, people —
        // so the brain has named subjects to surface even when intent
        // hints don't directly match. Hydrate each through find(byID:)
        // so the sourceObjectID is real (no synthetic UUID leak).
        let topUpKinds: [Entity.Kind] = [.emailAddress, .organization, .person, .vendor, .client, .project]
        for kind in topUpKinds {
            let rows = try await entities.list(kind: kind, limit: 8)
            for row in rows where seen.insert(row.id).inserted {
                if let real = try await entities.find(byID: row.id) {
                    results.append(real)
                }
            }
        }
        return results
    }

    private func metadataLayer(_ intent: UserIntent) async throws -> [RetrievedChunk] {
        let q = intent.rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let hits = try await chunks.searchFTS(q, limit: 25)
        var collected: [RetrievedChunk] = hits.enumerated().map { idx, chunk in
            RetrievedChunk(
                chunk: chunk,
                score: 1.0 / Double(idx + 1),
                viaLayer: .metadata
            )
        }

        // G2-SYNTHETIC-QUESTIONS — also search the synthetic-questions
        // FTS view; for each match, hydrate the underlying chunk and
        // merge into the result set. De-dupe by chunkID — if the same
        // chunk was hit by chunk-text FTS AND by a synthetic question,
        // we keep the higher score (synthetic-question matches signal
        // question-shaped relevance, which chatmind validated as the
        // strongest single retrieval lift).
        if let synthRepo = syntheticQuestions {
            let synthHits = (try? await synthRepo.search(q, limit: 25)) ?? []
            if !synthHits.isEmpty {
                let existingChunkIDs = Set(collected.map(\.chunk.id))
                // Hydrate chunks for synthetic-question hits not already
                // present in the chunk-text path.
                let missingChunkIDs = synthHits
                    .map(\.chunkID)
                    .filter { !existingChunkIDs.contains($0) }
                let hydrated = (try? await chunks.findByIDs(missingChunkIDs)) ?? []
                let hydratedByID: [Chunk.ID: Chunk] = Dictionary(
                    uniqueKeysWithValues: hydrated.map { ($0.id, $0) }
                )
                for hit in synthHits {
                    if let chunk = hydratedByID[hit.chunkID] {
                        collected.append(RetrievedChunk(
                            chunk: chunk,
                            score: hit.score,
                            viaLayer: .metadata
                        ))
                    }
                }
            }
        }

        // G2-QA-PAIRS — search the qa_pairs FTS view. For each pair the
        // user question matches, hydrate the FIRST chunk of the answer
        // KO (small enough that taking the head of its chunk set is a
        // decent stand-in for "the answer text"). Append as metadata-
        // layer hits so the verifier can merge with chunk-text + synthq
        // hits.
        if let qaRepo = qaPairs {
            let qaHits = (try? await qaRepo.search(q, limit: 15)) ?? []
            if !qaHits.isEmpty {
                let existingObjectIDs = Set(collected.map(\.chunk.objectID))
                let novelHits = qaHits.filter {
                    !existingObjectIDs.contains($0.answerObjectID)
                }
                for hit in novelHits {
                    if let chunk = try? await chunks.firstChunk(forObjectID: hit.answerObjectID) {
                        collected.append(RetrievedChunk(
                            chunk: chunk,
                            score: hit.score,
                            viaLayer: .metadata
                        ))
                    }
                }
            }
        }

        return collected
    }

    private func summaryLayer(_ intent: UserIntent) async throws -> [Summary] {
        try await summaries.listByLevel(.knowledgeBase, limit: 3)
    }

    private func graphLayer(seeds: [Entity]) async throws -> [Relationship] {
        var out: [Relationship] = []
        for seed in seeds.prefix(3) {
            out.append(contentsOf: try await graph.neighbors(of: seed.id, limit: 25))
        }
        return out
    }

    /// G3.17/G3.18/G3.20 — typed bond walk, intent-biased. For each
    /// seed entity, BFS over fact_bonds up to a per-intent hop budget,
    /// collect the source KO ids of the traversed bonds, and hydrate
    /// the first chunk per KO as retrieval evidence (`viaLayer:
    /// .graph`). Returns both chunks (for the retrieval set) and raw
    /// bond steps (for the WalkExplainer / "Why this answer?" UI).
    /// KOs that already appeared in earlier layers are skipped so we
    /// don't duplicate citations.
    private struct BondLayerOutcome {
        let chunks: [RetrievedChunk]
        let steps: [BondWalker.WalkResult.Step]
    }

    private func bondLayer(
        intent: UserIntent,
        seeds: [Entity],
        excludeObjectIDs: Set<KnowledgeObject.ID>
    ) async throws -> BondLayerOutcome {
        guard let walker = bondWalker, bondWalkSeedLimit > 0 else {
            return BondLayerOutcome(chunks: [], steps: [])
        }
        let budget = bondWalkBudget(for: intent)
        guard budget.seeds > 0, budget.chunks > 0 else {
            return BondLayerOutcome(chunks: [], steps: [])
        }
        var aggregatedKOIDs: [KnowledgeObject.ID] = []
        var seenKOIDs: Set<KnowledgeObject.ID> = excludeObjectIDs
        var allSteps: [BondWalker.WalkResult.Step] = []
        for seed in seeds.prefix(budget.seeds) {
            let result = await walker.expand(from: seed.id, maxHops: budget.hops)
            allSteps.append(contentsOf: result.steps)
            for koID in result.sourceObjectIDs {
                guard !seenKOIDs.contains(koID) else { continue }
                seenKOIDs.insert(koID)
                aggregatedKOIDs.append(koID)
                if aggregatedKOIDs.count >= budget.chunks { break }
            }
            if aggregatedKOIDs.count >= budget.chunks { break }
        }
        guard !aggregatedKOIDs.isEmpty else {
            return BondLayerOutcome(chunks: [], steps: allSteps)
        }
        let scoreFloor = bondChunkScore(for: intent)
        var out: [RetrievedChunk] = []
        for koID in aggregatedKOIDs {
            if let chunk = try? await chunks.firstChunk(forObjectID: koID) {
                out.append(RetrievedChunk(
                    chunk: chunk,
                    // G3.19 — score floor is intent-biased. Multi-hop
                    // questions promote bond chunks above most vector
                    // hits since the bond graph IS the answer path;
                    // lookups demote them so a direct semantic match
                    // still wins.
                    score: scoreFloor,
                    viaLayer: .graph
                ))
            }
        }
        return BondLayerOutcome(chunks: out, steps: allSteps)
    }

    /// G3.19 — pick the bond-chunk score floor based on intent. The
    /// values are kept inside a narrow band so MMR diversity (G2-MMR)
    /// can still reshuffle them; this is the BASELINE score, not the
    /// final ranking.
    private func bondChunkScore(for intent: UserIntent) -> Double {
        switch intent.kind {
        case .reconstructProject,
             .reconstructRelationship,
             .reconstructTimeline,
             .executiveBriefing:
            // Multi-hop / reconstruction — the bond graph is what the
            // question hinges on. Above most vector fallbacks.
            return 0.65
        case .riskDetection, .missingInformation:
            return 0.55
        case .factualLookup, .semanticSearch, .unknown:
            // Direct factual matches usually outrank a graph walk for
            // simple lookups; keep bond chunks visible but below.
            return 0.45
        }
    }

    /// G3.18 — pick (seeds × hops × chunkLimit) for bond walks based
    /// on the question's intent kind. Reconstruction-shaped questions
    /// (project / relationship / timeline) explore wider; flat factual
    /// lookups stay narrow so we don't pay the bond-walk cost on a
    /// "what is X" query that the entity layer already answers.
    private func bondWalkBudget(for intent: UserIntent) -> (seeds: Int, hops: Int, chunks: Int) {
        switch intent.kind {
        case .reconstructProject,
             .reconstructRelationship,
             .reconstructTimeline,
             .executiveBriefing:
            // Multi-hop questions — the bond graph is the whole point.
            return (
                seeds: max(bondWalkSeedLimit, 5),
                hops: 2,
                chunks: max(bondWalkChunkLimit, 15)
            )
        case .riskDetection, .missingInformation:
            // Want broad context but not exhaustive — sit between the
            // reconstruction tier and the cheap lookup tier.
            return (
                seeds: bondWalkSeedLimit,
                hops: 2,
                chunks: bondWalkChunkLimit
            )
        case .factualLookup, .semanticSearch, .unknown:
            // Cheap path: a single short hop off the top seed. Saves
            // ~ N×perHopLimit SQL queries on every direct-lookup query.
            return (
                seeds: min(bondWalkSeedLimit, 2),
                hops: 1,
                chunks: min(bondWalkChunkLimit, 5)
            )
        }
    }

    private func vectorLayer(
        _ intent: UserIntent,
        candidateChunkIDs: [Chunk.ID]? = nil
    ) async throws -> [RetrievedChunk] {
        let query = await embedder.embed(intent.rawQuestion)
        let hits = try await vectors.nearest(
            to: query,
            limit: vectorLayerLimit,
            candidateChunkIDs: candidateChunkIDs
        )
        let hydrated = try await chunks.findByIDs(hits.map(\.chunkID))
        let byID = Dictionary(uniqueKeysWithValues: hydrated.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard let chunk = byID[hit.chunkID] else { return nil }
            return RetrievedChunk(chunk: chunk, score: hit.score, viaLayer: .vector)
        }
    }

    // MARK: - Helpers

    private func memoryAsSummary(_ memory: MemoryObject) -> Summary {
        Summary(
            level: .knowledgeBase,
            length: .executive,
            scope: .knowledgeBase,
            body: memory.narrative,
            modelID: "memory.distilled",
            confidence: memory.confidence
        )
    }

    private func assemble(
        chunks: [RetrievedChunk],
        events: [Event],
        entities: [Entity],
        relationships: [Relationship] = [],
        summaries: [Summary],
        layers: [RetrievalLayer],
        shortCircuit: RetrievalLayer?,
        walkSteps: [WalkStep] = []
    ) -> RetrievalResult {
        RetrievalResult(
            chunks: chunks,
            events: events,
            entities: entities,
            relationships: relationships,
            summaries: summaries,
            layersUsed: layers,
            shortCircuitedAt: shortCircuit,
            walkSteps: walkSteps
        )
    }
}

extension RetrievalLayer {
    /// The locked priority order. Memory leads; vector is intentionally last.
    public nonisolated static let priorityOrder: [RetrievalLayer] = [
        .memory, .timeline, .entity, .metadata, .summary, .graph, .vector
    ]
}
