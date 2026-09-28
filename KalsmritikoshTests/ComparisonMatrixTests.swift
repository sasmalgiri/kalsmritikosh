//
//  ComparisonMatrixTests.swift
//  KalsmritikoshTests
//
//  G3 Workflow C — the comparison core distinguishes agreement, real
//  disagreement, different-units, single-source and unattested; and absent
//  evidence from evidence of absence. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G3 comparison matrix")
struct ComparisonMatrixTests {

    private func cell(_ cells: [ComparisonCell], _ field: String) -> ComparisonCell? {
        cells.first { $0.field == field }
    }

    @Test func agreementDisagreementAndUnitsAreDistinguished() {
        let sources = ["A", "B"]
        let values: [String: [SourceValue]] = [
            "grantDate": [.init(sourceID: "A", presence: .stated("28 November 2024")),
                          .init(sourceID: "B", presence: .stated("28 November 2024"))],
            "amount": [.init(sourceID: "A", presence: .stated("₹500000")),
                       .init(sourceID: "B", presence: .stated("$500000"))],   // same magnitude, diff currency
            "status": [.init(sourceID: "A", presence: .stated("granted")),
                       .init(sourceID: "B", presence: .stated("rejected"))],  // genuine disagreement
        ]
        let cells = ComparisonMatrix.build(fields: ["grantDate", "amount", "status"],
                                           sourceIDs: sources, values: values)
        #expect(cell(cells, "grantDate")?.verdict == .agree)
        #expect(cell(cells, "amount")?.verdict == .differentUnit, "unit difference is not a contradiction")
        #expect(cell(cells, "status")?.verdict == .disagree)
    }

    @Test func absentEvidenceVsEvidenceOfAbsence() {
        let sources = ["A", "B", "C"]
        let values: [String: [SourceValue]] = [
            "deathDate": [.init(sourceID: "A", presence: .stated("1971")),
                          .init(sourceID: "B", presence: .explicitlyNone),   // "no death recorded"
                          .init(sourceID: "C", presence: .silent)],          // simply doesn't mention it
        ]
        let c = cell(ComparisonMatrix.build(fields: ["deathDate"], sourceIDs: sources, values: values), "deathDate")
        #expect(c?.verdict == .singleSource, "only one source states a value")
        #expect(c?.silentSourceIDs == ["C"], "C is absent evidence")
        #expect(c?.explicitNoneSourceIDs == ["B"], "B is evidence of absence")
    }

    @Test func unattestedWhenNoSourceStates() {
        let cells = ComparisonMatrix.build(
            fields: ["salary"], sourceIDs: ["A"],
            values: ["salary": [.init(sourceID: "A", presence: .silent)]])
        #expect(cell(cells, "salary")?.verdict == .unattested)
    }

    @Test func missingSourceEntryDefaultsToSilent() {
        // Field with no entry for source B → B is silent, not fabricated.
        let cells = ComparisonMatrix.build(
            fields: ["role"], sourceIDs: ["A", "B"],
            values: ["role": [.init(sourceID: "A", presence: .stated("applicant"))]])
        let c = cell(cells, "role")
        #expect(c?.verdict == .singleSource)
        #expect(c?.silentSourceIDs == ["B"])
    }
}
