//
//  MethodPersistenceError.swift
//  Kalsmritikosh
//
//  PM-002 — errors for the Stage 4 method persistence layer.
//

import Foundation

public nonisolated enum MethodPersistenceError: Error, Equatable, Sendable {
    /// The MethodRun does not exist.
    case runNotFound(UUID)
    /// Optimistic concurrency: the caller's expected revision no longer matches.
    case revisionConflict(runID: UUID, expected: Int)
    /// The workspace named at run creation does not exist.
    case workspaceNotFound(UUID)
    /// A run field violates the contract (blank creator/definition, version < 1).
    case invalidRun(String)
    /// A child row references a node/finding/subject belonging to another run.
    case ownershipViolation(String)
    /// A workflow invocation reference supplied at creation cannot be resolved
    /// (missing run/step, or step outside the run / workspace).
    case unresolvedWorkflowReference(String)
    /// A method evidence link named a workflow-output kind (workflowArtifact /
    /// workProductRun) — only canonical evidence kinds are allowed.
    case unsupportedEvidenceTargetKind(String)
    /// The evidence gate denied the reference (missing / cross-workspace / scope).
    case evidenceReferenceDenied(reason: String)
    /// A finding's related Claim does not exist or is not valid for the workspace.
    case relatedClaimInvalid(UUID)
    /// A validation result names a subject that does not belong to the run.
    case invalidValidationSubject(String)
    /// An ordinal was negative.
    case invalidOrdinal(Int)
    /// A content write was attempted on a run that is not draft or active (PM-004).
    case contentMutationNotAllowed(UUID, status: String)
    /// PM-004.1: a lifecycle plan's review did not evaluate the run's effective content
    /// revision (current for a normal review, current+1 for a reopen). Gate epochs are
    /// enforced by the authoritative repository, not trusted from the caller.
    case reviewEpochMismatch(runID: UUID, expected: Int, actual: Int)
    /// PM-004.1: a lifecycle plan's validation batch is not a single, non-legacy batch
    /// evaluating the run's current content revision, all rows owned by the run.
    case invalidValidationBatch(String)
}
