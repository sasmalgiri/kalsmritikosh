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

import Foundation
import OSLog

/// Determines how a screen-level filter should bound its subject set.
public enum ScreenAccessBoundary: Sendable {
    /// The global owner view — all KOs are in scope; only sensitivity is checked.
    case globalOwner
    /// A workspace-scoped screen — only KOs belonging to this workspace.
    case workspace(UUID)
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
        let permitted = Set(koIDs.filter { check($0, resolutions: resolutions, scope: scope) })
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
        return rows.filter { check($0.id, resolutions: resolutions, scope: scope) }
    }

    /// Returns `false` when the repository is nil, the call throws, the resolution
    /// is brokenLineage, or the target key is absent from the batch result.
    public func authorize(_ koID: UUID, boundary: ScreenAccessBoundary) async -> Bool {
        guard let repo = repository else { return false }
        let target = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
        let resolutions: [SensitiveScopeTarget: ProtectionResolution]
        do {
            resolutions = try await repo.batchResolution([target])
        } catch {
            KalsmritikoshLog.storage.error(
                "ScreenScopeAuthorizer.authorize: batchResolution threw — denying. \(error, privacy: .public)")
            return false
        }
        let scope = makeScope(for: boundary)
        return check(koID, resolutions: resolutions, scope: scope)
    }

    // MARK: - Helpers

    private func makeScope(for boundary: ScreenAccessBoundary) -> SensitiveScope {
        let wsID: UUID
        switch boundary {
        case .globalOwner:       wsID = Self.screenSentinel
        case .workspace(let id): wsID = id
        }
        return SensitiveScope(
            workspaceID: wsID,
            maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: false,
            purpose: .screen)
    }

    private func check(_ koID: UUID,
                       resolutions: [SensitiveScopeTarget: ProtectionResolution],
                       scope: SensitiveScope) -> Bool {
        let t = SensitiveScopeTarget(kind: .knowledgeObject, id: koID)
        switch resolutions[t] {
        case .resolved(let label): return scope.permits(label)
        case .brokenLineage:       return false
        case nil:                  return false
        }
    }
}
