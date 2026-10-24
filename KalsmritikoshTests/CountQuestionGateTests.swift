//
//  CountQuestionGateTests.swift
//  KalsmritikoshTests
//
//  A how-many question gets a count or an honest "no count given".
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("How-many questions are answered with a count or an honest no-count")
struct CountQuestionGateTests {

    static let q = "How many employees were hurt in OSHA investigation 221257512?"
    static func answer(_ body: String) -> VerifiedAnswer {
        VerifiedAnswer(body: body, citations: [], confidence: Confidence(0.7))
    }

    @Test("A header passage with only the reference number and a date is refused")
    func refuses() {
        let a = Self.answer("OSHA accident investigation summary 221257512 | Event: Employee crushes hand | Event date: February 11, 2020 | Inspection number(s): 344714464")
        let out = CountQuestionGate.apply(question: Self.q, a)
        #expect(out.refused && out.body == "The documents don't give a count for this.")
    }

    @Test("Counts in words or numbers stand", arguments: [
        "1 employee is listed: “Employee #1: hospitalized injury, age 35”.", "Two employees were injured [1].",
        "No employees were hurt.", "The release lists 14 defendants."])
    func keeps(_ body: String) {
        #expect(!CountQuestionGate.apply(question: Self.q, Self.answer(body)).refused)
    }

    @Test("Only how-many questions are checked")
    func scope() {
        #expect(!CountQuestionGate.apply(question: "What happened in OSHA investigation 221257512?",
                                         Self.answer("OSHA accident investigation summary 221257512")).refused)
    }
}
