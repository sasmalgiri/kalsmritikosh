//
//  PersonaRubricTests.swift
//  KalsmritikoshTests
//
//  The recognized rubrics surfaced for the Genealogist and Content Creator lenses.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Genealogical Proof Standard")
struct GenealogicalProofStandardTests {

    @Test("All five GPS elements, numbered 1…5, uniquely identified")
    func fiveElements() {
        let e = GenealogicalProofStandard.elements
        #expect(e.count == 5)
        #expect(e.map(\.number) == [1, 2, 3, 4, 5])
        #expect(Set(e.map(\.id)).count == 5)
        #expect(e.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        #expect(GenealogicalProofStandard.helpSummary.contains("Reasonably exhaustive research"))
        #expect(GenealogicalProofStandard.disciplineNote.lowercased().contains("all five"))
    }
}

@Suite("Publish readiness")
struct PublishReadinessTests {

    @Test("The checklist covers the pre-publish steps, uniquely identified")
    func checklist() {
        let c = PublishReadiness.checks
        #expect(c.count >= 5)
        #expect(Set(c.map(\.id)).count == c.count)
        #expect(c.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        let ids = Set(c.map(\.id))
        for core in ["claims", "sources", "rights", "disclosure"] { #expect(ids.contains(core)) }
        #expect(PublishReadiness.disciplineNote.lowercased().contains("disclose"))
    }
}
