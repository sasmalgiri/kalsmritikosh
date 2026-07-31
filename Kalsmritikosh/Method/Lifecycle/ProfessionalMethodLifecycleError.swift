//
//  ProfessionalMethodLifecycleError.swift
//  Kalsmritikosh
//
//  PM-004 — the typed error vocabulary for the generic method lifecycle runtime.
//

import Foundation

public nonisolated enum ProfessionalMethodLifecycleError: Error, Equatable, Sendable {
    case runNotFound(UUID)
    case definitionNotFound(String)
    case definitionVersionNotFound(id: String, version: Int)
    case invalidActor(String)
    case humanActorRequired
    case invalidTransition(from: MethodRunStatus, action: MethodLifecycleAction)
    case terminalRunImmutable(MethodRunStatus)
    case revisionConflict(runID: UUID, expected: Int)
    case invalidLifecycleReason
    // Review
    case requiredReviewMissing(String)
    case reviewRejected(String)
    case reviewRevisionRequested(String)
    case unknownReviewKey(String)
    case malformedReview(String)
    // Validation
    case validatorNotRegistered(String)
    case validatorFailed(id: String, message: String)
    case validatorReturnedNoResult(String)
    case malformedValidatorResult(String)
    case staleValidationBatch
    case blockingValidation(code: String)
    // Completion / conformance
    case requiredInputRoleMissing(String)
    case unsupportedNodeKind(String)
    case unsupportedEdgeKind(String)
    case unsupportedFindingKind(String)
    case evidenceRequired
    case completionGateFailed(String)
    // Supersession
    case invalidSuccessor(UUID)
    case successorWorkspaceMismatch(UUID)
    case successorDefinitionMismatch(UUID)
}
