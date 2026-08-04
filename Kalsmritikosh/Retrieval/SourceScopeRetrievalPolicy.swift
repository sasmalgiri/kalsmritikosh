//
//  SourceScopeRetrievalPolicy.swift
//  Kalsmritikosh
//
//  INV-01-B2 — a persona-NEUTRAL, deterministic restriction of retrieved evidence to a fixed set of
//  authorized source versions. This is a SCOPE rule, not a relevance rule: it composes AFTER the shared
//  HybridRetriever (alongside the SensitiveRetrievalPolicy) and NEVER re-ranks or re-scores. The two
//  restrictions are independent dimensions — an item survives only if it is BOTH permitted by
//  SensitiveScope AND authorized by the active source scope; neither may weaken the other.
//
//  FAIL-CLOSED. When a scope is active, any retrieved item that cannot be resolved to an authorized
//  source version is EXCLUDED — a missing/unknown source identity is never treated as authorization.
//  When the scope is inactive (`.unscoped`) the filter is a no-op (whole-workspace retrieval), so
//  non-case query paths are byte-for-byte unchanged.
//
//  The policy is PURE: it reads only the RetrievalResult and a precomputed SourceScopeResolution (the
//  id→sourceVersion maps the caller builds from the ledger). No DB, no LLM, no clock, no mutation. This
//  keeps model-field/repository knowledge in the composing decorator and the boundary logic fully
//  unit-testable in isolation.
//

import Foundation

/// The concrete authorized source-version allow-set for one retrieval. `isActive == false` means the
/// caller is NOT running inside a case (whole-workspace retrieval) and the filter is a no-op.
public nonisolated struct RetrievalSourceScope: Sendable, Equatable {
    public let isActive: Bool
    public let authorizedSourceVersionIDs: Set<UUID>

    public nonisolated init(isActive: Bool, authorizedSourceVersionIDs: Set<UUID>) {
        self.isActive = isActive
        self.authorizedSourceVersionIDs = authorizedSourceVersionIDs
    }

    /// No scoping — whole-workspace retrieval (the non-case path).
    public static let unscoped = RetrievalSourceScope(isActive: false, authorizedSourceVersionIDs: [])

    /// An ACTIVE scope authorizing exactly `ids`. An empty set authorizes nothing (honest empty result,
    /// never a silent widen to the workspace).
    public static func authorizing(_ ids: Set<UUID>) -> RetrievalSourceScope {
        RetrievalSourceScope(isActive: true, authorizedSourceVersionIDs: ids)
    }
}

/// Precomputed maps that resolve indirectly-anchored retrieved items to their source version. The
/// composing decorator builds these from the ledger (chunks carry `sourceVersionID` directly; blocks and
/// KnowledgeObjects are resolved through it). Absent keys resolve to nil → fail-closed exclusion.
public nonisolated struct SourceScopeResolution: Sendable, Equatable {
    /// evidenceBlockID → sourceVersionID. The legacy fallback for chunks whose `sourceVersionID` is nil,
    /// and the resolution basis for block-derived generic facts.
    public let blockVersion: [UUID: UUID]
    /// KnowledgeObject.ID → sourceVersionID. For events / entities / relationships / document summaries /
    /// walk steps / authority documents, which reference a KnowledgeObject rather than a version directly.
    public let objectVersion: [UUID: UUID]

    public nonisolated init(blockVersion: [UUID: UUID] = [:], objectVersion: [UUID: UUID] = [:]) {
        self.blockVersion = blockVersion
        self.objectVersion = objectVersion
    }
}

/// The filtered result plus per-collection withheld counts (for the Advanced-mode / diagnostics
/// explanation: "N items outside this investigation's scope"). Mirrors `AuthorizedRetrievalResult` in
/// role but records CASE-SCOPE exclusions, kept distinct from SensitiveScope withholding.
public nonisolated struct ScopedRetrievalResult: Sendable {
    public let result: RetrievalResult
    public let scope: RetrievalSourceScope
    public let withheldChunkCount: Int
    public let withheldEventCount: Int
    public let withheldEntityCount: Int
    public let withheldRelationshipCount: Int
    public let withheldSummaryCount: Int
    public let withheldGenericFactCount: Int
    public let withheldClaimEvaluationCount: Int
    public let withheldWalkStepCount: Int
    public let withheldAuthorityCount: Int

    public nonisolated var totalWithheld: Int {
        withheldChunkCount + withheldEventCount + withheldEntityCount + withheldRelationshipCount
            + withheldSummaryCount + withheldGenericFactCount + withheldClaimEvaluationCount
            + withheldWalkStepCount + withheldAuthorityCount
    }
    public nonisolated var anyWithheld: Bool { totalWithheld > 0 }

    public nonisolated init(
        result: RetrievalResult, scope: RetrievalSourceScope,
        withheldChunkCount: Int = 0, withheldEventCount: Int = 0, withheldEntityCount: Int = 0,
        withheldRelationshipCount: Int = 0, withheldSummaryCount: Int = 0, withheldGenericFactCount: Int = 0,
        withheldClaimEvaluationCount: Int = 0, withheldWalkStepCount: Int = 0, withheldAuthorityCount: Int = 0
    ) {
        self.result = result; self.scope = scope
        self.withheldChunkCount = withheldChunkCount; self.withheldEventCount = withheldEventCount
        self.withheldEntityCount = withheldEntityCount; self.withheldRelationshipCount = withheldRelationshipCount
        self.withheldSummaryCount = withheldSummaryCount; self.withheldGenericFactCount = withheldGenericFactCount
        self.withheldClaimEvaluationCount = withheldClaimEvaluationCount; self.withheldWalkStepCount = withheldWalkStepCount
        self.withheldAuthorityCount = withheldAuthorityCount
    }
}

