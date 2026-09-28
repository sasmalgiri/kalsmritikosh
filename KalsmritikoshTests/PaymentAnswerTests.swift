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

    @Test("The owner's real screenshot: four OCR spellings of ₹3,800 across line blocks vote down the '23,800' misread")
    func documentVote() {
        let lines = ["Transaction Successful 03:34 pm on 05 Dec 2024", "Paid to", "Khurana and Khurana",
                     "UTR: 089305755533", "Powered by", "UPI /YES BANK", "23,800", "<", "R3,800", "\t·3,800\t<\t\t₺3,800\t"]
        let blocks = lines.map { (id: UUID(), text: $0) }
        let fact = TransactionDomainPack.documentLevelAmount(blocks: blocks, subjectLabel: "Transaction Successful")
        #expect(fact?.value == "₹3,800")
        #expect(TransactionDomainPack.documentLevelAmount(
            blocks: [(id: UUID(), text: "Agenda"), (id: UUID(), text: "·1,200 attendees")], subjectLabel: "x") == nil,
            "no payment confirmation, no amount")
    }

    @Test("'Paid to' on its own OCR line: the payee is read from the following lines")
    func splitPayee() {
        let lines = ["Transaction Successful", "05:18 pm on 04 Oct 2023", "Paid to", "Khurana and Khurana",
                     "Advocates and IP Attorneys", "XXXXXXXXXXX1671", "Axis Bank"]
        let fact = TransactionDomainPack.documentLevelPayee(blocks: lines.map { (id: UUID(), text: $0) }, subjectLabel: "x")
        #expect(fact?.value == "Khurana and Khurana Advocates and IP Attorneys")
        #expect(TransactionDomainPack.documentLevelPayee(blocks: [(id: UUID(), text: "Dear team")], subjectLabel: "x") == nil)
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
        #expect(p.phrase == "Khurana & Khurana", "the payee as the question wrote it")
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
        #expect(out.text.contains("Total on record: ₹15,000 + $100 (currencies are never mixed)."))
        #expect(out.facts.count == 3, "a repeated amount in one document is one payment")
    }
}

@Suite("P2.9 — is there any invoice from ‹party›")
struct DocumentKindAnswerTests {
    @Test("The question's kind and party are read; others are not")
    func reading() {
        let q = DocumentKindAnswerComposer.read("is there any invoice from Khurana and Khurana")
        #expect(q?.kinds == [.invoice] && q?.kindWord == "invoice")
        #expect(q?.partyPhrase == "Khurana and Khurana" && q?.tokens == ["khurana"])
        #expect(DocumentKindAnswerComposer.read("Do I have receipts from Acme Stores?")?.kinds == [.receipt, .image])
        #expect(DocumentKindAnswerComposer.read("How much did I pay Khurana?") == nil)
        #expect(DocumentKindAnswerComposer.read("is there any invoice from the company") == nil, "no distinctive party word")
    }

    @Test("Yes, numbered, dated and ordered")
    func compose() {
        let q = DocumentKindAnswerComposer.read("is there any invoice from Khurana & Khurana")!
        let a = UUID(), b = UUID()
        let text = DocumentKindAnswerComposer.compose(q, matches: [
            .init(objectID: a, title: "24-25_9617.pdf", number: "24-25/9617", date: "2024-12-02"),
            .init(objectID: b, title: "23-24_9643.pdf", number: "23-24/9643", date: "2023-10-04"),
        ], searched: 7)
        #expect(text.hasPrefix("Yes — 2 invoices from Khurana & Khurana on record:"))
        #expect(text.contains("No. 23-24/9643 — 2023-10-04 (23-24_9643.pdf)\n• No. 24-25/9617"), "oldest first")
    }
}
