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

    @Test("An announcement date must be tied to the announcement, not another event")
    func publicationDate() {
        let q = "When did the Justice Department announce \"Man Sentenced for Fraud\"?"
        let other = Self.answer("The defendant pleaded guilty on March 3, 2014, and was sentenced on June 9, 2014 [1].")
        let out = DateQuestionGate.apply(question: q, other)
        #expect(out.refused && out.body.hasPrefix("The documents don't say when it was announced"))
        let anchored = Self.answer("The U.S. Attorney's Office announced the sentence on June 10, 2014 [1].")
        #expect(!DateQuestionGate.apply(question: q, anchored).refused)
        let dateline = Self.answer("WASHINGTON, June 10, 2014 — A man was sentenced today [1].")
        #expect(!DateQuestionGate.apply(question: q, dateline).refused)
        // Not a publication question: any date stands.
        #expect(!DateQuestionGate.apply(question: "When was he sentenced?", other).refused)
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