public enum SourceScopeRetrievalPolicy {

    /// Restrict `result` to items anchored to an authorized source version. Deterministic, fail-closed,
    /// no re-ranking. Inactive scope → returned unchanged.
    public nonisolated static func filter(
        _ result: RetrievalResult, scope: RetrievalSourceScope, resolution: SourceScopeResolution
    ) -> ScopedRetrievalResult {
        guard scope.isActive else { return ScopedRetrievalResult(result: result, scope: scope) }
        let allowed = scope.authorizedSourceVersionIDs

        func authorizedVersion(_ id: UUID?) -> Bool {
            guard let id else { return false }             // unresolved → fail-closed
            return allowed.contains(id)
        }
        func chunkVersion(_ c: Chunk) -> UUID? {
            c.sourceVersionID ?? c.evidenceBlockID.flatMap { resolution.blockVersion[$0] }
        }

        // Source-anchored collections — resolved directly to a version.
        let keptChunks = result.chunks.filter { authorizedVersion(chunkVersion($0.chunk)) }
        let keptEvents = result.events.filter { authorizedVersion(resolution.objectVersion[$0.sourceObjectID]) }
        let keptEntities = result.entities.filter { authorizedVersion(resolution.objectVersion[$0.sourceObjectID]) }
        let keptRelationships = result.relationships.filter { authorizedVersion(resolution.objectVersion[$0.sourceObjectID]) }
        // Summaries: only a document-scoped summary has a single source object; every other scope
        // (community/global/…) has no single anchor → fail-closed drop while a case is active.
        let keptSummaries = result.summaries.filter { summary in
            if case .document(let ko) = summary.scope { return authorizedVersion(resolution.objectVersion[ko]) }
            return false
        }
        // Generic facts: authorized only when EVERY source block resolves to an authorized version
        // (a fact partly derived from out-of-scope material must not surface). Empty → fail-closed.
        let keptFacts = result.genericFacts.filter { fact in
            !fact.sourceBlockIDs.isEmpty
                && fact.sourceBlockIDs.allSatisfy { authorizedVersion(resolution.blockVersion[$0]) }
        }
        // Claim evaluations carry the ORIGINAL fact id as their id — keep exactly those whose fact survived.
        let keptFactIDs = Set(keptFacts.map(\.id))
        let keptClaimEvaluations = result.claimEvaluations.filter { keptFactIDs.contains($0.id) }
        // Walk steps: authorized only when every evidence object resolves to an authorized version.
        let keptWalkSteps = result.walkSteps.filter { step in
            !step.evidenceObjectIDs.isEmpty
                && step.evidenceObjectIDs.allSatisfy { authorizedVersion(resolution.objectVersion[$0]) }
        }
        let keptAuthority = result.authorityObjectIDs.filter { authorizedVersion(resolution.objectVersion[$0]) }

        let filtered = RetrievalResult(
            chunks: keptChunks, events: keptEvents, entities: keptEntities, relationships: keptRelationships,
            summaries: keptSummaries, layersUsed: result.layersUsed, shortCircuitedAt: result.shortCircuitedAt,
            walkSteps: keptWalkSteps, genericFacts: keptFacts, claimEvaluations: keptClaimEvaluations,
            authorityObjectIDs: keptAuthority)

        return ScopedRetrievalResult(
            result: filtered, scope: scope,
            withheldChunkCount: result.chunks.count - keptChunks.count,
            withheldEventCount: result.events.count - keptEvents.count,
            withheldEntityCount: result.entities.count - keptEntities.count,
            withheldRelationshipCount: result.relationships.count - keptRelationships.count,
            withheldSummaryCount: result.summaries.count - keptSummaries.count,
            withheldGenericFactCount: result.genericFacts.count - keptFacts.count,
            withheldClaimEvaluationCount: result.claimEvaluations.count - keptClaimEvaluations.count,
            withheldWalkStepCount: result.walkSteps.count - keptWalkSteps.count,
            withheldAuthorityCount: result.authorityObjectIDs.count - keptAuthority.count)
    }
}
