//
//  AmountContradictionTests.swift
//  KalsmritikoshTests
//
//  A5.6 — ContradictionDetector.detectEventAmountConflicts: two independent
//  sources stating different amounts for the same financial event conflict;
//  same source, cross-currency, or within-tolerance pairs do not. Add to the
//  test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct AmountContradictionTests {

    private func invoice(_ amount: Double, _ currency: String, source: UUID, title: String = "Invoice issued") -> Event {
        Event(
            kind: .invoiceIssued, date: Date(timeIntervalSince1970: 1_700_000_000),
            title: title, sourceObjectID: source, confidence: .high,
            attributes: [
                "amount": AnyCodable(.double(amount)),
                "currency": AnyCodable(.string(currency))
            ]
        )
    }

    @Test func differentAmountsSameCurrencyDifferentSourcesConflict() {
        let a = invoice(1000, "USD", source: UUID())
        let b = invoice(1200, "USD", source: UUID())
        let found = ContradictionDetector().detectEventAmountConflicts([a, b])
        #expect(found.count == 1)
        #expect(found.first?.kind == .amount)
        #expect(found.first?.claimA.contains("1000") == true)
        #expect(found.first?.claimB.contains("1200") == true)
    }

    @Test func sameSourceDoesNotConflict() {
        let s = UUID()
        let found = ContradictionDetector().detectEventAmountConflicts([
            invoice(1000, "USD", source: s), invoice(1200, "USD", source: s)
        ])
        #expect(found.isEmpty)
    }

    @Test func differentCurrenciesDoNotConflict() {
        let found = ContradictionDetector().detectEventAmountConflicts([
            invoice(1000, "USD", source: UUID()), invoice(1000, "EUR", source: UUID())
        ])
        #expect(found.isEmpty)
    }

    @Test func withinToleranceDoesNotConflict() {
        // 0.3% apart, below the 0.5% default tolerance.
        let found = ContradictionDetector().detectEventAmountConflicts([
            invoice(1000.00, "USD", source: UUID()), invoice(1002.00, "USD", source: UUID())
        ])
        #expect(found.isEmpty)
    }

    @Test func differentTitlesAreNotTheSameEvent() {
        let found = ContradictionDetector().detectEventAmountConflicts([
            invoice(1000, "USD", source: UUID(), title: "Invoice 100"),
            invoice(9999, "USD", source: UUID(), title: "Invoice 200")
        ])
        #expect(found.isEmpty)
    }
}
