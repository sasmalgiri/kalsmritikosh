//
//  PaymentProofCustodyGapTests.swift
//  KalsmritikoshTests
//
//  A5.7 — GapDetector.detectMissingPaymentProof (invoice issued but no matching
//  payment) and detectCustodyBreaks (file bytes changed since first ingest).
//  Add to the test target to run.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct PaymentProofCustodyGapTests {

    // MARK: Payment proof

    @Test func unpaidInvoiceIsAGap() {
        let gaps = GapDetector().detectMissingPaymentProof(
            issued: [(amount: 1200, currency: "USD", objectID: UUID())],
            paid: []
        )
        #expect(gaps.count == 1)
        #expect(gaps.first?.kind == .paymentProof)
        #expect(gaps.first?.description.contains("USD 1200") == true)
        // Non-accusatory framing per the spec.
        #expect(gaps.first?.reason.contains("not proof of non-payment") == true)
    }

    @Test func matchingPaymentClearsTheInvoice() {
        let gaps = GapDetector().detectMissingPaymentProof(
            issued: [(amount: 1200, currency: "USD", objectID: UUID())],
            paid: [(amount: 1200, currency: "USD")]
        )
        #expect(gaps.isEmpty)
    }

    @Test func currencyMustMatch() {
        let gaps = GapDetector().detectMissingPaymentProof(
            issued: [(amount: 1200, currency: "USD", objectID: UUID())],
            paid: [(amount: 1200, currency: "EUR")]
        )
        #expect(gaps.count == 1)
    }

    @Test func onePaymentSatisfiesOnlyOneInvoice() {
        let gaps = GapDetector().detectMissingPaymentProof(
            issued: [(1200, "USD", UUID()), (1200, "USD", UUID())],
            paid: [(1200, "USD")]
        )
        // Two identical invoices, one payment → exactly one still unpaid.
        #expect(gaps.count == 1)
    }

    // MARK: Custody break

    @Test func hashMismatchBecomesCustodyBreak() {
        let id = UUID()
        let gaps = GapDetector().detectCustodyBreaks(
            mismatches: [(detail: "content at contract.pdf changed since last ingest", fileID: id)]
        )
        #expect(gaps.count == 1)
        #expect(gaps.first?.kind == .custodyBreak)
        #expect(gaps.first?.description.contains("contract.pdf") == true)
        #expect(gaps.first?.reason.contains("not tampering") == true)
    }

    @Test func custodyBreaksDedupeByFile() {
        let id = UUID()
        let gaps = GapDetector().detectCustodyBreaks(
            mismatches: [(detail: "x", fileID: id), (detail: "x again", fileID: id)]
        )
        #expect(gaps.count == 1)
    }
}
