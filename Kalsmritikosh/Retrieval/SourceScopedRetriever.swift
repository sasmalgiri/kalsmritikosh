//
//  SourceScopedRetriever.swift
//  Kalsmritikosh
//
//  INV-01-B2 — a persona-NEUTRAL decorator that restricts a shared Retriever's output to an authorized
//  set of source versions. It does NOT re-implement or re-rank retrieval: it delegates to the wrapped
//  retriever (which already applies the SensitiveRetrievalPolicy on the access-aware path) and then
//  applies the pure SourceScopeRetrievalPolicy. Composition order is SensitiveScope → case scope; both
//  are exclusion-only intersections, so neither can weaken the other and the final evidence satisfies
//  BOTH dimensions.
//
//  When the injected scope is `.unscoped` this is a transparent pass-through (whole-workspace
//  retrieval), so wrapping a retriever for a non-case path changes nothing. When active it is
//  FAIL-CLOSED: every corrective / Full-Evidence re-retrieval flows back through this same decorator, so
//  the boundary cannot be bypassed by a second pass.
//
//  Resolution of indirectly-anchored items (events/entities/relationships/document summaries/authority
//  documents/walk steps → their source version; generic facts + legacy chunks → their blocks' version)
//  is built here from the shared EvidenceStore, so the pure policy stays free of DB knowledge.
//

import Foundation

