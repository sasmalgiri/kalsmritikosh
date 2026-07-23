//
//  AssertabilityPolicyTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, Commit C1. Locks the assertability decision table over the five separated
//  dimensions + evidence shape. Key safety properties: human confirmation never becomes a
//  bare fact; corroboration needs INDEPENDENT source groups, not raw citation count;
//  rejected/missing/unsupported are refused; inference and conflict are labelled.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 C1 — AssertabilityPolicy")
struct AssertabilityPolicyTests {

    private func ctx(basis: EvidenceBasis = .sourceAsserted,
                     review: ReviewDisposition = .unreviewed,
                     origin: ProposalOrigin = .sourceExtraction,
                     availability: AvailabilityStatus = .present,
                     conflict: ConflictStatus = .none,
                     legacy: EvidenceStatus? = nil,
                     evidence: Int = 1, groups: Int = 1,
                     locator: Bool = false, reproducible: Bool = false) -> AssertabilityContext {
        AssertabilityContext(
            assessment: EvidenceAssessment(basis: basis, review: review, origin: origin,
                                           availability: availability, conflict: conflict, legacyStatus: legacy),
            exactEvidenceCount: evidence, independentEvidenceGroupCount: groups,
            hasExactLocator: locator, hasReproducibleDerivation: reproducible)
    }
    private func decide(_ c: AssertabilityContext) -> AssertabilityDecision { AssertabilityPolicy.evaluate(c) }

    @Test("Rejected review and missing/unsupported evidence are refused")
    func refusals() {
        #expect(decide(ctx(review: .rejected)) == .refuse)
        #expect(decide(ctx(availability: .missingEvidence)) == .refuse)
        #expect(decide(ctx(availability: .unsupported)) == .refuse)
        #expect(decide(ctx(evidence: 0)) == .refuse)          // no exact citation
    }

    @Test("Conflict and inference are surfaced but labelled, never asserted as fact")
    func labelledNotAsserted() {
        #expect(decide(ctx(conflict: .contradicted)) == .presentAsConflict)
        #expect(decide(ctx(conflict: .unresolved)) == .presentAsConflict)
        #expect(decide(ctx(basis: .inferred)) == .presentAsInference)
        // Model-proposed & not human-verified → labelled inference.
        #expect(decide(ctx(basis: .sourceAsserted, origin: .modelProposed)) == .presentAsInference)
    }

    @Test("Direct observation is a fact only when exactly located")
    func directObservation() {
        #expect(decide(ctx(basis: .directlyObserved, locator: true)) == .assertAsFact)
        #expect(decide(ctx(basis: .directlyObserved, locator: false)) == .assertWithAttribution)
    }

    @Test("Corroboration needs ≥2 INDEPENDENT groups — raw citation count never substitutes")
    func corroborationNeedsIndependence() {
        // 5 raw citations but all one independent group → attribution, NOT corroborated.
        #expect(decide(ctx(basis: .sourceAsserted, evidence: 5, groups: 1)) == .assertWithAttribution)
        // 2 independent groups → corroborated.
        #expect(decide(ctx(basis: .sourceAsserted, evidence: 2, groups: 2)) == .assertAsCorroborated)
    }

    @Test("Deterministic derivation asserts only when reproducible")
    func derivation() {
        #expect(decide(ctx(basis: .deterministicallyDerived, reproducible: true)) == .assertAsDerivation)
        #expect(decide(ctx(basis: .deterministicallyDerived, reproducible: false)) == .presentAsInference)
    }

    @Test("Human-confirmed with unknown basis is user-attributed, NEVER a fact")
    func humanConfirmedUnknownBasis() {
        let d = decide(ctx(basis: .unknownLegacy, review: .confirmed, origin: .importedLegacy,
                           legacy: .humanConfirmed, evidence: 3, groups: 3, locator: true))
        #expect(d == .assertWithUserAttribution)
        #expect(d != .assertAsFact)                            // the core guarantee
    }

    @Test("A human workflow action over unknown basis requires evidence; corrected is handled like confirmed")
    func humanActionRequiresEvidence() {
        // C1.1 defect fix: user-attribution must NOT precede the evidence guard.
        #expect(decide(ctx(basis: .unknownLegacy, review: .confirmed, origin: .importedLegacy,
                           legacy: .humanConfirmed, evidence: 0)) == .refuse)
        // Corrected + evidence → user-attributed (not generic attribution).
        #expect(decide(ctx(basis: .unknownLegacy, review: .corrected, origin: .userCreated,
                           legacy: .humanCorrected, evidence: 1)) == .assertWithUserAttribution)
        // Corrected + zero evidence → refuse.
        #expect(decide(ctx(basis: .unknownLegacy, review: .corrected, origin: .userCreated,
                           legacy: .humanCorrected, evidence: 0)) == .refuse)
    }

    @Test("Malformed corroboration counts cannot fabricate corroboration")
    func malformedCorroborationCounts() {
        // One exact citation but two claimed groups → NOT corroborated (groups clamped to citations).
        #expect(decide(ctx(basis: .sourceAsserted, evidence: 1, groups: 2)) == .assertWithAttribution)
        // Two citations + two independent groups → corroborated.
        #expect(decide(ctx(basis: .sourceAsserted, evidence: 2, groups: 2)) == .assertAsCorroborated)
    }

    @Test("Human confirmation over a KNOWN basis still stands on that basis, not the confirmation")
    func humanConfirmedKnownBasis() {
        // Confirmed + directlyObserved + located → asserts as fact on its observed basis.
        #expect(decide(ctx(basis: .directlyObserved, review: .confirmed, locator: true)) == .assertAsFact)
    }

    @Test("Visibility (maySurface) is separate from assertion (isAssertiveDecision)")
    func surfaceVsAssert() {
        // Inference and conflict MUST remain visible (labelled), only refuse is hidden.
        #expect(AssertabilityDecision.presentAsInference.maySurface)
        #expect(AssertabilityDecision.presentAsConflict.maySurface)
        #expect(!AssertabilityDecision.refuse.maySurface)
        #expect(AssertabilityDecision.assertAsFact.maySurface)

        // But inference/conflict are NOT assertive decisions.
        #expect(AssertabilityDecision.assertAsFact.isAssertiveDecision)
        #expect(AssertabilityDecision.assertWithUserAttribution.isAssertiveDecision)
        #expect(!AssertabilityDecision.presentAsInference.isAssertiveDecision)
        #expect(!AssertabilityDecision.presentAsConflict.isAssertiveDecision)
        #expect(!AssertabilityDecision.refuse.isAssertiveDecision)

        // Framing is forced for attributed / user-attributed / inference / conflict.
        #expect(AssertabilityDecision.assertWithAttribution.requiresExplicitFraming)
        #expect(AssertabilityDecision.assertWithUserAttribution.requiresExplicitFraming)
        #expect(AssertabilityDecision.presentAsInference.requiresExplicitFraming)
        #expect(AssertabilityDecision.presentAsConflict.requiresExplicitFraming)
        #expect(!AssertabilityDecision.assertAsFact.requiresExplicitFraming)
        #expect(!AssertabilityDecision.assertAsCorroborated.requiresExplicitFraming)
    }
}
