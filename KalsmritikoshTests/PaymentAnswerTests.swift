//
//  PaymentAnswerTests.swift
//  KalsmritikoshTests
//
//  P2 payments — one-line OCR receipts yield a payee and an amount; a payment
//  question sums only payment confirmations to that payee, per currency.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P2 — payments to a payee")
struct PaymentAnswerTests {

    @Test("A one-line UPI screenshot yields the payee (stopping at the masked account) and the OCR-lost rupee amount")
    func ocrReceipt() {
        let text = "Transaction Successful 05:18 pm on 04 Oct 2023 Paid to Khurana and Khurana Advocates and IP Attorneys XXXXXXXXXXX1671 Axis Bank Transfer Details Transaction ID T2310041718119366351819 Debited from XXXXXX1872 UTR: 327780872723 Powered by YES BANK ·10,000 ^ ·10,000"
        let facts = TransactionDomainPack.extractFacts(fromText: text, subjectLabel: "Transaction Successful", blockID: UUID())
        #expect(facts.first(where: { $0.field == "counterparty" })?.value == "Khurana and Khurana Advocates and IP Attorneys")
        let amount = facts.first(where: { $0.field == "amount" })
        #expect(amount?.value == "₹10,000")
        #expect(amount?.unit == "INR")
        #expect(facts.first(where: { $0.field == "date" })?.value == "2023-10-04", "a written-month receipt date")
    }

    @Test("OCR splits a screenshot: the amount's own block ('Powered by YES BANK ·10,000') still yields the amount")
    func splitBlock() {
        let facts = TransactionDomainPack.extractFacts(fromText: "UTR: 327780872723 Powered by YES BANK ·10,000 ^ ·10,000",
                                                       subjectLabel: "x", blockID: UUID())
        #expect(facts.first(where: { $0.field == "amount" })?.value == "₹10,000")
    }

    @Test("A '·' figure outside a payment confirmation is not money")
    func noOcrAmountWithoutPayment() {
        let facts = TransactionDomainPack.extractFacts(fromText: "Agenda · 1,200 attendees expected", subjectLabel: "x", blockID: UUID())
        #expect(!facts.contains { $0.field == "amount" })
    }

    @Test("The payee is read from the question; generic firm words do not count as its tokens")
    func questionPayee() throws {
        let p = try #require(PaymentAnswerComposer.payee(in: "How much did I pay Khurana & Khurana?"))
        #expect(p.tokens == ["khurana"])
        #expect(PaymentAnswerComposer.payee(in: "How much did I pay the advocates?") == nil)
        #expect(PaymentAnswerComposer.counterpartyMatches("Khurana and Khurana Advocates", tokens: ["khurana"]))
        #expect(!PaymentAnswerComposer.counterpartyMatches("info@khuranaandkhurana", tokens: ["khurana"]),
                "an e-mail recipient is correspondence, not a payee")
    }

    @Test("Amounts are listed by date and totalled per currency, never mixed")
    func totals() throws {
        func f(_ field: String, _ value: String, _ unit: String? = nil, _ label: String) -> GenericFact {
            GenericFact(subjectLabel: label, field: field, value: value, unit: unit,
                        assessment: EvidenceAssessment(basis: .sourceAsserted, origin: .sourceExtraction),
                        confidence: 0.8, sourceBlockIDs: [UUID()])
        }
        let out = try #require(PaymentAnswerComposer.compose(payeePhrase: "khurana & khurana", documents: [
            (label: "Receipt B", amounts: [f("amount", "₹5,000", "INR", "Receipt B")], dates: [f("date", "2024-01-10", nil, "Receipt B")]),
            (label: "Receipt A", amounts: [f("amount", "₹10,000", "INR", "Receipt A"), f("amount", "₹10,000", "INR", "Receipt A")],
             dates: [f("date", "2023-10-04", nil, "Receipt A")]),
            (label: "Wire", amounts: [f("amount", "$100", "USD", "Wire")], dates: []),
        ]))
        #expect(out.text.contains("2023-10-04 — ₹10,000 (Receipt A)\n2024-01-10 — ₹5,000 (Receipt B)"))
        #expect(out.text.contains("Total on record: INR 15000 + USD 100 (currencies are never mixed)."))
        #expect(out.facts.count == 3, "a repeated amount in one document is one payment")
    }
}
