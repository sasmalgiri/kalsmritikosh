//
//  SensitiveRetrievalPolicy.swift
//  Kalsmritikosh
//
//  OPS-003B — the single policy actor that filters a RetrievalResult against a
//  SensitiveAccessContext. Injected into HybridRetriever and replaces the
//  legacy binary knowledge_objects.privileged post-filter (T18/P6.4 §21) on
//  the access-context-aware retrieve(for:layers:access:) path.
//
//  Filter rules (applied in one pass after batch KO label resolution):
//  1. Chunks: withheld when the chunk's source KO label exceeds the scope ceiling
//     or the KO's lineage is broken; also withheld when not in scope's workspace.
//  2. Events: same — sensitivity + workspace.
//  3. Entities: withheld when the entity's sensitivity exceeds ceiling or the
//     entity is not a member of the scope's workspace.
//  4. Relationships: withheld when the relationship's source KO label exceeds ceiling
//     or the KO is not in the workspace.
//  5. Summaries: document-scoped summaries withheld when their KO label exceeds
//     ceiling or KO not in workspace; other summary scopes fail-closed (no lineage).
//  6. GenericFacts + ClaimEvaluations removed as a pair: a fact is withheld when
//     none of its source blocks appear in any permitted chunk.
//  7. AuthorityObjectIDs: filtered by sensitivity AND workspace — blocked authority
//     KOs must not seed DocumentFitness scoring or authority-chunk injection.
//  8. WalkSteps: denied when any evidence KO is blocked.
//
//  Fail-closed: errors from either repository are treated as total denial so a
//  DB failure can never cause a scope bypass.
//
//  Workspace enforcement: active when workspaceRepository is non-nil AND the
//  scope is not the testUnrestricted() sentinel. Items whose source KO is not
//  in the workspace are denied. Missing or error from the membership check fails
//  closed (deny all).
//

import Foundation
import OSLog

