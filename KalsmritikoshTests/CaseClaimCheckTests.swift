//
//  CaseClaimCheckTests.swift
//  KalsmritikoshTests
//
//  Case plan 2026-11-16 (SEARCH-15): "Check this claim" builds valid case-search queries — supporting (subject and figure)
//  and contrary (same subject, not that figure) — deterministically, with AI off.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Check this claim — supporting and contrary queries in the case search's syntax")
struct CaseClaimCheckTests {

    @Test("A duplicate-payment claim: the subject and the figure, and the same subject without it; both parse as valid searches")
    func duplicatePaymentClaim() throws {
        let p = CaseClaimCheck.plan(claim: "Kestrel Supplies was paid INR 50,000 twice for invoice INV-104")
        #expect(p.subject.first == "Kestrel Supplies", "\(p.subject)")
        #expect(p.figures == ["amount:50000"], "\(p.figures)")
        #expect(p.supporting.hasPrefix("\"Kestrel Supplies\"") && p.supporting.hasSuffix("amount:50000"), "\(p.supporting)")
        let contrary = try #require(p.contrary)
        #expect(contrary.contains(" NOT amount:50000"), "\(contrary)")
        #expect(CaseSearchParser.parse(p.supporting).isValid, "\(CaseSearchParser.parse(p.supporting).errors)")
        #expect(CaseSearchParser.parse(contrary).isValid, "\(CaseSearchParser.parse(contrary).errors)")
        #expect(p.explanation.contains("read them to decide"))
        #expect(CaseClaimCheck.plan(claim: "Kestrel Supplies was paid INR 50,000 twice for invoice INV-104") == p, "deterministic")
    }

    @Test("A claim with no figure: no other-figure query, said so; a claim with nothing distinctive asks for words")
    func noFigureAndNothingDistinctive() {
        let p = CaseClaimCheck.plan(claim: "The seal on the sample was broken before Ravi Kumar signed for it")
        #expect(p.contrary == nil && p.figures.isEmpty)
        #expect(p.subject.contains("Ravi Kumar") && CaseSearchParser.parse(p.supporting).isValid, "\(p.supporting)")
        #expect(p.explanation.contains("states no figure"))
        let empty = CaseClaimCheck.plan(claim: "it was so")
        #expect(empty.subject.isEmpty && empty.supporting.isEmpty && empty.explanation.contains("nothing distinctive"))
    }

    @Test("Two figures are searched as either; the contrary excludes both")
    func twoFigures() throws {
        let p = CaseClaimCheck.plan(claim: "Northwind paid $1,200 and then $1,500 to the contractor")
        #expect(p.figures == ["amount:1200", "amount:1500"])
        #expect(p.supporting.contains("(amount:1200 OR amount:1500)") && p.contrary?.contains("NOT (amount:1200 OR amount:1500)") == true, "\(p.supporting)")
        #expect(CaseSearchParser.parse(try #require(p.contrary)).isValid)
    }
}
