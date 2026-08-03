//
//  WorkbenchExpression.swift
//  Kalsmritikosh
//
//  LAB-002 (Stage C) — the safe parsed expression language behind every calculated value. A formula is
//  turned into a value by a hand-written tokenizer → recursive-descent parser → tree-walking evaluator
//  (WorkbenchExpressionEvaluator). There is NO `eval`, NO dynamic code loading and NO reflection: the
//  grammar is fixed, operators are a closed set, and only functions on an explicit allowlist parse at
//  all — an unknown function or symbol is a parse error, not a silently ignored token. This is what lets
//  the contract's promise hold: a derived value is reproducible from (formula + inputs + engine version)
//  because the engine that produced it can only do the small, total set of things defined here.
//
//  The parser produces a `WorkbenchExpr` AST and the exact set of field names it references (so the
//  engine can pin a derived value's lineage to the precise input cells). The AST is pure data; nothing
//  here touches the database, the network or the clock.
//

import Foundation

/// The bumpable identity of the transformation engine's semantics. Persisted with every derived value
/// so a later reproduction knows which evaluator rules produced it. Bump ONLY on a semantic change.
public nonisolated enum WorkbenchTransformEngineVersion {
    public static let current = "workbench-transform-1"
}

/// Unary operators (closed set).
public nonisolated enum WorkbenchUnaryOp: String, Sendable, Equatable {
    case negate
    case not
}

/// Binary operators (closed set): arithmetic, comparison, logical, string concatenation.
public nonisolated enum WorkbenchBinaryOp: String, Sendable, Equatable {
    case add, subtract, multiply, divide
    case equal, notEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual
    case and, or
    case concat
}

/// The parsed formula tree. Pure data — evaluated by WorkbenchExpressionEvaluator against a row context.
public indirect nonisolated enum WorkbenchExpr: Sendable, Equatable {
    case number(Double)
    case string(String)
    case boolean(Bool)
    case null
    case field(String)                              // a column reference, resolved by name at eval time
    case unary(WorkbenchUnaryOp, WorkbenchExpr)
    case binary(WorkbenchBinaryOp, WorkbenchExpr, WorkbenchExpr)
    case call(String, [WorkbenchExpr])              // allowlisted function (uppercased) + arguments

    /// Every distinct field name this expression reads, in first-seen order — the basis for pinning a
    /// derived value's input-cell lineage.
    public nonisolated var referencedFields: [String] {
        var seen: Set<String> = []
        var order: [String] = []
        func walk(_ e: WorkbenchExpr) {
            switch e {
            case .field(let n): if seen.insert(n).inserted { order.append(n) }
            case .unary(_, let a): walk(a)
            case .binary(_, let l, let r): walk(l); walk(r)
            case .call(_, let args): args.forEach(walk)
            case .number, .string, .boolean, .null: break
            }
        }
        walk(self)
        return order
    }
}

/// Errors from parsing a formula. Fail-closed and specific — never a partial parse silently accepted.
public nonisolated enum WorkbenchExpressionError: Error, Sendable, Equatable {
    case empty
    case unexpectedCharacter(Character)
    case unterminatedString
    case unexpectedToken(String)
    case expected(String)
    case unknownFunction(String)
    case trailingTokens(String)
}

/// The allowlist of callable functions. A name outside this set is a parse error. (Boolean AND/OR/NOT
/// are operators, not functions.)
public nonisolated enum WorkbenchFunctionCatalog {
    public static let allowed: Set<String> = [
        "IF", "COALESCE", "ISBLANK",
        "ABS", "ROUND", "FLOOR", "CEIL", "SQRT", "MOD", "MIN", "MAX", "NUMBER",
        "LEN", "UPPER", "LOWER", "TRIM", "CONCAT", "CONTAINS", "STARTSWITH", "ENDSWITH", "TEXT",
        "PERCENT", "DATEDIFF", "YEAR", "MONTH", "DAY"
    ]
}

