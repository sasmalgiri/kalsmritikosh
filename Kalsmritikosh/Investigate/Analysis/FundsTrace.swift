//
//  FundsTrace.swift
//  Kalsmritikosh
//
//  A-8 — amount-weighted funds tracing. Pure logic, no database and no model: it takes the ledger's
//  payer → payee payment relationships (with the documents each was observed in) and the money
//  amounts extracted from those documents, and works out
//    • which amount belongs to which payment (only when a document is unambiguous),
//    • the total per edge, PER CURRENCY (different currencies are never added together),
//    • each party's in / out / net,
//    • a "follow the money" trace from one party: the downstream flow, where each party can pass on
//      at most what it received in the trace, and where the money stops.
//  Every figure carries the fact ids and document ids it was computed from, so it can be cited.
//  Nothing here decides anything — it arranges recorded amounts so a person can check them.
//

import Foundation

// MARK: - Money

public nonisolated struct FundsMoney: Hashable, Sendable {
    public let amount: Decimal
    /// ISO-style code (INR, USD, EUR, GBP …), `FundsMoney.unstated` when the source gave none, or
    /// `FundsMoney.ambiguousDollar` for a bare "$" (MONEY-02: never assumed to be US dollars).
    public let currency: String

    public static let unstated = "UNSTATED"
    public static let ambiguousDollar = FAMoney.ambiguousDollar

    public init(amount: Decimal, currency: String) { self.amount = amount; self.currency = currency }
}

