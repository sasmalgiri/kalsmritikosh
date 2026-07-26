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

    /// OPS-003B — scope-aware retrieve. Filters the result through the
    /// SensitiveRetrievalPolicy before returning. The default extension
    /// wraps the unfiltered result with zero withheld counts; HybridRetriever
    /// overrides this with real policy filtering.
    func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer],
        access: SensitiveAccessContext
    ) async throws -> AuthorizedRetrievalResult
}

public extension Retriever {
    func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer],
        access: SensitiveAccessContext
    ) async throws -> AuthorizedRetrievalResult {
        let result = try await retrieve(for: intent, layers: layers)
        return AuthorizedRetrievalResult(result: result, accessContext: access)
    }
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
    /// DEPRECATED compatibility field — the surfaced facts as raw GenericFacts. The
    /// canonical output is `claimEvaluations` (S0.5 item 2 C2); this is retained only for
    /// any residual reader and holds the facts whose evaluation may surface.
    public let genericFacts: [GenericFact]
    /// S0.5 item 2 C2 — the CANONICAL per-claim assertability evaluations, produced once at
    /// retrieval (with real evidence context) and threaded UNCHANGED to the expert/brain and
    /// export validator. `refuse` decisions are already excluded. This is the single source
    /// of truth for whether/how a GenericFact-derived claim may surface.
    public let claimEvaluations: [ClaimEvaluation]
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
        claimEvaluations: [ClaimEvaluation] = [],
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
        self.claimEvaluations = claimEvaluations
        self.authorityObjectIDs = authorityObjectIDs
    }

    // Backward-compatible Codable: pre-C2 payloads have no `claimEvaluations` key (and older
    // ones may lack walkSteps/genericFacts/authorityObjectIDs) — decode those as empty rather
    // than failing the whole result. (S0.5 item 2 C2.1)
    private enum CodingKeys: String, CodingKey {
        case chunks, events, entities, relationships, summaries, layersUsed
        case shortCircuitedAt, walkSteps, genericFacts, claimEvaluations, authorityObjectIDs
    }
    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chunks = try c.decodeIfPresent([RetrievedChunk].self, forKey: .chunks) ?? []
        self.events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
        self.entities = try c.decodeIfPresent([Entity].self, forKey: .entities) ?? []
        self.relationships = try c.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        self.summaries = try c.decodeIfPresent([Summary].self, forKey: .summaries) ?? []
        self.layersUsed = try c.decodeIfPresent([RetrievalLayer].self, forKey: .layersUsed) ?? []
        self.shortCircuitedAt = try c.decodeIfPresent(RetrievalLayer.self, forKey: .shortCircuitedAt)
        self.walkSteps = try c.decodeIfPresent([WalkStep].self, forKey: .walkSteps) ?? []
        self.genericFacts = try c.decodeIfPresent([GenericFact].self, forKey: .genericFacts) ?? []
        self.claimEvaluations = try c.decodeIfPresent([ClaimEvaluation].self, forKey: .claimEvaluations) ?? []
        self.authorityObjectIDs = try c.decodeIfPresent([KnowledgeObject.ID].self, forKey: .authorityObjectIDs) ?? []
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
