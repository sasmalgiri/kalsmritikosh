//
//  NearestPassageTests.swift
//  Kalsmritikosh Tests
//
//  §1.3 — the closest-match line on a not-found answer: the passage sharing
//  the most informative question terms wins; a lone common word never
//  qualifies; the quote is one sentence with honest ellipses.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("§1.3 — closest match on a not-found answer")
struct NearestPassageTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test("The passage sharing the most question terms wins; ties keep keyword rank")
    func mostSharedTermsWins() {
        let q = "when was the renewal fee for the trademark paid?"
        let picked = NearestPassageFinder.pick(question: q, candidates: [
            (a, "The fee schedule was revised in 2023."),
            (b, "Our trademark renewal fee reminder: the renewal must be filed by June. Unrelated closing line."),
            (c, "Trademark search report attached."),
        ])
        #expect(picked?.objectID == b)
        #expect(picked?.sharedTerms == ["renewal", "fee", "trademark"])
        #expect(picked?.quote == "Our trademark renewal fee reminder: the renewal must be filed by June.")
    }

    @Test("Honest floor: a single shared word does not qualify when the question carries two or more terms")
    func singleWordNeverQualifies() {
        let q = "what is the warranty period of the laptop?"
        #expect(NearestPassageFinder.pick(question: q, candidates: [
            (a, "The period of the lease is five years."),
        ]) == nil)
    }

    @Test("Stopword-only questions and empty candidate sets yield no line")
    func nothingToShow() {
        #expect(NearestPassageFinder.pick(question: "what is it?", candidates: [(a, "it is what it is")]) == nil)
        #expect(NearestPassageFinder.pick(question: "invoice 4471 amount", candidates: []) == nil)
    }

    @Test("Identifier tokens count as terms; a long sentence is cut with an ellipsis, never passed off as whole")
    func identifierAndCut() {
        let long = String(repeating: "filler words here ", count: 30)
            + "Application 202331019665 was examined and a hearing was fixed "
            + String(repeating: "more filler text ", count: 30)
        let picked = NearestPassageFinder.pick(question: "status of application 202331019665",
                                               candidates: [(a, long)])
        #expect(picked?.sharedTerms == ["application", "202331019665"])
        #expect(picked?.quote.hasPrefix("…") == true)
        #expect(picked?.quote.hasSuffix("…") == true)
        #expect((picked?.quote.count ?? 0) <= NearestPassageFinder.maxQuote + 2)
        #expect(picked?.quote.contains("202331019665") == true)
    }
}