public nonisolated enum FundsMoneyParser {
    /// Parse an extracted amount ("₹10,000", "$1,234.56", "Rs. 5,00,000", "1500") with the fact's unit.
    /// The unit wins when present; otherwise the currency sign in the value; otherwise UNSTATED (kept
    /// apart from every stated currency). nil when there is no positive number.
    /// S7 (MONEY-02): the sign as written is kept — "-₹1,000", "₹ -1,000", "−1,000" and "(1,000)" are negative amounts, never
    /// silently made positive (`FundsTrace.attribute` then leaves a negative amount unassigned rather than guess what it means).
    /// nil when there is no number or the number is zero.
    public static func parse(value: String, unit: String?) -> FundsMoney? {
        guard let range = value.range(of: #"\d[\d,]*(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        let digits = value[range].replacingOccurrences(of: ",", with: "")
        guard let magnitude = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")), magnitude > 0 else { return nil }
        let before = value[..<range.lowerBound].replacingOccurrences(of: #"[\s₹$€£¥A-Za-z.]"#, with: "", options: .regularExpression)
        let after = value[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let negative = before.hasSuffix("-") || before.hasSuffix("−") || (before.hasSuffix("(") && after.hasPrefix(")"))
        let fromUnit = unit.map(normalizeCurrency).flatMap { $0.isEmpty ? nil : $0 }
        return FundsMoney(amount: negative ? -magnitude : magnitude, currency: fromUnit ?? currencyFromSign(value) ?? FundsMoney.unstated)
    }

    static func normalizeCurrency(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch s {
        case "₹", "RS", "RS.", "INR": return "INR"
        case "$": return FundsMoney.ambiguousDollar          // MONEY-02: which dollar is not said
        case "USD", "US$": return "USD"
        case "€", "EUR": return "EUR"
        case "£", "GBP": return "GBP"
        default:
            let code = FAMoney.currency(of: s)              // CA$, A$, HK$ …
            return code.isEmpty ? s : code
        }
    }

    /// The currency the written amount names. The schedule's rules (FAMoney.currency) first: an ISO code or a
    /// country-prefixed dollar names it; ₹/Rs, € and £ are unambiguous. A bare "$" is the ambiguous dollar —
    /// shown as "$ (currency not stated)", never assumed to be USD.
    static func currencyFromSign(_ value: String) -> String? {
        let code = FAMoney.currency(of: value.uppercased())
        if !code.isEmpty { return code }
        let v = value.lowercased()
        if v.contains("₹") || v.range(of: #"\brs\.?"#, options: .regularExpression) != nil || v.contains("inr") { return "INR" }
        if v.contains("€") || v.contains("eur") { return "EUR" }
        if v.contains("£") || v.contains("gbp") { return "GBP" }
        if v.contains("usd") { return "USD" }
        if v.contains("$") { return FundsMoney.ambiguousDollar }
        return nil
    }
}

// MARK: - Inputs

/// A payer → payee payment relationship and the documents it was observed in.
public nonisolated struct FundsPaymentEdge: Hashable, Sendable {
    public let fromID: String
    public let fromLabel: String
    public let toID: String
    public let toLabel: String
    public let documentIDs: [String]
    public init(fromID: String, fromLabel: String, toID: String, toLabel: String, documentIDs: [String]) {
        self.fromID = fromID; self.fromLabel = fromLabel; self.toID = toID; self.toLabel = toLabel; self.documentIDs = documentIDs
    }
}

/// One extracted money fact and the document it was read from.
public nonisolated struct FundsAmountFact: Hashable, Sendable {
    public let factID: String
    public let documentID: String
    public let value: String
    public let unit: String?
    /// MONEY-04 — part of the transaction's identity when the source gives it: the day the payment was
    /// made and its reference (UTR, cheque or wire number).
    public let date: Date?
    public let reference: String?
    /// S7 (MONEY-03) — the words the extractor recorded around the amount (its subject label and matched text), used only
    /// to recognise an amount that says it is NOT a movement (an invoice total, a balance, an estimate…).
    public var context: String? = nil
    public init(factID: String, documentID: String, value: String, unit: String?, date: Date? = nil, reference: String? = nil, context: String? = nil) {
        self.factID = factID; self.documentID = documentID; self.value = value; self.unit = unit
        self.date = date; self.reference = reference; self.context = context
    }
}

/// S7 (MONEY-03) — an amount fact is classified BEFORE fund-flow attribution: one whose own words say it is an invoice
/// total, an amount due, a balance, an estimate or quotation, an allegation, a claim or a reserve is a mention of money, not
/// a movement, and is never tied to a payment. An amount with no such words is not thereby proven a movement: it is what a
/// document with a payment relationship states (FundsTrace says so), and only the case's money records classify for certain.
public nonisolated enum FundsAmountClass: String, Sendable, Hashable, CaseIterable {
    case invoice, balance, estimate, allegation, claim, reserve
    public var label: String {
        switch self {
        case .invoice: return "an invoice total or amount due"
        case .balance: return "a balance"
        case .estimate: return "an estimate or quotation"
        case .allegation: return "an alleged amount"
        case .claim: return "a claim"
        case .reserve: return "a reserve or limit"
        }
    }
    /// The non-movement class the words state, or nil when they state none (word boundaries, case-insensitive).
    public static func of(_ context: String?) -> FundsAmountClass? {
        guard let t = context?.lowercased(), !t.isEmpty else { return nil }
        let rules: [(FundsAmountClass, String)] = [
            (.balance, #"\b(opening|closing|available|outstanding)?\s*balance\b"#),
            (.invoice, #"\b(invoice[ds]?|invoiced|bill(ed)?|total payable|amount due|payable by)\b"#),
            (.estimate, #"\b(estimated?|estimates|quot(e|ed|ation)|approximately|budget(ed)?)\b"#),
            (.allegation, #"\b(alleged(ly)?|allegation|purported(ly)?)\b"#),
            (.claim, #"\b(claim(ed|s)?|demand(ed)?)\b"#),
            (.reserve, #"\b(reserve[ds]?|credit limit|limit of)\b"#),
        ]
        for (c, pattern) in rules where t.range(of: pattern, options: .regularExpression) != nil { return c }
        return nil
    }
}

// MARK: - Outputs

/// One payment with its amount, read from one document.
public nonisolated struct FundsTransfer: Hashable, Sendable, Identifiable {
    public var id: String { "\(documentID)|\(fromID)|\(toID)|\(money.currency)" }
    public let fromID: String
    public let fromLabel: String
    public let toID: String
    public let toLabel: String
    public let money: FundsMoney
    public let documentID: String
    public let factIDs: [String]
    /// MONEY-04: the payment's day (UTC calendar day) and reference, when its facts state them.
    public var date: Date? = nil
    public var reference: String? = nil
}

/// MONEY-04 — one real payment, however many documents record it. Its identity is payer + payee +
/// currency + amount + day + reference: occurrences in different documents that agree on all of these
/// (a missing day or reference agrees with any) are ONE transaction, counted once, with every
/// occurrence kept as provenance. Two payments of the same amount on different days, or with different
/// references, stay two. When neither day nor reference is known the occurrences are still counted
/// once (a total never adds money it cannot show is separate) and the transaction says so
/// (`identityBasis == .amountAndPartiesOnly`), so the person can split it.
public nonisolated struct FundsTransaction: Hashable, Sendable, Identifiable {
    public enum IdentityBasis: String, Sendable, Hashable { case reference, date, amountAndPartiesOnly }
    public var id: String { occurrences.map(\.id).sorted().joined(separator: "+") }
    public let fromID: String
    public let fromLabel: String
    public let toID: String
    public let toLabel: String
    public let money: FundsMoney
    public let date: Date?
    public let reference: String?
    /// Every document occurrence (provenance), in document order.
    public let occurrences: [FundsTransfer]
    public var identityBasis: IdentityBasis { reference != nil ? .reference : (date != nil ? .date : .amountAndPartiesOnly) }
    public var documentIDs: [String] { FundsTrace.unique(occurrences.map(\.documentID)) }
    public var factIDs: [String] { FundsTrace.unique(occurrences.flatMap(\.factIDs)) }
    /// More than one document, matched on amount and parties alone.
    public var isUnconfirmedMerge: Bool { occurrences.count > 1 && identityBasis == .amountAndPartiesOnly }
}

/// A document that backs a payment but whose amount could not be tied to it without guessing.
public nonisolated struct FundsUnattributed: Hashable, Sendable, Identifiable {
    public enum Reason: String, Sendable, Hashable {
        case noAmount            // the document records the payment but no amount
        case severalAmounts      // more than one different amount — which one is the payment is unclear
        case severalPayments     // one amount but several payments in the same document
        /// S7 (MONEY-02): the only amount is written negative — a debit, a reversal or a correction? Not assigned.
        case negativeAmount
        /// S7 (MONEY-03): the amount's own words say it is not a movement (an invoice total, a balance…). Never a payment.
        case notAMovement
    }
    public var id: String { "\(documentID)|\(reason.rawValue)" }
    public let documentID: String
    public let reason: Reason
    public let factIDs: [String]
    public let payments: [String]      // "payer → payee" labels
    /// S7 (MONEY-03): for `.notAMovement`, what the amounts say they are.
    public var classes: [FundsAmountClass] = []

    public var explanation: String {
        switch reason {
        case .noAmount: return "Records a payment but no amount"
        case .severalAmounts: return "Several different amounts — not assigned to a payment"
        case .severalPayments: return "One amount but several payments — not assigned"
        case .negativeAmount: return "The amount is written as a negative figure — a debit, a reversal or a correction is not decided here; not assigned"
        case .notAMovement: return "An amount the document describes as \(classes.map(\.label).joined(separator: ", ")) — a mention of money, not a payment; never counted"
        }
    }
}

/// The total on one payer → payee edge in one currency.
public nonisolated struct FundsEdgeTotal: Hashable, Sendable, Identifiable {
    public var id: String { "\(fromID)|\(toID)|\(currency)" }
    public let fromID: String
    public let fromLabel: String
    public let toID: String
    public let toLabel: String
    public let currency: String
    public let total: Decimal
    /// Distinct transactions on this edge (MONEY-04: one payment recorded in two documents is one).
    public let transferCount: Int
    public let factIDs: [String]
    public let documentIDs: [String]
    /// Document occurrences behind those transactions (≥ transferCount).
    public var occurrenceCount: Int = 0
    /// Transactions counted once although only amount and parties tie their documents together.
    public var unconfirmedMerges: Int = 0
}

/// One party's money in one currency: received, sent, net (received − sent).
public nonisolated struct FundsPartyBalance: Hashable, Sendable, Identifiable {
    public var id: String { "\(partyID)|\(currency)" }
    public let partyID: String
    public let label: String
    public let currency: String
    public let received: Decimal
    public let sent: Decimal
    public var net: Decimal { received - sent }
    public let factIDs: [String]
    public let documentIDs: [String]
}

/// One edge followed in a trace: how much of its recorded total the trace carried along it.
public nonisolated struct FundsTraceStep: Hashable, Sendable, Identifiable {
    public var id: String { "\(fromID)|\(toID)" }
    public let depth: Int               // hop number at which the trace first reached this edge (1 = from the origin)
    public let fromID: String
    public let fromLabel: String
    public let toID: String
    public let toLabel: String
    public let traced: Decimal
    public let recorded: Decimal
    /// True when the edge records more than the trace could carry (the payer had received less).
    public var capped: Bool { traced < recorded }
    public let factIDs: [String]
    public let documentIDs: [String]
}

/// Where traced money stops, and why.
public nonisolated struct FundsTraceStop: Hashable, Sendable, Identifiable {
    public enum Reason: String, Sendable, Hashable {
        case noOnwardPayments    // no payment out of this party is recorded
        case keptMoreThanPassedOn // it received more than its recorded onward payments
        case returnedToOrigin    // the money came back to the starting party
        case depthLimit          // the trace stopped following after the hop limit
    }
    public var id: String { "\(partyID)|\(reason.rawValue)" }
    public let partyID: String
    public let label: String
    public let reason: Reason
    public let amount: Decimal
    /// The facts/documents of the traced payments INTO this party (what the figure rests on).
    public let factIDs: [String]
    public let documentIDs: [String]

    public var explanation: String {
        switch reason {
        case .noOnwardPayments: return "No onward payment recorded"
        case .keptMoreThanPassedOn: return "Received more than it is recorded as passing on"
        case .returnedToOrigin: return "Came back to the starting party"
        case .depthLimit: return "Not followed further (hop limit)"
        }
    }
}

public nonisolated struct FundsTraceResult: Hashable, Sendable, Identifiable {
    public var id: String { "\(originID)|\(currency)" }
    public let originID: String
    public let originLabel: String
    public let currency: String
    public let sentByOrigin: Decimal
    public let steps: [FundsTraceStep]
    public let stops: [FundsTraceStop]
    public let maxDepth: Int
}

// MARK: - Logic

public nonisolated enum FundsTrace {

    /// Tie amounts to payments. A document's amount is assigned only when the document backs exactly
    /// ONE payment and holds exactly ONE distinct amount (same value and currency, however many facts
    /// repeat it). Everything else is reported as unattributed with the reason — never guessed.
    public static func attribute(edges: [FundsPaymentEdge], amounts: [FundsAmountFact])
        -> (transfers: [FundsTransfer], unattributed: [FundsUnattributed]) {
        var edgesByDoc: [String: [FundsPaymentEdge]] = [:]
        for e in edges {
            for d in Set(e.documentIDs) where !d.isEmpty {
                if !(edgesByDoc[d] ?? []).contains(where: { $0.fromID == e.fromID && $0.toID == e.toID }) {
                    edgesByDoc[d, default: []].append(e)
                }
            }
        }
        var amountsByDoc: [String: [FundsMoney: [String]]] = [:]
        var factInfo: [String: FundsAmountFact] = [:]
        // S7 (MONEY-03): an amount whose words say it is not a movement is set aside first, per document, with its class.
        var mentions: [String: (facts: [String], classes: Set<FundsAmountClass>)] = [:]
        for f in amounts {
            guard let m = FundsMoneyParser.parse(value: f.value, unit: f.unit) else { continue }
            if let c = FundsAmountClass.of(f.context) {
                mentions[f.documentID, default: ([], [])].facts.append(f.factID)
                mentions[f.documentID, default: ([], [])].classes.insert(c)
                continue
            }
            amountsByDoc[f.documentID, default: [:]][m, default: []].append(f.factID)
            factInfo[f.factID] = f
        }
        var transfers: [FundsTransfer] = []
        var unattributed: [FundsUnattributed] = []
        for doc in edgesByDoc.keys.sorted() {
            let docEdges = edgesByDoc[doc] ?? []
            var money = amountsByDoc[doc] ?? [:]
            // The same figure read once with its currency sign and once without is one amount.
            let stated = money.keys.filter { $0.currency != FundsMoney.unstated }
            if stated.count == 1, let s = stated.first {
                for u in money.keys where u.currency == FundsMoney.unstated && u.amount == s.amount {
                    money[s, default: []] += money[u] ?? []
                    money[u] = nil
                }
            }
            let allFacts = money.values.flatMap { $0 }.sorted()
            let labels = docEdges.map { "\($0.fromLabel) → \($0.toLabel)" }.sorted()
            if let m = mentions[doc] {
                var u = FundsUnattributed(documentID: doc, reason: .notAMovement, factIDs: m.facts.sorted(), payments: labels)
                u.classes = m.classes.sorted { $0.rawValue < $1.rawValue }
                unattributed.append(u)
            }
            if money.isEmpty, mentions[doc] != nil {
                continue      // only mentions of money: listed above, nothing to assign
            } else if money.count == 1, let only = money.first, only.key.amount < 0 {
                unattributed.append(FundsUnattributed(documentID: doc, reason: .negativeAmount, factIDs: allFacts, payments: labels))
            } else if money.isEmpty {
                unattributed.append(FundsUnattributed(documentID: doc, reason: .noAmount, factIDs: [], payments: labels))
            } else if money.count > 1 {
                unattributed.append(FundsUnattributed(documentID: doc, reason: .severalAmounts, factIDs: allFacts, payments: labels))
            } else if docEdges.count > 1 {
                unattributed.append(FundsUnattributed(documentID: doc, reason: .severalPayments, factIDs: allFacts, payments: labels))
            } else if let e = docEdges.first, let only = money.first {
                let facts = unique(only.value).compactMap { factInfo[$0] }
                // A day or reference is kept only when the document's facts for this amount agree on one.
                let days = Set(facts.compactMap(\.date).map(dayKey))
                let refs = Set(facts.compactMap(\.reference).map(normalizedReference).filter { !$0.isEmpty })
                transfers.append(FundsTransfer(fromID: e.fromID, fromLabel: e.fromLabel, toID: e.toID, toLabel: e.toLabel,
                                               money: only.key, documentID: doc, factIDs: unique(only.value),
                                               date: days.count == 1 ? facts.compactMap(\.date).first.map(startOfDay) : nil,
                                               reference: refs.count == 1 ? refs.first : nil))
            }
        }
        return (transfers, unattributed)
    }

    // MARK: MONEY-04 — transaction identity

    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC") ?? .gmt; return c }()
    static func startOfDay(_ d: Date) -> Date { utc.startOfDay(for: d) }
    static func dayKey(_ d: Date) -> Int { Int(startOfDay(d).timeIntervalSince1970 / 86_400) }
    static func normalizedReference(_ r: String) -> String {
        r.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Group document occurrences into transactions (see `FundsTransaction`). Deterministic: documents in order.
    public static func transactions(_ transfers: [FundsTransfer]) -> [FundsTransaction] {
        struct Group { var items: [FundsTransfer]; var date: Date?; var reference: String? }
        struct Key: Hashable { let from: String; let to: String; let money: FundsMoney }
        var groups: [Key: [Group]] = [:]
        let ordered = transfers.sorted { ($0.documentID, $0.id) < ($1.documentID, $1.id) }
        for t in ordered {
            let key = Key(from: t.fromID, to: t.toID, money: t.money)
            var list = groups[key] ?? []
            let match = list.firstIndex { g in
                !g.items.contains { $0.documentID == t.documentID }        // one document records one payment once
                    && (g.reference == nil || t.reference == nil || g.reference == t.reference)
                    && (g.date == nil || t.date == nil || dayKey(g.date!) == dayKey(t.date!))
            }
            if let i = match {
                list[i].items.append(t)
                list[i].date = list[i].date ?? t.date
                list[i].reference = list[i].reference ?? t.reference
            } else {
                list.append(Group(items: [t], date: t.date, reference: t.reference))
            }
            groups[key] = list
        }
        return groups.flatMap { key, list in
            list.map { g in
                FundsTransaction(fromID: key.from, fromLabel: g.items[0].fromLabel, toID: key.to, toLabel: g.items[0].toLabel,
                                 money: key.money, date: g.date, reference: g.reference, occurrences: g.items)
            }
        }
        .sorted { ($0.fromID, $0.toID, $0.money.currency, $0.documentIDs.first ?? "") < ($1.fromID, $1.toID, $1.money.currency, $1.documentIDs.first ?? "") }
    }

    /// Sum TRANSACTIONS per (payer, payee, currency) — one payment recorded in several documents counts
    /// once, with every document kept (MONEY-04). Largest first within each currency.
    public static func edgeTotals(_ transfers: [FundsTransfer]) -> [FundsEdgeTotal] {
        struct Key: Hashable { let from: String; let to: String; let currency: String }
        var groups: [Key: [FundsTransaction]] = [:]
        for t in transactions(transfers) { groups[Key(from: t.fromID, to: t.toID, currency: t.money.currency), default: []].append(t) }
        return groups.map { key, ts in
            FundsEdgeTotal(fromID: key.from, fromLabel: ts[0].fromLabel, toID: key.to, toLabel: ts[0].toLabel,
                           currency: key.currency, total: ts.reduce(Decimal(0)) { $0 + $1.money.amount },
                           transferCount: ts.count, factIDs: unique(ts.flatMap(\.factIDs)),
                           documentIDs: unique(ts.flatMap(\.documentIDs)),
                           occurrenceCount: ts.reduce(0) { $0 + $1.occurrences.count },
                           unconfirmedMerges: ts.filter(\.isUnconfirmedMerge).count)
        }
        .sorted { a, b in
            if a.currency != b.currency { return a.currency < b.currency }
            if a.total != b.total { return a.total > b.total }
            return (a.fromLabel, a.toLabel, a.fromID, a.toID) < (b.fromLabel, b.toLabel, b.fromID, b.toID)
        }
    }

    /// Received / sent / net per party and currency, over transactions (MONEY-04: never per document copy).
    public static func partyBalances(_ transfers: [FundsTransfer]) -> [FundsPartyBalance] {
        struct Key: Hashable { let party: String; let currency: String }
        var received: [Key: Decimal] = [:], sent: [Key: Decimal] = [:]
        var labels: [String: String] = [:]
        var facts: [Key: [String]] = [:], docs: [Key: [String]] = [:]
        for t in transactions(transfers) {
            let out = Key(party: t.fromID, currency: t.money.currency)
            let inn = Key(party: t.toID, currency: t.money.currency)
            sent[out, default: 0] += t.money.amount
            received[inn, default: 0] += t.money.amount
            labels[t.fromID] = t.fromLabel; labels[t.toID] = t.toLabel
            for k in [out, inn] { facts[k, default: []] += t.factIDs; docs[k, default: []] += t.documentIDs }
        }
        let keys = Set(received.keys).union(sent.keys)
        return keys.map { k in
            FundsPartyBalance(partyID: k.party, label: labels[k.party] ?? k.party, currency: k.currency,
                              received: received[k] ?? 0, sent: sent[k] ?? 0,
                              factIDs: unique(facts[k] ?? []), documentIDs: unique(docs[k] ?? []))
        }
        .sorted { ($0.currency, $0.label) < ($1.currency, $1.label) }
    }

    /// Follow the money from `originID`, one trace per currency the origin is recorded as paying out.
    public static func trace(from originID: String, transfers: [FundsTransfer], maxDepth: Int = 8) -> [FundsTraceResult] {
        let totals = edgeTotals(transfers)
        let currencies = Set(totals.filter { $0.fromID == originID }.map(\.currency)).sorted()
        return currencies.map { trace(from: originID, currency: $0, edges: totals, maxDepth: maxDepth) }
    }

    /// Follow the money from `originID` in one currency, hop by hop. The origin passes on everything
    /// it is recorded as paying. Every other party passes on at most what reached it in the trace,
    /// split across its onward payments in proportion to what each still has recorded; an edge never
    /// carries more in total than its recorded amount. Money that cannot move on is a stop.
    public static func trace(from originID: String, currency: String, edges allEdges: [FundsEdgeTotal],
                             maxDepth: Int = 8) -> FundsTraceResult {
        let edges = allEdges.filter { $0.currency == currency && $0.fromID != $0.toID }
        var outgoing: [String: [FundsEdgeTotal]] = [:]
        var labels: [String: String] = [:]
        for e in edges {
            outgoing[e.fromID, default: []].append(e)
            labels[e.fromID] = e.fromLabel; labels[e.toID] = e.toLabel
        }
        for k in outgoing.keys { outgoing[k]?.sort { $0.toID < $1.toID } }
        var remaining: [String: Decimal] = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0.total) })
        var traced: [String: Decimal] = [:]
        var firstDepth: [String: Int] = [:]
        var inbound: [String: (facts: [String], docs: [String])] = [:]
        var stops: [String: (party: String, reason: FundsTraceStop.Reason, amount: Decimal)] = [:]

        func stop(_ party: String, _ reason: FundsTraceStop.Reason, _ amount: Decimal) {
            guard amount > 0 else { return }
            let key = "\(party)|\(reason.rawValue)"
            stops[key] = (party, reason, (stops[key]?.amount ?? 0) + amount)
        }

        let sentByOrigin = (outgoing[originID] ?? []).reduce(Decimal(0)) { $0 + $1.total }
        var pending: [String: Decimal] = sentByOrigin > 0 ? [originID: sentByOrigin] : [:]
        var depth = 0
        while !pending.isEmpty && depth < maxDepth {
            depth += 1
            var next: [String: Decimal] = [:]
            for node in pending.keys.sorted() {
                guard let amount = pending[node], amount > 0 else { continue }
                if node == originID && depth > 1 { stop(node, .returnedToOrigin, amount); continue }
                let outs = (outgoing[node] ?? []).filter { (remaining[$0.id] ?? 0) > 0 }
                let capacity = outs.reduce(Decimal(0)) { $0 + (remaining[$1.id] ?? 0) }
                if capacity == 0 {
                    stop(node, (outgoing[node] ?? []).isEmpty ? .noOnwardPayments : .keptMoreThanPassedOn, amount)
                    continue
                }
                let pass = min(amount, capacity)
                var allocated = Decimal(0)
                for (i, e) in outs.enumerated() {
                    let room = remaining[e.id] ?? 0
                    let flow: Decimal
                    if pass == capacity { flow = room }
                    else if i == outs.count - 1 { flow = min(room, pass - allocated) }
                    else { flow = room * pass / capacity }
                    guard flow > 0 else { continue }
                    allocated += flow
                    remaining[e.id] = room - flow
                    traced[e.id, default: 0] += flow
                    if firstDepth[e.id] == nil { firstDepth[e.id] = depth }
                    next[e.toID, default: 0] += flow
                    inbound[e.toID, default: ([], [])].facts += e.factIDs
                    inbound[e.toID, default: ([], [])].docs += e.documentIDs
                }
                if amount > pass { stop(node, .keptMoreThanPassedOn, amount - pass) }
            }
            pending = next
        }
        for (node, amount) in pending where amount > 0 {
            if node == originID { stop(node, .returnedToOrigin, amount) }
            else if (outgoing[node] ?? []).isEmpty { stop(node, .noOnwardPayments, amount) }
            else { stop(node, .depthLimit, amount) }
        }

        let steps = edges.compactMap { e -> FundsTraceStep? in
            guard let t = traced[e.id], t > 0, let d = firstDepth[e.id] else { return nil }
            return FundsTraceStep(depth: d, fromID: e.fromID, fromLabel: e.fromLabel, toID: e.toID, toLabel: e.toLabel,
                                  traced: t, recorded: e.total, factIDs: e.factIDs, documentIDs: e.documentIDs)
        }
        .sorted { ($0.depth, $0.fromLabel, $0.toLabel) < ($1.depth, $1.fromLabel, $1.toLabel) }
        let stopList = stops.values.map { s in
            FundsTraceStop(partyID: s.party, label: labels[s.party] ?? s.party, reason: s.reason, amount: s.amount,
                           factIDs: unique(inbound[s.party]?.facts ?? []), documentIDs: unique(inbound[s.party]?.docs ?? []))
        }
        .sorted { ($0.label, $0.reason.rawValue) < ($1.label, $1.reason.rawValue) }
        return FundsTraceResult(originID: originID, originLabel: labels[originID] ?? originID, currency: currency,
                                sentByOrigin: sentByOrigin, steps: steps, stops: stopList, maxDepth: maxDepth)
    }

    // MARK: S7 (MONEY-10) — every figure in the amount diagram, with what it rests on

    /// What the amount diagram draws and what each width means, said in words.
    public static let amountLegend = "Ribbon width is the amount, in this currency only. A party's figure is the sum of the payments drawn to or from it; every figure lists the payments and documents it is made of. Width never means how certain a payment is, and a path drawn between parties does not show that particular money travelled along it."
    public static let corroborationLegend = "Ribbon width is corroboration strength — how often and in how many documents the payment relationship was observed — not an amount."
    /// The tracing rule, stated (the proportional cap).
    public static let tracingAssumption = "Following the money: each party can pass on at most what reached it in the trace, split across its recorded onward payments in proportion to their recorded amounts. This is an allocation assumption, not a finding that particular funds moved."

    /// One party's total on one side of the amount diagram, with the payments, facts and documents it is made of.
    public struct NodeTotal: Hashable, Sendable, Identifiable {
        public enum Side: String, Sendable, Hashable { case payer, payee }
        public var id: String { "\(side.rawValue)|\(partyID)|\(currency)" }
        public let side: Side
        public let partyID: String
        public let label: String
        public let currency: String
        public let total: Decimal
        /// The edge totals (payer → payee) that make this figure.
        public let edges: [String]
        public let factIDs: [String]
        public let documentIDs: [String]
        public var display: String { "\(label) · \(FundsTrace.format(total, currency: currency))" }
    }

    /// The payer and payee totals of `edges` in one currency, exact (Decimal), each with its contributing edges and sources.
    public static func nodeTotals(_ edges: [FundsEdgeTotal], currency: String) -> [NodeTotal] {
        let inCurrency = edges.filter { $0.currency == currency }
        var out: [NodeTotal] = []
        for side in [NodeTotal.Side.payer, .payee] {
            let groups = Dictionary(grouping: inCurrency, by: { side == .payer ? $0.fromID : $0.toID })
            for (party, es) in groups {
                out.append(NodeTotal(side: side, partyID: party, label: side == .payer ? es[0].fromLabel : es[0].toLabel, currency: currency,
                                     total: es.reduce(Decimal(0)) { $0 + $1.total }, edges: es.map(\.id).sorted(),
                                     factIDs: unique(es.flatMap(\.factIDs)), documentIDs: unique(es.flatMap(\.documentIDs))))
            }
        }
        return out.sorted { ($0.side.rawValue, $1.total, $0.label) < ($1.side.rawValue, $0.total, $1.label) }
    }

    /// A display string for an amount (MONEY-02): the one shared formatter (FAMoney.format) at the
    /// currency's own precision — JPY 0 decimals, INR/USD 2, KWD 3 — never rounding the stored Decimal away.
    /// No currency: "(currency not stated)"; a bare "$": "$ (currency not stated)".
    public static func format(_ amount: Decimal, currency: String) -> String {
        if currency == FundsMoney.unstated { return "\(FAMoney.format(amount, currency: "")) (currency not stated)" }
        return "\(FAMoney.label(currency)) \(FAMoney.format(amount, currency: currency))"
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out.sorted()
    }
}
