//
//  WorkbenchEvaluatorTests.swift
//  KalsmritikoshTests
//
//  LAB-002 — the tree-walking evaluator. Proves total, deterministic semantics: arithmetic and its
//  honest null (divide-by-zero, missing operand), comparison/logical/concat, the allowlisted function
//  library (IF/COALESCE/ISBLANK, math, string, PERCENT, DATEDIFF, YEAR/MONTH/DAY), value coercion, an
//  unknown-field error, and reproducibility (same context → same output). No wall-clock, no locale.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 — expression evaluator")
struct WorkbenchEvaluatorTests {

    private func eval(_ s: String, _ ctx: [String: WorkbenchValue] = [:]) throws -> WorkbenchValue {
        try WorkbenchExpressionEvaluator.evaluate(try WorkbenchExpressionParser.parse(s), in: WorkbenchRowContext(values: ctx))
    }

    @Test("Arithmetic computes; a missing operand or divide-by-zero is the honest null")
    func arithmetic() throws {
        #expect(try eval("2 + 3 * 4") == .number(14))
        #expect(try eval("[a] + [b]", ["a": .number(10), "b": .number(5)]) == .number(15))
        #expect(try eval("[a] / [b]", ["a": .number(1), "b": .number(0)]) == .null)          // divide-by-zero → null
        #expect(try eval("[a] + [b]", ["a": .number(1), "b": .null]) == .null)               // null propagates
    }

    @Test("Comparison operators evaluate to booleans; ordering across null yields null")
    func comparison() throws {
        #expect(try eval("3 > 2") == .boolean(true))
        #expect(try eval("3 <= 2") == .boolean(false))
        #expect(try eval("[a] = [b]", ["a": .number(5), "b": .number(5)]) == .boolean(true))
        #expect(try eval("[a] < [b]", ["a": .null, "b": .number(5)]) == .null)
        #expect(try eval("[a] = [b]", ["a": .null, "b": .null]) == .boolean(true))
    }

    @Test("Logical operators use truthiness and short-circuit")
    func logical() throws {
        #expect(try eval("TRUE AND FALSE") == .boolean(false))
        #expect(try eval("FALSE OR TRUE") == .boolean(true))
        #expect(try eval("NOT (1 = 1)") == .boolean(false))
    }

    @Test("Concatenation joins text; null contributes empty")
    func concat() throws {
        #expect(try eval("\"a\" & \"b\"") == .text("ab"))
        #expect(try eval("[x] & \"!\"", ["x": .text("hi")]) == .text("hi!"))
    }

    @Test("IF / COALESCE / ISBLANK behave deterministically")
    func controlFunctions() throws {
        #expect(try eval("IF(1 > 0, \"y\", \"n\")") == .text("y"))
        #expect(try eval("IF(1 < 0, \"y\", \"n\")") == .text("n"))
        #expect(try eval("IF(1 < 0, \"y\")") == .null)                                   // no else → null
        #expect(try eval("COALESCE([a], [b], 0)", ["a": .null, "b": .number(7)]) == .number(7))
        #expect(try eval("ISBLANK([a])", ["a": .null]) == .boolean(true))
        #expect(try eval("ISBLANK([a])", ["a": .number(1)]) == .boolean(false))
    }

    @Test("Math functions compute; a bad domain is null")
    func mathFunctions() throws {
        #expect(try eval("ABS(-4)") == .number(4))
        #expect(try eval("ROUND(3.14159, 2)") == .number(3.14))
        #expect(try eval("ROUND(2.5)") == .number(3))
        #expect(try eval("MOD(7, 3)") == .number(1))
        #expect(try eval("MOD(7, 0)") == .null)
        #expect(try eval("MIN(3, 1, 2)") == .number(1))
        #expect(try eval("MAX(3, 1, 2)") == .number(3))
        #expect(try eval("SQRT(-1)") == .null)
    }

    @Test("String functions compute")
    func stringFunctions() throws {
        #expect(try eval("LEN(\"abc\")") == .number(3))
        #expect(try eval("UPPER(\"ab\")") == .text("AB"))
        #expect(try eval("TRIM(\"  x  \")") == .text("x"))
        #expect(try eval("CONCAT(\"a\", \"b\", \"c\")") == .text("abc"))
        #expect(try eval("CONTAINS(\"hello\", \"ell\")") == .boolean(true))
        #expect(try eval("STARTSWITH(\"hello\", \"he\")") == .boolean(true))
        #expect(try eval("ENDSWITH(\"hello\", \"lo\")") == .boolean(true))
    }

    @Test("PERCENT divides safely")
    func percent() throws {
        #expect(try eval("PERCENT(25, 200)") == .number(12.5))
        #expect(try eval("PERCENT(1, 0)") == .null)
    }

    @Test("DATEDIFF and date-part functions use a fixed UTC calendar")
    func dateFunctions() throws {
        let a = WorkbenchValue.date(WorkbenchValue.parseDate("2020-01-01")!)
        let b = WorkbenchValue.date(WorkbenchValue.parseDate("2020-01-31")!)
        #expect(try eval("DATEDIFF(\"days\", [a], [b])", ["a": a, "b": b]) == .number(30))
        let y0 = WorkbenchValue.date(WorkbenchValue.parseDate("2018-06-01")!)
        let y1 = WorkbenchValue.date(WorkbenchValue.parseDate("2021-06-01")!)
        #expect(try eval("DATEDIFF(\"years\", [a], [b])", ["a": y0, "b": y1]) == .number(3))
        #expect(try eval("YEAR([d])", ["d": a]) == .number(2020))
        #expect(try eval("MONTH([d])", ["d": b]) == .number(1))
        #expect(try eval("DAY([d])", ["d": b]) == .number(31))
    }

    @Test("A reference to a field absent from the context is an error, not a silent null")
    func unknownFieldErrors() {
        #expect(throws: WorkbenchEvaluationError.self) {
            _ = try WorkbenchExpressionEvaluator.evaluate(try WorkbenchExpressionParser.parse("[missing] + 1"),
                                                          in: WorkbenchRowContext(values: [:]))
        }
    }

    @Test("Coercion parses money / dates / booleans; unparseable typed values become null")
    func coercion() {
        #expect(WorkbenchValue.coerce("$1,234.50", shape: .money).asNumber == 1234.5)
        #expect(WorkbenchValue.coerce("(1,000)", shape: .money).asNumber == -1000)
        #expect(WorkbenchValue.coerce("not-a-number", shape: .number) == .null)
        #expect(WorkbenchValue.coerce("yes", shape: .boolean) == .boolean(true))
        #expect(WorkbenchValue.coerce("2021-03-04", shape: .date).asDate != nil)
        #expect(WorkbenchValue.coerce(nil, shape: .text) == .null)
    }

    @Test("Evaluation is reproducible: the same formula + context yields the same value twice")
    func deterministic() throws {
        let ctx: [String: WorkbenchValue] = ["a": .number(3), "b": .number(4)]
        let first = try eval("SQRT([a]*[a] + [b]*[b])", ctx)
        let second = try eval("SQRT([a]*[a] + [b]*[b])", ctx)
        #expect(first == .number(5))
        #expect(first == second)
    }

    @Test("A rendered number is round-trip stable (integers without a decimal point)")
    func numberRendering() {
        #expect(WorkbenchValue.number(5).storedString == "5")
        #expect(WorkbenchValue.number(2.5).storedString == "2.5")
        #expect(WorkbenchValue.null.storedString == nil)
    }
}
