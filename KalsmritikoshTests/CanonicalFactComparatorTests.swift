//
//  CanonicalFactComparatorTests.swift
//  KalsmritikoshTests
//
//  CLM-003 — canonical comparison: format differences are NOT contradictions; genuine value
//  differences are. Both sides preserved (never averaged).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("CLM-003 CanonicalFactComparator")
struct CanonicalFactComparatorTests {

    private let cmp = CanonicalFactComparator()
    private func f(_ field: String, _ v: String) -> GenericFact {
        GenericFact(subjectLabel: "S", field: field, value: v, status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    @Test("Currency/format differences are equivalent, not contradictions")
    func moneyFormats() {
        #expect(cmp.compare(f("amount", "₹3,800"), f("amount", "Rs 3800")) == .equivalent)
        #expect(cmp.compare(f("amount", "₹3,800"), f("amount", "₹5,000")) == .contradictory)
    }

    @Test("Different date formats for the same day are equivalent")
    func dateFormats() {
        #expect(cmp.compare(f("date", "12/01/2024"), f("date", "12 Jan 2024")) == .equivalent)
        #expect(cmp.compare(f("date", "12 Jan 2024"), f("date", "13 Jan 2024")) == .contradictory)
    }

    @Test("Org suffix/case differences are equivalent")
    func orgNames() {
        #expect(cmp.compare(f("employer", "Orchid Chemicals Ltd"), f("employer", "orchid chemicals")) == .equivalent)
        #expect(cmp.compare(f("employer", "Hospira"), f("employer", "Orchid")) == .contradictory)
    }

    @Test("Different fields are incomparable")
    func incomparable() {
        #expect(cmp.compare(f("amount", "1"), f("date", "1")) == .incomparable)
    }

    @Test("contradictions(in:) returns only genuine conflicts")
    func setContradictions() {
        let facts = [f("amount", "₹3,800"), f("amount", "Rs 3800"), f("amount", "₹9,000")]
        // 3800≡3800 (equivalent), both contradict 9000 → 2 conflict pairs
        #expect(cmp.contradictions(in: facts).count == 2)
    }
}
