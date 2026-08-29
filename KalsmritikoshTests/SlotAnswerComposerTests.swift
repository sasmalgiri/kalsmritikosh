//
//  SlotAnswerComposerTests.swift
//  KalsmritikoshTests
//
//  D-12 / D-14 / D-15 (P0 answer-quality pack) — the slot answer is ONE
//  sentence with the requested value, an explicit conflict, or an honest
//  field-named not-found; label humanization and money rendering; the
//  slot-confidence floor.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("D-12/14/15 — slot answer composition")
struct SlotAnswerComposerTests {

    // MARK: - Fixtures

    private func fact(_ field: String, _ value: String, unit: String? = nil,
                      confidence: Double = 0.8) -> GenericFact {
        GenericFact(subjectLabel: "Nila Instruments", field: field, value: value, unit: unit,
                    status: .sourceAsserted, confidence: confidence, sourceBlockIDs: [UUID()])
    }

    private func evalFor(_ f: GenericFact, objectID: UUID) -> ClaimEvaluation {
        let ev = [AssertabilityEvidence(objectID: objectID, blockID: f.sourceBlockIDs.first,
                                        independenceKey: objectID.uuidString)]
        let ctx = AssertabilityContextBuilder().build(assessment: f.assessment, evidence: ev)
        return ClaimEvaluation(id: f.id, claimKind: .genericFact, assessment: ctx.assessment,
                               evidence: ev, context: ctx, decision: AssertabilityPolicy.evaluate(ctx))
    }

    // MARK: - D-12 composition

    @Test("Three assertions, one requested field → exactly the requested value, one citation")
    func singleValueComposition() {
        let emailObj = UUID(), certObj = UUID()
        let app1 = fact("applicationNumber", "202499055555")
        let app2 = fact("applicationNumber", "202499055555")
        let patent = fact("patentNumber", "900123")
        let facts = [app1, app2, patent]
        let evals = [evalFor(app1, objectID: emailObj), evalFor(app2, objectID: emailObj),
                     evalFor(patent, objectID: certObj)]

        let c = SlotAnswerComposer.compose(
            slotFieldIDs: ["patentnumber"], facts: facts, evaluations: evals,
            authorityObjectIDs: [certObj], documentsSearched: 3)
        #expect(c != nil)
        #expect(c?.primaryText == "Patent number: 900123.")
        #expect(c?.supportingObjectIDs == [certObj])
        #expect(c?.isConflict == false)
        #expect(c?.singleCanonicalValue == true)
        #expect(c?.structuredSource == true)
        // The application number appears only in the detail line, never the primary.
        #expect(c?.primaryText.contains("202499055555") == false)
        #expect(c?.alsoOnFile?.contains("Application number 202499055555") == true)
    }

    @Test("Two DIFFERENT values for the requested field → an explicit conflict, both shown")
    func conflictComposition() {
        let a = fact("patentNumber", "900123"), b = fact("patentNumber", "911999")
        let objA = UUID(), objB = UUID()
        let c = SlotAnswerComposer.compose(
            slotFieldIDs: ["patentnumber"], facts: [a, b],
            evaluations: [evalFor(a, objectID: objA), evalFor(b, objectID: objB)],
            authorityObjectIDs: [], documentsSearched: 2)
        #expect(c?.isConflict == true)
        #expect(c?.primaryText.contains("900123") == true)
        #expect(c?.primaryText.contains("911999") == true)
        #expect(c?.primaryText.lowercased().contains("conflicting") == true)
        #expect(Set(c?.supportingObjectIDs ?? []) == Set([objA, objB]))
    }

    @Test("Identical values in different formats dedupe to one")
    func formatDedupe() {
        let a = fact("grantDate", "17 June 2025"), b = fact("grantDate", "June 2025")
        let c = SlotAnswerComposer.compose(
            slotFieldIDs: ["grantdate"], facts: [a, b],
            evaluations: [evalFor(a, objectID: UUID()), evalFor(b, objectID: UUID())],
            authorityObjectIDs: [], documentsSearched: 2)
        // Month-grain vs day-grain of the same period is NOT a conflict.
        #expect(c?.isConflict == false)
        #expect(c?.singleCanonicalValue == true)
    }

    // MARK: - D-15 honest not-found

    @Test("Missing requested field → the not-found NAMES the field and the related evidence")
    func honestNotFound() {
        let certObj = UUID()
        let patent = fact("patentNumber", "900123")
        let c = SlotAnswerComposer.compose(
            slotFieldIDs: ["grantdate"], facts: [patent],
            evaluations: [evalFor(patent, objectID: certObj)],
            authorityObjectIDs: [certObj], documentsSearched: 70)
        #expect(c?.isNotFound == true)
        #expect(c?.primaryText.contains("Patent number 900123") == true)
        #expect(c?.primaryText.contains("70 document(s) searched") == true)
        #expect(c?.primaryText.contains("grant date") == true)
        #expect(c?.primaryText.contains("Reported:") == false)
        #expect(c?.supportingObjectIDs == [certObj])
    }

    // MARK: - D-12 rendering rules

    @Test("Money renders canonically — 'Rs20,000 INR' never dumps raw")
    func moneyRendering() {
        #expect(SlotAnswerComposer.renderMoney(value: "Rs20,000", unit: "INR") == "₹20,000")
        #expect(SlotAnswerComposer.renderMoney(value: "20000", unit: "INR") == "₹20,000")
        #expect(SlotAnswerComposer.renderMoney(value: "$1,200", unit: nil) == "$1,200")
        #expect(SlotAnswerComposer.renderMoney(value: "1200.50", unit: "USD") == "$1,200.50")
        let amount = fact("amount", "Rs20,000", unit: "INR")
        #expect(SlotAnswerComposer.renderValue(amount) == "₹20,000")
    }

    // MARK: - D-14 slot confidence floor

    @Test("Slot profile floors confidence at 0.8×coverage-factor; any failed condition keeps base")
    func slotProfileFloor() {
        let base = Confidence(0.37)
        let floored = DefaultConfidenceEngine.slotProfileFloor(
            base: base, singleCanonicalValue: true, structuredSource: true,
            conflictOnRequestedField: false, ingestCoverage: 1.0)
        #expect(floored.value >= 0.8)
        // Coverage multiplier still applies (T11 untouched).
        let partial = DefaultConfidenceEngine.slotProfileFloor(
            base: base, singleCanonicalValue: true, structuredSource: true,
            conflictOnRequestedField: false, ingestCoverage: 0.9)
        #expect(abs(partial.value - 0.8 * 0.9) < 0.0001)
        // Conflict on the REQUESTED field → no floor.
        let conflicted = DefaultConfidenceEngine.slotProfileFloor(
            base: base, singleCanonicalValue: false, structuredSource: true,
            conflictOnRequestedField: true, ingestCoverage: 1.0)
        #expect(conflicted.value == base.value)
        // Unstructured single source → no floor.
        let weak = DefaultConfidenceEngine.slotProfileFloor(
            base: base, singleCanonicalValue: true, structuredSource: false,
            conflictOnRequestedField: false, ingestCoverage: 1.0)
        #expect(weak.value == base.value)
    }
}
