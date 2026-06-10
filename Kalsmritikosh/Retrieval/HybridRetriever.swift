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
    public static let defaultVectorLayerLimit = 20

    private let memory: MemoryRepository
    private let events: EventsRepository
    private let entities: EntitiesRepository
    private let chunks: ChunksRepository
    private let summaries: SummariesRepository
    private let graph: GraphStore
    private let vectors: VectorStore
    private let embedder: Embedder
    private let vectorLayerLimit: Int

    public init(
        memory: MemoryRepository,
        events: EventsRepository,
        entities: EntitiesRepository,
        chunks: ChunksRepository,
        summaries: SummariesRepository,
        graph: GraphStore,
        vectors: VectorStore,
        embedder: Embedder,
        vectorLayerLimit: Int = HybridRetriever.defaultVectorLayerLimit
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

        return assemble(
            chunks: collectedChunks,
            events: collectedEvents,
            entities: collectedEntities,
            relationships: collectedRelationships,
            summaries: collectedSummaries,
            layers: usedLayers,
            shortCircuit: nil
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

        for candidate in Set(candidates) where !candidate.isEmpty {
            for kind in MemoryObject.SubjectKind.allCases {
                if let current = try? await memory.current(forSubject: kind, identifier: candidate),
                   seen.insert(current.id).inserted {
                    hits.append(current)
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
        for hint in intent.entityHints.prefix(6) {
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
        return hits.enumerated().map { idx, chunk in
            RetrievedChunk(
                chunk: chunk,
                score: 1.0 / Double(idx + 1),
                viaLayer: .metadata
            )
        }
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
        shortCircuit: RetrievalLayer?
    ) -> RetrievalResult {
        RetrievalResult(
            chunks: chunks,
            events: events,
            entities: entities,
            relationships: relationships,
            summaries: summaries,
            layersUsed: layers,
            shortCircuitedAt: shortCircuit
        )
    }
}

extension RetrievalLayer {
    /// The locked priority order. Memory leads; vector is intentionally last.
    public static let priorityOrder: [RetrievalLayer] = [
        .memory, .timeline, .entity, .metadata, .summary, .graph, .vector
    ]
}
