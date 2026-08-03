//
//  WorkbenchExpressionEvaluator.swift
//  Kalsmritikosh
//
//  LAB-002 (Stage C) — the tree-walking evaluator for a parsed WorkbenchExpr. It is total and pure:
//  every operator and every allowlisted function has fixed, deterministic semantics; a not-computable
//  result (missing operand, divide-by-zero, un-parseable date) is the honest `.null`, never a crash or
//  a fabricated zero. It reads a row context (field name → value) supplied by the engine and NOTHING
//  else — no database, no network, no wall-clock — so `(formula + inputs + engine version)` reproduces
//  the same output every time, on any machine. Calendar arithmetic uses a fixed UTC Gregorian calendar
//  so DATEDIFF / YEAR / MONTH / DAY do not depend on the host locale or time zone.
//

import Foundation

/// The per-row variable bindings a formula reads. The engine populates a value for EVERY field of the
/// dataset (a missing cell is `.null`), so a reference to a non-existent column is a real error.
public nonisolated struct WorkbenchRowContext: Sendable {
    public let values: [String: WorkbenchValue]
    public nonisolated init(values: [String: WorkbenchValue]) { self.values = values }
    public nonisolated static let empty = WorkbenchRowContext(values: [:])
}

public nonisolated enum WorkbenchEvaluationError: Error, Sendable, Equatable {
    case unknownField(String)
    case wrongArgumentCount(function: String, got: Int)
    case unknownDateUnit(String)
}

