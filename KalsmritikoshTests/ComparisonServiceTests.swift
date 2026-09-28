//
//  ComparisonServiceTests.swift
//  KalsmritikoshTests
//
//  G3 Workflow C — the service wires injected per-source values into the
//  matrix + brief without a DB. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G3 comparison service")
struct ComparisonServiceTests {

    @Test func wiresInjectedValuesIntoMatrixAndBrief() async {
        // Two sources over four fields via an injected resolver.
        let service = ComparisonService { field, source in
            switch (field, source) {
            case ("grantDate", _):            return .stated("28 November 2024")   // both agree
            case ("amount", "A"):             return .stated("₹500000")
            case ("amount", "B"):             return .stated("$500000")            // different units
            case ("status", "A"):             return .stated("granted")
            case ("status", "B"):             return .stated("rejected")           // disagree
            case ("deathDate", "A"):          return .stated("1971")
            case ("deathDate", "B"):          return .silent                       // absent evidence
            default:                          return .silent
            }
        }
        let (cells, brief) = await service.compare(
            fields: ["grantDate", "amount", "status", "deathDate"],
            sources: [(id: "A", label: "Deed"), (id: "B", label: "Email")])

        func verdict(_ f: String) -> ComparisonCell.Verdict? { cells.first { $0.field == f }?.verdict }
        #expect(verdict("grantDate") == .agree)
        #expect(verdict("amount") == .differentUnit)
        #expect(verdict("status") == .disagree)
        #expect(verdict("deathDate") == .singleSource)
        // The brief carries the labelled sources and the disagreement.
        #expect(brief.sourceRegister == ["Deed", "Email"])
        #expect(brief.text.contains("Disagreements:"))
        #expect(brief.disagreements.contains { $0.contains("status") })
        // deathDate: A stated, B silent → B listed as absent evidence.
        #expect(cells.first { $0.field == "deathDate" }?.silentSourceIDs == ["B"])
    }
}
