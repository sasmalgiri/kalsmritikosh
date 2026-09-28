//
//  FactValuePlausibilityTests.swift
//  KalsmritikoshTests
//
//  Topic-Ledger U4 — the junk-value gate. Uses the exact junk the live audit
//  surfaced in `amount` ("rs,", "$0", "$1", "Rs9") plus real amounts that must
//  survive, and confirms non-monetary fields keep normal values.
//

import Testing
@testable import Kalsmritikosh

@Suite("Topic-Ledger U4 — fact value plausibility")
struct FactValuePlausibilityTests {

    @Test func monetaryJunkIsRejected() {
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "rs,") == false)
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "$0") == false)
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "$1") == false)
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "Rs9") == false)
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "$") == false)
    }

    @Test func realAmountsSurvive() {
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "$27") == true)
        #expect(FactValuePlausibility.isAcceptable(field: "amount", value: "₹5,00,000") == true)
        #expect(FactValuePlausibility.isAcceptable(field: "consideration", value: "500000") == true)
    }

    @Test func nonMonetaryFieldsKeepNormalValues() {
        #expect(FactValuePlausibility.isAcceptable(field: "role", value: "Director") == true)
        #expect(FactValuePlausibility.isAcceptable(field: "employer", value: "Liteon Corporation") == true)
        // still rejects pure-punctuation / too-short noise
        #expect(FactValuePlausibility.isAcceptable(field: "role", value: "-") == false)
        #expect(FactValuePlausibility.isAcceptable(field: "status", value: "=") == false)
    }
}
