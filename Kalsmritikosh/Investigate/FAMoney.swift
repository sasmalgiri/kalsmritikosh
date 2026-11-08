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
public enum FAKind: String, Codable, CaseIterable, Sendable {
    case unclassified
    case payment, receipt, transfer, refund, reversal, fee
    case invoice, claim, reserve, balance, quotation

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
        }
    }

    /// Money actually moved.
    public var isMovement: Bool { [.payment, .receipt, .transfer, .refund, .reversal, .fee].contains(self) }
    /// Money leaving an account (a candidate for the gross outflow; see FAScheduleSummary for the rules).
    var isOutflow: Bool { [.payment, .transfer, .fee].contains(self) }
    /// Money coming back: reduces the net.
    var isReturn: Bool { [.refund, .reversal].contains(self) }
}

public enum FAMoney {

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
