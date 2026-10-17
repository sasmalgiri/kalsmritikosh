//
//  WorkbenchNumberGrammarTests.swift
//  KalsmritikoshTests
//
//  F26 — numbers are read by a declared grammar, not by deleting every non-digit; tiny
//  values survive storage; ROUND rejects a non-finite or out-of-range precision instead
//  of trapping.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F26 — Workbench number grammar and ROUND bounds")
struct WorkbenchNumberGrammarTests {

    private func eval(_ s: String, _ ctx: [String: WorkbenchValue] = [:]) throws -> WorkbenchValue {
        try WorkbenchExpressionEvaluator.evaluate(try WorkbenchExpressionParser.parse(s), in: WorkbenchRowContext(values: ctx))
    }

    @Test("Scientific notation, grouping, currency, percent and accounting negatives parse exactly")
    func acceptedForms() {
        let cases: [(String, Double)] = [
            ("1e3", 1000), ("2.5E-2", 0.025), ("-4", -4), ("+7", 7), (".5", 0.5),
            ("1,234.50", 1234.5), ("1,23,456.75", 123456.75),           // western and Indian grouping
            ("$1,200", 1200), ("₹ 5,000", 5000), ("-$5", -5), ("$-5", -5), ("12 €", 12),
            ("INR 300", 300), ("Rs. 40", 40), ("45%", 45), ("(1,234.50)", -1234.5), ("−3", -3),
        ]
        for (raw, value) in cases {
            #expect(WorkbenchValue.parseNumber(raw) == value, "\(raw)")
        }
    }

    @Test("Junk, ambiguous grouping and non-finite text are not numbers")
    func rejectedForms() {
        for raw in ["abc12", "12abc", "1,23", "1,2345", "1.2.3", "--5", "1e", "e5", "12-34",
                    "1e999", "nan", "inf", "5 6", "$", "%", "()", "2024-08-06"] {
            #expect(WorkbenchValue.parseNumber(raw) == nil, "\(raw) should not parse")
        }
    }

    @Test("Tiny and huge values keep their digits in the stored cell; non-finite is a missing cell")
    func storageKeepsSignificance() {
        #expect(WorkbenchValue.number(1e-11).storedString == "0.00000000001")
        #expect(WorkbenchValue.number(0.1 + 0.2).storedString == "0.3")
        #expect(WorkbenchValue.number(1.5e20).storedString == "150000000000000000000")
        #expect(WorkbenchValue.number(-2.5e-7).storedString == "-0.00000025")
        #expect(WorkbenchValue.number(.nan).storedString == nil)
        #expect(WorkbenchValue.number(.infinity).storedString == nil)
        // Round trip: the stored string parses back to the same value.
        for n in [1e-11, 123.456, -0.000789, 9.87654321e18] {
            #expect(WorkbenchValue.parseNumber(WorkbenchValue.number(n).storedString ?? "") == n)
        }
    }

    @Test("ROUND with a non-finite or out-of-range precision is an error, never a trap")
    func roundPrecisionBounded() throws {
        #expect(try eval("ROUND([x], [p])", ["x": .number(3.14159), "p": .number(2)]) == .number(3.14))
        #expect(try eval("ROUND([x], [p])", ["x": .number(1234), "p": .number(-2)]) == .number(1200))
        for bad in [Double.nan, .infinity, 1e20, -1e20, 400, 2.5] {
            #expect(throws: WorkbenchEvaluationError.self, "precision \(bad)") {
                try eval("ROUND([x], [p])", ["x": .number(1), "p": .number(bad)])
            }
        }
        // An overflowing result is the honest null, not infinity.
        #expect(try eval("ROUND([x], [p])", ["x": .number(1e300), "p": .number(15)]) == .null)
    }
}
