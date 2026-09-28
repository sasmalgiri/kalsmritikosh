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

    /// Parse a number by a DECLARED grammar (F26) — pure, no locale:
    ///   [ "(" ] [sign] [currency] [sign] core [ "%" ] [currency] [ ")" ]
    /// where core is digits with optional western (1,234,567) or Indian (12,34,567) grouping, an
    /// optional "." fraction and an optional exponent. Currency is a Unicode currency symbol or one
    /// of a small closed set of codes. Anything else — letters mixed into digits, ambiguous grouping
    /// such as "1,23", a second decimal point, a non-finite result — is not a number (nil), never a
    /// value built from whichever digits happened to be present.
    public nonisolated static func parseNumber(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2212}", with: "-")          // Unicode minus sign
        if s.isEmpty { return nil }
        // Parenthesised negatives, e.g. accounting "(1,234.50)".
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var sawSign = false
        func takeSign() -> Bool {
            guard let c = s.first, c == "-" || c == "+" else { return true }
            if sawSign { return false }
            sawSign = true
            if c == "-" { negative.toggle() }
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
            return true
        }
        guard takeSign() else { return nil }
        s = stripCurrency(s, leading: true)
        guard takeSign() else { return nil }
        s = stripCurrency(s, leading: false)
        if s.hasSuffix("%") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard s.range(of: numberCorePattern, options: .regularExpression) != nil,
              let v = Double(s.replacingOccurrences(of: ",", with: "")), v.isFinite else { return nil }
        return negative ? -v : v
    }

    /// Digits (plain, western-grouped or Indian-grouped), optional fraction, optional exponent.
    /// The lookahead requires a digit up front, so "", "e5" and "." never match.
    private nonisolated static let numberCorePattern =
        #"^(?=\.?\d)(?:\d+|\d{1,3}(?:,\d{3})+|\d{1,2}(?:,\d{2})+,\d{3})?(?:\.\d+)?(?:[eE][+-]?\d+)?$"#

    private nonisolated static let currencyCodes = ["USD", "EUR", "GBP", "INR", "JPY", "CNY", "AUD", "CAD", "Rs.", "Rs"]

    /// Remove one currency decoration (symbol or code) from the leading or trailing edge.
    private nonisolated static func stripCurrency(_ s: String, leading: Bool) -> String {
        var t = s
        if leading {
            if let c = t.unicodeScalars.first, c.properties.generalCategory == .currencySymbol {
                t.unicodeScalars.removeFirst()
            } else if let code = currencyCodes.first(where: { t.hasPrefix($0) }) {
                t.removeFirst(code.count)
            }
        } else {
            if let c = t.unicodeScalars.last, c.properties.generalCategory == .currencySymbol {
                t.unicodeScalars.removeLast()
            } else if let code = currencyCodes.first(where: { t.hasSuffix($0) }) {
                t.removeLast(code.count)
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
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

    // ISO8601DateFormatter is documented thread-safe but not marked Sendable;
    // these are configured once and never mutated after creation.
    private nonisolated(unsafe) static let iso8601WithTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private nonisolated(unsafe) static let iso8601DateOnly: ISO8601DateFormatter = {
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
        case .number(let n): return n.isFinite ? WorkbenchValue.renderNumber(n) : nil   // F26: missing, not "null" text
        }
    }

    /// Fixed-form decimal rendering: integral values without a fractional part, others trimmed of
    /// trailing zeros (deterministic, no locale grouping). F26 — the digits are the value's 15
    /// significant digits, written out positionally, so 1e-11 stays 0.00000000001 instead of
    /// rounding to "0" at a fixed ten decimal places.
    public nonisolated static func renderNumber(_ n: Double) -> String {
        if !n.isFinite { return "null" }
        if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
        return positional(String(format: "%.15g", n))
    }

    /// Rewrite a "%g" string ("1.5e+20", "-2.5e-07", "0.3") as a plain positional decimal.
    private nonisolated static func positional(_ g: String) -> String {
        var s = g
        var sign = ""
        if s.hasPrefix("-") { sign = "-"; s.removeFirst() }
        var exponent = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(s[s.index(after: e)...]) ?? 0
            s = String(s[..<e])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = String(parts[0])
        let fracPart = parts.count > 1 ? String(parts[1]) : ""
        var digits = intPart + fracPart
        var point = intPart.count + exponent                  // decimal point position within `digits`
        if point <= 0 { digits = String(repeating: "0", count: 1 - point) + digits; point = 1 }
        if point > digits.count { digits += String(repeating: "0", count: point - digits.count) }
        var whole = String(digits.prefix(point))
        var fraction = String(digits.dropFirst(point))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        while whole.count > 1 && whole.hasPrefix("0") { whole.removeFirst() }
        return sign + whole + (fraction.isEmpty ? "" : "." + fraction)
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
