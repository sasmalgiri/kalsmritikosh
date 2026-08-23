//
//  WorkplaceFairnessPrinciplesTests.swift
//  KalsmritikoshTests
//
//  The procedural-fairness checklist a workplace investigation must satisfy.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("WorkplaceFairnessPrinciples")
struct WorkplaceFairnessPrinciplesTests {

    @Test("The checklist covers the core natural-justice steps, uniquely identified")
    func checklist() {
        let p = WorkplaceFairnessPrinciples.principles
        #expect(p.count >= 5)
        #expect(Set(p.map(\.id)).count == p.count)
        #expect(p.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        let ids = Set(p.map(\.id))
        for core in ["notice", "respond", "impartial", "evidence"] { #expect(ids.contains(core)) }
    }

    @Test("The summary and discipline line make fairness explicit")
    func summary() {
        #expect(WorkplaceFairnessPrinciples.helpSummary.contains("Notice of the allegations"))
        let note = WorkplaceFairnessPrinciples.disciplineNote.lowercased()
        #expect(note.contains("process") && note.contains("unfair"))
    }
}
