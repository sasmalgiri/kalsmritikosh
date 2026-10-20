//
//  AnswerSynthesizerValueGateTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-20, first run with Apple's on-device model: AI prose that drops the value
//  the question asks for ("… involved injured employees" for "How many were hurt?") is rejected
//  so the grounded body ships instead.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Answer synthesis keeps the asked-for value")
struct AnswerSynthesizerValueGateTests {

    private let findings = "OSHA accident 220962021 — injured employees\nEmployee #1: hospitalized injury, age 42"

    @Test("A count question whose prose has no count is rejected; one with the count is kept")
    func countKept() {
        let q = "How many employees were hurt in OSHA investigation 220962021?"
        #expect(AnswerSynthesizer.dropsAskedValue(question: q, findings: findings,
            prose: "The document states that the OSHA accident 220962021 involved injured employees [1]."))
        #expect(!AnswerSynthesizer.dropsAskedValue(question: q, findings: findings,
            prose: "One employee was hurt [1]."))
        #expect(!AnswerSynthesizer.dropsAskedValue(question: q, findings: findings,
            prose: "1 employee was hospitalized [1]."))
    }

    @Test("A when-question needs a year in the prose when the findings carry one")
    func dateKept() {
        let q = "When did the accident in OSHA investigation 220962021 happen?"
        let f = "Event date: June 8, 2017. An employee was overcome by chemical fumes."
        #expect(AnswerSynthesizer.dropsAskedValue(question: q, findings: f, prose: "An employee was overcome by fumes [1]."))
        #expect(!AnswerSynthesizer.dropsAskedValue(question: q, findings: f, prose: "It happened on June 8, 2017 [1]."))
    }

    @Test("An existence question needs its yes/no or the harm itself")
    func existenceKept() {
        let q = "Was anyone killed in OSHA investigation 200041994?"
        #expect(AnswerSynthesizer.dropsAskedValue(question: q, findings: "Employee #1: fatality, age 55",
            prose: "The document states that an OSHA accident investigation summary exists for 200041994 [1]."))
        #expect(!AnswerSynthesizer.dropsAskedValue(question: q, findings: "Employee #1: fatality, age 55",
            prose: "Yes. One employee died [1]."))
        #expect(!AnswerSynthesizer.dropsAskedValue(question: q, findings: "Employee #1: fatality, age 55",
            prose: "The employee was fatally injured [1]."))
    }

    @Test("Other questions are not gated")
    func otherQuestions() {
        #expect(!AnswerSynthesizer.dropsAskedValue(question: "What happened in OSHA investigation 220962021?",
            findings: findings, prose: "An employee was overcome by fumes [1]."))
    }
}
