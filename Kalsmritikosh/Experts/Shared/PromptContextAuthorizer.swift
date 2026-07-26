//
//  PromptContextAuthorizer.swift
//  Kalsmritikosh
//
//  OPS-003B — the handoff layer between retrieval enforcement and prompt
//  construction. A PromptAuthorizedRetrieval proves that a
//  SensitiveRetrievalPolicy has already filtered the content; PromptTemplates
//  functions accept this type on their canonical path so callers cannot bypass
//  scope enforcement by passing a raw RetrievalResult directly.
//
//  PromptContextAuthorizer holds an optional SensitiveRetrievalPolicy and
//  re-runs it at authorization time so that assignment changes between
//  retrieval and prompt construction are caught (e.g. a workspace membership
//  removed after retrieval succeeded). When no policy is wired the authorizer
//  acts as a pure conversion wrapper.
//

import Foundation

/// A retrieval result that has been confirmed as scope-filtered by
/// SensitiveRetrievalPolicy. PromptTemplates canonical overloads accept this
/// type; the accessContext field travels alongside so audit layers can verify
/// which scope authorized the content.
///
/// Construction is package-internal — callers MUST obtain this through
/// PromptContextAuthorizer.authorize(_:) rather than building it directly,
/// so authorization is always tied to a genuine AuthorizedRetrievalResult.
public nonisolated struct PromptAuthorizedRetrieval: Sendable {
    public let retrieval: RetrievalResult
    public let accessContext: SensitiveAccessContext

    /// Package-internal initializer. External callers use PromptContextAuthorizer.
    init(retrieval: RetrievalResult, accessContext: SensitiveAccessContext) {
        self.retrieval = retrieval
        self.accessContext = accessContext
    }
}

/// Converts an AuthorizedRetrievalResult into a PromptAuthorizedRetrieval,
/// optionally re-running the policy to catch assignment changes since retrieval.
///
/// Nonisolated: can be called from any isolation context without an actor hop.
public nonisolated struct PromptContextAuthorizer: Sendable {
    /// The policy to re-run at authorization time. When nil the authorizer acts
    /// as a pure conversion wrapper (legacy / test paths).
    public let policy: SensitiveRetrievalPolicy?

    public nonisolated init(policy: SensitiveRetrievalPolicy? = nil) {
        self.policy = policy
    }

    /// Convert an AuthorizedRetrievalResult into a PromptAuthorizedRetrieval.
    /// When a policy is wired the filter is re-run so that any assignment changes
    /// since retrieval (workspace membership removed, sensitivity raised) are
    /// applied before any prompt is built.
    public nonisolated func authorize(
        _ authorized: AuthorizedRetrievalResult
    ) async -> PromptAuthorizedRetrieval {
        guard let policy else {
            return PromptAuthorizedRetrieval(
                retrieval: authorized.result,
                accessContext: authorized.accessContext
            )
        }
        let refiltered = await policy.filter(
            result: authorized.result,
            access: authorized.accessContext
        )
        return PromptAuthorizedRetrieval(
            retrieval: refiltered.result,
            accessContext: refiltered.accessContext
        )
    }
}
