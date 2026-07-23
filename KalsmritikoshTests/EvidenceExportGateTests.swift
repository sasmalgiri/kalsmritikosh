//
//  EvidenceExportGateTests.swift
//  Kalsmritikosh Tests
//
//  S0.5 item 2, C2.1 Part 3B — the production export evidence-integrity gate. The
//  user-facing report/receipt export now validates WorkProductValidator.materialComposition
//  and fails CLOSED: a material claim (direct/source/derived) with no resolved, block-backed
//  citation blocks the export; inference and human-note disclosures are allowed.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("C2.1 Part 3B — production export integrity gate")
struct EvidenceExportGateTests {

    private func resolvedCite(_ block: UUID) -> CitationRecord {
        CitationRecord(sourceVersionID: UUID(), evidenceBlockIDs: [block], displayLabel: "[1]", sourceTitle: "doc")
    }
    private func unresolvedCite() -> CitationRecord {
        CitationRecord(sourceVersionID: nil, evidenceBlockIDs: [], displayLabel: "[?]", sourceTitle: "unresolved")
    }
    private func wp(_ claims: [WorkProductClaim]) -> WorkProduct {
        WorkProduct(template: .generalSummary, title: "T",
                    sections: [WorkProductSection(title: "Facts", claims: claims)])
    }

    @Test("A material claim backed by a resolved, block-backed citation passes the gate")
    func backedMaterialPasses() {
        let product = wp([WorkProductClaim(text: "Employer: Orchid", status: .directEvidence,
                                           supporting: [resolvedCite(UUID())])])
        let report = WorkProductValidator().validate(WorkProductValidator.materialComposition(from: product))
        #expect(report.isValid)
    }

    @Test("A material claim with NO resolved evidence blocks the export (fail closed)")
    func unsupportedMaterialBlocks() {
        let product = wp([WorkProductClaim(text: "Employer: Orchid", status: .sourceAssertion,
                                           supporting: [unresolvedCite()])])
        let report = WorkProductValidator().validate(WorkProductValidator.materialComposition(from: product))
        #expect(!report.isValid)                                  // export must be blocked
    }

    @Test("Inference and human-note disclosures are allowed (not required to carry evidence)")
    func disclosuresAllowed() {
        let product = wp([
            WorkProductClaim(text: "Possibly related", status: .inference),
            WorkProductClaim(text: "Analyst note", status: .humanNote)
        ])
        let report = WorkProductValidator().validate(WorkProductValidator.materialComposition(from: product))
        #expect(report.isValid)                                   // disclosures don't block
    }

    @Test("A backed material claim alongside disclosures still passes")
    func mixedPasses() {
        let product = wp([
            WorkProductClaim(text: "Employer: Orchid", status: .directEvidence, supporting: [resolvedCite(UUID())]),
            WorkProductClaim(text: "Possibly related", status: .inference)
        ])
        let report = WorkProductValidator().validate(WorkProductValidator.materialComposition(from: product))
        #expect(report.isValid)
    }
}
