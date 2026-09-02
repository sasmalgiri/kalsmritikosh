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

    @Test("Real-data noise: 555489 spellings collapse and the mislabeled application number is dropped")
    func realDataDedupAndMislabel() {
        // The owner's re-ingested ledger: 555489 in three spellings, the
        // application number 202331019665 mislabeled under patentNumber in a
        // couple of blocks while dominant as applicationNumber. Expect the ONE
        // clean patent number, no conflict.
        let certObj = UUID(), emailObj = UUID()
        let p1 = fact("patentNumber", "Patent No. 555489")   // certificate (authority)
        let p2 = fact("patentNumber", "Patent No 555489")
        let p3 = fact("patentNumber", "Patent No. : 555489")
        let mis = fact("patentNumber", "Patent No. 202331019665")  // application no. mislabeled
        let app1 = fact("applicationNumber", "Application No. 202331019665")
        let app2 = fact("applicationNumber", "Application No 202331019665")
        let app3 = fact("applicationNumber", "Application No: 202331019665")
        let facts = [p1, p2, p3, mis, app1, app2, app3]
        let evals = [evalFor(p1, objectID: certObj), evalFor(p2, objectID: emailObj),
                     evalFor(p3, objectID: emailObj), evalFor(mis, objectID: emailObj),
                     evalFor(app1, objectID: certObj), evalFor(app2, objectID: emailObj),
                     evalFor(app3, objectID: emailObj)]
        let c = SlotAnswerComposer.compose(
            slotFieldIDs: ["patentnumber"], facts: facts, evaluations: evals,
            authorityObjectIDs: [certObj], documentsSearched: 70)
        #expect(c?.isConflict == false, "spellings + mislabel produced a false conflict")
        #expect(c?.singleCanonicalValue == true)
        #expect(c?.primaryText == "Patent No. 555489.")
        #expect(c?.primaryText.contains("202331019665") == false, "application number surfaced as the patent number")
    }

    @Test("Live-witness case: a date under patentNumber is dropped at query time, no false conflict")
    func queryTimeDateGuardOnLegacyRow() {
        // The owner's rc13 live witness: the legacy ledger holds
        // "Patent : 22/03/2023" (a date) under patentNumber alongside 555489,
        // producing a false 2-value conflict at 36%. rc12's date reject is
        // write-time only; this proves the query-time guard defends the
        // legacy row without a re-ingest.
        let certObj = UUID(), emailObj = UUID()
        let p1 = fact("patentNumber", "Patent No. 555489")
        let p2 = fact("patentNumber", "Patent No 555489")
        let dateRow = fact("patentNumber", "Patent : 22/03/2023")   // legacy garbage
        let facts = [p1, p2, dateRow]
        let evals = [evalFor(p1, objectID: certObj), evalFor(p2, objectID: emailObj),
                     evalFor(dateRow, objectID: emailObj)]
        let c = SlotAnswerComposer.compose(
            slotFieldIDs: ["patentnumber"], facts: facts, evaluations: evals,
            authorityObjectIDs: [certObj], documentsSearched: 70)
        #expect(c?.isConflict == false, "date-shaped legacy row produced a false conflict")
        #expect(c?.singleCanonicalValue == true)
        #expect(c?.primaryText == "Patent No. 555489.")
        #expect(c?.primaryText.contains("22/03/2023") == false, "a date surfaced as the patent number")
        #expect(SlotAnswerComposer.isDateShapedIdentifier("Patent : 22/03/2023"))
        #expect(!SlotAnswerComposer.isDateShapedIdentifier("Patent No. 555489"))
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

    @Test("V2 2b — version-aware rendering via displayLabel: v0 fused and v1 bare render the IDENTICAL surface, by constant")
    func versionAwareRendering() {
        // v0 (the entire live ledger pre-drain): value is the fused display
        // form; render as-is — today's bytes.
        let v0 = GenericFact(subjectLabel: "s", field: "patentNumber",
                             value: "Patent No. 555489", status: .sourceAsserted,
                             confidence: 0.8, sourceBlockIDs: [UUID()],
                             producerVersion: nil, rawMatch: nil)
        #expect(SlotAnswerComposer.renderValue(v0) == "Patent No. 555489")

        // v1 (what V2's writer emits): value is the normalized ATOM; the
        // surface is rebuilt from the per-field displayLabel CONSTANT — NOT
        // from rawMatch (which, post-C-10-merge, would be ingestion-order-
        // hostage) and NOT from humanLabel (which would say "Patent number").
        let v1 = GenericFact(subjectLabel: "s", field: "patentNumber",
                             value: "555489", status: .sourceAsserted,
                             confidence: 0.8, sourceBlockIDs: [UUID()],
                             producerVersion: 1, rawMatch: "PATENT NO.: 555489")
        #expect(SlotAnswerComposer.renderValue(v1) == "Patent No. 555489",
                "v1 surface must come from the displayLabel constant, not the OCR-noisy rawMatch")
        #expect(SlotAnswerComposer.renderValue(v0) == SlotAnswerComposer.renderValue(v1),
                "version-aware render must produce the identical surface across dialects")
        // The ATOM is what dedup/comparison use — bare, no label token.
        #expect(v1.value == "555489")
    }

    @Test("V2 2b — displayLabel constants equal today's witnessed answer-surface prefixes")
    func displayLabelMatchesWitnessedSurface() {
        // The gold answer surface is "Patent No. 900123." — its prefix is the
        // displayLabel. If a pack ever changes the fused surface, this fails,
        // forcing the constant and the gold to move together (no silent drift).
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "patentNumber") == "Patent No.")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "applicationNumber") == "Application No.")
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "publicationNumber") == "Publication No.")
        // Case-insensitive on the field id (normalized internally).
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "patentnumber") == "Patent No.")
        // A field with no v1 rewrite yet has no constant — renders v0 as-is.
        #expect(SlotAnswerComposer.displayLabel(forFieldID: "grantDate") == nil)
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
