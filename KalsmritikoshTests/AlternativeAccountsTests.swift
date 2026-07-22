//
//  AlternativeAccountsTests.swift
//  KalsmritikoshTests
//
//  REC-002 — genuine conflicts become balanced, unresolved alternative accounts; format
//  variants merge as corroboration; single-value fields are not conflicts.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("REC-002 AlternativeAccounts")
struct AlternativeAccountsTests {

    private let builder = AlternativeAccountsBuilder()
    private func fact(_ field: String, _ v: String) -> GenericFact {
        GenericFact(subjectLabel: "Sasmal", field: field, value: v, status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()])
    }

    @Test("Genuinely different values become one unresolved account with both versions")
    func genuineConflict() {
        let accts = builder.build(from: [fact("employer", "Orchid Chemicals Ltd"), fact("employer", "Hospira India")])
        #expect(accts.count == 1)
        #expect(accts.first?.versions.count == 2)
        #expect(accts.first?.isUnresolved == true)
    }

    @Test("Format variants merge as corroboration, not a second version")
    func formatVariantMerges() {
        let accts = builder.build(from: [fact("employer", "Orchid Chemicals Ltd"), fact("employer", "orchid chemicals")])
        #expect(accts.isEmpty)   // same canonical value → no conflict
    }

    @Test("Single-value field is not a conflict")
    func singleValue() {
        #expect(builder.build(from: [fact("role", "PPIC Executive")]).isEmpty)
    }

    @Test("Render presents versions without resolving them")
    func balancedRender() {
        let accts = builder.build(from: [fact("employer", "Orchid Chemicals Ltd"), fact("employer", "Hospira India")])
        let text = builder.render(accts[0])
        #expect(text.contains("disagree"))
        #expect(text.contains("Orchid"))
        #expect(text.contains("Hospira"))
    }
}
