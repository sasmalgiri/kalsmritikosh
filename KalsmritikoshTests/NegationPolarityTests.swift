//
//  NegationPolarityTests.swift
//  KalsmritikoshTests
//
//  F07 — a composed sentence's polarity must MATCH the evidence sentence it rests on, both
//  ways: adding a negation dies, and so does dropping one. Contractions count as negations.
//  A negation elsewhere in a long cited span does not kill an unrelated positive sentence.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F07 — negation polarity both ways")
struct NegationPolarityTests {

    private func sweep(_ candidate: String, _ evidence: String) -> [(text: String, citedID: String)] {
        ToolGroundedComposer.sweep(candidate: candidate, question: "q",
                                   results: [ToolResult(id: "T1", text: evidence, objectIDs: [UUID()])])
    }

    @Test("Dropping the evidence's negation is a reversal and dies")
    func droppedNegationDies() {
        #expect(sweep("The patent was granted [T1].", "The patent was not granted in 2024.").isEmpty)
        #expect(sweep("The invoice was paid [T1].", "The invoice was never paid.").isEmpty)
    }

    @Test("A contraction is a negation, in the sentence and in the evidence")
    func contractionsCount() {
        #expect(sweep("The patent wasn't granted [T1].", "The patent was granted on 28 November 2024.").isEmpty)
        #expect(sweep("The patent was granted [T1].", "The patent wasn’t granted.").isEmpty)   // curly apostrophe
        #expect(sweep("The patent wasn't granted [T1].", "The patent was not granted.").count == 1)
    }

    @Test("A negation elsewhere in the cited span does not kill a positive sentence it supports")
    func unrelatedNegationInSpan() {
        let span = "The patent was granted on 28 November 2024. No objections were raised by the examiner."
        #expect(sweep("The patent was granted on 28 November 2024 [T1].", span).count == 1)
        #expect(sweep("No objections were raised [T1].", span).count == 1)
        #expect(sweep("Objections were raised [T1].", span).isEmpty)
    }
}
