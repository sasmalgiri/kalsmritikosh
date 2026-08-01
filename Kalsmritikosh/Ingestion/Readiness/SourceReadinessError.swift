//
//  SourceReadinessError.swift
//  Kalsmritikosh
//
//  USF-002 — typed readiness failures. Never reduced to generic strings.
//

import Foundation

public nonisolated enum SourceReadinessError: Error, Equatable, Sendable {
    /// The source version does not exist.
    case sourceVersionNotFound(UUID)
    /// No readiness aggregate exists for the source version.
    case aggregateNotFound(UUID)
    /// A required dimension row is absent (the ten-dimension invariant is broken).
    case dimensionMissing(SourceReadinessDimension)
    /// A single plan tried to update the same dimension twice.
    case duplicateDimensionUpdate(SourceReadinessDimension)
    /// The requested state transition is not allowed from the current state.
    case invalidTransition(dimension: SourceReadinessDimension, from: SourceReadinessDimensionState, to: SourceReadinessDimensionState)
    /// The applicability/state combination is illegal (e.g. notApplicable that is not ready).
    case invalidApplicability(SourceReadinessDimension)
    /// A `blocked` state was submitted without a blocking condition.
    case blockingConditionRequired(SourceReadinessDimension)
    /// A non-blocked state carried a blocking condition.
    case unexpectedBlockingCondition(SourceReadinessDimension)
    /// Coverage units are malformed (only one set, negative, or completed > total).
    case invalidCoverageUnits(SourceReadinessDimension)
    /// The producer id is blank.
    case blankProducerID
    /// The producer version is blank.
    case blankProducerVersion
    /// A basis reference names a row that does not exist.
    case basisNotFound(SourceReadinessBasis)
    /// A basis reference belongs to a different source version.
    case basisOwnershipMismatch(SourceReadinessBasis)
    /// The optimistic revision check failed (a concurrent update won).
    case revisionConflict(expected: Int, actual: Int)
    /// Readiness was already initialized for this source version.
    case alreadyInitialized(UUID)
    /// A source version does not carry all ten dimensions.
    case incompleteDimensionSet(UUID)
    /// The atomic readiness write failed.
    case databaseWriteFailed(String)
    /// The snapshot could not be reconstructed after the write.
    case snapshotReconstructionFailed(UUID)
    /// The action is not permitted for this update (e.g. `initialize` outside bootstrap).
    case invalidAction(SourceReadinessAction)
    /// A positive (ready/partial) state for a proof-bearing dimension was submitted with no basis.
    case basisRequired(SourceReadinessDimension)
    /// The supplied coverage units disagree with the database-derived coverage.
    case coverageMismatch(dimension: SourceReadinessDimension, supplied: Int, actual: Int)
    /// A readiness plan carried no updates.
    case emptyPlan
    /// An invalidation did not change the producer version or the basis (a no-op invalidation).
    case invalidationWithoutChange(SourceReadinessDimension)
}
