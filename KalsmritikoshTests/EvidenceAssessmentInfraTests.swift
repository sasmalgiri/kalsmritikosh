//
//  EvidenceAssessmentInfraTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, Commit C2 (infra, non-behavioural). Locks the three shared pieces the
//  behavioural wiring will consume: the conservative verified independent-source count,
//  the per-field row decoder (one malformed dimension never drops the row), and the
//  shared context builder (identical context → identical policy decision everywhere).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S0.5 item 2 C2 — shared assertability infrastructure")
struct EvidenceAssessmentInfraTests {

    // MARK: verifiedIndependentCount

    @Test("Unkeyed / duplicate evidence never raises the verified independent count")
    func verifiedIndependence() {
        let g = SourceIndependenceGrouper()
        let a = UUID(), b = UUID(), c = UUID()
        // Two unkeyed objects (e.g. forwarded copies with no key) → 0 verified independence.
        #expect(g.verifiedIndependentCount(objectIDs: [a, b], keys: [:]) == 0)
        // The permissive count would treat them as 2 — proving the conservative API differs.
        #expect(g.independentCount(objectIDs: [a, b], keys: [:]) == 2)
        // Same key twice → one independent source.
        #expect(g.verifiedIndependentCount(objectIDs: [a, b], keys: [a: "k1", b: "k1"]) == 1)
        // Two distinct non-empty keys → two independent sources.
        #expect(g.verifiedIndependentCount(objectIDs: [a, b], keys: [a: "k1", b: "k2"]) == 2)
        // Whitespace-only key is not reliable.
        #expect(g.verifiedIndependentCount(objectIDs: [a, b, c], keys: [a: "k1", b: "  ", c: ""]) == 1)
    }

    // MARK: EvidenceAssessmentRowDecoder

    @Test("Row decoder prefers valid dimensions, falls back per-field, never drops a row")
    func rowDecoderFallback() {
        // Fully-populated row → exact dimensions.
        let full = EvidenceAssessmentRowDecoder.Row(
            evidenceBasis: "sourceAsserted", reviewDisposition: "confirmed", proposalOrigin: "sourceExtraction",
            availabilityStatus: "present", conflictStatus: "none", legacyStatus: "SOURCE_ASSERTED", status: "SOURCE_ASSERTED")
        let a = EvidenceAssessmentRowDecoder.decode(full)
        #expect(a.basis == .sourceAsserted && a.review == .confirmed && a.origin == .sourceExtraction)

        // All dimensions NULL → fall back to legacy status (INFERRED).
        let legacyOnly = EvidenceAssessmentRowDecoder.Row(legacyStatus: "INFERRED")
        let b = EvidenceAssessmentRowDecoder.decode(legacyOnly)
        #expect(b.basis == .inferred)
        #expect(b.legacyStatus == .inferred)

        // ONE malformed dimension (unknown basis) → conservative default for THAT field only;
        // the other valid dimensions survive; row is NOT dropped.
        let partlyBad = EvidenceAssessmentRowDecoder.Row(
            evidenceBasis: "SOME_FUTURE_BASIS", reviewDisposition: "disputed", availabilityStatus: "present",
            status: "SOURCE_ASSERTED")
        let c = EvidenceAssessmentRowDecoder.decode(partlyBad)
        #expect(c.basis == .sourceAsserted)     // unknown dim → falls back to legacy status basis
        #expect(c.review == .disputed)          // valid dim preserved
        #expect(c.availability == .present)

        // Nothing usable at all → conservative defaults, still a valid assessment.
        let empty = EvidenceAssessmentRowDecoder.Row()
        let d = EvidenceAssessmentRowDecoder.decode(empty)
        #expect(d.basis == .unknownLegacy && d.review == .needsReview && d.origin == .importedLegacy
                && d.availability == .partiallyAvailable && d.conflict == .none)
    }

    @Test("History-item review precedence: disposition → mapped review_status → needsReview; conflict derived")
    func historyItemReviewAndConflict() {
        // No disposition column, legacy review_status 'accepted' → confirmed.
        let r = EvidenceAssessmentRowDecoder.Row(status: "SOURCE_ASSERTED")
        let a = EvidenceAssessmentRowDecoder.decodeHistoryItem(r, historyReviewStatusRaw: "accepted", derivedConflict: nil)
        #expect(a.review == .confirmed)
        // Derived conflict wins.
        let b = EvidenceAssessmentRowDecoder.decodeHistoryItem(r, historyReviewStatusRaw: "unreviewed", derivedConflict: .contradicted)
        #expect(b.conflict == .contradicted)
        #expect(b.review == .unreviewed)
        // Unknown history review status BUT a legacy status present → legacy-status review
        // (SOURCE_ASSERTED → unreviewed) precedes needsReview (per §C2 precedence).
        let c = EvidenceAssessmentRowDecoder.decodeHistoryItem(r, historyReviewStatusRaw: "weird", derivedConflict: nil)
        #expect(c.review == .unreviewed)
        // Unknown review status AND no legacy status → needsReview (last-resort default).
        let none = EvidenceAssessmentRowDecoder.Row()
        let e = EvidenceAssessmentRowDecoder.decodeHistoryItem(none, historyReviewStatusRaw: "weird", derivedConflict: nil)
        #expect(e.review == .needsReview)
    }

    // MARK: AssertabilityContextBuilder

    @Test("Context builder yields identical context (and decision) for the same inputs")
    func builderDeterministicAndConservative() {
        let builder = AssertabilityContextBuilder()
        let a = UUID(), b = UUID()
        let assessment = EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction)

        // Two forwarded copies (no keys): supports attribution, but NOT corroboration.
        let (ctx1, dec1) = builder.decision(assessment: assessment, evidenceObjectIDs: [a, b],
                                            independenceKeys: [:], hasExactLocator: true)
        #expect(ctx1.exactEvidenceCount == 2)
        #expect(ctx1.independentEvidenceGroupCount == 0)     // conservative
        #expect(dec1 == .assertWithAttribution)              // NOT corroborated

        // Same inputs → identical context + decision (the cross-consumer guarantee).
        let (ctx2, dec2) = builder.decision(assessment: assessment, evidenceObjectIDs: [a, b],
                                            independenceKeys: [:], hasExactLocator: true)
        #expect(ctx1 == ctx2)
        #expect(dec1 == dec2)

        // Two independently-keyed sources → corroborated.
        let (_, dec3) = builder.decision(assessment: assessment, evidenceObjectIDs: [a, b],
                                         independenceKeys: [a: "h1", b: "h2"], hasExactLocator: true)
        #expect(dec3 == .assertAsCorroborated)

        // A derived contradiction overrides stored conflict → presentAsConflict.
        let (_, dec4) = builder.decision(assessment: assessment, evidenceObjectIDs: [a],
                                         independenceKeys: [a: "h1"], hasExactLocator: true,
                                         derivedConflict: .contradicted)
        #expect(dec4 == .presentAsConflict)
    }
}
