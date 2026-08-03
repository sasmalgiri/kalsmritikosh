//
//  WorkbenchExpressionTests.swift
//  KalsmritikoshTests
//
//  LAB-002 — the safe parsed expression language (tokenizer → recursive-descent parser). Proves the
//  grammar is fixed and closed: operator precedence, field references (bracketed + bare), literals,
//  function calls against the allowlist, referenced-field extraction — and, crucially, that an unknown
//  function or stray symbol is a PARSE ERROR, never silently accepted. There is no `eval` path.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 — safe expression parser")
struct WorkbenchExpressionTests {

    private func parse(_ s: String) throws -> WorkbenchExpr { try WorkbenchExpressionParser.parse(s) }

    @Test("Numbers, strings, booleans and null parse to their literal nodes")
    func literals() throws {
        #expect(try parse("42") == .number(42))
        #expect(try parse("3.5") == .number(3.5))
        #expect(try parse("\"hi\"") == .string("hi"))
        #expect(try parse("TRUE") == .boolean(true))
        #expect(try parse("false") == .boolean(false))
        #expect(try parse("NULL") == .null)
    }

    @Test("A bare identifier and a bracketed name both parse as field references")
    func fieldReferences() throws {
        #expect(try parse("amount") == .field("amount"))
        #expect(try parse("[Total Due]") == .field("Total Due"))
    }

    @Test("Arithmetic honours precedence and left associativity")
    func arithmeticPrecedence() throws {
        // 1 + 2 * 3  →  1 + (2*3)
        #expect(try parse("1 + 2 * 3") == .binary(.add, .number(1), .binary(.multiply, .number(2), .number(3))))
        // (1 + 2) * 3
        #expect(try parse("(1 + 2) * 3") == .binary(.multiply, .binary(.add, .number(1), .number(2)), .number(3)))
        // 10 - 2 - 3  →  (10-2)-3  (left assoc)
        #expect(try parse("10 - 2 - 3") == .binary(.subtract, .binary(.subtract, .number(10), .number(2)), .number(3)))
    }

    @Test("Unary minus and NOT parse")
    func unary() throws {
        #expect(try parse("-5") == .unary(.negate, .number(5)))
        #expect(try parse("NOT TRUE") == .unary(.not, .boolean(true)))
    }

    @Test("Comparison, logical and concatenation operators parse with the right shape")
    func operators() throws {
        #expect(try parse("a = 1") == .binary(.equal, .field("a"), .number(1)))
        #expect(try parse("a <> 1") == .binary(.notEqual, .field("a"), .number(1)))
        #expect(try parse("a != 1") == .binary(.notEqual, .field("a"), .number(1)))
        #expect(try parse("a >= 1 AND b < 2") ==
                .binary(.and, .binary(.greaterOrEqual, .field("a"), .number(1)), .binary(.lessThan, .field("b"), .number(2))))
        #expect(try parse("\"x\" & \"y\"") == .binary(.concat, .string("x"), .string("y")))
    }

    @Test("Allowlisted function calls parse with their arguments")
    func functionCalls() throws {
        #expect(try parse("ROUND(3.14159, 2)") == .call("ROUND", [.number(3.14159), .number(2)]))
        #expect(try parse("IF(a > 0, \"pos\", \"neg\")") ==
                .call("IF", [.binary(.greaterThan, .field("a"), .number(0)), .string("pos"), .string("neg")]))
        #expect(try parse("COALESCE(a, b, 0)") == .call("COALESCE", [.field("a"), .field("b"), .number(0)]))
    }

    @Test("referencedFields returns each distinct field once, in first-seen order")
    func referencedFields() throws {
        let e = try parse("[Gross] - [Tax] + [Gross] * 0")
        #expect(e.referencedFields == ["Gross", "Tax"])
    }

    // MARK: - The engine is closed: bad input is rejected, never evaluated

    @Test("An unknown function is a parse error (no dynamic dispatch, no eval)")
    func unknownFunctionRejected() {
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("SYSTEM(\"rm -rf\")") }
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("EVAL(1)") }
    }

    @Test("An unterminated string is rejected")
    func unterminatedString() {
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("\"oops") }
    }

    @Test("A stray character is rejected")
    func strayCharacter() {
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("1 $ 2") }
    }

    @Test("An empty formula is rejected")
    func emptyRejected() {
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("   ") }
    }

    @Test("Trailing tokens after a complete expression are rejected")
    func trailingTokensRejected() {
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("1 + 2 3") }
    }

    @Test("An unbalanced parenthesis is rejected")
    func unbalancedParen() {
        #expect(throws: WorkbenchExpressionError.self) { _ = try parse("(1 + 2") }
    }

    @Test("The engine version is a stable non-empty constant")
    func engineVersion() {
        #expect(!WorkbenchTransformEngineVersion.current.isEmpty)
        #expect(WorkbenchTransformEngine.engineVersion == WorkbenchTransformEngineVersion.current)
    }
}
