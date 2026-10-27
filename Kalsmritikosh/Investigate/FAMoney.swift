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
    /// Counted in the gross outflow the engagement traces.
    var isOutflow: Bool { [.payment, .transfer, .fee].contains(self) }
    /// Money coming back: reduces the net.
    var isReturn: Bool { [.refund, .reversal].contains(self) }
}

public enum FAMoney {

    /// The currency an amount is written in, from its symbol or code ("" when it states none).
    public static func currency(of text: String) -> String {
        if text.contains("₹") || text.range(of: #"\b(?:INR|Rs\.?|RS\.?)(?=\s?\d)"#, options: .regularExpression) != nil { return "INR" }
        if text.contains("€") { return "EUR" }
        if text.contains("£") { return "GBP" }
        if text.contains("$") { return "USD" }
        // An ISO code written in capitals next to the amount; never an arbitrary three-letter word.
        if let r = text.range(of: #"\b(?:USD|EUR|GBP|INR|JPY|CNY|AUD|CAD|CHF|SGD|AED|HKD|NZD|ZAR|SEK|NOK|DKK|SAR|BRL|MXN)\b"#, options: .regularExpression) { return String(text[r]) }
        return ""
    }

    /// The amount as an exact Decimal: symbols, codes, grouping separators and spaces removed;
    /// "(1,000)" or "-1,000" is negative. Nil when the text holds no number.
    public static func value(of text: String) -> Decimal? {
        var t = text.trimmingCharacters(in: .whitespaces)
        let negative = t.hasPrefix("-") || t.hasPrefix("−") || (t.hasPrefix("(") && t.hasSuffix(")"))
        t = t.replacingOccurrences(of: #"(?i)\brs\."#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1, let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -d : d
    }

    /// "1,000.00" with two decimals, exact.
    public static func format(_ d: Decimal) -> String {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 2, .bankers)
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; f.usesGroupingSeparator = true
        return f.string(from: r as NSDecimalNumber) ?? "\(r)"
    }

    static func label(_ currency: String) -> String { currency.isEmpty ? "currency not stated" : currency }
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
    public struct Totals: Equatable, Sendable {
        public var gross = Decimal(0)      // payments, transfers, fees
        public var returned = Decimal(0)   // refunds, reversals
        public var receipts = Decimal(0)   // money into the traced account
        public var net: Decimal { gross - returned }
    }
    public var byCurrency: [String: Totals] = [:]
    /// Rows not counted: not classified, not a movement, a duplicate copy, or no readable amount.
    public var unclassified: [UUID] = []
    public var notMovements: [UUID] = []
    public var duplicateCopies: [(row: UUID, of: UUID)] = []
    public var unreadable: [UUID] = []

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
    public var difference: Decimal? { expectedClosing.flatMap { e in stated.map { $0 - e } } }
}