public actor SensitiveRetrievalPolicy {
    private let repository: SensitiveScopeRepository
    private let workspaceRepository: WorkspaceRepository?

    public init(
        repository: SensitiveScopeRepository,
        workspaceRepository: WorkspaceRepository? = nil
    ) {
        self.repository = repository
        self.workspaceRepository = workspaceRepository
    }

    /// Filter `result` to only the items the `access` scope permits.
    /// Returns an `AuthorizedRetrievalResult` with per-type withheld counts.
    /// Never throws — errors are treated as brokenLineage (deny).
    public func filter(
        result: RetrievalResult,
        access: SensitiveAccessContext
    ) async -> AuthorizedRetrievalResult {
        let totalDenial = AuthorizedRetrievalResult(
            result: RetrievalResult(layersUsed: result.layersUsed,
                                    shortCircuitedAt: result.shortCircuitedAt),
            accessContext: access,
            withheldChunkCount: result.chunks.count,
            withheldEventCount: result.events.count,
            withheldEntityCount: result.entities.count,
            withheldSummaryCount: result.summaries.count,
            withheldRelationshipCount: result.relationships.count)

        // ── Step 1: batch sensitivity resolution ──────────────────────────
        var koIDs: Set<UUID> = []
        for c in result.chunks        { koIDs.insert(c.chunk.objectID) }
        for e in result.events        { koIDs.insert(e.sourceObjectID) }
        for e in result.entities      { koIDs.insert(e.sourceObjectID) }
        for r in result.relationships { koIDs.insert(r.sourceObjectID) }
        for s in result.summaries {
            if case .document(let koID) = s.scope { koIDs.insert(koID) }
        }
        for koID in result.authorityObjectIDs { koIDs.insert(koID) }
        for w in result.walkSteps { for koID in w.evidenceObjectIDs { koIDs.insert(koID) } }

        let targets = koIDs.map { SensitiveScopeTarget(kind: .knowledgeObject, id: $0) }
        let resolutions: [SensitiveScopeTarget: ProtectionResolution]
        do {
            resolutions = try await repository.batchResolution(targets)
        } catch {
            KalsmritikoshLog.storage.error(
                "SensitiveRetrievalPolicy: batchResolution failed — denying all. \(error, privacy: .public)")
            return totalDenial
        }

        func permitted(_ koID: UUID) -> Bool {
            let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
            switch resolutions[target] {
            case .resolved(let label):
                return access.scope.permits(label)
            case .brokenLineage:
                return false
            case nil:
                let defaultLabel = ProtectionLabel(sensitivity: .internalLevel, privileged: false)
                return access.scope.permits(defaultLabel)
            }
        }

        // ── Step 2: sensitivity filter ────────────────────────────────────
        var filteredChunks        = result.chunks.filter        { permitted($0.chunk.objectID) }
        var filteredEvents        = result.events.filter        { permitted($0.sourceObjectID) }
        var filteredEntities      = result.entities.filter      { permitted($0.sourceObjectID) }
        var filteredRelationships = result.relationships.filter { permitted($0.sourceObjectID) }
        var filteredSummaries     = result.summaries.filter { summary in
            switch summary.scope {
            case .document(let koID): return permitted(koID)
            default: return false   // fail-closed: no exact lineage → deny
            }
        }
        // Preliminary sensitivity filter on authority KOs — workspace check
        // refines this further in step 3 when enforcement is active.
        var filteredAuthority = result.authorityObjectIDs.filter { permitted($0) }

        // ── Step 3: workspace enforcement ─────────────────────────────────
        // Active when workspaceRepository is wired AND the scope is not the
        // testUnrestricted() sentinel. Repository errors → total denial.
        // Authority KOs are included in the workspace batch so that blocked
        // KOs cannot seed DocumentFitness scoring or authority-chunk injection.
        var enforcedWorkspaceKOs: Set<UUID>? = nil

        if let workspaceRepo = workspaceRepository,
           !access.scope.isTestSentinel {

            let workspaceID = access.scope.workspaceID

            // KO-level workspace check (chunks, events, relationships, summaries, authority KOs)
            let allKoIDs = Array(Set(
                filteredChunks.map { $0.chunk.objectID }
                + filteredEvents.map { $0.sourceObjectID }
                + filteredRelationships.map { $0.sourceObjectID }
                + filteredSummaries.compactMap {
                    if case .document(let id) = $0.scope { return id }
                    return nil
                }
                + filteredAuthority   // authority KOs must also prove workspace membership
            ))
            let workspaceKOs: Set<UUID>
            do {
                workspaceKOs = try await workspaceRepo.koIDsInWorkspace(allKoIDs, workspaceID: workspaceID)
            } catch {
                KalsmritikoshLog.storage.error(
                    "SensitiveRetrievalPolicy: workspace KO membership check failed — denying all. \(error, privacy: .public)")
                return totalDenial
            }
            enforcedWorkspaceKOs = workspaceKOs
            filteredChunks        = filteredChunks.filter        { workspaceKOs.contains($0.chunk.objectID) }
            filteredEvents        = filteredEvents.filter        { workspaceKOs.contains($0.sourceObjectID) }
            filteredRelationships = filteredRelationships.filter { workspaceKOs.contains($0.sourceObjectID) }
            filteredSummaries     = filteredSummaries.filter {
                guard case .document(let koID) = $0.scope else { return false }
                return workspaceKOs.contains(koID)
            }
            filteredAuthority     = filteredAuthority.filter     { workspaceKOs.contains($0) }

            // Entity-level workspace check (workspace_entities table)
            let entityIDs = filteredEntities.map { $0.id }
            let workspaceEntityIDs: Set<UUID>
            do {
                workspaceEntityIDs = try await workspaceRepo.entityIDsInWorkspace(entityIDs, workspaceID: workspaceID)
            } catch {
                KalsmritikoshLog.storage.error(
                    "SensitiveRetrievalPolicy: workspace entity membership check failed — denying all. \(error, privacy: .public)")
                return totalDenial
            }
            filteredEntities = filteredEntities.filter { workspaceEntityIDs.contains($0.id) }
        }

        // ── Step 4: GenericFacts + ClaimEvaluations ───────────────────────
        let permittedBlockIDs = Set(filteredChunks.compactMap(\.chunk.evidenceBlockID))
        let filteredFacts = result.genericFacts.filter { fact in
            guard !fact.sourceBlockIDs.isEmpty else { return true }
            return fact.sourceBlockIDs.contains { permittedBlockIDs.contains($0) }
        }
        let filteredFactIDs = Set(filteredFacts.map(\.id))
        let filteredEvals   = result.claimEvaluations.filter { filteredFactIDs.contains($0.id) }

        // ── Step 5: WalkSteps (authority KOs already filtered above) ──────
        let filteredWalkSteps = result.walkSteps.filter { step in
            step.evidenceObjectIDs.allSatisfy { permitted($0) }
        }

        // ── Step 6: tally + return ────────────────────────────────────────
        let withheldChunks        = result.chunks.count        - filteredChunks.count
        let withheldEvents        = result.events.count        - filteredEvents.count
        let withheldEntities      = result.entities.count      - filteredEntities.count
        let withheldRelationships = result.relationships.count - filteredRelationships.count
        let withheldSummaries     = result.summaries.count     - filteredSummaries.count
        let totalWithheld = withheldChunks + withheldEvents + withheldEntities
            + withheldRelationships + withheldSummaries

        if totalWithheld > 0 {
            KalsmritikoshLog.storage.notice(
                "SensitiveRetrievalPolicy: withheld \(withheldChunks, privacy: .public) chunks, \(withheldEvents, privacy: .public) events, \(withheldEntities, privacy: .public) entities, \(withheldRelationships, privacy: .public) rels, \(withheldSummaries, privacy: .public) summaries.")
        }

        return AuthorizedRetrievalResult(
            result: RetrievalResult(
                chunks:             filteredChunks,
                events:             filteredEvents,
                entities:           filteredEntities,
                relationships:      filteredRelationships,
                summaries:          filteredSummaries,
                layersUsed:         result.layersUsed,
                shortCircuitedAt:   result.shortCircuitedAt,
                walkSteps:          filteredWalkSteps,
                genericFacts:       filteredFacts,
                claimEvaluations:   filteredEvals,
                authorityObjectIDs: filteredAuthority
            ),
            accessContext:             access,
            withheldChunkCount:        withheldChunks,
            withheldEventCount:        withheldEvents,
            withheldEntityCount:       withheldEntities,
            withheldSummaryCount:      withheldSummaries,
            withheldRelationshipCount: withheldRelationships
        )
    }
}
