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
    /// decorator filters, so a small case's evidence can be crowded out by higher-ranked chunks from
    /// outside it. When wired, a keyword pass restricted to the authorized versions (inside the query,
    /// before LIMIT) recovers those chunks. `sensitivePolicy` must mirror the base: pass the policy
    /// the base applies at retrieval, or nil when the base (like the production HybridRetriever)
    /// leaves sensitivity to the downstream ExpertContext — supplemental chunks then flow exactly
    /// where base chunks do.
    public struct ScopedRecall: Sendable {
        public let chunks: ChunksRepository
        public let sensitivePolicy: SensitiveRetrievalPolicy?
        public let limit: Int
        public init(chunks: ChunksRepository, sensitivePolicy: SensitiveRetrievalPolicy?, limit: Int = 25) {
            self.chunks = chunks
            self.sensitivePolicy = sensitivePolicy
            self.limit = limit
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
        var extraWithheld = 0
        if let recall = scopedRecall, !scope.authorizedSourceVersionIDs.isEmpty {
            let recovered = try await recoverScopedChunks(intent: intent, alreadyHave: scoped.result, recall: recall, access: access)
            finalResult = recovered.result
            extraWithheld = recovered.withheld
        }
        return AuthorizedRetrievalResult(
            result: finalResult,
            accessContext: authorized.accessContext,
            withheldChunkCount: authorized.withheldChunkCount + scoped.withheldChunkCount + extraWithheld,
            withheldEventCount: authorized.withheldEventCount + scoped.withheldEventCount,
            withheldEntityCount: authorized.withheldEntityCount + scoped.withheldEntityCount,
            withheldSummaryCount: authorized.withheldSummaryCount + scoped.withheldSummaryCount,
            withheldRelationshipCount: authorized.withheldRelationshipCount + scoped.withheldRelationshipCount)
    }

    /// F08 — keyword pass restricted to the authorized versions (predicate inside the query, before
    /// LIMIT). New chunks pass the mirrored sensitivity policy (when the base applies one) and the
    /// same case-scope filter, then join AFTER the base-ranked chunks — they add recall, never
    /// displace a base hit. Returns the merged result and how many recovered chunks were withheld.
    private func recoverScopedChunks(intent: UserIntent, alreadyHave result: RetrievalResult,
                                     recall: ScopedRecall, access: SensitiveAccessContext) async throws
                                     -> (result: RetrievalResult, withheld: Int) {
        let have = Set(result.chunks.map(\.chunk.id))
        let hits = try await recall.chunks.searchFTS(intent.rawQuestion, limit: recall.limit,
                                                      sourceVersionIDs: scope.authorizedSourceVersionIDs)
        let fresh = hits.filter { !have.contains($0.id) }.map { RetrievedChunk(chunk: $0, score: 0.5, viaLayer: .metadata) }
        guard !fresh.isEmpty else { return (result, 0) }
        var candidate = RetrievalResult(chunks: fresh, layersUsed: result.layersUsed)
        var withheld = 0
        if let policy = recall.sensitivePolicy {
            let filtered = await policy.filter(result: candidate, access: access)
            candidate = filtered.result
            withheld += filtered.withheldChunkCount
        }
        let rescoped = SourceScopeRetrievalPolicy.filter(candidate, scope: scope,
                                                         resolution: try await buildResolution(for: candidate))
        withheld += rescoped.withheldChunkCount
        guard !rescoped.result.chunks.isEmpty else { return (result, withheld) }
        let merged = RetrievalResult(
            chunks: result.chunks + rescoped.result.chunks, events: result.events, entities: result.entities,
            relationships: result.relationships, summaries: result.summaries,
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
