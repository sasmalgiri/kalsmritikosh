//
//  SlotFieldLabelTests.swift
//  KalsmritikoshTests
//
//  A joined field id reads as words ("Recalling firm"), built from the id alone — never from the
//  extraction's raw match (RawMatchBoundaryTests).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Joined field ids read as words")
struct SlotFieldLabelTests {

    static func fact(_ field: String) -> GenericFact {
        GenericFact(subjectLabel: "doc", field: field, value: "x", status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [])
    }

    @Test("Known field words split", arguments: [
        ("recallingfirm", "Recalling firm"), ("decisiondate", "Decision date"), ("casenumber", "Case number"),
        ("incidentdate", "Incident date"), ("policynumber", "Policy number")])
    func splits(_ pair: (String, String)) {
        #expect(SlotAnswerComposer.documentLabel(Self.fact(pair.0)) == pair.1)
    }

    @Test("Unknown or single words are left alone")
    func leftAlone() {
        #expect(SlotAnswerComposer.documentLabel(Self.fact("plaintiff")) == nil)
        #expect(SlotAnswerComposer.documentLabel(Self.fact("xyzzyfoo")) == nil)
        #expect(SlotAnswerComposer.documentLabel(Self.fact("case_no")) == nil)
    }
}
