//
//  ComposeTwinTests.swift
//  KalsmritikoshTests
//
//  P3-U4 part 2 — the compose twin's PURE half, proven in CI: value and
//  polarity comparison, the owner's guardrail semantics (disagreement is a
//  verify-flag, never a competing answer), and the honest skip.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P3-U4 — the compose twin (pure comparator + guardrail semantics)")
@MainActor
struct ComposeTwinTests {

    @Test("Agreement: same values in different words")
    func agreesOnValues() {
        let v = ComposeTwinComparator.compare(
            primary: "Yes — granted 28 November 2024.",
            twin: "The patent was granted on 28 November 2024 according to the letter.")
        #expect(v == .agreed)
    }

    @Test("Disagreement: a missing value is named plainly")
    func disagreesOnMissingValue() {
        let v = ComposeTwinComparator.compare(
            primary: "The amount due is Rs 48,500 on invoice 7741.",
            twin: "Invoice 7741 shows an amount of Rs 41,000.")
        guard case .disagreed(let d) = v else {
            Issue.record("expected disagreement, got \(v)"); return
        }
        #expect(d.contains("48") , "the missing value is named: \(d)")
    }

    @Test("Disagreement: opposite yes/no polarity")
    func disagreesOnPolarity() {
        let v = ComposeTwinComparator.compare(
            primary: "Yes — the patent was granted.",
            twin: "No record of a grant appears in the excerpts.")
        #expect(v == .disagreed(detail: "the readings disagree on yes versus no"))
    }

    @Test("Prose wording differences alone never disagree")
    func wordingIsNoise() {
        let v = ComposeTwinComparator.compare(
            primary: "The document states: \u{201C}Employees must receive at least 24 hours' notice\u{201D}",
            twin: "Staff are entitled to 24 hours of advance notice per the policy.")
        #expect(v == .agreed)
    }

    @Test("The twin's empty reading never fabricates a disagreement")
    func emptyTwinIsSafe() {
        let v = ComposeTwinComparator.compare(
            primary: "Grant date: 29/11/2024.",
            twin: "No answer in the excerpts.")
        #expect(v == .agreed, "no values on the twin side → nothing to contradict; got \(v)")
    }

    @Test("Guardrails: strip lines are plain language; skip is honest")
    func stripLines() {
        #expect(TwinVerdict.agreed.stripLine == "Independent AI reading agreed.")
        #expect(TwinVerdict.skipped(reason: "on-device AI unavailable on this Mac").stripLine
            .contains("not run"))
        let d = TwinVerdict.disagreed(detail: "x").stripLine
        #expect(d.contains("second look") && !d.lowercased().contains("llm"), "RC-8 plain language")
    }
}
