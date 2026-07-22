//
//  TransactionDomainPackTests.swift
//  KalsmritikoshTests
//
//  SEM-005 — the transaction/payment domain pack extracts amount + counterparty + date as
//  evidence-linked SOURCE_ASSERTED facts, and stays quiet on non-transactional text.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("SEM-005 TransactionDomainPack")
struct TransactionDomainPackTests {

    private let block = UUID()

    @Test("Receipt text yields amount + counterparty + date, all evidence-linked")
    func extractsReceipt() {
        let receipt = "PhonePe Transaction Successful\nPaid to Rajesh Kumar\nAmount ₹3,800\nDate 12/01/2024"
        let facts = TransactionDomainPack.extractFacts(fromText: receipt, subjectLabel: "payment", blockID: block)
        let byField = Dictionary(uniqueKeysWithValues: facts.map { ($0.field, $0) })
        #expect(byField["amount"]?.value == "₹3,800")
        #expect(byField["amount"]?.unit == "INR")
        #expect(byField["counterparty"]?.value == "Rajesh Kumar")
        #expect(byField["date"]?.value == "12/01/2024")
        for f in facts {
            #expect(f.status == .sourceAsserted)
            #expect(f.sourceBlockIDs == [block])
            #expect(f.isMaterialAndSupported)
        }
    }

    @Test("Non-transactional text extracts nothing (no false facts)")
    func quietOnNonTransactional() {
        #expect(TransactionDomainPack.extractFacts(fromText: "Hope the project goes well.",
                                                   subjectLabel: "x", blockID: block).isEmpty)
    }

    @Test("Pack registers its recognizers additively onto the semantics registry")
    func registersRecognizers() {
        let reg = TransactionDomainPack.registry()
        #expect(reg.tags(forText: "Paid to Rajesh Kumar").contains { $0.role == "payeeLine" })
        #expect(reg.tags(forText: "UPI Ref: 40233112").contains { $0.role == "transactionReference" })
    }

    @Test("USD amounts carry a USD unit")
    func usdUnit() {
        let facts = TransactionDomainPack.extractFacts(fromText: "Paid to Acme. Amount $120.50",
                                                       subjectLabel: "p", blockID: block)
        #expect(facts.first { $0.field == "amount" }?.unit == "USD")
    }
}
