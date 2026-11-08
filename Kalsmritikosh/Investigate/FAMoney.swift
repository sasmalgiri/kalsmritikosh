//
//  FAMoney.swift
//  Kalsmritikosh
//
//  Final brief §3.4 — the forensic schedule's arithmetic. An amount the case mentions is a CANDIDATE
//  until the accountant classifies it: an invoice total, a claim, a reserve or a balance is not a
//  movement of money. Money is a Decimal with an explicit currency (₹, $, €, £ or a code); totals are
//  per currency, never mixed. One transaction filed in two documents (same date, amount, account,
//  parties and reference) counts once; two payments of the same amount are two payments. Gross
//  movements, money returned (refunds, reversals) and the net are kept apart, and each account's
//  stated opening/closing balances reconcile against the schedule, with missing periods shown.
//
//  Pure value code; no I/O.
//

import Foundation

/// What a schedule row is. `nil` on a row saved before 2026-10-27 (see ForensicEngagement.kind(of:)).
public nonisolated enum FAKind: String, Codable, CaseIterable, Sendable {
    case unclassified
    case payment, receipt, transfer, refund, reversal, fee
    case invoice, claim, reserve, balance, quotation
    /// S7 (MONEY-03): an amount someone alleges (taken, owed, lost) and an estimate — neither is a movement of money.
    case allegation, estimate

    public var label: String {
        switch self {
        case .unclassified: return "Not yet classified"
        case .payment: return "Payment (money out)"
        case .receipt: return "Receipt (money in)"
        case .transfer: return "Transfer between accounts"
        case .refund: return "Refund"
        case .reversal: return "Reversal"
        case .fee: return "Fee / charge"
        case .invoice: return "Invoice (not a movement)"
        case .claim: return "Claim amount (not a movement)"
        case .reserve: return "Reserve (not a movement)"
        case .balance: return "Balance (not a movement)"
        case .quotation: return "Quotation / estimate (not a movement)"
        case .allegation: return "Alleged amount (not a movement)"
        case .estimate: return "Estimate (not a movement)"
        }
    }

    /// Money actually moved.
    public var isMovement: Bool { [.payment, .receipt, .transfer, .refund, .reversal, .fee].contains(self) }
    /// Money leaving an account (a candidate for the gross outflow; see FAScheduleSummary for the rules).
    var isOutflow: Bool { [.payment, .transfer, .fee].contains(self) }
    /// Money coming back: reduces the net.
    var isReturn: Bool { [.refund, .reversal].contains(self) }
}

