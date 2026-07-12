//
//  AmountExtractionTests.swift
//  KalsmritikoshTests
//
//  A5.3 — RuleEventExtractor.extractAmount: monetary amount + currency parsing
//  that gives financial events a comparable quantity (the data A5.6's amount-
//  contradiction detector needs). Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct AmountExtractionTests {

    @Test func symbolPrefixedAmount() {
        let m = RuleEventExtractor.extractAmount(from: "Total due: $1,200.50 on receipt.")
        #expect(m?.value == 1200.50)
        #expect(m?.currency == "USD")
    }

    @Test func codePrefixAndSuffix() {
        #expect(RuleEventExtractor.extractAmount(from: "Amount EUR 500")?.currency == "EUR")
        #expect(RuleEventExtractor.extractAmount(from: "Amount EUR 500")?.value == 500)
        let suffix = RuleEventExtractor.extractAmount(from: "Paid 2,000 GBP in full")
        #expect(suffix?.value == 2000)
        #expect(suffix?.currency == "GBP")
    }

    @Test func symbolMapping() {
        #expect(RuleEventExtractor.extractAmount(from: "£99")?.currency == "GBP")
        #expect(RuleEventExtractor.extractAmount(from: "₹1,50,000")?.currency == "INR")
    }

    @Test func noAmountReturnsNil() {
        #expect(RuleEventExtractor.extractAmount(from: "No money mentioned here.") == nil)
    }

    @Test func earliestAmountWins() {
        // Symbol form appears before the code form → symbol wins.
        let m = RuleEventExtractor.extractAmount(from: "Invoice $300 then later EUR 900")
        #expect(m?.value == 300)
        #expect(m?.currency == "USD")
    }
}