public actor SourceScopedRetriever: Retriever {
    private let base: any Retriever
    private let evidence: EvidenceStore
    private let scope: RetrievalSourceScope
    private let scopedRecall: ScopedRecall?

    /// F08 — the base retriever ranks the WHOLE corpus and truncates to its limits before this
    /// decorator filters, so a small case's evidence can be crowded out by higher-ranked items from
    /// outside it. When wired, recall passes restricted to the authorized versions — the scope
    /// predicate INSIDE each candidate query, before its LIMIT — recover that evidence lane by lane:
    /// keyword (FTS), vector (the scan restricted to the case's chunks), events (by timeframe),
    /// entities (by hint) and graph (relationships touching the case's entities). `sensitivePolicy`
    /// must mirror the base: pass the policy the base applies at retrieval, or nil when the base (like
    /// the production HybridRetriever) leaves sensitivity to the downstream ExpertContext — recovered
    /// items then flow exactly where base items do. Lanes whose dependency is nil are skipped.
    public struct ScopedRecall: Sendable {
        public let chunks: ChunksRepository
        public let sensitivePolicy: SensitiveRetrievalPolicy?
        public let limit: Int
        public let vectors: (any VectorStore)?
        public let embedder: (any Embedder)?
        public let events: EventsRepository?
        public let entities: EntitiesRepository?
        public let relationships: RelationshipsRepository?
        /// Most chunks a scoped vector scan compares against (its memory/latency bound).
        public let vectorCandidateCap: Int
        public init(chunks: ChunksRepository, sensitivePolicy: SensitiveRetrievalPolicy?, limit: Int = 25,
                    vectors: (any VectorStore)? = nil, embedder: (any Embedder)? = nil,
                    events: EventsRepository? = nil, entities: EntitiesRepository? = nil,
                    relationships: RelationshipsRepository? = nil, vectorCandidateCap: Int = 20_000) {
            self.chunks = chunks
            self.sensitivePolicy = sensitivePolicy
            self.limit = limit
            self.vectors = vectors
            self.embedder = embedder
            self.events = events
            self.entities = entities
            self.relationships = relationships
            self.vectorCandidateCap = vectorCandidateCap
        }
    }

    public init(base: any Retriever, evidence: EvidenceStore, scope: RetrievalSourceScope,
                scopedRecall: ScopedRecall? = nil) {
        self.base = base
        self.evidence = evidence
        self.scope = scope
        self.scopedRecall = scopedRecall
    }

    // Non-access path (protocol requirement). Still enforces the source scope so no caller can obtain
    // unscoped evidence through the bare overload while a case is active.
    public func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
        let base = try await base.retrieve(for: intent, layers: layers)
        guard scope.isActive else { return base }
        let resolution = try await buildResolution(for: base)
        return SourceScopeRetrievalPolicy.filter(base, scope: scope, resolution: resolution).result
    }

    // Access-aware path: the wrapped retriever applies SensitiveScope first; we then intersect with the
    // case scope. The returned AuthorizedRetrievalResult sums both dimensions' withheld counts so the
    // quality strip can report total withholding (case-scope exclusions are additionally available via
    // the diagnostics path if needed).
    public func retrieve(
        for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext
    ) async throws -> AuthorizedRetrievalResult {
        let authorized = try await base.retrieve(for: intent, layers: layers, access: access)
        guard scope.isActive else { return authorized }
        let resolution = try await buildResolution(for: authorized.result)
        let scoped = SourceScopeRetrievalPolicy.filter(authorized.result, scope: scope, resolution: resolution)
        var finalResult = scoped.result
        var extra = RecallWithheld()
        if let recall = scopedRecall, !scope.authorizedSourceVersionIDs.isEmpty {
            let recovered = try await recoverScopedChunks(intent: intent, alreadyHave: scoped.result, recall: recall, access: access)
            finalResult = recovered.result
            extra = recovered.withheld
        }
        return AuthorizedRetrievalResult(
            result: finalResult,
            accessContext: authorized.accessContext,
            withheldChunkCount: authorized.withheldChunkCount + scoped.withheldChunkCount + extra.chunks,
            withheldEventCount: authorized.withheldEventCount + scoped.withheldEventCount + extra.events,
            withheldEntityCount: authorized.withheldEntityCount + scoped.withheldEntityCount + extra.entities,
            withheldSummaryCount: authorized.withheldSummaryCount + scoped.withheldSummaryCount,
            withheldRelationshipCount: authorized.withheldRelationshipCount + scoped.withheldRelationshipCount + extra.relationships)
    }

    /// Per-kind counts of recovered items withheld by the mirrored policies.
    struct RecallWithheld {
        var chunks = 0, events = 0, entities = 0, relationships = 0
        mutating func add(chunks c: Int, events e: Int, entities n: Int, relationships r: Int) {
            chunks += c; events += e; entities += n; relationships += r
        }
    }

    /// F08 — recall passes restricted to the authorized versions (predicate inside each query, before
    /// LIMIT). Recovered items pass the mirrored sensitivity policy (when the base applies one) and the
    /// same case-scope filter, then join AFTER the base-ranked items — they add recall, never displace
    /// a base hit. Returns the merged result and how many recovered items were withheld.
    private func recoverScopedChunks(intent: UserIntent, alreadyHave result: RetrievalResult,
                                     recall: ScopedRecall, access: SensitiveAccessContext) async throws
                                     -> (result: RetrievalResult, withheld: RecallWithheld) {
        let versions = scope.authorizedSourceVersionIDs
        let haveChunks = Set(result.chunks.map(\.chunk.id))
        var chunkIDs = Set<Chunk.ID>()
        var freshChunks: [RetrievedChunk] = []
        func addChunk(_ c: Chunk, score: Double, via layer: RetrievalLayer) {
            guard !haveChunks.contains(c.id), chunkIDs.insert(c.id).inserted else { return }
            freshChunks.append(RetrievedChunk(chunk: c, score: score, viaLayer: layer))
        }
        // Keyword.
        for c in try await recall.chunks.searchFTS(intent.rawQuestion, limit: recall.limit, sourceVersionIDs: versions) {
            addChunk(c, score: 0.5, via: .metadata)
        }
        // Vector — the scan compares only the case's own chunks, so outside neighbours cannot fill k.
        if let vectors = recall.vectors, let embedder = recall.embedder {
            let query = await embedder.embed(intent.rawQuestion)
            if !query.isEmpty {
                let candidates = try await recall.chunks.chunkIDs(sourceVersionIDs: versions, limit: recall.vectorCandidateCap)
                if !candidates.isEmpty {
                    let hits = try await vectors.nearest(to: query, limit: recall.limit, candidateChunkIDs: candidates)
                    let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.chunkID, $0.score) })
                    for c in try await recall.chunks.findByIDs(hits.map(\.chunkID), sourceVersionIDs: versions) {
                        addChunk(c, score: byID[c.id] ?? 0.5, via: .vector)
                    }
                }
            }
        }
        // Events — the case's own timeline (the question's timeframe when it has one).
        let haveEvents = Set(result.events.map(\.id))
        var freshEvents: [Event] = []
        if let events = recall.events {
            for e in try await events.forSourceVersions(versions, start: intent.timeframe?.start, end: intent.timeframe?.end,
                                                         limit: recall.limit * 4)
            where !haveEvents.contains(e.id) { freshEvents.append(e) }
        }
        // Entities — the question's hints matched only among the case's entities.
        let haveEntities = Set(result.entities.map(\.id))
        var freshEntities: [Entity] = []
        if let entities = recall.entities {
            var seen = haveEntities
            for hint in intent.entityHints.prefix(8) where !hint.isEmpty {
                for e in try await entities.find(byValue: hint, sourceVersionIDs: versions, limit: recall.limit)
                where seen.insert(e.id).inserted { freshEntities.append(e) }
            }
        }
        // Graph — relationships of the case that touch any entity now in hand.
        var freshRelationships: [Relationship] = []
        if let relationships = recall.relationships {
            let anchors = Set(result.entities.map(\.id) + freshEntities.map(\.id))
            let have = Set(result.relationships.map(\.id))
            for r in try await relationships.touching(anchors, sourceVersionIDs: versions, limit: recall.limit * 4)
            where !have.contains(r.id) { freshRelationships.append(r) }
        }
        guard !(freshChunks.isEmpty && freshEvents.isEmpty && freshEntities.isEmpty && freshRelationships.isEmpty) else {
            return (result, RecallWithheld())
        }

        var candidate = RetrievalResult(chunks: freshChunks, events: freshEvents, entities: freshEntities,
                                        relationships: freshRelationships, layersUsed: result.layersUsed)
        var withheld = RecallWithheld()
        if let policy = recall.sensitivePolicy {
            let filtered = await policy.filter(result: candidate, access: access)
            candidate = filtered.result
            withheld.add(chunks: filtered.withheldChunkCount, events: filtered.withheldEventCount,
                         entities: filtered.withheldEntityCount, relationships: filtered.withheldRelationshipCount)
        }
        let rescoped = SourceScopeRetrievalPolicy.filter(candidate, scope: scope,
                                                         resolution: try await buildResolution(for: candidate))
        withheld.add(chunks: rescoped.withheldChunkCount, events: rescoped.withheldEventCount,
                     entities: rescoped.withheldEntityCount, relationships: rescoped.withheldRelationshipCount)
        let r = rescoped.result
        guard !(r.chunks.isEmpty && r.events.isEmpty && r.entities.isEmpty && r.relationships.isEmpty) else {
            return (result, withheld)
        }
        let merged = RetrievalResult(
            chunks: result.chunks + r.chunks, events: result.events + r.events, entities: result.entities + r.entities,
            relationships: result.relationships + r.relationships, summaries: result.summaries,
            layersUsed: result.layersUsed, shortCircuitedAt: result.shortCircuitedAt,
            walkSteps: result.walkSteps, genericFacts: result.genericFacts, claimEvaluations: result.claimEvaluations,
            authorityObjectIDs: result.authorityObjectIDs)
        return (merged, withheld)
    }

    /// Build the id→sourceVersion maps for exactly the items present in `result`, using the shared
    /// EvidenceStore. Chunks that already carry `sourceVersionID` need no lookup; only legacy (nil)
    /// chunks contribute a block to resolve.
    private func buildResolution(for result: RetrievalResult) async throws -> SourceScopeResolution {
        // KnowledgeObject ids referenced by indirectly-anchored collections.
        var objectIDs = Set<UUID>()
        for e in result.events { objectIDs.insert(e.sourceObjectID) }
        for e in result.entities { objectIDs.insert(e.sourceObjectID) }
        for r in result.relationships { objectIDs.insert(r.sourceObjectID) }
        for s in result.summaries { if case .document(let ko) = s.scope { objectIDs.insert(ko) } }
        for a in result.authorityObjectIDs { objectIDs.insert(a) }
        for w in result.walkSteps { for id in w.evidenceObjectIDs { objectIDs.insert(id) } }

        var objectVersion = [UUID: UUID]()
        for ko in objectIDs {
            if let v = try await evidence.currentVersionID(forObject: ko) { objectVersion[ko] = v }
        }

        // Block ids: generic-fact source blocks + legacy chunks whose version is unproven.
        var blockIDs = Set<UUID>()
        for f in result.genericFacts { for b in f.sourceBlockIDs { blockIDs.insert(b) } }
        for rc in result.chunks where rc.chunk.sourceVersionID == nil {
            for b in rc.chunk.allBlockIDs { blockIDs.insert(b) }
        }
        var blockVersion = [UUID: UUID]()
        if !blockIDs.isEmpty {
            for ref in try await evidence.resolveEvidenceBlocks(Array(blockIDs)) {
                if let v = ref.sourceVersionID { blockVersion[ref.blockID] = v }
            }
        }
        return SourceScopeResolution(blockVersion: blockVersion, objectVersion: objectVersion)
    }
}
