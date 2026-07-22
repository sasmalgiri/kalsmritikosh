//
//  Retriever.swift
//  Kalsmritikosh
//
//  The retrieval surface the MasterBrain and Experts use. The priority
//  order (Timeline → Entity → Metadata → Summary → Graph → Vector) is
//  baked into the concrete HybridRetriever, NOT this protocol — callers
//  can also request a specific layer when they know what they need.
//

import Foundation

public protocol Retriever: Sendable {
    func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> RetrievalResult
}

public struct RetrievalResult: Codable, Sendable {
    public let chunks: [RetrievedChunk]
    public let events: [Event]
    public let entities: [Entity]
    public let relationships: [Relationship]
    public let summaries: [Summary]
    public let layersUsed: [RetrievalLayer]
    public let shortCircuitedAt: RetrievalLayer?
    /// G3.20 — typed walk-path steps from the bond engine, ready for
    /// the "Why this answer?" UI. Empty when no bond walks ran (no
    /// entity seeds, no walker wired, or intent budget = 0).
    public let walkSteps: [WalkStep]
    /// SEM — domain-pack facts derived from the evidence blocks that this
    /// retrieval surfaced (option A: facts ride the evidence). Empty when no
    /// GenericFact repo is wired or the surfaced blocks carry no facts. Each
    /// fact keeps its source-block ids, so the answer layer can cite them.
    public let genericFacts: [GenericFact]
    /// RET-009 — the authoritative source documents this retrieval identified,
    /// best→worst by DocumentFitness (role + requested-field match against the
    /// compiled QueryPlan). Empty on the density-only fallback path. The
    /// reconstruct answer path reads this to cite the authoritative structural
    /// document (a contract/amendment) that produced no dated event and so was
    /// uncitable from the narrative's event sources alone (P5.2).
    public let authorityObjectIDs: [KnowledgeObject.ID]

    public nonisolated init(
        chunks: [RetrievedChunk] = [],
        events: [Event] = [],
        entities: [Entity] = [],
        relationships: [Relationship] = [],
        summaries: [Summary] = [],
        layersUsed: [RetrievalLayer] = [],
        shortCircuitedAt: RetrievalLayer? = nil,
        walkSteps: [WalkStep] = [],
        genericFacts: [GenericFact] = [],
        authorityObjectIDs: [KnowledgeObject.ID] = []
    ) {
        self.chunks = chunks
        self.events = events
        self.entities = entities
        self.relationships = relationships
        self.summaries = summaries
        self.layersUsed = layersUsed
        self.shortCircuitedAt = shortCircuitedAt
        self.walkSteps = walkSteps
        self.genericFacts = genericFacts
        self.authorityObjectIDs = authorityObjectIDs
    }
}

public struct RetrievedChunk: Codable, Sendable, Hashable {
    public let chunk: Chunk
    public let score: Double
    public let viaLayer: RetrievalLayer

    public nonisolated init(chunk: Chunk, score: Double, viaLayer: RetrievalLayer) {
        self.chunk = chunk
        self.score = score
        self.viaLayer = viaLayer
    }
}
