//
//  DateQuestionGateTests.swift
//  KalsmritikoshTests
//
//  Q-3 — a when-question gets a date or an honest "no date given" (case bench round 4: DOJ
//  releases answered with a paragraph saying "today").
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("When-questions are answered with a date or an honest no-date")
struct DateQuestionGateTests {

    static func answer(_ body: String, refused: Bool = false) -> VerifiedAnswer {
        VerifiedAnswer(body: body, citations: [], confidence: Confidence(0.7), refused: refused)
    }

    @Test("A paragraph with no date becomes an honest refusal quoting the relative wording")
    func noDateRefuses() {
        let a = Self.answer("Honduran National Pleads Guilty to Illegal Reentry | U.S. Attorney Kenneth A. Polite announced that JOSE LOPEZ pled guilty today to a one-count indictment.")
        let out = DateQuestionGate.apply(question: "When did the Justice Department announce \"Honduran National Pleads Guilty\"?", a)
        #expect(out.refused)
        #expect(out.body.hasPrefix("The documents don't give a date for this."))
        #expect(out.body.contains("pled guilty today"))
    }

    @Test("Answers that carry a date are untouched", arguments: [
        "Decision date: 05/09/2000.", "It was granted on March 3, 2009 [1].", "Filed 2014-11-04.",
        "The order was entered on 4 November 2014.", "The plant closed in 1998.", "It happened in March."])
    func datesKept(_ body: String) {
        let a = Self.answer(body)
        let out = DateQuestionGate.apply(question: "When was it decided?", a)
        #expect(!out.refused && out.body == body)
    }

    @Test("Only when-questions are checked; refusals stay as they are")
    func scope() {
        let paragraph = Self.answer("The office announced the plea today.")
        #expect(!DateQuestionGate.apply(question: "Which office announced the case?", paragraph).refused)
        let refused = Self.answer("No date in the evidence.", refused: true)
        #expect(DateQuestionGate.apply(question: "When did it happen?", refused).body == "No date in the evidence.")
        #expect(DateQuestionGate.asksWhen("On what date was the patent granted?"))
        #expect(DateQuestionGate.asksWhen("What year did the firm open?"))
        #expect(!DateQuestionGate.asksWhen("Whenever possible, who signed?"))
    }
}
