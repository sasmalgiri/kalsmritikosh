//
//  ScreenScopeAuthorizer.swift
//  Kalsmritikosh
//
//  OPS-003D.1 — fail-closed screen-level gate for view layers.
//  Uses batchResolution directly (not SensitiveRetrievalPolicy) so workspace
//  membership enforcement is not mixed with per-KO sensitivity checking.
//  Internal sentinel UUID 00000001-... is distinct from the test sentinel
//  (00000000-...) and the global-owner retrieval bypass (00000002-...).
//
//  OPS-003D.1.1 changes:
//  - Removed .workspace(UUID) from ScreenAccessBoundary (unimplemented membership
//    enforcement removed rather than left as a false guarantee).
//  - authorize(target:boundary:) generic form added; old authorize(_:boundary:) is a
//    convenience wrapper calling the generic form.
//

import Foundation
import OSLog

/// Determines the boundary for a screen-level filter.
/// Only `.globalOwner` is available; a workspace-scoped boundary requires workspace
/// membership enforcement that is not yet implemented.
public enum ScreenAccessBoundary: Sendable {
    /// The global owner view — all KOs are in scope; only sensitivity is checked.
    case globalOwner
}

/// Fail-closed screen-level scope gate for view layers.
/// Nil repo, any repository error, broken lineage, or a missing resolution all
/// deny access — nothing is shown rather than something that should not be.
public actor ScreenScopeAuthorizer {

    private let repository: SensitiveScopeRepository?

    // Internal screen-purpose sentinel — not the test sentinel (00000000-...) and
    // not the global-owner retrieval bypass (00000002-...).
    private static let screenSentinel = UUID(uuidString: "00000001-0000-0000-0000-000000000000")!

    public init(repository: SensitiveScopeRepository?) {
        self.repository = repository
    }

    // MARK: - Filter

    public func filterChunks(_ chunks: [Chunk],
                              boundary: ScreenAccessBoundary) async -> [Chunk] {
        guard let repo = repository, !chunks.isEmpty else { return [] }
        let koIDs = Array(Set(chunks.map(\.objectID)))
        let targets = koIDs.map { SensitiveScopeTarget(kind: .knowledgeObject, id: $0) }
        let resolutions: [SensitiveScopeTarget: ProtectionResolution]
        do {
            resolutions = try await repo.batchResolution(targets)
        } catch {
            KalsmritikoshLog.storage.error(
                "ScreenScopeAuthorizer.filterChunks: batchResolution threw — denying all. \(error, privacy: .public)")
            return []
        }
        let scope = makeScope(for: boundary)
        let permitted = Set(koIDs.filter {
            check(SensitiveScopeTarget(kind: .knowledgeObject, id: $0),
                  resolutions: resolutions, scope: scope)
        })
        return chunks.filter { permitted.contains($0.objectID) }
    }

    public func filterRows(_ rows: [KnowledgeObjectSummaryRow],
                            boundary: ScreenAccessBoundary) async -> [KnowledgeObjectSummaryRow] {
        guard let repo = repository, !rows.isEmpty else { return [] }
        let koIDs = rows.map(\.id)
        let targets = koIDs.map { SensitiveScopeTarget(kind: .knowledgeObject, id: $0) }
        let resolutions: [SensitiveScopeTarget: ProtectionResolution]
        do {
            resolutions = try await repo.batchResolution(targets)
        } catch {
            KalsmritikoshLog.storage.error(
                "ScreenScopeAuthorizer.filterRows: batchResolution threw — denying all. \(error, privacy: .public)")
            return []
        }
        let scope = makeScope(for: boundary)
        return rows.filter {
            check(SensitiveScopeTarget(kind: .knowledgeObject, id: $0.id),
                  resolutions: resolutions, scope: scope)
        }
    }

    // MARK: - Authorize (generic — accepts any SensitiveScopeTarget kind)

    /// Returns `false` when the repository is nil, the call throws, the resolution
    /// is brokenLineage, or the target key is absent from the batch result.
    public func authorize(target: SensitiveScopeTarget,
                          boundary: ScreenAccessBoundary) async -> Bool {
        guard let repo = repository else { return false }
        let resolutions: [SensitiveScopeTarget: ProtectionResolution]
        do {
            resolutions = try await repo.batchResolution([target])
        } catch {
            KalsmritikoshLog.storage.error(
                "ScreenScopeAuthorizer.authorize: batchResolution threw — denying. \(error, privacy: .public)")
            return false
        }
        let scope = makeScope(for: boundary)
        return check(target, resolutions: resolutions, scope: scope)
    }

    /// Convenience wrapper for KnowledgeObject targets.
    public func authorize(_ koID: UUID, boundary: ScreenAccessBoundary) async -> Bool {
        await authorize(target: SensitiveScopeTarget(kind: .knowledgeObject, id: koID),
                        boundary: boundary)
    }

    // MARK: - Helpers

    private func makeScope(for boundary: ScreenAccessBoundary) -> SensitiveScope {
        let wsID: UUID
        switch boundary {
        case .globalOwner: wsID = Self.screenSentinel
        }
        return SensitiveScope(
            workspaceID: wsID,
            maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false,
            purpose: .screen)
    }

    private func check(_ target: SensitiveScopeTarget,
                       resolutions: [SensitiveScopeTarget: ProtectionResolution],
                       scope: SensitiveScope) -> Bool {
        switch resolutions[target] {
        case .resolved(let label): return scope.permits(label)
        case .brokenLineage:       return false
        case nil:                  return false
        }
    }
}
