//
//  EvidenceSufficiencyTests.swift
//  KalsmritikoshTests
//
//  RET-006 — verifies the answer layer can honestly disclose which requested fields
//  the retrieved evidence does and does not cover, instead of fabricating a value or
//  emitting a vague "not specified". Absence is disclosed neutrally, never as proof.
//

import Testing
@testable import Kalsmritikosh

@Suite("RET-006 EvidenceSufficiency")
struct EvidenceSufficiencyTests {

    private let qc = QueryPlanCompiler()
    private let assessor = EvidenceSufficiencyAssessor()

    private func plan(_ q: String, scope: UserIntent.Scope = .global) -> QueryPlan {
        qc.compile(intent: UserIntent(kind: .factualLookup, scope: scope, rawQuestion: q),
                   category: .fact, queryClass: .ordinary)
    }

    @Test("Payment answered only by a date-only email reports amount + payee missing")
    func paymentMissingAmountAndPayee() {
        let s = assessor.assess(plan: plan("PhonePe payment — to whom and how much?"),
                                evidenceTexts: ["Payment done on 12 Jan 2024. Regards."])
        #expect(s.missing.contains(.monetaryAmount))
        #expect(s.missing.contains(.counterparty))
        #expect(!s.isComplete)
        #expect(s.disclosure().contains("amount"))
    }

    @Test("Payment answered by the receipt is complete")
    func paymentCompleteWithReceipt() {
        let s = assessor.assess(plan: plan("PhonePe payment — to whom and how much?"),
                                evidenceTexts: ["Paid to Rajesh Kumar. Amount ₹3,800. Transaction successful."])
        #expect(s.covered.contains(.monetaryAmount))
        #expect(s.covered.contains(.counterparty))
        #expect(s.isComplete)
    }

    @Test("Employment answered by the résumé is complete")
    func employmentCompleteWithResume() {
        let s = assessor.assess(plan: plan("Where has Sasmal worked?", scope: .person("Sasmal")),
                                evidenceTexts: ["Work Experience: PPIC Executive at Orchid Chemicals since Dec 2004."])
        #expect(s.covered.contains(.employment))
        #expect(s.isComplete)
    }

    @Test("No requested fields → trivially complete, empty disclosure")
    func noFieldsComplete() {
        let s = assessor.assess(plan: plan("Tell me about the project"), evidenceTexts: ["Some text."])
        #expect(s.isComplete)
        #expect(s.disclosure().isEmpty)
    }
}