/// The parser: `parse(_:)` turns a formula string into a validated AST or throws.
public nonisolated enum WorkbenchExpressionParser {

    public nonisolated static func parse(_ source: String) throws -> WorkbenchExpr {
        let tokens = try WorkbenchTokenizer.tokenize(source)
        guard !tokens.isEmpty else { throw WorkbenchExpressionError.empty }
        var parser = RecursiveDescent(tokens: tokens)
        let expr = try parser.parseExpression()
        if let leftover = parser.remainingDescription {
            throw WorkbenchExpressionError.trailingTokens(leftover)
        }
        return expr
    }
}

// MARK: - Tokenizer

nonisolated enum WorkbenchToken: Equatable {
    case number(Double)
    case string(String)
    case identifier(String)     // bare word: keyword, function name, or field name
    case field(String)          // [Bracketed Field Name]
    case symbol(String)         // ( ) , and operators
}

nonisolated enum WorkbenchTokenizer {
    static func tokenize(_ source: String) throws -> [WorkbenchToken] {
        var tokens: [WorkbenchToken] = []
        let chars = Array(source)
        var i = 0
        func peek(_ o: Int = 0) -> Character? { i + o < chars.count ? chars[i + o] : nil }

        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            // Numbers: digits with an optional single decimal point.
            if c.isNumber || (c == "." && (peek(1)?.isNumber ?? false)) {
                var s = ""
                while let d = peek(), d.isNumber || d == "." { s.append(d); i += 1 }
                guard let v = Double(s) else { throw WorkbenchExpressionError.unexpectedToken(s) }
                tokens.append(.number(v)); continue
            }

            // Quoted string literal ("..." with "" as an escaped quote).
            if c == "\"" {
                i += 1
                var s = ""
                var closed = false
                while let d = peek() {
                    if d == "\"" {
                        if peek(1) == "\"" { s.append("\""); i += 2; continue }
                        i += 1; closed = true; break
                    }
                    s.append(d); i += 1
                }
                guard closed else { throw WorkbenchExpressionError.unterminatedString }
                tokens.append(.string(s)); continue
            }

            // Bracketed field reference [Field Name].
            if c == "[" {
                i += 1
                var s = ""
                var closed = false
                while let d = peek() { if d == "]" { i += 1; closed = true; break }; s.append(d); i += 1 }
                guard closed else { throw WorkbenchExpressionError.expected("]") }
                tokens.append(.field(s.trimmingCharacters(in: .whitespaces))); continue
            }

            // Identifier / keyword / bare field name.
            if c.isLetter || c == "_" {
                var s = ""
                while let d = peek(), d.isLetter || d.isNumber || d == "_" { s.append(d); i += 1 }
                tokens.append(.identifier(s)); continue
            }

            // Multi-character operators first, then single-character symbols.
            let two = String([c, peek(1) ?? " "])
            if ["<=", ">=", "<>", "!="].contains(two) { tokens.append(.symbol(two)); i += 2; continue }
            if "+-*/&=<>(),".contains(c) { tokens.append(.symbol(String(c))); i += 1; continue }

            throw WorkbenchExpressionError.unexpectedCharacter(c)
        }
        return tokens
    }
}

// MARK: - Recursive-descent parser

private struct RecursiveDescent {
    let tokens: [WorkbenchToken]
    var pos = 0

    var remainingDescription: String? {
        pos < tokens.count ? "\(tokens[pos])" : nil
    }

    private func peek() -> WorkbenchToken? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func advance() -> WorkbenchToken? { defer { pos += 1 }; return peek() }

    private mutating func matchSymbol(_ s: String) -> Bool {
        if case .symbol(let v)? = peek(), v == s { pos += 1; return true }
        return false
    }
    private mutating func matchKeyword(_ word: String) -> Bool {
        if case .identifier(let v)? = peek(), v.uppercased() == word { pos += 1; return true }
        return false
    }

