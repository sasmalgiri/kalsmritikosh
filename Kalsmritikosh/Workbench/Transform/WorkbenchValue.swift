//
//  WorkbenchValue.swift
//  Kalsmritikosh
//
//  LAB-002 (Stage C) — the deterministic runtime value of the safe transformation engine. A cell on
//  disk is an untyped `String?`; at transform time it is coerced, through its field's canonical
//  FactSchemaRegistry.ValueShape, into one of these closed value cases so arithmetic, comparison and
//  functions are total and reproducible. Coercion is pure and locale-independent — it parses ONLY the
//  strings it is handed (never reads the wall clock), so the same inputs always yield the same output.
//  A value that cannot be coerced becomes `.null` (honest missing), never a silent zero.
//
//  This is a computation vocabulary, NOT a second evidence/epistemic-status vocabulary: a computed
//  WorkbenchValue only becomes a durable cell as a `deterministicCalculation` (see WorkbenchTransform),
//  whose lineage records the formula, the exact input cell IDs and the engine version.
//

import Foundation

/// A total, deterministic runtime value. `.null` is the single honest "missing / not computable".
public nonisolated enum WorkbenchValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    case boolean(Bool)
    case date(Date)
    case null

    public nonisolated var isNull: Bool { if case .null = self { return true }; return false }

    // MARK: - Coercion from a stored cell string

    /// Coerce a stored cell string into a runtime value using the field's canonical shape. A nil or
    /// unparseable value for a typed shape becomes `.null` — never a fabricated default.
    public nonisolated static func coerce(_ raw: String?, shape: FactSchemaRegistry.ValueShape) -> WorkbenchValue {
        guard let raw, !raw.isEmpty else { return .null }
        switch shape {
        case .number, .money, .duration:
            return parseNumber(raw).map(WorkbenchValue.number) ?? .null
        case .date:
            return parseDate(raw).map(WorkbenchValue.date) ?? .null
        case .boolean:
            return parseBoolean(raw).map(WorkbenchValue.boolean) ?? .null
        case .text, .identifier, .email, .phone, .url:
            return .text(raw)
        }
    }

    /// Parse a number, tolerating money/grouping decoration (currency symbols, thousands separators,
    /// surrounding whitespace, a trailing % which is kept as a plain number). Pure — no locale.
    public nonisolated static func parseNumber(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        // Parenthesised negatives, e.g. accounting "(1,234.50)".
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        s = s.filter { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        if s.isEmpty || s == "-" || s == "+" || s == "." { return nil }
        guard let v = Double(s) else { return nil }
        return negative ? -v : v
    }

    /// Parse a boolean from a small closed set of textual spellings.
    public nonisolated static func parseBoolean(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "y", "1": return true
        case "false", "no", "n", "0": return false
        default: return nil
        }
    }

    /// The fixed, locale-independent date parsers the engine understands, tried in order.
    private nonisolated static let dateParsers: [(String) -> Date?] = [
        { iso8601WithTime.date(from: $0) },
        { iso8601DateOnly.date(from: $0) },
        { fixed("yyyy-MM-dd").date(from: $0) },
        { fixed("yyyy/MM/dd").date(from: $0) },
        { fixed("MM/dd/yyyy").date(from: $0) },
        { fixed("dd/MM/yyyy").date(from: $0) },
        { fixed("dd MMM yyyy").date(from: $0) },
        { fixed("MMMM d, yyyy").date(from: $0) }
    ]

    public nonisolated static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        for parse in dateParsers { if let d = parse(s) { return d } }
        return nil
    }

    private nonisolated static let iso8601WithTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private nonisolated static let iso8601DateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f
    }()
    private nonisolated static func fixed(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    // MARK: - Rendering back to a durable cell string

    /// The canonical string form written into a `deterministicCalculation` cell. `.null` renders as nil
    /// (a missing cell). Numbers use a fixed, round-trip-stable decimal form (no scientific notation,
    /// integers without a decimal point); dates use ISO-8601 full date-time.
    public nonisolated var storedString: String? {
        switch self {
        case .null: return nil
        case .text(let s): return s
        case .boolean(let b): return b ? "true" : "false"
        case .date(let d): return WorkbenchValue.iso8601WithTime.string(from: d)
        case .number(let n): return WorkbenchValue.renderNumber(n)
        }
    }

    /// Fixed-form decimal rendering: integral values without a fractional part, others trimmed of
    /// trailing zeros (deterministic, no locale grouping).
    public nonisolated static func renderNumber(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.10f", n)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Numeric / boolean projections used by the evaluator

    /// Numeric projection: numbers pass through, booleans map to 1/0, numeric-looking text is parsed,
    /// dates project to their reference-time seconds; anything else is nil (not a value).
    public nonisolated var asNumber: Double? {
        switch self {
        case .number(let n): return n
        case .boolean(let b): return b ? 1 : 0
        case .text(let s): return WorkbenchValue.parseNumber(s)
        case .date(let d): return d.timeIntervalSinceReferenceDate
        case .null: return nil
        }
    }

    /// Truthiness for logical operators: an explicit boolean, a non-zero number, or a non-empty
    /// non-"false" string. `.null` is false.
    public nonisolated var asBool: Bool {
        switch self {
        case .boolean(let b): return b
        case .number(let n): return n != 0
        case .text(let s):
            if let parsed = WorkbenchValue.parseBoolean(s) { return parsed }
            return !s.isEmpty
        case .date: return true
        case .null: return false
        }
    }

    public nonisolated var asDate: Date? {
        switch self {
        case .date(let d): return d
        case .text(let s): return WorkbenchValue.parseDate(s)
        default: return nil
        }
    }

    public nonisolated var asText: String {
        switch self {
        case .text(let s): return s
        default: return storedString ?? ""
        }
    }
}
