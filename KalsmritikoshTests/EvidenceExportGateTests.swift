//
//  EvidenceExportGateTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, C2.1 — the production export evidence gate. The user-facing report/receipt
//  export runs WorkProductValidator.validateProductionExport on the REAL WorkProduct and
//  fails CLOSED when a CITED material claim cites a source that cannot be reopened. It must
//  NOT falsely block legitimate reports: deterministic counts, inference/gap/conflict
//  disclosures, and uncited claims are allowed. These tests compose real WorkProducts via
//  WorkProductComposer.compose (not hand-built) for all four templates.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("C2.1 — production export integrity gate")
struct EvidenceExportGateTests {

    private func event(_ title: String, _ obj: UUID = UUID()) -> WorkProductComposer.EventInput {
        WorkProductComposer.EventInput(
            event: Event(kind: .other, date: Date(timeIntervalSince1970: 1_100_000_000),
                         title: title, entityIDs: [], sourceObjectID: obj, datePrecision: .day),
            filename: "\(title).pdf")
    }

    @Test("All four real report templates export cleanly (no false blocks)")
    func allFourTemplatesExportClean() {
        let events = [event("Contract"), event("Invoice")]
        for template in WorkProductTemplate.allCases {
            let wp = WorkProductComposer.compose(
                template: template, title: "T", scopeNote: "scope",
                events: events, contradictions: [], gaps: [], disclaimer: "d")
            let report = WorkProductValidator().validateProductionExport(wp)
            #expect(report.isValid, "\(template.rawValue) should export cleanly")
        }
    }

    @Test("Deterministic counts and inference/gap disclosures do not block export")
    func countsAndDisclosuresAllowed() {
        // general-summary emits count claims (deterministicDerivation, uncited) + a gap
        // inference — none of which are cited material assertions.
        let wp = WorkProductComposer.compose(
            template: .generalSummary, title: "T", scopeNote: "scope",
            events: [event("E1")], contradictions: [], gaps: [], disclaimer: nil)
        let hasCount = wp.sections.flatMap(\.claims).contains {
            $0.status == .deterministicDerivation && $0.supporting.isEmpty
        }
        #expect(hasCount)                                            // a real uncited count exists
        #expect(WorkProductValidator().validateProductionExport(wp).isValid)   // yet export is allowed
    }

    @Test("A cited material claim whose citation cannot be reopened is blocked (fail closed)")
    func unsupportedCitedMaterialBlocked() {
        let unresolved = CitationRecord(sourceVersionID: nil, evidenceBlockIDs: [],
                                        displayLabel: "[?]", sourceTitle: "unresolved")
        let wp = WorkProduct(template: .factMemo, title: "T", sections: [
            WorkProductSection(title: "Facts", claims: [
                WorkProductClaim(text: "Employer: Orchid", status: .sourceAssertion, supporting: [unresolved])
            ])
        ])
        let report = WorkProductValidator().validateProductionExport(wp)
        #expect(!report.isValid)                                     // blocked
    }

    @Test("A cited material claim with a reopenable citation passes")
    func resolvedCitedMaterialPasses() {
        let resolved = CitationRecord(sourceVersionID: UUID(), evidenceBlockIDs: [UUID()],
                                      displayLabel: "[1]", sourceTitle: "doc")
        let wp = WorkProduct(template: .factMemo, title: "T", sections: [
            WorkProductSection(title: "Facts", claims: [
                WorkProductClaim(text: "Employer: Orchid", status: .directEvidence, supporting: [resolved])
            ])
        ])
        #expect(WorkProductValidator().validateProductionExport(wp).isValid)
    }

    // MARK: Decision-aware gate (covers the full materiality set, not just direct/source)

    private func claim(_ decision: AssertabilityDecision, status: EpistemicStatus, resolved: Bool) -> WorkProductClaim {
        let cite = CitationRecord(sourceVersionID: resolved ? UUID() : nil,
                                  evidenceBlockIDs: resolved ? [UUID()] : [],
                                  displayLabel: "[1]", sourceTitle: "doc")
        return WorkProductClaim(text: "x", status: status, supporting: [cite], assertabilityDecision: decision)
    }
    private func wp(_ c: WorkProductClaim) -> WorkProduct {
        WorkProduct(template: .generalSummary, title: "T", sections: [WorkProductSection(title: "S", claims: [c])])
    }

    @Test("An unresolved assertive DERIVATION is blocked (missed by the coarse-status gate)")
    func derivationUnresolvedBlocked() {
        // status .deterministicDerivation is NOT direct/source — the legacy gate would pass it.
        let report = WorkProductValidator().validateProductionExport(
            wp(claim(.assertAsDerivation, status: .deterministicDerivation, resolved: false)))
        #expect(!report.isValid)
    }

    @Test("A resolved assertive derivation passes")
    func derivationResolvedPasses() {
        #expect(WorkProductValidator().validateProductionExport(
            wp(claim(.assertAsDerivation, status: .deterministicDerivation, resolved: true))).isValid)
    }

    @Test("An unresolved USER-ATTRIBUTED assertion is blocked (also missed by the coarse gate)")
    func userAttributedUnresolvedBlocked() {
        let report = WorkProductValidator().validateProductionExport(
            wp(claim(.assertWithUserAttribution, status: .humanNote, resolved: false)))
        #expect(!report.isValid)
    }

    @Test("Inference and conflict disclosures are allowed even with unresolved citations")
    func disclosuresAllowedDecisionAware() {
        #expect(WorkProductValidator().validateProductionExport(
            wp(claim(.presentAsInference, status: .inference, resolved: false))).isValid)
        #expect(WorkProductValidator().validateProductionExport(
            wp(claim(.presentAsConflict, status: .inference, resolved: false))).isValid)
    }

    @Test("A carried refuse decision is a violation")
    func refuseDecisionBlocked() {
        #expect(!WorkProductValidator().validateProductionExport(
            wp(claim(.refuse, status: .inference, resolved: true))).isValid)
    }
}