    // expression := orExpr
    mutating func parseExpression() throws -> WorkbenchExpr { try parseOr() }

    private mutating func parseOr() throws -> WorkbenchExpr {
        var left = try parseAnd()
        while matchKeyword("OR") { left = .binary(.or, left, try parseAnd()) }
        return left
    }
    private mutating func parseAnd() throws -> WorkbenchExpr {
        var left = try parseNot()
        while matchKeyword("AND") { left = .binary(.and, left, try parseNot()) }
        return left
    }
    private mutating func parseNot() throws -> WorkbenchExpr {
        if matchKeyword("NOT") { return .unary(.not, try parseNot()) }
        return try parseComparison()
    }
    private mutating func parseComparison() throws -> WorkbenchExpr {
        var left = try parseConcat()
        while case .symbol(let s)? = peek(), ["=", "<>", "!=", "<", "<=", ">", ">="].contains(s) {
            pos += 1
            let op: WorkbenchBinaryOp
            switch s {
            case "=": op = .equal
            case "<>", "!=": op = .notEqual
            case "<": op = .lessThan
            case "<=": op = .lessOrEqual
            case ">": op = .greaterThan
            default: op = .greaterOrEqual
            }
            left = .binary(op, left, try parseConcat())
        }
        return left
    }
    private mutating func parseConcat() throws -> WorkbenchExpr {
        var left = try parseAdditive()
        while matchSymbol("&") { left = .binary(.concat, left, try parseAdditive()) }
        return left
    }
    private mutating func parseAdditive() throws -> WorkbenchExpr {
        var left = try parseMultiplicative()
        while true {
            if matchSymbol("+") { left = .binary(.add, left, try parseMultiplicative()) }
            else if matchSymbol("-") { left = .binary(.subtract, left, try parseMultiplicative()) }
            else { break }
        }
        return left
    }
    private mutating func parseMultiplicative() throws -> WorkbenchExpr {
        var left = try parseUnary()
        while true {
            if matchSymbol("*") { left = .binary(.multiply, left, try parseUnary()) }
            else if matchSymbol("/") { left = .binary(.divide, left, try parseUnary()) }
            else { break }
        }
        return left
    }
    private mutating func parseUnary() throws -> WorkbenchExpr {
        if matchSymbol("-") { return .unary(.negate, try parseUnary()) }
        if matchSymbol("+") { return try parseUnary() }
        return try parsePrimary()
    }
    private mutating func parsePrimary() throws -> WorkbenchExpr {
        guard let tok = peek() else { throw WorkbenchExpressionError.expected("expression") }
        switch tok {
        case .number(let n): pos += 1; return .number(n)
        case .string(let s): pos += 1; return .string(s)
        case .field(let f): pos += 1; return .field(f)
        case .symbol("("):
            pos += 1
            let inner = try parseExpression()
            guard matchSymbol(")") else { throw WorkbenchExpressionError.expected(")") }
            return inner
        case .identifier(let word):
            pos += 1
            let upper = word.uppercased()
            // Keyword literals.
            switch upper {
            case "TRUE": return .boolean(true)
            case "FALSE": return .boolean(false)
            case "NULL": return .null
            default: break
            }
            // Function call: identifier immediately followed by '('.
            if case .symbol("(")? = peek() {
                pos += 1
                guard WorkbenchFunctionCatalog.allowed.contains(upper) else {
                    throw WorkbenchExpressionError.unknownFunction(word)
                }
                var args: [WorkbenchExpr] = []
                if !matchSymbol(")") {
                    repeat { args.append(try parseExpression()) } while matchSymbol(",")
                    guard matchSymbol(")") else { throw WorkbenchExpressionError.expected(")") }
                }
                return .call(upper, args)
            }
            // Otherwise a bare field reference.
            return .field(word)
        default:
            throw WorkbenchExpressionError.unexpectedToken("\(tok)")
        }
    }
}