public nonisolated enum WorkbenchExpressionEvaluator {

    /// A fixed UTC Gregorian calendar — deterministic, host-independent date math.
    private nonisolated static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public nonisolated static func evaluate(_ expr: WorkbenchExpr, in ctx: WorkbenchRowContext) throws -> WorkbenchValue {
        switch expr {
        case .number(let n): return .number(n)
        case .string(let s): return .text(s)
        case .boolean(let b): return .boolean(b)
        case .null: return .null
        case .field(let name):
            guard let v = ctx.values[name] else { throw WorkbenchEvaluationError.unknownField(name) }
            return v
        case .unary(let op, let a):
            return try evalUnary(op, try evaluate(a, in: ctx))
        case .binary(let op, let l, let r):
            return try evalBinary(op, l, r, ctx)
        case .call(let name, let args):
            return try evalCall(name, args, ctx)
        }
    }

    // MARK: - Unary

    private nonisolated static func evalUnary(_ op: WorkbenchUnaryOp, _ v: WorkbenchValue) throws -> WorkbenchValue {
        switch op {
        case .negate: return v.asNumber.map { WorkbenchValue.number(-$0) } ?? .null
        case .not: return .boolean(!v.asBool)
        }
    }

    // MARK: - Binary

    private nonisolated static func evalBinary(_ op: WorkbenchBinaryOp, _ le: WorkbenchExpr, _ re: WorkbenchExpr,
                                               _ ctx: WorkbenchRowContext) throws -> WorkbenchValue {
        // Logical operators short-circuit and never propagate null as an error.
        if op == .and {
            if try !evaluate(le, in: ctx).asBool { return .boolean(false) }
            return .boolean(try evaluate(re, in: ctx).asBool)
        }
        if op == .or {
            if try evaluate(le, in: ctx).asBool { return .boolean(true) }
            return .boolean(try evaluate(re, in: ctx).asBool)
        }

        let l = try evaluate(le, in: ctx)
        let r = try evaluate(re, in: ctx)

        switch op {
        case .concat:
            if l.isNull && r.isNull { return .null }
            return .text((l.isNull ? "" : l.asText) + (r.isNull ? "" : r.asText))
        case .add, .subtract, .multiply, .divide:
            guard let a = l.asNumber, let b = r.asNumber else { return .null }
            switch op {
            case .add: return .number(a + b)
            case .subtract: return .number(a - b)
            case .multiply: return .number(a * b)
            case .divide: return b == 0 ? .null : .number(a / b)
            default: return .null
            }
        case .equal, .notEqual:
            let eq = valuesEqual(l, r)
            return .boolean(op == .equal ? eq : !eq)
        case .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
            guard let c = compare(l, r) else { return .null }
            switch op {
            case .lessThan: return .boolean(c < 0)
            case .lessOrEqual: return .boolean(c <= 0)
            case .greaterThan: return .boolean(c > 0)
            default: return .boolean(c >= 0)
            }
        case .and, .or: return .null   // handled above
        }
    }

    private nonisolated static func valuesEqual(_ l: WorkbenchValue, _ r: WorkbenchValue) -> Bool {
        if l.isNull || r.isNull { return l.isNull && r.isNull }
        if let a = l.asNumber, let b = r.asNumber, case .number = l, case .number = r { return a == b }
        if let a = l.asDate, let b = r.asDate, case .date = l, case .date = r { return a == b }
        if let a = l.asNumber, let b = r.asNumber { return a == b }
        return l.asText == r.asText
    }

    /// Ordering comparison → negative / zero / positive, or nil when incomparable (a null operand).
    private nonisolated static func compare(_ l: WorkbenchValue, _ r: WorkbenchValue) -> Int? {
        if l.isNull || r.isNull { return nil }
        if let a = l.asDate, let b = r.asDate, case .date = l, case .date = r {
            return a == b ? 0 : (a < b ? -1 : 1)
        }
        if let a = l.asNumber, let b = r.asNumber { return a == b ? 0 : (a < b ? -1 : 1) }
        let a = l.asText, b = r.asText
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    // MARK: - Functions (allowlisted; the catalog gate is enforced at parse time)

    private nonisolated static func evalCall(_ name: String, _ argExprs: [WorkbenchExpr],
                                             _ ctx: WorkbenchRowContext) throws -> WorkbenchValue {
        func args() throws -> [WorkbenchValue] { try argExprs.map { try evaluate($0, in: ctx) } }
        func arity(_ n: Int) throws { guard argExprs.count == n else { throw WorkbenchEvaluationError.wrongArgumentCount(function: name, got: argExprs.count) } }
        func atLeast(_ n: Int) throws { guard argExprs.count >= n else { throw WorkbenchEvaluationError.wrongArgumentCount(function: name, got: argExprs.count) } }

        switch name {
        case "IF":
            guard argExprs.count == 2 || argExprs.count == 3 else {
                throw WorkbenchEvaluationError.wrongArgumentCount(function: name, got: argExprs.count)
            }
            let cond = try evaluate(argExprs[0], in: ctx)
            if cond.asBool { return try evaluate(argExprs[1], in: ctx) }
            return argExprs.count == 3 ? try evaluate(argExprs[2], in: ctx) : .null
        case "COALESCE":
            try atLeast(1)
            for e in argExprs { let v = try evaluate(e, in: ctx); if !v.isNull { return v } }
            return .null
        case "ISBLANK":
            try arity(1); return .boolean(try evaluate(argExprs[0], in: ctx).isNull)

        case "ABS": try arity(1); return num(try evaluate(argExprs[0], in: ctx)) { abs($0) }
        case "FLOOR": try arity(1); return num(try evaluate(argExprs[0], in: ctx)) { $0.rounded(.down) }
        case "CEIL": try arity(1); return num(try evaluate(argExprs[0], in: ctx)) { $0.rounded(.up) }
        case "SQRT": try arity(1); return num(try evaluate(argExprs[0], in: ctx)) { $0 < 0 ? Double.nan : $0.squareRoot() }
        case "NUMBER": try arity(1); return try evaluate(argExprs[0], in: ctx).asNumber.map(WorkbenchValue.number) ?? .null
        case "ROUND":
            guard argExprs.count == 1 || argExprs.count == 2 else { throw WorkbenchEvaluationError.wrongArgumentCount(function: name, got: argExprs.count) }
            guard let x = try evaluate(argExprs[0], in: ctx).asNumber else { return .null }
            let places = argExprs.count == 2 ? (try evaluate(argExprs[1], in: ctx).asNumber.map { Int($0) } ?? 0) : 0
            let f = pow(10.0, Double(places))
            return .number((x * f).rounded() / f)
        case "MOD":
            try arity(2)
            guard let a = try evaluate(argExprs[0], in: ctx).asNumber, let b = try evaluate(argExprs[1], in: ctx).asNumber, b != 0 else { return .null }
            return .number(a.truncatingRemainder(dividingBy: b))
        case "MIN", "MAX":
            try atLeast(1)
            let nums = try args().compactMap { $0.asNumber }
            guard !nums.isEmpty else { return .null }
            return .number(name == "MIN" ? nums.min()! : nums.max()!)

        case "LEN": try arity(1); return .number(Double(try evaluate(argExprs[0], in: ctx).asText.count))
        case "UPPER": try arity(1); return .text(try evaluate(argExprs[0], in: ctx).asText.uppercased())
        case "LOWER": try arity(1); return .text(try evaluate(argExprs[0], in: ctx).asText.lowercased())
        case "TRIM": try arity(1); return .text(try evaluate(argExprs[0], in: ctx).asText.trimmingCharacters(in: .whitespacesAndNewlines))
        case "TEXT": try arity(1); return .text(try evaluate(argExprs[0], in: ctx).asText)
        case "CONCAT":
            try atLeast(1)
            return .text(try args().map { $0.isNull ? "" : $0.asText }.joined())
        case "CONTAINS":
            try arity(2); return .boolean(try evaluate(argExprs[0], in: ctx).asText.contains(try evaluate(argExprs[1], in: ctx).asText))
        case "STARTSWITH":
            try arity(2); return .boolean(try evaluate(argExprs[0], in: ctx).asText.hasPrefix(try evaluate(argExprs[1], in: ctx).asText))
        case "ENDSWITH":
            try arity(2); return .boolean(try evaluate(argExprs[0], in: ctx).asText.hasSuffix(try evaluate(argExprs[1], in: ctx).asText))

        case "PERCENT":
            try arity(2)
            guard let part = try evaluate(argExprs[0], in: ctx).asNumber, let whole = try evaluate(argExprs[1], in: ctx).asNumber, whole != 0 else { return .null }
            return .number(part / whole * 100)
        case "DATEDIFF":
            try arity(3)
            let unit = try evaluate(argExprs[0], in: ctx).asText.lowercased()
            guard let start = try evaluate(argExprs[1], in: ctx).asDate, let end = try evaluate(argExprs[2], in: ctx).asDate else { return .null }
            return try dateDiff(unit: unit, start: start, end: end)
        case "YEAR", "MONTH", "DAY":
            try arity(1)
            guard let d = try evaluate(argExprs[0], in: ctx).asDate else { return .null }
            let comp = utcCalendar.dateComponents([.year, .month, .day], from: d)
            switch name {
            case "YEAR": return comp.year.map { .number(Double($0)) } ?? .null
            case "MONTH": return comp.month.map { .number(Double($0)) } ?? .null
            default: return comp.day.map { .number(Double($0)) } ?? .null
            }
        default:
            // Unreachable: the parser only admits allowlisted names.
            throw WorkbenchEvaluationError.wrongArgumentCount(function: name, got: argExprs.count)
        }
    }

    private nonisolated static func num(_ v: WorkbenchValue, _ f: (Double) -> Double) -> WorkbenchValue {
        guard let x = v.asNumber else { return .null }
        let r = f(x)
        return r.isFinite ? .number(r) : .null
    }

    private nonisolated static func dateDiff(unit: String, start: Date, end: Date) throws -> WorkbenchValue {
        let seconds = end.timeIntervalSince(start)
        switch unit {
        case "seconds", "second", "s": return .number(seconds)
        case "minutes", "minute", "min": return .number(seconds / 60)
        case "hours", "hour", "h": return .number(seconds / 3600)
        case "days", "day", "d": return .number(seconds / 86_400)
        case "weeks", "week", "w": return .number(seconds / 604_800)
        case "months", "month", "mo":
            let c = utcCalendar.dateComponents([.month], from: start, to: end)
            return c.month.map { .number(Double($0)) } ?? .null
        case "years", "year", "y":
            let c = utcCalendar.dateComponents([.year], from: start, to: end)
            return c.year.map { .number(Double($0)) } ?? .null
        default:
            throw WorkbenchEvaluationError.unknownDateUnit(unit)
        }
    }
}
