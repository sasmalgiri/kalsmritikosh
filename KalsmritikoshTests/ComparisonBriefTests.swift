//
//  ComparisonBriefTests.swift
//  KalsmritikoshTests
//
//  G3 Workflow C — the brief renders the matrix honestly: agreements,
//  disagreements, different-units (not conflicts), unresolved, and a source
//  register. Pure, fast tier.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("G3 comparison brief")
struct ComparisonBriefTests {

    private func matrix() -> [ComparisonCell] {
        ComparisonMatrix.build(
            fields: ["grantDate", "amount", "status", "deathDate"],
            sourceIDs: ["A", "B"],
            values: [
                "grantDate": [.init(sourceID: "A", presence: .stated("28 November 2024")),
                              .init(sourceID: "B", presence: .stated("28 November 2024"))],
                "amount": [.init(sourceID: "A", presence: .stated("₹500000")),
                           .init(sourceID: "B", presence: .stated("$500000"))],
                "status": [.init(sourceID: "A", presence: .stated("granted")),
                           .init(sourceID: "B", presence: .stated("rejected"))],
                "deathDate": [.init(sourceID: "A", presence: .stated("1971")),
                              .init(sourceID: "B", presence: .explicitlyNone)],
            ])
    }

    @Test func briefRendersEachSectionHonestly() {
        let brief = ComparisonBrief.make(cells: matrix(),
                                         sourceLabels: ["A": "Deed", "B": "Email"])
        #expect(brief.agreements.contains { $0.contains("grantDate") && $0.contains("28 November 2024") })
        #expect(brief.disagreements.contains { $0.contains("status") && $0.contains("granted") && $0.contains("rejected") })
        #expect(brief.differentUnits.contains { $0.contains("amount") && $0.contains("not a conflict") })
        #expect(brief.unresolved.contains { $0.contains("deathDate") })
        #expect(brief.sourceRegister == ["Deed", "Email"])
        // The assembled text carries the labelled sources, never raw ids.
        #expect(brief.text.contains("Deed") && brief.text.contains("Email"))
        #expect(brief.text.contains("Disagreements:"))
        #expect(brief.text.contains("Sources compared: Deed, Email."))
    }

    @Test func evidenceOfAbsenceIsCalledOut() {
        // deathDate: A states 1971, B explicitly none → unresolved names B.
        let brief = ComparisonBrief.make(cells: matrix(), sourceLabels: ["A": "Deed", "B": "Email"])
        #expect(brief.unresolved.contains { $0.contains("Recorded as none by: Email") })
    }
}
