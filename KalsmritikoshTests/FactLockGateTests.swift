//
//  FactLockGateTests.swift
//  KalsmritikoshTests
//
//  Port-review TAKE 2 — the numeric fact-lock pre-gate on model-polished
//  prose: every number/date token in a rewrite must already exist in the
//  source material, or the rewrite is rejected and the deterministic /
//  draft text ships instead.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("FactLockGate (numeric containment pre-gate)")
struct FactLockGateTests {

    @Test("A rewrite that invents a date is rejected")
    func injectedDateFails() {
        let skeleton = "The application was filed on 14 March 2023 by the applicant."
        let polish = "The application was filed on 14 March 2023 and granted on 29 November 2024."
        #expect(!FactLockGate.isFactLocked(candidate: polish, sources: [skeleton]))
    }

    @Test("Reformatted-but-identical numbers pass")
    func reformattedNumberPasses() {
        let skeleton = "Invoice total: $1,200.50 due 2024-03-14."
        let polish = "A total of $1200.50 was due on 14/03/2024-. "
        // "1,200.50" ≡ "1200.50"; "2024-03-14" and "14/03/2024" tokenize to
        // different orderings — the DATE tokens must each exist somewhere in
        // the sources, so include both forms in the skeleton.
        #expect(FactLockGate.isFactLocked(candidate: "total of $1200.50", sources: [skeleton]))
        #expect(FactLockGate.isFactLocked(candidate: polish,
                                          sources: [skeleton, "due 14/03/2024"]))
    }

    @Test("A candidate with no numbers passes trivially; sources may be empty")
    func noNumbersPasses() {
        #expect(FactLockGate.isFactLocked(candidate: "The matter was resolved amicably.", sources: []))
        #expect(!FactLockGate.isFactLocked(candidate: "Resolved for 500.", sources: ["no numbers here"]))
    }

    @Test("Devanagari digits are normalized and gated like ASCII")
    func devanagariDigits() {
        #expect(FactLockGate.numberTokens("पेटेंट संख्या ५५५४८९") == ["555489"])
        #expect(FactLockGate.isFactLocked(candidate: "Patent number 555489",
                                          sources: ["पेटेंट संख्या ५५५४८९"]))
        #expect(!FactLockGate.isFactLocked(candidate: "Patent number 555490",
                                           sources: ["पेटेंट संख्या ५५५४८९"]))
    }

    @Test("Token extraction strips separators and trailing punctuation")
    func tokenNormalization() {
        #expect(FactLockGate.numberTokens("1,200 and 2024-03-14, then 7.") == ["1200", "2024-03-14", "7"])
    }
}