public nonisolated enum FAMoney {

    static let isoCodes = "USD|EUR|GBP|INR|JPY|CNY|AUD|CAD|CHF|SGD|AED|HKD|NZD|ZAR|SEK|NOK|DKK|SAR|BRL|MXN"

    /// The currency an amount is written in ("" when it states none, or states it ambiguously).
    /// Review R6: an explicit ISO code wins ("CAD $1,000" is CAD); a prefixed dollar names its
    /// currency (CA$, C$, A$, NZ$, HK$, S$, US$); ₹/Rs, € and £ are unambiguous; a bare "$" is NOT
    /// assumed to be US dollars — the row stays "currency not stated" until the person says.
    public static func currency(of text: String) -> String {
        if let r = text.range(of: #"\b(?:"# + isoCodes + #")\b"#, options: .regularExpression) { return String(text[r]) }
        let prefixed: [(String, String)] = [("US$", "USD"), ("CA$", "CAD"), ("C$", "CAD"), ("A$", "AUD"), ("AU$", "AUD"),
                                            ("NZ$", "NZD"), ("HK$", "HKD"), ("S$", "SGD"), ("SG$", "SGD"), ("R$", "BRL"), ("MX$", "MXN")]
        for (p, code) in prefixed where text.contains(p) { return code }
        if text.contains("₹") || text.range(of: #"\b(?:Rs\.?|RS\.?)(?=\s?\d)"#, options: .regularExpression) != nil { return "INR" }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        if text.contains("¥") { return "" }      // JPY or CNY: ambiguous
        return ""
    }

    /// True when the amount uses "$" (or "¥") without saying which currency.
    public static func currencyIsAmbiguous(_ text: String) -> Bool {
        currency(of: text).isEmpty && (text.contains("$") || text.contains("¥"))
    }

    /// The amount as an exact Decimal, or nil when the text is not ONE plain amount. Review R6: the
    /// whole token must parse — currency marks and spaces aside, only digits, one decimal separator
    /// and grouping separators; "1,234.56" and "1.234,56" are both read correctly; "1.5 million",
    /// "2 lakh", "5k" or any other word make it unreadable instead of being silently dropped.
    /// "(1,000)" or "-1,000" is negative.
    public static func value(of text: String) -> Decimal? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"\b(?:"# + isoCodes + #")\b"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?:US|CA|C|A|AU|NZ|HK|S|SG|R|MX)\$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\brs\.?"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[₹$€£¥\s\x{00A0}]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "/-", with: "")          // "₹1,000/-"
        var negative = false
        if t.hasPrefix("(") && t.hasSuffix(")") { negative = true; t = String(t.dropFirst().dropLast()) }
        if t.hasPrefix("-") || t.hasPrefix("−") { negative = true; t = String(t.dropFirst()) }
        guard !t.isEmpty, t.range(of: #"^[0-9][0-9.,]*$"#, options: .regularExpression) != nil else { return nil }
        let dots = t.filter { $0 == "." }.count, commas = t.filter { $0 == "," }.count
        var plain: String
        if dots > 0 && commas > 0 {
            // The separator that comes last is the decimal one.
            let lastDot = t.lastIndex(of: ".")!, lastComma = t.lastIndex(of: ",")!
            plain = lastDot > lastComma ? t.replacingOccurrences(of: ",", with: "")
                                        : t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if commas > 0 {
            let tail = t.split(separator: ",", omittingEmptySubsequences: false).last ?? ""
            // "1,000" / "12,34,567" group; "12,5" is a decimal comma.
            plain = (commas == 1 && tail.count != 3 && tail.count <= 2) ? t.replacingOccurrences(of: ",", with: ".") : t.replacingOccurrences(of: ",", with: "")
        } else if dots > 1 {
            plain = t.replacingOccurrences(of: ".", with: "")    // "1.234.567"
        } else {
            // "1.234" is 1234 in European notation and 1.234 in English: ambiguous, so unreadable
            // until the person writes it unambiguously. "0.125" and "12.50" are plain decimals.
            if dots == 1, let tail = t.split(separator: ".").last, tail.count == 3, !t.hasPrefix("0.") { return nil }
            plain = t
        }
        guard plain.filter({ $0 == "." }).count <= 1, plain.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let d = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -d : d
    }

    /// S7 (MONEY-02/12) — an amount read together with HOW it was read, so a figure written as "2.5 lakh", "₹1.2 crore"
    /// or "Rupees fifty thousand only" can be used without guessing: the basis is stored beside the value and shown with
    /// it. `value(of:)` stays strict (one plain figure); this reader adds only explicit, stated scales (thousand, lakh,
    /// crore, million, billion) and English number words. Anything else — "about 5k", "fifty-odd thousand", a word it does
    /// not know — is unreadable (nil), never approximated.
    public struct Reading: Equatable, Sendable {
        public let value: Decimal
        /// "as written", "2.5 lakh read as 2.5 × 1,00,000", "written in words: “fifty thousand”".
        public let basis: String
        /// The currency the text names, by symbol, code or word ("rupees" → INR); "" when it names none.
        public let currency: String
    }

    static let scales: [(String, Decimal)] = [("thousand", 1_000), ("lakh", 100_000), ("lakhs", 100_000), ("lac", 100_000), ("lacs", 100_000),
                                              ("crore", 10_000_000), ("crores", 10_000_000), ("million", 1_000_000), ("billion", 1_000_000_000)]
    static let units: [String: Decimal] = {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                     "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        var m: [String: Decimal] = [:]
        for (i, w) in words.enumerated() { m[w] = Decimal(i) }
        for (w, n) in [("twenty", 20), ("thirty", 30), ("forty", 40), ("fifty", 50), ("sixty", 60), ("seventy", 70), ("eighty", 80), ("ninety", 90)] { m[w] = Decimal(n) }
        return m
    }()

    /// The currency a written amount names in words ("rupees", "US dollars", "euros"); "" for none or an unqualified
    /// "dollars" (which dollar is not said — the same rule as a bare "$").
    public static func currencyInWords(_ text: String) -> String {
        let t = " " + text.lowercased() + " "
        if t.range(of: #"\b(rupees?|inr)\b"#, options: .regularExpression) != nil { return "INR" }
        if t.range(of: #"\b(us dollars?|usd)\b"#, options: .regularExpression) != nil { return "USD" }
        if t.range(of: #"\beuros?\b"#, options: .regularExpression) != nil { return "EUR" }
        if t.range(of: #"\b(pounds sterling|gbp)\b"#, options: .regularExpression) != nil { return "GBP" }
        if t.range(of: #"\byen\b"#, options: .regularExpression) != nil { return "JPY" }
        return ""
    }

    /// See `Reading`. Nil when the text is not one amount this reader can read exactly.
    public static func read(_ text: String) -> Reading? {
        let symbolCurrency = currency(of: text)
        if let v = value(of: text) { return Reading(value: v, basis: "as written", currency: symbolCurrency) }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A figure with a stated scale: "2.5 lakh", "₹ 1.2 crore", "INR 3 million".
        if let m = t.range(of: #"^(.*?)\s*\b(thousand|lakhs?|lacs?|crores?|million|billion)\b\.?\s*(only)?\.?$"#, options: .regularExpression) {
            let whole = String(t[m])
            for (word, scale) in scales.sorted(by: { $0.0.count > $1.0.count }) {
                guard let r = whole.range(of: #"\b"# + word + #"\b"#, options: .regularExpression) else { continue }
                let figure = String(whole[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let n = value(of: figure.uppercased()) {
                    let v = n * scale
                    return Reading(value: v, basis: "\(figure) \(word) read as \(format(n.magnitude, currency: "")) × \(indianGrouped(scale)) = \(indianGrouped(v.magnitude))",
                                   currency: symbolCurrency.isEmpty ? currencyInWords(text) : symbolCurrency)
                }
                break
            }
        }
        // Words: "Rupees fifty thousand only", "one lakh twenty thousand", "two hundred and five dollars and fifty cents".
        t = t.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ".", with: " ")
        let ignorable: Set<String> = ["rupees", "rupee", "rs", "inr", "only", "and", "us", "dollars", "dollar", "usd", "euros", "euro", "pounds", "sterling",
                                      "gbp", "yen", "the", "sum", "of", "a"]
        var words = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var fraction: Decimal = 0
        if let i = words.firstIndex(where: { ["paise", "paisa", "cents", "cent", "pence"].contains($0) }) {
            // "… and fifty paise": the number words just before the minor unit are the fraction (hundredths).
            var j = i - 1
            var minor: [String] = []
            while j >= 0, units[words[j]] != nil || words[j] == "hundred" { minor.insert(words[j], at: 0); j -= 1 }
            guard !minor.isEmpty, let cents = wordsValue(minor), cents < 100 else { return nil }
            fraction = cents / 100
            words = Array(words[0...max(j, 0)]) + Array(words[(i + 1)...])
            if j < 0 { words = Array(words.dropFirst()) }
        }
        let numberWords = words.filter { !ignorable.contains($0) }
        guard !numberWords.isEmpty, numberWords.allSatisfy({ w in units[w] != nil || w == "hundred" || scales.contains { s in s.0 == w } }),
              let whole = wordsValue(numberWords) else { return nil }
        let v = whole + fraction
        return Reading(value: v, basis: "written in words: “\(text.trimmingCharacters(in: .whitespacesAndNewlines))” read as \(format(v, currency: ""))",
                       currency: symbolCurrency.isEmpty ? currencyInWords(text) : symbolCurrency)
    }

    /// English number words (Indian or international scales) → value; nil when the order is not a number.
    static func wordsValue(_ words: [String]) -> Decimal? {
        var total = Decimal(0), current = Decimal(0), lastScale = Decimal.greatestFiniteMagnitude
        var any = false
        for w in words {
            if let n = units[w] { current += n; any = true }
            else if w == "hundred" { guard current != 0 else { return nil }; current *= 100; any = true }
            else if let s = scales.first(where: { $0.0 == w })?.1 {
                // "thousand lakh" is not a number, and a scale with no number before it ("lakh") is not read as one.
                guard s < lastScale, current != 0 else { return nil }
                total += current * s; current = 0; lastScale = s; any = true
            } else { return nil }
        }
        return any ? total + current : nil
    }

    /// 1,00,000-style grouping (lakh/crore), for the stated basis of a scaled amount.
    static func indianGrouped(_ d: Decimal) -> String {
        let plain = NSDecimalNumber(decimal: d).stringValue
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        var whole = String(parts.first ?? "0")
        guard whole.count > 3 else { return plain }
        let last3 = String(whole.suffix(3)); whole.removeLast(3)
        var groups: [String] = []
        while whole.count > 2 { groups.insert(String(whole.suffix(2)), at: 0); whole.removeLast(2) }
        if !whole.isEmpty { groups.insert(whole, at: 0) }
        return (groups + [last3]).joined(separator: ",") + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// MONEY-02 — the currency's minor units (ISO 4217 exponent): JPY 0, INR/USD/EUR 2, KWD 3. A currency
    /// not in the table (or not stated) has no assumed precision: its amount is shown exactly as stored.
    public static func minorUnits(_ currency: String) -> Int? {
        switch currency.uppercased() {
        case "JPY", "KRW", "VND", "CLP", "ISK", "UGX", "PYG", "XAF", "XOF": return 0
        case "BHD", "KWD", "OMR", "JOD", "TND", "LYD", "IQD": return 3
        case "USD", "EUR", "GBP", "INR", "CNY", "AUD", "CAD", "CHF", "SGD", "AED", "HKD", "NZD", "ZAR", "SEK", "NOK", "DKK", "SAR",
             "BRL", "MXN", "IDR", "THB", "MYR", "PHP", "PKR", "BDT", "LKR", "NPR", "PLN", "CZK", "HUF", "TRY", "RUB", "ILS", "EGP", "NGN", "KES":
            return 2
        default: return nil
        }
    }

    /// MONEY-02 — an amount for display in its currency, never changing the stored value: grouped, at the
    /// currency's own precision (JPY 1,000 · INR 1,000.00 · KWD 1.000), and with MORE digits only when the
    /// stored amount has them (nothing is rounded away). A currency without a known precision (or none
    /// stated) shows exactly the digits stored.
    public static func format(_ d: Decimal, currency: String) -> String {
        // Built from the Decimal's own exact digits (no Double, no formatter rounding).
        let plain = NSDecimalNumber(decimal: d).stringValue.replacingOccurrences(of: "-", with: "")
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts.first ?? "0")
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        let digits = minorUnits(currency) ?? 0
        if fraction.count < digits { fraction += String(repeating: "0", count: digits - fraction.count) }
        var grouped = ""
        for (i, c) in whole.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped.append(",") }
            grouped.append(c)
        }
        let body = String(grouped.reversed()) + (fraction.isEmpty ? "" : "." + fraction)
        return (d < 0 ? "-" : "") + body
    }

    /// "1,000.00" — kept for callers with no currency; a currency's own precision: `format(_:currency:)`.
    public static func format(_ d: Decimal) -> String { format(d, currency: "USD") }

    /// The ambiguous dollar: "$" written with no country prefix and no ISO code.
    public static let ambiguousDollar = "$"

    static func label(_ currency: String) -> String {
        if currency.isEmpty { return "currency not stated" }
        if currency == ambiguousDollar { return "$ (currency not stated)" }
        return currency
    }
}

/// One account's stated balances for a period, reconciled against the schedule.
public struct FAReconciliation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var account: String = ""
    public var periodStart: String = ""   // yyyy-MM-dd
    public var periodEnd: String = ""     // yyyy-MM-dd
    public var opening: String = ""
    public var closing: String = ""
    public var currency: String = ""
    public var sourceDoc: String = ""     // the statement the balances come from
    public init() {}
}

/// The schedule's arithmetic, per currency.
public struct FAScheduleSummary: Equatable, Sendable {
    /// MONEY-06 — the calculation rules, so following money through several accounts never inflates a
    /// total: GROSS is money that left the traced funds for the first time — payments and fees whose payer
    /// had not itself received that money earlier in the schedule. A payment by a party that earlier
    /// received a scheduled payment (in the same currency) is an ONWARD hop of money already counted: shown,
    /// never added again. A "transfer between accounts" moves money between the traced party's own
    /// accounts: shown as INTERNAL, never added to gross. Net = gross − returned.
    public struct Totals: Equatable, Sendable {
        public var gross = Decimal(0)      // first-hop payments and fees out of the traced funds
        public var returned = Decimal(0)   // refunds, reversals
        public var receipts = Decimal(0)   // money into the traced account
        public var onward = Decimal(0)     // later hops of money already in gross (not added)
        public var internalTransfers = Decimal(0)   // between the traced party's own accounts (not added)
        public var net: Decimal { gross - returned }
    }
    /// Rows shown as onward hops / internal transfers (MONEY-06), not added to gross.
    public var onwardRows: [UUID] = []
    public var internalRows: [UUID] = []
    public var byCurrency: [String: Totals] = [:]
    /// Rows not counted: not classified, not a movement, a duplicate copy, or no readable amount.
    public var unclassified: [UUID] = []
    public var notMovements: [UUID] = []
    public var duplicateCopies: [(row: UUID, of: UUID)] = []
    /// Look alike but carry no transaction reference: COUNTED, flagged for the person to decide.
    public var possibleDuplicates: [(row: UUID, of: UUID)] = []
    public var unreadable: [UUID] = []
    /// Movements whose currency is not stated (or stated ambiguously): counted under "currency not
    /// stated", and they block an approved schedule.
    public var currencyUnstated: [UUID] = []

    public static func == (a: Self, b: Self) -> Bool {
        a.byCurrency == b.byCurrency && a.unclassified == b.unclassified && a.notMovements == b.notMovements
            && a.unreadable == b.unreadable && a.duplicateCopies.map(\.row) == b.duplicateCopies.map(\.row)
    }
}

/// A reconciliation's result: what the schedule says the closing balance should be.
public struct FAReconciliationResult: Equatable, Sendable {
    public let id: UUID
    public let expectedClosing: Decimal?
    public let stated: Decimal?
    /// Why this reconciliation cannot be relied on (unknown account or currency, unreadable balance,
    /// movements of the account that could not be placed). Empty: it can.
    public var unresolved: [String] = []
    /// The statement's currency (for display at that currency's precision).
    public var currency: String = ""
    public var difference: Decimal? { unresolved.isEmpty ? expectedClosing.flatMap { e in stated.map { $0 - e } } : nil }
}
