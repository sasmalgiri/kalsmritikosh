//
//  SIUFraudIndicatorTests.swift
//  KalsmritikoshTests
//
//  The recognized SIU red-flag taxonomy — and the discipline that governs it.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SIUFraudIndicators")
struct SIUFraudIndicatorTests {

    @Test("The taxonomy is non-empty, uniquely identified, and fully described")
    func taxonomy() {
        let cats = SIUFraudIndicators.categories
        #expect(cats.count >= 10)
        #expect(Set(cats.map(\.id)).count == cats.count)                 // ids unique
        #expect(cats.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.group.isEmpty })
    }

    @Test("Groups are stable, unique, and cover the core screening axes")
    func groups() {
        let g = SIUFraudIndicators.groups()
        #expect(Set(g).count == g.count)                                 // no duplicates
        for expected in ["Claim timing", "Coverage", "Documentation", "History"] {
            #expect(g.contains(expected))
        }
        #expect(SIUFraudIndicators.helpSummary.contains("Claim timing"))
    }

    @Test("The discipline line keeps red flags as indicators, never proof")
    func discipline() {
        let note = SIUFraudIndicators.disciplineNote.lowercased()
        #expect(note.contains("indicator"))
        #expect(note.contains("never"))
        #expect(note.contains("proof"))
    }
}
