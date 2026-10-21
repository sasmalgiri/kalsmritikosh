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

    @Test("A labelled value from the ledger survives the rewrite")
    func leadValueKept() {
        let court = "Court: United States District Court E.D. Pennsylvania.\n\n---\nAlso on file: Status granted"
        #expect(AnswerSynthesizer.dropsLeadValue(findings: court,
            prose: "The Supreme Court of Pennsylvania decided Securities & Exchange Commission v. Morgan [1]."))
        #expect(!AnswerSynthesizer.dropsLeadValue(findings: court,
            prose: "The case was decided by the United States District Court for the E.D. of Pennsylvania [1]."))
        let docket = "Docket: 00-1083."
        #expect(AnswerSynthesizer.dropsLeadValue(findings: docket, prose: "The docket number is 2d 15, 18-19 (1st Cir) [1]."))
        #expect(!AnswerSynthesizer.dropsLeadValue(findings: docket, prose: "The docket number is 00-1083 [1]."))
        let date = "Decision date: 10/06/1955."
        #expect(AnswerSynthesizer.dropsLeadValue(findings: date, prose: "It was decided on Wed, 21 Oct 2026 [1]."))
        #expect(!AnswerSynthesizer.dropsLeadValue(findings: date, prose: "It was decided on June 10, 1955 [1]."))
        // Prose findings and unlabelled dumps are not gated.
        #expect(!AnswerSynthesizer.dropsLeadValue(findings: "## Extracted facts\n- **Court:** X", prose: "Anything [1]."))
        #expect(!AnswerSynthesizer.dropsLeadValue(findings: "An employee was overcome by fumes.", prose: "Fumes [1]."))
    }

    @Test("Other questions are not gated")
    func otherQuestions() {
        #expect(!AnswerSynthesizer.dropsAskedValue(question: "What happened in OSHA investigation 220962021?",
            findings: findings, prose: "An employee was overcome by fumes [1]."))
    }
}

@Suite("An absence is stated only when the passages show none either")
struct AbsenceNeedsEmptyPassagesTests {
    @Test("A written date, a docket number or the label's noun in the passages blocks the absence")
    func passagesCarry() {
        let caption = "WRIGHT v. MATHIAS. No. 1867. Municipal Court of Appeals for the District of Columbia. Argued Nov. 7, 1956. Decided Jan. 9, 1957."
        #expect(EvidenceVerifier.passagesMayCarry(field: "decisionDate", label: "Decision date", texts: [caption]))
        #expect(EvidenceVerifier.passagesMayCarry(field: "caseNumber", label: "Case number", texts: [caption]))
        #expect(EvidenceVerifier.passagesMayCarry(field: "court", label: "Court", texts: [caption]))
    }

    @Test("Passages without such a value let the absence stand")
    func passagesLack() {
        let prose = "The parties met to discuss the roof repairs and agreed to meet again."
        #expect(!EvidenceVerifier.passagesMayCarry(field: "decisionDate", label: "Decision date", texts: [prose]))
        #expect(!EvidenceVerifier.passagesMayCarry(field: "caseNumber", label: "Case number", texts: [prose]))
        #expect(!EvidenceVerifier.passagesMayCarry(field: "court", label: "Court", texts: [prose]))
        #expect(!EvidenceVerifier.passagesMayCarry(field: "decisionDate", label: "Decision date", texts: []))
    }
}
