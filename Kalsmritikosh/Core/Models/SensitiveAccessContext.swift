//
//  SensitiveAccessContext.swift
//  Kalsmritikosh
//
//  OPS-003B — per-request authority envelope. Every retrieve() call that may
//  surface sensitive evidence must carry one of these; its SensitiveScope
//  determines what the retrieval layer may include.
//
//  SensitiveAccessContext is immutable and Sendable — it can be passed across
//  actors without copying. AuthorizedRetrievalResult is the output type of a
//  scope-aware retrieve() call; it wraps the filtered RetrievalResult and
//  records how many items were withheld so the UI quality strip can surface
//  "N items withheld due to sensitivity restrictions."
//

import Foundation

/// Immutable authority envelope for one retrieval or prompt-construction request.
///
/// Built by the caller (UI / MasterBrain) from the active workspace's
/// SensitiveScope and threaded unchanged through retrieval and prompt layers.
/// The retrieval policy checks each item against `scope.permits(_:)` and
/// withholds anything that exceeds the ceiling.
public nonisolated struct SensitiveAccessContext: Sendable, Equatable {
    public let scope: SensitiveScope

    public nonisolated init(scope: SensitiveScope) {
        self.scope = scope
    }
}

/// Output of an access-context-aware retrieve() call.
///
/// Wraps the filtered RetrievalResult together with metadata about what was
/// withheld so the UI quality strip can surface "N items withheld." The
/// `accessContext` field travels unchanged from the call site through to
/// PromptContextAuthorizer so the prompt layer can prove authorization was
/// checked without re-querying the ledger.
public nonisolated struct AuthorizedRetrievalResult: Sendable {
    public let result: RetrievalResult
    public let accessContext: SensitiveAccessContext
    public let withheldChunkCount: Int
    public let withheldEventCount: Int
    public let withheldEntityCount: Int
    public let withheldSummaryCount: Int
    public let withheldRelationshipCount: Int

    public nonisolated var totalWithheld: Int {
        withheldChunkCount + withheldEventCount + withheldEntityCount
            + withheldSummaryCount + withheldRelationshipCount
    }

    public nonisolated var anyWithheld: Bool { totalWithheld > 0 }

    public nonisolated init(
        result: RetrievalResult,
        accessContext: SensitiveAccessContext,
        withheldChunkCount: Int = 0,
        withheldEventCount: Int = 0,
        withheldEntityCount: Int = 0,
        withheldSummaryCount: Int = 0,
        withheldRelationshipCount: Int = 0
    ) {
        self.result = result
        self.accessContext = accessContext
        self.withheldChunkCount = withheldChunkCount
        self.withheldEventCount = withheldEventCount
        self.withheldEntityCount = withheldEntityCount
        self.withheldSummaryCount = withheldSummaryCount
        self.withheldRelationshipCount = withheldRelationshipCount
    }
}

/// Errors surfaced by retrieval enforcement.
public enum SensitiveRetrievalError: Error, Sendable {
    /// A retrieval call was made without a required SensitiveAccessContext.
    case unscopedRetrieval
}

#if DEBUG
extension SensitiveAccessContext {
    /// DEBUG-ONLY factory: maximally permissive access context that bypasses workspace
    /// enforcement (sentinel UUID skips the workspace-sources check in
    /// SensitiveRetrievalPolicy). Use ONLY in tests, SmokeTest, NarrativeEvalKit, and
    /// UI callers not yet ported to workspace-scoped access (OPS-003C).
    /// Must NOT be reachable from consumer-release builds.
    public static func testUnrestricted(
        purpose: SensitiveUsePurpose = .retrieval
    ) -> SensitiveAccessContext {
        SensitiveAccessContext(scope: SensitiveScope(
            workspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            maximumSensitivity: .restricted,
            permitsPrivilegedMaterial: true,
            purpose: purpose
        ))
    }
}
#endif
