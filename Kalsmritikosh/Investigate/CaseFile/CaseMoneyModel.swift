//
//  CaseMoneyModel.swift
//  Kalsmritikosh
//
//  Smart-map S7 (docs/IME_Full_Smart_Map_Implementation_TODO_2026-11-08.md §15 MONEY; plan §8; schema v183). The case's
//  canonical financial records — accounts, who holds or controls them over time, statements, and money records (movements,
//  invoices, claims, balances, allegations, estimates, assets, statement rows) — over the ONE case file repository and its
//  savepoint. The same records appear in the money, people, time and question views (CaseMapProjector reads this ledger).
//  Nothing here calls a model or the network, and nothing here decides anything about a person.
//
//  The arithmetic is the schedule's (FAMoney): exact Decimal, the raw text kept beside the value, per currency, never mixed.
//  • Classification (MONEY-03): only a classified MOVEMENT enters a paid, received or returned figure. An invoice, claim,
//    balance, reserve, quotation, allegation, estimate or asset is a mention of money; an unclassified amount is a candidate.
//  • Identity (MONEY-04): records of one real payment — a statement row and the same payment in a report, or a byte-identical
//    copy — are one transaction, every occurrence kept. Rule: the same reference is the same payment; different references or
//    different days are different payments; rows of one document are different payments; anything else (a day or reference
//    missing) is a CANDIDATE: counted once and flagged with what the total would be if they were separate, until a person
//    confirms (same) or splits (distinct) it. Equal amounts alone never merge two payments that the rule can tell apart.
//  • Outcomes (MONEY-05): gross paid, received, returned, fees, outstanding and disputed are separate figures, each with its
//    contributing records. Net outflow = gross paid + fees − returned, and it is never called a loss.
//  • Paths (MONEY-06): parties are matched through the accounts' recorded holders (ownership), else the account, else — said
//    so — the written name. A payment by a party that had received scheduled money earlier is an onward hop (shown, not added);
//    a transfer between accounts is internal (shown, not added), flagged when the accounts' recorded holders differ.
//  • Statements (MONEY-07): per account, period and currency; rows imported from the statement; records of the account in the
//    period that are not on the statement, movements no statement covers, and gaps between statements are listed. A statement
//    is "reconciled" only with nothing unresolved, nothing unmatched and no difference.
//  • Conversion (MONEY-08): only with a recorded rate (rate, source, date, method), shown beside the original-currency figures,
//    and marked partial when a currency has no rate. Nothing is converted silently.
//  • Ownership and control (MONEY-09): dated, sourced assertions (holder, signatory, direct/indirect owner, controller,
//    beneficial owner). Holding or controlling an account says nothing about authorising a payment or being liable for it.
//  • Gaps (MONEY-11): one proposed request per account and missing period (statement copies count once), never a storm.
//

import Foundation
import os

// MARK: - Vocabulary

public nonisolated enum CaseMoneyKind: String, Sendable, CaseIterable, Codable, Identifiable {
    case unclassified
    case payment, receipt, transfer, refund, reversal, fee
    case invoice, claim, reserve, balance, quotation, allegation, estimate, asset
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .asset: return "Asset (not a movement)"
        default: return faKind?.label ?? rawValue
        }
    }
    /// The schedule's kind (the same arithmetic); nil for an asset, which the schedule has no row for.
    public var faKind: FAKind? { FAKind(rawValue: rawValue) }
    public var isMovement: Bool { faKind?.isMovement ?? false }
    /// An amount someone is owed (an invoice or claim) that a movement can settle.
    public var isReceivable: Bool { self == .invoice || self == .claim }
}

public nonisolated enum CaseMoneyRelation: String, Sendable, CaseIterable, Codable, Identifiable {
    case holder, jointHolder, signatory, directOwner, indirectOwner, controller, beneficialOwner
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .holder: return "Account holder"
        case .jointHolder: return "Joint account holder"
        case .signatory: return "Authorised signatory (as stated)"
        case .directOwner: return "Direct owner"
        case .indirectOwner: return "Indirect owner"
        case .controller: return "Controls (as stated)"
        case .beneficialOwner: return "Beneficial owner (as asserted)"
        }
    }
    /// Whose money the account is, for matching parties (MONEY-06): its holders.
    var definesParty: Bool { self == .holder || self == .jointHolder }
    /// Said wherever the relationship is shown.
    public static let impliesNothing = "Holding, signing for, owning or controlling an account is a relationship to it. It does not by itself mean authorising any payment from it, or being liable for one."
}

public nonisolated enum CaseMoneyBasis: String, Sendable, CaseIterable, Codable {
    case source, supplied, investigatorNote
    public var label: String {
        switch self {
        case .source: return "From a source in the case"
        case .supplied: return "Supplied — not checked against a source"
        case .investigatorNote: return "Investigator's note — not from a source"
        }
    }
}

// MARK: - Records

public nonisolated struct CaseMoneyAccount: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let identifier: String
    public let identifierKey: String
    public let institution: String?
    public let label: String?
    public let currency: String?
    public let sourceVersionID: UUID?
    public let quote: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    public var title: String { "Account \(identifier)" + (institution.map { " — \($0)" } ?? "") + (label.map { " (\($0))" } ?? "") }

    /// "#2210", "A/c 2210", "2210" → "2210"; the institution (lower-cased) keeps two banks' equal numbers apart.
    public static func key(_ identifier: String, institution: String?) -> String {
        var k = identifier.lowercased().replacingOccurrences(of: #"\b(a/c|acct\.?|account( no\.?| number)?)\b"#, with: "", options: .regularExpression)
        k = k.filter { $0.isLetter || $0.isNumber }
        let inst = (institution ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return inst.isEmpty ? k : "\(k)@\(inst)"
    }
}

public nonisolated struct CaseMoneyOwnership: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let accountID: UUID
    public let holderPersonID: UUID?
    public let holderName: String
    public let relation: CaseMoneyRelation
    public let share: String?
    public let via: String?
    public let validFrom: Date?
    public let validTo: Date?
    public let validText: String?
    public let basis: CaseMoneyBasis
    public let sourceVersionID: UUID?
    public let quote: String?
    public let suppliedBy: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    /// Whether the assertion holds on `day`: true inside its period, false outside it, nil when the period is not recorded.
    public func holds(on day: Date?) -> Bool? {
        guard let day, validFrom != nil || validTo != nil else { return nil }
        if let f = validFrom, day < f { return false }
        if let t = validTo, day > t { return false }
        return true
    }
    public var period: String {
        if validFrom == nil && validTo == nil { return validText.map { "“\($0)”" } ?? "period not recorded" }
        let f = { (d: Date?) in d.map { CaseMoneyLedger.day($0) } ?? "…" }
        return "\(f(validFrom)) – \(f(validTo))" + (validText.map { " (“\($0)”)" } ?? "")
    }
    public var line: String {
        var s = "\(relation.label): \(holderName)"
        if let share { s += " (\(share))" }
        if let via { s += " through \(via)" }
        s += " — \(period) — \(basis.label)"
        if basis == .supplied, let suppliedBy { s += " by \(suppliedBy)" }
        if let quote { s += ": “\(quote)”" }
        return s
    }
}

public nonisolated struct CaseMoneyStatement: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let accountID: UUID
    public let periodStart: String
    public let periodEnd: String
    public let opening: String?
    public let closing: String?
    public let currency: String
    public let sourceVersionID: UUID?
    public let sourceName: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    /// Copies of one statement (same account, period and currency) count as one (MONEY-11).
    public var periodKey: String { "\(accountID.uuidString.lowercased())|\(periodStart)|\(periodEnd)|\(currency)" }
}

public nonisolated struct CaseMoneyRecord: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let kind: CaseMoneyKind
    /// The amount exactly as written.
    public let amountText: String
    /// The exact value, nil when it could not be read without guessing.
    public let amount: Decimal?
    /// How the value was read ("as written", "2.5 lakh read as …", "written in words …").
    public let amountBasis: String
    /// ISO code, "$" (dollar, which one not stated) or "" (not stated).
    public let currency: String
    /// yyyy-MM-dd, when the day is known.
    public let date: String?
    public let dateText: String?
    public let reference: String?
    public let payerAccountID: UUID?
    public let payeeAccountID: UUID?
    public let payerName: String?
    public let payeeName: String?
    public let description: String?
    public let settlesRecordID: UUID?
    public let statementID: UUID?
    public let statementRow: Int?
    public let amendsRecordID: UUID?
    public let amendReason: String?
    public let sourceVersionID: UUID?
    public let blockID: UUID?
    public let quote: String?
    public let sourceName: String?
    public let disputedBy: String?
    public let disputedAt: Date?
    public let disputeNote: String?
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    public var isDisputed: Bool { disputedAt != nil }
    public var display: String {
        guard let amount else { return "\(amountText) (amount not readable)" }
        return "\(FAMoney.label(currency)) \(FAMoney.format(amount, currency: currency))"
    }
    /// Where it comes from, always stated.
    public var provenance: String {
        var parts: [String] = []
        if let s = sourceName { parts.append(s) } else if let v = sourceVersionID { parts.append("source version \(v.uuidString.prefix(8))") }
        if let r = statementRow { parts.append("statement row \(r)") }
        if let q = quote { parts.append("“\(q)”") }
        return parts.isEmpty ? "No source recorded (investigator's entry)" : parts.joined(separator: " — ")
    }
}

/// A person's recorded answer about two records that may be one payment (MONEY-04). Append-only; the latest for a pair counts.
public nonisolated struct CaseMoneyIdentityDecision: Identifiable, Sendable, Equatable, Hashable {
    public enum Decision: String, Sendable, CaseIterable, Codable { case sameTransaction, distinct }
    public let id: UUID
    public let recordA: UUID
    public let recordB: UUID
    public let decision: Decision
    public let reason: String
    public let decidedBy: String
    public let decidedAt: Date
}

/// A recorded exchange rate (MONEY-08): 1 unit of `from` = `rate` units of `to`, from a named source, on a date, by a method.
public nonisolated struct CaseMoneyConversion: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let from: String
    public let to: String
    public let rate: Decimal
    public let rateText: String
    public let rateDate: String
    public let rateSource: String
    public let method: String
    public let recordedBy: String
    public let recordedAt: Date
    public let withdrawnAt: Date?
    public var isActive: Bool { withdrawnAt == nil }
    public var line: String { "1 \(from) = \(rateText) \(to) (\(rateSource), \(rateDate), \(method))" }
}

/// A proposed request for missing financial material (MONEY-11): one per account and period, however often it is found.
public nonisolated struct CaseMoneyGapProposal: Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, CaseIterable, Codable { case missingStatement, uncoveredMovements, unreconciledStatement }
    public enum State: String, Sendable, CaseIterable, Codable { case proposed, accepted, dismissed }
    public let id: UUID
    public let key: String
    public let kind: Kind
    public let accountID: UUID?
    public let periodStart: String
    public let periodEnd: String
    public let deliverable: String
    public let reason: String
    public let state: State
    public let taskID: UUID?
    public let decidedBy: String?
    public let decidedAt: Date?
    public let decisionReason: String?
}

// MARK: - The ledger (pure)

/// One real payment and every record of it.
public nonisolated struct CaseMoneyTransaction: Identifiable, Sendable, Equatable, Hashable {
    public enum Basis: String, Sendable, Hashable {
        case single, reference, decision
        /// Records counted once although nothing tells whether they are one payment or several (a day or reference missing).
        case unresolved
        public var label: String {
            switch self {
            case .single: return "One record"
            case .reference: return "Same reference — one payment recorded in several places"
            case .decision: return "Recorded as one payment by a person"
            case .unresolved: return "Counted once, but it may be several payments (a day or reference is missing) — confirm or split it"
            }
        }
    }
    public var id: UUID { records[0].id }
    public let records: [CaseMoneyRecord]
    public let basis: Basis
    /// How many of its records joined it only as look-alikes (each could be a separate payment).
    public var uncertain = 0
    public var primary: CaseMoneyRecord { records[0] }
    public var kind: CaseMoneyKind { primary.kind }
    public var amount: Decimal { primary.amount?.magnitude ?? 0 }
    public var currency: String { primary.currency }
    /// The earliest known day of any of its records.
    public var date: String? { records.compactMap(\.date).min() }
    public var recordIDs: [UUID] { records.map(\.id) }
}

/// A figure and the records it is made of.
public nonisolated struct CaseMoneyFigure: Sendable, Equatable, Hashable {
    public var amount = Decimal(0)
    public var records: [UUID] = []
    public var transactions = 0
    mutating func add(_ t: CaseMoneyTransaction) { amount += t.amount; records += t.recordIDs; transactions += 1 }
    mutating func add(_ r: CaseMoneyRecord, _ v: Decimal) { amount += v; records.append(r.id); transactions += 1 }
}

/// MONEY-05 — the separate outcomes in one currency.
public nonisolated struct CaseMoneyOutcome: Sendable, Equatable {
    public let currency: String
    public var grossPaid = CaseMoneyFigure()
    public var received = CaseMoneyFigure()
    public var returned = CaseMoneyFigure()
    public var fees = CaseMoneyFigure()
    public var onward = CaseMoneyFigure()
    public var internalTransfers = CaseMoneyFigure()
    public var outstanding = CaseMoneyFigure()
    public var disputed = CaseMoneyFigure()
    /// gross paid + fees − returned.
    public var netOutflow: Decimal { grossPaid.amount + fees.amount - returned.amount }
    /// What a total would add if every unresolved candidate turned out to be separate payments.
    public var ifCandidatesSeparate = Decimal(0)
    public static let netLabel = "Net outflow (gross paid + fees − returned). It is arithmetic, not a finding that anything was lost."
}

/// MONEY-07 — one statement against the case's records.
public nonisolated struct CaseMoneyStatementCheck: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable { case reconciled, difference, partial }
    public var id: UUID { statementID }
    public let statementID: UUID
    public let accountID: UUID
    public let periodStart: String
    public let periodEnd: String
    public let currency: String
    public let opening: Decimal?
    public let expectedClosing: Decimal?
    public let stated: Decimal?
    /// The statement's own rows.
    public let rows: [UUID]
    /// Records of the account in the period that are on the statement (another record of the same payment as a row).
    public let matched: [UUID]
    /// Records of the account in the period that are NOT on the statement.
    public let notOnStatement: [UUID]
    public let unresolved: [String]
    public var difference: Decimal? { unresolved.isEmpty ? expectedClosing.flatMap { e in stated.map { $0 - e } } : nil }
    public var state: State {
        if !unresolved.isEmpty || !notOnStatement.isEmpty || difference == nil { return .partial }
        return difference == 0 ? .reconciled : .difference
    }
    public var label: String {
        switch state {
        case .reconciled: return "Reconciles: opening + money in − money out equals the stated closing balance, and every record of the account in the period is on the statement."
        case .difference: return "Does not reconcile: \(FAMoney.format(difference ?? 0, currency: currency)) unexplained. A difference is a gap in the records or the statement — not, by itself, a loss."
        case .partial: return "Not reconciled — partial: " + (unresolved + (notOnStatement.isEmpty ? [] : ["\(notOnStatement.count) record(s) of the account in this period are not on the statement"])).joined(separator: "; ")
        }
    }
}

public nonisolated struct CaseMoneyConvertedTotal: Sendable, Equatable {
    public struct Part: Sendable, Equatable { public let currency: String; public let original: Decimal; public let converted: Decimal; public let conversion: CaseMoneyConversion }
    public let target: String
    public let figure: String
    public let parts: [Part]
    /// Currencies with no recorded rate to the target (left out, so the converted total is partial).
    public let notConverted: [String]
    public var total: Decimal { parts.reduce(Decimal(0)) { $0 + $1.converted } }
    public var isPartial: Bool { !notConverted.isEmpty }
    public var label: String {
        var s = "\(figure) converted to \(target): \(FAMoney.format(total, currency: target))"
        s += parts.isEmpty ? "" : " — " + parts.map { "\(FAMoney.label($0.currency)) \(FAMoney.format($0.original, currency: $0.currency)) at \($0.conversion.line)" }.joined(separator: "; ")
        if isPartial { s += ". Partial: no rate recorded for \(notConverted.map(FAMoney.label).joined(separator: ", ")), left out." }
        return s + " The original-currency figures stay the record; this is a conversion beside them."
    }
}

public nonisolated struct CaseMoneyLedger: Sendable, Equatable {
    public var caseID: UUID
    public var accounts: [CaseMoneyAccount] = []
    public var ownership: [CaseMoneyOwnership] = []
    public var statements: [CaseMoneyStatement] = []
    public var records: [CaseMoneyRecord] = []
    public var decisions: [CaseMoneyIdentityDecision] = []
    public var conversions: [CaseMoneyConversion] = []
    public var proposals: [CaseMoneyGapProposal] = []
    public init(caseID: UUID) { self.caseID = caseID }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }
    static func date(_ s: String) -> Date? { dayFormatter.date(from: s) }

    public func account(_ id: UUID?) -> CaseMoneyAccount? { id.flatMap { i in accounts.first { $0.id == i } } }
    public func record(_ id: UUID) -> CaseMoneyRecord? { records.first { $0.id == id } }

    /// Records replaced by an active amendment (kept, inspectable, not counted).
    public var amended: Set<UUID> { Set(records.filter(\.isActive).compactMap(\.amendsRecordID)) }
    /// Active records that are not replaced by an amendment.
    public var current: [CaseMoneyRecord] {
        let replaced = amended
        return records.filter { $0.isActive && !replaced.contains($0.id) }
    }
    public var unclassified: [CaseMoneyRecord] { current.filter { $0.kind == .unclassified } }
    public var mentions: [CaseMoneyRecord] { current.filter { !$0.kind.isMovement && $0.kind != .unclassified } }
    public var unreadable: [CaseMoneyRecord] { current.filter { $0.kind.isMovement && $0.amount == nil } }
    public var currencyUnstated: [CaseMoneyRecord] { current.filter { $0.kind.isMovement && ($0.currency.isEmpty || $0.currency == FAMoney.ambiguousDollar) } }

    // MARK: MONEY-06 parties

    /// Whose money an account is on `day`: its recorded holders (person id, else name), else the account itself.
    public func partyKeys(account id: UUID?, name: String?, on day: String?) -> (keys: Set<String>, basis: String) {
        if let id, let acct = account(id) {
            let d = day.flatMap(Self.date)
            let holders = ownership.filter { $0.isActive && $0.accountID == id && $0.relation.definesParty && $0.holds(on: d) != false }
            if !holders.isEmpty {
                return (Set(holders.map { h in h.holderPersonID.map { "person:\($0.uuidString.lowercased())" } ?? "name:\(Self.norm(h.holderName))" }),
                        "the recorded holder(s) of \(acct.title)")
            }
            return (["account:\(id.uuidString.lowercased())"], "\(acct.title) (no holder recorded)")
        }
        guard let name, !Self.norm(name).isEmpty else { return ([], "no party recorded") }
        return (["name:\(Self.norm(name))"], "the written name only (no account recorded)")
    }
    static func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }
    static func normRef(_ s: String?) -> String? {
        guard let s else { return nil }
        let r = s.uppercased().replacingOccurrences(of: #"^(UTR|REF|REFERENCE|CHQ|CHEQUE|NO)\b[.:#\s]*"#, with: "", options: .regularExpression).filter { $0.isLetter || $0.isNumber }
        return r.isEmpty ? nil : r
    }

    // MARK: MONEY-04 identity

    enum PairRule: Equatable { case same(CaseMoneyTransaction.Basis), distinct, candidate }

    func latestDecision(_ a: UUID, _ b: UUID) -> CaseMoneyIdentityDecision? {
        decisions.filter { ($0.recordA == a && $0.recordB == b) || ($0.recordA == b && $0.recordB == a) }.max { ($0.decidedAt, $0.id.uuidString) < ($1.decidedAt, $1.id.uuidString) }
    }

    func rule(_ a: CaseMoneyRecord, _ b: CaseMoneyRecord) -> PairRule {
        if let d = latestDecision(a.id, b.id) { return d.decision == .sameTransaction ? .same(.decision) : .distinct }
        let ra = Self.normRef(a.reference), rb = Self.normRef(b.reference)
        if let ra, let rb { return ra == rb ? .same(.reference) : .distinct }
        if let da = a.date, let db = b.date, da != db { return .distinct }
        // Two rows of one document (or of one statement) are two entries of it, not copies of each other.
        if let sa = a.statementID, sa == b.statementID { return .distinct }
        if let va = a.sourceVersionID, va == b.sourceVersionID, a.blockID != b.blockID || a.blockID == nil { return .distinct }
        return .candidate
    }

    /// Movements grouped into transactions; the candidate pairs no rule or person has settled.
    public func transactions() -> (transactions: [CaseMoneyTransaction], candidates: [(UUID, UUID)]) {
        let movements = current.filter { $0.kind.isMovement && $0.amount != nil }
        struct Key: Hashable { let kind: String; let currency: String; let amount: Decimal; let payer: Set<String>; let payee: Set<String> }
        func key(_ r: CaseMoneyRecord) -> Key {
            Key(kind: r.kind.rawValue, currency: r.currency, amount: r.amount?.magnitude ?? 0,
                payer: partyKeys(account: r.payerAccountID, name: r.payerName, on: r.date).keys,
                payee: partyKeys(account: r.payeeAccountID, name: r.payeeName, on: r.date).keys)
        }
        var out: [CaseMoneyTransaction] = []
        var candidates: [(UUID, UUID)] = []
        let buckets = Dictionary(grouping: movements, by: key)
        for (_, rs) in buckets {
            let ordered = rs.sorted { ($0.date ?? "~", $0.recordedAt, $0.id.uuidString) < ($1.date ?? "~", $1.recordedAt, $1.id.uuidString) }
            var groups: [(records: [CaseMoneyRecord], basis: CaseMoneyTransaction.Basis, uncertain: Int)] = []
            for r in ordered {
                // Join the first group every member of which this record may be (never one it is distinct from).
                var joined = false
                for i in groups.indices {
                    let rules = groups[i].records.map { rule($0, r) }
                    if rules.contains(.distinct) { continue }
                    let decided = rules.compactMap { if case .same(let b) = $0 { return b } else { return nil } }
                    if decided.isEmpty {
                        // Only look-alike to every member: counted once, flagged, and it could be one more payment.
                        candidates.append((groups[i].records[0].id, r.id))
                        groups[i].records.append(r); groups[i].basis = .unresolved; groups[i].uncertain += 1
                    } else {
                        // The same payment as a member (by reference or a decision): any remaining doubt is about another member.
                        groups[i].records.append(r)
                        if groups[i].basis == .single { groups[i].basis = decided.contains(.decision) ? .decision : .reference }
                    }
                    joined = true
                    break
                }
                if !joined { groups.append(([r], .single, 0)) }
            }
            out += groups.map { var t = CaseMoneyTransaction(records: $0.records, basis: $0.uncertain > 0 ? .unresolved : $0.basis); t.uncertain = $0.uncertain; return t }
        }
        out.sort { ($0.date ?? "~", $0.currency, $0.primary.recordedAt, $0.id.uuidString) < ($1.date ?? "~", $1.currency, $1.primary.recordedAt, $1.id.uuidString) }
        return (out, candidates.sorted { ($0.0.uuidString, $0.1.uuidString) < ($1.0.uuidString, $1.1.uuidString) })
    }

    // MARK: MONEY-05 / MONEY-06 outcomes

    /// The separate outcomes per currency, and warnings (a transfer between different holders, parties matched by name only).
    public func outcomes() -> (byCurrency: [String: CaseMoneyOutcome], warnings: [String]) {
        let (txs, _) = transactions()
        var out: [String: CaseMoneyOutcome] = [:]
        var warnings: [String] = []
        // Who received a payment, and when (per currency), for onward hops.
        var receivedAt: [String: [String]] = [:]
        for t in txs where t.kind == .payment || t.kind == .fee {
            for k in partyKeys(account: t.primary.payeeAccountID, name: t.primary.payeeName, on: t.date).keys { receivedAt["\(t.currency)|\(k)", default: []].append(t.date ?? "") }
        }
        var nameOnly = 0
        for t in txs {
            var o = out[t.currency] ?? CaseMoneyOutcome(currency: t.currency)
            let payer = partyKeys(account: t.primary.payerAccountID, name: t.primary.payerName, on: t.date)
            let payee = partyKeys(account: t.primary.payeeAccountID, name: t.primary.payeeName, on: t.date)
            if payer.basis.hasPrefix("the written name") || payee.basis.hasPrefix("the written name") { nameOnly += 1 }
            if t.uncertain > 0 { o.ifCandidatesSeparate += t.amount * Decimal(t.uncertain) }
            switch t.kind {
            case .transfer:
                o.internalTransfers.add(t)
                if !payer.keys.isEmpty, !payee.keys.isEmpty, payer.keys.isDisjoint(with: payee.keys), !payer.basis.hasSuffix("(no holder recorded)") {
                    warnings.append("\(t.primary.display) on \(t.date ?? "an unknown day") is classified as a transfer between own accounts, but the accounts' recorded holders differ — check the classification.")
                }
            case .payment, .fee:
                let d = t.date ?? ""
                let onwardHop = !payer.keys.isEmpty && payer.keys.isDisjoint(with: payee.keys) && payer.keys.contains { k in
                    (receivedAt["\(t.currency)|\(k)"] ?? []).contains { $0.isEmpty || d.isEmpty ? ($0.isEmpty && d.isEmpty) : $0 < d }
                }
                if onwardHop { o.onward.add(t) } else if t.kind == .fee { o.fees.add(t) } else { o.grossPaid.add(t) }
            case .receipt: o.received.add(t)
            case .refund, .reversal: o.returned.add(t)
            default: break
            }
            out[t.currency] = o
        }
        // Outstanding: an invoice or claim less the movements recorded as settling it (same currency).
        var settling: [UUID: [CaseMoneyTransaction]] = [:]
        for t in txs { if let target = t.records.compactMap(\.settlesRecordID).first { settling[target, default: []].append(t) } }
        for r in current where r.kind.isReceivable {
            guard let v = r.amount?.magnitude else { continue }
            let paid = (settling[r.id] ?? []).filter { $0.currency == r.currency }.reduce(Decimal(0)) { $0 + $1.amount }
            if (settling[r.id] ?? []).contains(where: { $0.currency != r.currency }) {
                warnings.append("\(r.display) is settled in part in another currency; that part is not subtracted (no conversion is applied).")
            }
            if v - paid > 0 {
                var o = out[r.currency] ?? CaseMoneyOutcome(currency: r.currency)
                o.outstanding.add(r, v - paid)
                out[r.currency] = o
            }
        }
        // Disputed: every disputed record, whatever its kind.
        for r in current where r.isDisputed {
            guard let v = r.amount?.magnitude else { continue }
            var o = out[r.currency] ?? CaseMoneyOutcome(currency: r.currency)
            o.disputed.add(r, v)
            out[r.currency] = o
        }
        if nameOnly > 0 { warnings.append("\(nameOnly) payment(s) are matched to their parties by the written name only (no account recorded); same name is not the same party.") }
        return (out, warnings)
    }

    /// Every record a figure rests on, with where each comes from (MONEY-05/10 drill-down).
    public func drill(_ figure: CaseMoneyFigure) -> [CaseMoneyRecord] { figure.records.compactMap(record) }

    // MARK: MONEY-07 statements

    public func check(_ st: CaseMoneyStatement) -> CaseMoneyStatementCheck {
        let (txs, _) = transactions()
        var unresolved: [String] = []
        let opening = st.opening.flatMap { FAMoney.read($0)?.value }
        let stated = st.closing.flatMap { FAMoney.read($0)?.value }
        if opening == nil { unresolved.append("the opening balance is not recorded or cannot be read") }
        if stated == nil { unresolved.append("the closing balance is not recorded or cannot be read") }
        if st.currency.isEmpty || st.currency == FAMoney.ambiguousDollar { unresolved.append("the statement's currency is not stated") }
        let rows = current.filter { $0.statementID == st.id }.map(\.id)
        var bal = opening ?? 0
        var matched: [UUID] = [], notOn: [UUID] = []
        var undated = 0, otherCurrency = 0
        for t in txs {
            let outOf = t.records.contains { $0.payerAccountID == st.accountID }, into = t.records.contains { $0.payeeAccountID == st.accountID }
            guard outOf || into else { continue }
            guard let d = t.date else { undated += 1; continue }
            guard d >= st.periodStart, d <= st.periodEnd else { continue }
            guard t.currency == st.currency else { otherCurrency += 1; continue }
            if t.kind != .transfer || outOf != into { bal += into ? t.amount : -t.amount }
            let onIt = t.records.contains { $0.statementID == st.id }
            for r in t.records where r.statementID != st.id { if onIt { matched.append(r.id) } else { notOn.append(r.id) } }
        }
        if undated > 0 { unresolved.append("\(undated) movement(s) of the account have no day and cannot be placed in a period") }
        if otherCurrency > 0 { unresolved.append("\(otherCurrency) movement(s) of the account in this period are in another currency") }
        return CaseMoneyStatementCheck(statementID: st.id, accountID: st.accountID, periodStart: st.periodStart, periodEnd: st.periodEnd, currency: st.currency,
                                       opening: opening, expectedClosing: opening == nil ? nil : bal, stated: stated, rows: rows,
                                       matched: matched, notOnStatement: notOn, unresolved: unresolved)
    }

    /// Statements counted once per account, period and currency (a copy of a statement is not a second statement).
    public var distinctStatements: [CaseMoneyStatement] {
        var seen = Set<String>()
        return statements.filter(\.isActive).sorted { ($0.periodStart, $0.recordedAt) < ($1.periodStart, $1.recordedAt) }.filter { seen.insert($0.periodKey).inserted }
    }

    /// Gaps between one account's statements.
    public func missingPeriods() -> [(account: UUID, start: String, end: String)] {
        var out: [(UUID, String, String)] = []
        let cal = Calendar(identifier: .gregorian)
        for (acct, sts) in Dictionary(grouping: distinctStatements, by: \.accountID) {
            let sorted = sts.sorted { $0.periodStart < $1.periodStart }
            var coveredTo: String? = nil
            for s in sorted {
                if let c = coveredTo, let end = Self.date(c), let next = cal.date(byAdding: .day, value: 1, to: end), let start = Self.date(s.periodStart),
                   next < start, let last = cal.date(byAdding: .day, value: -1, to: start) {
                    out.append((acct, Self.day(next), Self.day(last)))
                }
                coveredTo = max(coveredTo ?? s.periodEnd, s.periodEnd)
            }
        }
        return out.sorted { ($0.0.uuidString, $0.1) < ($1.0.uuidString, $1.1) }
    }

    /// Dated movements of an account that no statement of that account covers, by account and month.
    public func uncoveredMovements() -> [(account: UUID, month: String, records: [UUID])] {
        var out: [String: (UUID, String, [UUID])] = [:]
        let sts = distinctStatements
        for r in current where r.kind.isMovement && r.statementID == nil {
            guard let d = r.date else { continue }
            for acct in [r.payerAccountID, r.payeeAccountID].compactMap({ $0 }) where account(acct) != nil {
                let covered = sts.contains { $0.accountID == acct && d >= $0.periodStart && d <= $0.periodEnd }
                guard !covered else { continue }
                let month = String(d.prefix(7))
                out["\(acct)|\(month)", default: (acct, month, [])].2.append(r.id)
            }
        }
        return out.values.map { ($0.0, $0.1, $0.2) }.sorted { ($0.0.uuidString, $0.1) < ($1.0.uuidString, $1.1) }
    }

    // MARK: MONEY-11 proposals (derived; the repository stores each key once)

    public struct ProposedGap: Sendable, Equatable { public let key: String; public let kind: CaseMoneyGapProposal.Kind; public let account: UUID?; public let start: String; public let end: String; public let deliverable: String; public let reason: String }

    public func proposedGaps() -> [ProposedGap] {
        var out: [ProposedGap] = []
        let name = { (id: UUID) in self.account(id)?.title ?? "the account" }
        for g in missingPeriods() {
            out.append(ProposedGap(key: "missing|\(g.account.uuidString.lowercased())|\(g.start)|\(g.end)", kind: .missingStatement, account: g.account, start: g.start, end: g.end,
                                   deliverable: "The statement of \(name(g.account)) for \(g.start) – \(g.end): opening and closing balance and every entry.",
                                   reason: "The case has statements before and after this period but none for it."))
        }
        for u in uncoveredMovements() {
            let (start, end) = Self.monthBounds(u.month)
            out.append(ProposedGap(key: "uncovered|\(u.account.uuidString.lowercased())|\(u.month)", kind: .uncoveredMovements, account: u.account, start: start, end: end,
                                   deliverable: "The statement of \(name(u.account)) covering \(u.month), to check \(u.records.count) recorded movement(s) against it.",
                                   reason: "\(u.records.count) movement(s) of this account in \(u.month) are recorded, but no statement covers that month."))
        }
        for st in distinctStatements {
            let c = check(st)
            guard c.state == .difference || !c.notOnStatement.isEmpty else { continue }
            out.append(ProposedGap(key: "unreconciled|\(st.periodKey)", kind: .unreconciledStatement, account: st.accountID, start: st.periodStart, end: st.periodEnd,
                                   deliverable: "An explanation, with supporting records, of why \(name(st.accountID)) does not reconcile for \(st.periodStart) – \(st.periodEnd).",
                                   reason: c.label))
        }
        return out
    }

    static func monthBounds(_ month: String) -> (String, String) {
        guard let start = date(month + "-01"), let next = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: start),
              let last = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: next) else { return (month, month) }
        return (day(start), day(last))
    }

    // MARK: MONEY-08 conversion

    /// One figure in every currency it has, converted to `target` only through recorded rates.
    public func converted(_ pick: (CaseMoneyOutcome) -> Decimal, figure: String, to target: String) -> CaseMoneyConvertedTotal {
        let (byCurrency, _) = outcomes()
        var parts: [CaseMoneyConvertedTotal.Part] = []
        var missing: [String] = []
        for (cur, o) in byCurrency.sorted(by: { $0.key < $1.key }) {
            let v = pick(o)
            guard v != 0 else { continue }
            if cur == target {
                parts.append(.init(currency: cur, original: v, converted: v, conversion: CaseMoneyConversion(id: UUID(), from: cur, to: cur, rate: 1, rateText: "1",
                    rateDate: "—", rateSource: "same currency", method: "no conversion", recordedBy: "", recordedAt: .distantPast, withdrawnAt: nil)))
            } else if let c = conversions.filter({ $0.isActive && $0.from == cur && $0.to == target }).max(by: { $0.recordedAt < $1.recordedAt }) {
                parts.append(.init(currency: cur, original: v, converted: v * c.rate, conversion: c))
            } else {
                missing.append(cur)
            }
        }
        return CaseMoneyConvertedTotal(target: target, figure: figure, parts: parts, notConverted: missing)
    }

    // MARK: MONEY-01 views

    /// The accounts a case person holds or controls (as recorded), and every record moving money in or out of them.
    public func forPerson(_ personID: UUID) -> (accounts: [CaseMoneyAccount], relations: [CaseMoneyOwnership], records: [CaseMoneyRecord]) {
        let rel = ownership.filter { $0.isActive && $0.holderPersonID == personID }
        let ids = Set(rel.map(\.accountID))
        return (accounts.filter { ids.contains($0.id) }, rel,
                current.filter { r in [r.payerAccountID, r.payeeAccountID].contains { $0.map(ids.contains) ?? false } })
    }

    /// Dated records in day order (the time view).
    public var timeline: [CaseMoneyRecord] { current.filter { $0.date != nil }.sorted { ($0.date ?? "", $0.recordedAt) < ($1.date ?? "", $1.recordedAt) } }

    // MARK: MONEY-12 the same figures on every surface

    /// The case's movements as forensic schedule rows (one per TRANSACTION, every occurrence named), so the studio's own
    /// arithmetic gives the same figures.
    public func scheduleRows() -> [FATransaction] {
        transactions().transactions.map { t in
            var row = FATransaction()
            row.date = t.date ?? ""
            row.descriptionText = t.primary.description ?? t.kind.label
            row.payer = account(t.primary.payerAccountID)?.title ?? (t.primary.payerName ?? "")
            row.payee = account(t.primary.payeeAccountID)?.title ?? (t.primary.payeeName ?? "")
            row.amount = t.primary.amountText
            row.currency = t.currency
            row.kind = t.kind.faKind
            row.reference = t.primary.reference
            row.account = account(t.primary.payerAccountID)?.identifier ?? account(t.primary.payeeAccountID)?.identifier ?? ""
            row.sourceDoc = t.records.map(\.provenance).joined(separator: "; ")
            row.confirmedDistinct = true      // identity was settled here; the schedule must not merge them again
            if let v = t.primary.amount { row.amount = FAMoney.format(v.magnitude, currency: t.currency) }
            return row
        }
    }
}

// MARK: - Report text (the report and the exported package use this one text)

public nonisolated enum CaseMoneyReport {
    public static func markdown(_ l: CaseMoneyLedger) -> String {
        var out = "## Money\n\n"
        let (byCurrency, warnings) = l.outcomes()
        let (txs, candidates) = l.transactions()
        if byCurrency.isEmpty { out += "_No classified money movement is recorded in this case._\n" }
        for (cur, o) in byCurrency.sorted(by: { $0.key < $1.key }) {
            let m = { (d: Decimal) in "\(FAMoney.label(cur)) \(FAMoney.format(d, currency: cur))" }
            out += "### \(FAMoney.label(cur))\n\n"
            out += "| Figure | Amount | Records |\n|---|---|---|\n"
            for (name, f) in [("Gross paid", o.grossPaid), ("Received", o.received), ("Returned (refunds, reversals)", o.returned), ("Fees", o.fees),
                              ("Outstanding (invoices and claims not settled)", o.outstanding), ("Disputed", o.disputed),
                              ("Onward hops (already in gross, not added)", o.onward), ("Transfers between own accounts (not added)", o.internalTransfers)] {
                out += "| \(name) | \(m(f.amount)) | \(f.transactions) |\n"
            }
            out += "\n**\(CaseMoneyOutcome.netLabel)** \(m(o.netOutflow))\n"
            if o.ifCandidatesSeparate != 0 { out += "\n_If the unresolved look-alike records are separate payments, the figures above are low by \(m(o.ifCandidatesSeparate)) in total._\n" }
            out += "\n"
        }
        if byCurrency.count > 1 { out += "_Each currency is totalled on its own; nothing is converted unless a conversion with its rate is shown below._\n\n" }
        for c in l.conversions where c.isActive { out += "- Recorded rate: \(c.line)\n" }
        out += "\n### Transactions\n\n| Day | Kind | Amount | Reference | Identity | Records |\n|---|---|---|---|---|---|\n"
        for t in txs {
            out += "| \(t.date ?? "—") | \(t.kind.label) | \(t.primary.display) | \(t.primary.reference ?? "—") | \(t.basis.label) | \(t.records.map(\.provenance).joined(separator: "; ")) |\n"
        }
        if !candidates.isEmpty { out += "\n_\(candidates.count) pair(s) of records may be one payment or two; they are counted once until a person confirms or splits them._\n" }
        if !l.unclassified.isEmpty { out += "\n_Not in any figure — amounts not yet classified: \(l.unclassified.count)._\n" }
        if !l.mentions.isEmpty { out += "_Not movements (invoices, claims, balances, allegations, estimates, assets): \(l.mentions.count) — listed, never added to paid or lost._\n" }
        if !l.amended.isEmpty { out += "_Replaced by an amendment (kept, not counted): \(l.amended.count)._\n" }
        for w in warnings { out += "\n- \(w)" }
        for st in l.distinctStatements {
            out += "\n\n**Statement \(l.account(st.accountID)?.title ?? "") \(st.periodStart) – \(st.periodEnd):** \(l.check(st).label)"
        }
        for g in l.missingPeriods() { out += "\n\n**No statement:** \(l.account(g.account)?.title ?? "account") \(g.start) – \(g.end)." }
        return out + "\n"
    }
}

// MARK: - Statement rows (MONEY-07 import)

/// One row of a statement table, as written.
public nonisolated struct CaseMoneyStatementRow: Sendable, Equatable {
    public let row: Int
    public let date: String?
    public let dateText: String
    public let description: String
    public let reference: String?
    public let debit: String?
    public let credit: String?
}

/// Reads the rows of a statement written as a table (Markdown pipes, or comma/tab separated) whose header names a date and a
/// debit/credit (or withdrawal/deposit) column. Only ISO days (yyyy-MM-dd) become days; any other date stays as written.
public nonisolated enum CaseMoneyStatementParser {
    public static func rows(_ text: String) -> [CaseMoneyStatementRow] {
        var header: [String]? = nil
        var out: [CaseMoneyStatementRow] = []
        var n = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let cells: [String]
            if line.hasPrefix("|") {
                cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.contains("\t") {
                cells = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.contains(",") {
                cells = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else { continue }
            let lower = cells.map { $0.lowercased() }
            if header == nil {
                if lower.contains(where: { $0.contains("date") }) && lower.contains(where: { ["debit", "credit", "withdrawal", "deposit", "withdrawals", "deposits"].contains($0) }) {
                    header = lower
                }
                continue
            }
            guard let h = header, cells.count == h.count, !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) else { continue }
            func col(_ names: [String]) -> String? {
                guard let i = h.firstIndex(where: { c in names.contains { c.contains($0) } }) else { return nil }
                let v = cells[i]; return v.isEmpty ? nil : v
            }
            let dateText = col(["date"]) ?? ""
            n += 1
            let iso = dateText.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? dateText : nil
            out.append(CaseMoneyStatementRow(row: n, date: iso, dateText: dateText, description: col(["description", "narration", "particulars", "details"]) ?? "",
                                             reference: col(["reference", "ref", "utr", "cheque"]), debit: col(["debit", "withdrawal"]), credit: col(["credit", "deposit"])))
        }
        return out
    }
}

// MARK: - Errors

public nonisolated enum CaseMoneyError: Error, Equatable, LocalizedError {
    case notFound(String)
    case duplicateAccount(UUID)
    case badPeriod
    case alreadyClassified
    case notUnclassified
    case notAMovement
    case sameRecord
    case badRate
    case alreadyDecided
    case alreadyDisputed
    case rowHasNoAmount(Int)
    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "The \(what) was not found in this case."
        case .duplicateAccount: return "That account is already recorded in this case."
        case .badPeriod: return "The period ends before it starts."
        case .alreadyClassified: return "This amount is already classified. Record an amendment to change what it is (the original stays)."
        case .notUnclassified: return "Choose a kind for the amount."
        case .notAMovement: return "Only movements of money can be the same payment or settle an invoice."
        case .sameRecord: return "Choose two different records."
        case .badRate: return "A rate must be one exact positive figure."
        case .alreadyDecided: return "That proposal was already decided."
        case .alreadyDisputed: return "That record is already marked disputed."
        case .rowHasNoAmount(let n): return "Row \(n) has neither a debit nor a credit."
        }
    }
}

/// What a new money record says.
public nonisolated struct CaseMoneyRecordInput: Sendable {
    public var kind: CaseMoneyKind = .unclassified
    public var amountText: String
    public var currency: String? = nil
    public var date: String? = nil
    public var dateText: String? = nil
    public var reference: String? = nil
    public var payerAccountID: UUID? = nil
    public var payeeAccountID: UUID? = nil
    public var payerName: String? = nil
    public var payeeName: String? = nil
    public var description: String? = nil
    public var settlesRecordID: UUID? = nil
    public var sourceVersionID: UUID? = nil
    public var blockID: UUID? = nil
    public var quote: String? = nil
    public var sourceName: String? = nil
    public init(kind: CaseMoneyKind = .unclassified, amountText: String) { self.kind = kind; self.amountText = amountText }
}

// MARK: - Repository

extension CaseFileRepository {

    static func moneyRowInCase(_ db: isolated Database, table: String, _ id: UUID?, caseID: UUID, what: String) throws {
        guard let id else { return }
        guard try !db.query("SELECT 1 FROM \(table) WHERE case_id = ? AND id = ? AND withdrawn_at IS NULL;", [.uuid(caseID), .uuid(id)]).isEmpty else {
            throw CaseMoneyError.notFound(what)
        }
    }

    // MARK: MONEY-01 accounts and statements

    @discardableResult
    public func addMoneyAccount(caseID: UUID, identifier: String, institution: String? = nil, label: String? = nil, currency: String? = nil,
                                sourceVersionID: UUID? = nil, quote: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), ident = try Self.clean(identifier, "The account identifier")
        let inst = Self.blankToNil(institution)
        let key = CaseMoneyAccount.key(ident, institution: inst)
        guard !key.isEmpty else { throw CaseFileError.blank("The account identifier") }
        let id = UUID()
        try await write("cf_macct", caseID: caseID, actor: who, action: "moneyAccountRecorded", detail: ident, at: date) { db in
            if let s = sourceVersionID, !(try Self.versionInCase(db, s, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            if let existing = try db.query("SELECT id FROM case_money_accounts WHERE case_id = ? AND identifier_key = ? AND withdrawn_at IS NULL;",
                                           [.uuid(caseID), .text(key)]).first?.uuid(0) { throw CaseMoneyError.duplicateAccount(existing) }
            try db.exec("""
                INSERT INTO case_money_accounts (id, case_id, identifier, identifier_key, institution, label, currency, source_version_id, quote, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(ident), .text(key), .optionalText(inst), .optionalText(Self.blankToNil(label)),
                      .optionalText(Self.blankToNil(currency)?.uppercased()), sourceVersionID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(quote)),
                      .text(who), .date(date)])
        }
        return id
    }

    @discardableResult
    public func recordAccountRelation(caseID: UUID, accountID: UUID, holderPersonID: UUID? = nil, holderName: String, relation: CaseMoneyRelation,
                                      share: String? = nil, via: String? = nil, validFrom: Date? = nil, validTo: Date? = nil, validText: String? = nil,
                                      basis: CaseMoneyBasis, sourceVersionID: UUID? = nil, quote: String? = nil, suppliedBy: String? = nil,
                                      actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), name = try Self.clean(holderName, "The holder's name")
        if basis == .source, sourceVersionID == nil { throw CaseWorkError.sourceNotInCase }
        if basis == .supplied, Self.blankToNil(suppliedBy) == nil { throw CaseFileError.blank("Who supplied it") }
        if let a = validFrom, let b = validTo, b < a { throw CaseMoneyError.badPeriod }
        let id = UUID()
        try await write("cf_mown", caseID: caseID, actor: who, action: "accountRelationRecorded", detail: "\(relation.rawValue): \(name)", at: date) { db in
            try Self.moneyRowInCase(db, table: "case_money_accounts", accountID, caseID: caseID, what: "account")
            if let p = holderPersonID { try Self.requirePerson(db, p, caseID: caseID) }
            if let s = sourceVersionID, !(try Self.versionInCase(db, s, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_money_ownership (id, case_id, account_id, holder_person_id, holder_name, relation, share_text, via_text, valid_from, valid_to,
                    valid_text, basis, source_version_id, quote, supplied_by, recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(accountID), .optionalText(holderPersonID?.uuidString.lowercased()), .text(name), .text(relation.rawValue),
                      .optionalText(Self.blankToNil(share)), .optionalText(Self.blankToNil(via)), .optionalDate(validFrom), .optionalDate(validTo),
                      .optionalText(Self.blankToNil(validText)), .text(basis.rawValue), sourceVersionID.map { .uuid($0) } ?? .null,
                      .optionalText(Self.blankToNil(quote)), .optionalText(Self.blankToNil(suppliedBy)), .text(who), .date(date)])
        }
        return id
    }

    public func withdrawAccountRelation(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        try await withdrawMoneyRow(table: "case_money_ownership", what: "account relation", caseID: caseID, id: id, reason: reason, actor: actor, at: date)
    }

    func withdrawMoneyRow(table: String, what: String, caseID: UUID, id: UUID, reason: String, actor: String, at date: Date) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_mwd", caseID: caseID, actor: who, action: "moneyRecordWithdrawn", detail: "\(what): \(why)", at: date) { db in
            guard let r = try db.query("SELECT withdrawn_at FROM \(table) WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else { throw CaseMoneyError.notFound(what) }
            guard r.isNull(0) else { throw CasePeopleError.alreadyEnded }
            try db.exec("UPDATE \(table) SET withdrawn_by = ?, withdrawn_at = ?, withdrawn_reason = ? WHERE id = ?;", [.text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    @discardableResult
    public func addMoneyStatement(caseID: UUID, accountID: UUID, periodStart: String, periodEnd: String, opening: String?, closing: String?,
                                  currency: String, sourceVersionID: UUID? = nil, sourceName: String? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor")
        guard CaseMoneyLedger.date(periodStart) != nil, CaseMoneyLedger.date(periodEnd) != nil else { throw CaseMoneyError.badPeriod }
        guard periodEnd >= periodStart else { throw CaseMoneyError.badPeriod }
        let id = UUID()
        try await write("cf_mstmt", caseID: caseID, actor: who, action: "moneyStatementRecorded", detail: "\(periodStart) – \(periodEnd)", at: date) { db in
            try Self.moneyRowInCase(db, table: "case_money_accounts", accountID, caseID: caseID, what: "account")
            if let s = sourceVersionID, !(try Self.versionInCase(db, s, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_money_statements (id, case_id, account_id, period_start, period_end, opening_text, closing_text, currency, source_version_id, source_name,
                    recorded_by, recorded_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(accountID), .text(periodStart), .text(periodEnd), .optionalText(Self.blankToNil(opening)),
                      .optionalText(Self.blankToNil(closing)), .text(currency.trimmingCharacters(in: .whitespaces).uppercased()),
                      sourceVersionID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(sourceName)), .text(who), .date(date)])
        }
        return id
    }

    // MARK: MONEY-01/02/03 records

    /// The value, its basis and the currency of a written amount (`FAMoney.read`), the stated currency winning.
    nonisolated static func readMoney(_ text: String, currency: String?) -> (value: Decimal?, basis: String, currency: String) {
        let reading = FAMoney.read(text)
        let stated = blankToNil(currency)?.uppercased()
        let named = reading?.currency ?? ""
        let cur = stated ?? (!named.isEmpty ? named : (FAMoney.currencyIsAmbiguous(text) || text.lowercased().contains("dollar") ? FAMoney.ambiguousDollar : ""))
        return (reading?.value, reading?.basis ?? "not readable without guessing — write it as one figure", cur)
    }

    @discardableResult
    public func recordMoney(caseID: UUID, _ input: CaseMoneyRecordInput, statementID: UUID? = nil, statementRow: Int? = nil,
                            amends: (record: UUID, reason: String)? = nil, actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), text = try Self.clean(input.amountText, "The amount")
        let read = Self.readMoney(text, currency: input.currency)
        if let d = input.date, CaseMoneyLedger.date(d) == nil { throw CaseFileError.blank("A day as yyyy-MM-dd") }
        if input.settlesRecordID != nil, !input.kind.isMovement { throw CaseMoneyError.notAMovement }
        let id = UUID()
        try await write("cf_mrec", caseID: caseID, actor: who, action: amends == nil ? "moneyRecorded" : "moneyAmended",
                        detail: "\(input.kind.rawValue) \(text)" + (amends.map { " (amends: \($0.reason))" } ?? ""), at: date) { db in
            for (acct, what) in [(input.payerAccountID, "payer account"), (input.payeeAccountID, "payee account")] {
                try Self.moneyRowInCase(db, table: "case_money_accounts", acct, caseID: caseID, what: what)
            }
            try Self.moneyRowInCase(db, table: "case_money_statements", statementID, caseID: caseID, what: "statement")
            try Self.moneyRowInCase(db, table: "case_money_records", input.settlesRecordID, caseID: caseID, what: "invoice or claim")
            if let a = amends { try Self.moneyRowInCase(db, table: "case_money_records", a.record, caseID: caseID, what: "record being amended") }
            if let s = input.sourceVersionID, !(try Self.versionInCase(db, s, caseID: caseID)) { throw CaseWorkError.sourceNotInCase }
            try db.exec("""
                INSERT INTO case_money_records (id, case_id, kind, amount_text, amount, amount_basis, currency, record_date, date_text, reference,
                    payer_account_id, payee_account_id, payer_name, payee_name, description, settles_record_id, statement_id, statement_row,
                    amends_record_id, amend_reason, source_version_id, block_id, quote, source_name, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(input.kind.rawValue), .text(text), .optionalText(read.value.map { NSDecimalNumber(decimal: $0).stringValue }),
                      .text(read.basis), .text(read.currency), .optionalText(input.date), .optionalText(Self.blankToNil(input.dateText)),
                      .optionalText(Self.blankToNil(input.reference)), input.payerAccountID.map { .uuid($0) } ?? .null, input.payeeAccountID.map { .uuid($0) } ?? .null,
                      .optionalText(Self.blankToNil(input.payerName)), .optionalText(Self.blankToNil(input.payeeName)), .optionalText(Self.blankToNil(input.description)),
                      input.settlesRecordID.map { .uuid($0) } ?? .null, statementID.map { .uuid($0) } ?? .null, statementRow.map { .integer(Int64($0)) } ?? .null,
                      amends.map { .uuid($0.record) } ?? .null, .optionalText(amends.map(\.reason)),
                      input.sourceVersionID.map { .uuid($0) } ?? .null, input.blockID.map { .uuid($0) } ?? .null, .optionalText(Self.blankToNil(input.quote)),
                      .optionalText(Self.blankToNil(input.sourceName)), .text(who), .date(date)])
        }
        return id
    }

    /// Import a statement's rows (MONEY-07): each row becomes a record of the statement, with its row number. A debit is a
    /// payment out of the statement's account; a credit is a receipt into it, or a refund/reversal when its description says
    /// so; a row whose description says fee/charge is a fee. The counterparty account is linked only when the description
    /// names, as a whole token, the identifier of an account recorded in this case. The classification basis is recorded.
    @discardableResult
    public func importStatementRows(caseID: UUID, statementID: UUID, text: String, sourceVersionID: UUID? = nil, sourceName: String? = nil,
                                    actor: String, at date: Date = Date()) async throws -> [UUID] {
        let ledger = try await moneyLedger(caseID: caseID)
        guard let st = ledger.statements.first(where: { $0.id == statementID && $0.isActive }) else { throw CaseMoneyError.notFound("statement") }
        var ids: [UUID] = []
        for row in CaseMoneyStatementParser.rows(text) {
            let d = row.description.lowercased()
            let isDebit = row.debit != nil
            guard let amount = row.debit ?? row.credit else { throw CaseMoneyError.rowHasNoAmount(row.row) }
            var kind: CaseMoneyKind = isDebit ? .payment : .receipt
            var basis = isDebit ? "debit column" : "credit column"
            if d.range(of: #"\b(fee|charges?|commission)\b"#, options: .regularExpression) != nil, isDebit { kind = .fee; basis += "; the description says fee/charge" }
            if !isDebit, d.range(of: #"\brefund"#, options: .regularExpression) != nil { kind = .refund; basis += "; the description says refund" }
            if !isDebit, d.range(of: #"\brevers"#, options: .regularExpression) != nil { kind = .reversal; basis += "; the description says reversal" }
            let other = ledger.accounts.filter(\.isActive).first { a in
                a.id != st.accountID && d.range(of: #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: a.identifier.lowercased()) + #"(?![A-Za-z0-9])"#,
                                                options: .regularExpression) != nil
            }
            var input = CaseMoneyRecordInput(kind: kind, amountText: amount)
            input.currency = st.currency.isEmpty ? nil : st.currency
            input.date = row.date; input.dateText = row.dateText; input.reference = row.reference
            input.description = "\(row.description) [classified from the statement: \(basis)]"
            if isDebit { input.payerAccountID = st.accountID; input.payeeAccountID = other?.id; input.payeeName = other == nil ? Self.counterparty(row.description) : nil }
            else { input.payeeAccountID = st.accountID; input.payerAccountID = other?.id; input.payerName = other == nil ? Self.counterparty(row.description) : nil }
            input.sourceVersionID = sourceVersionID ?? st.sourceVersionID
            input.sourceName = sourceName ?? st.sourceName
            input.quote = "\(row.dateText) | \(row.description) | \(row.reference ?? "") | \(row.debit ?? "") | \(row.credit ?? "")"
            ids.append(try await recordMoney(caseID: caseID, input, statementID: statementID, statementRow: row.row, actor: actor, at: date))
        }
        return ids
    }

    /// "Transfer to Kestrel Supplies Pvt Ltd, a/c 8804" → "Kestrel Supplies Pvt Ltd" (the words after to/from, up to a comma).
    public nonisolated static func counterparty(_ description: String) -> String? {
        guard let r = description.range(of: #"(?i)\b(to|from)\s+([^,;|]+)"#, options: .regularExpression) else { return nil }
        let name = description[r].replacingOccurrences(of: #"(?i)^(to|from)\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Classify an unclassified amount. A classified one changes only by an amendment (the original stays).
    public func classifyMoney(caseID: UUID, id: UUID, kind: CaseMoneyKind, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor")
        guard kind != .unclassified else { throw CaseMoneyError.notUnclassified }
        try await write("cf_mcls", caseID: caseID, actor: who, action: "moneyClassified", detail: kind.rawValue, at: date) { db in
            guard let r = try db.query("SELECT kind FROM case_money_records WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseMoneyError.notFound("money record")
            }
            guard r.string(0) == CaseMoneyKind.unclassified.rawValue else { throw CaseMoneyError.alreadyClassified }
            try db.exec("UPDATE case_money_records SET kind = ? WHERE id = ?;", [.text(kind.rawValue), .uuid(id)])
        }
    }

    /// Record a replacement for a record (a corrected amount, day, reference or kind). The original stays, inspectable, and
    /// leaves every figure.
    @discardableResult
    public func amendMoney(caseID: UUID, id: UUID, with input: CaseMoneyRecordInput, reason: String, actor: String, at date: Date = Date()) async throws -> UUID {
        let why = try Self.clean(reason, "The reason")
        let old = try await moneyLedger(caseID: caseID).record(id)
        guard let old, old.isActive else { throw CaseMoneyError.notFound("money record") }
        return try await recordMoney(caseID: caseID, input, statementID: old.statementID, statementRow: old.statementRow, amends: (id, why), actor: actor, at: date)
    }

    public func withdrawMoney(caseID: UUID, id: UUID, reason: String, actor: String, at date: Date = Date()) async throws {
        try await withdrawMoneyRow(table: "case_money_records", what: "money record", caseID: caseID, id: id, reason: reason, actor: actor, at: date)
    }

    /// Mark a record disputed, with what is disputed (MONEY-05). It stays in its own figure and is also shown as disputed.
    public func disputeMoney(caseID: UUID, id: UUID, note: String, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), what = try Self.clean(note, "What is disputed")
        try await write("cf_mdsp", caseID: caseID, actor: who, action: "moneyDisputed", detail: what, at: date) { db in
            guard let r = try db.query("SELECT disputed_at FROM case_money_records WHERE id = ? AND case_id = ? AND withdrawn_at IS NULL;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseMoneyError.notFound("money record")
            }
            guard r.isNull(0) else { throw CaseMoneyError.alreadyDisputed }
            try db.exec("UPDATE case_money_records SET disputed_by = ?, disputed_at = ?, dispute_note = ? WHERE id = ?;", [.text(who), .date(date), .text(what), .uuid(id)])
        }
    }

    // MARK: MONEY-04 confirm / split

    /// Record that two records are ONE payment (confirm) or two (split). Append-only; the latest decision for a pair counts.
    @discardableResult
    public func decideMoneyIdentity(caseID: UUID, recordA: UUID, recordB: UUID, decision: CaseMoneyIdentityDecision.Decision, reason: String,
                                    actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        guard recordA != recordB else { throw CaseMoneyError.sameRecord }
        let id = UUID()
        try await write("cf_mid", caseID: caseID, actor: who, action: decision == .sameTransaction ? "moneyConfirmedSame" : "moneySplit", detail: why, at: date) { db in
            for r in [recordA, recordB] {
                guard let k = try db.query("SELECT kind FROM case_money_records WHERE id = ? AND case_id = ?;", [.uuid(r), .uuid(caseID)]).first?.string(0) else {
                    throw CaseMoneyError.notFound("money record")
                }
                guard CaseMoneyKind(rawValue: k)?.isMovement == true else { throw CaseMoneyError.notAMovement }
            }
            try db.exec("""
                INSERT INTO case_money_identity_decisions (id, case_id, record_a, record_b, decision, reason, decided_by, decided_at) VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .uuid(recordA), .uuid(recordB), .text(decision.rawValue), .text(why), .text(who), .date(date)])
        }
        return id
    }

    // MARK: MONEY-08 rates

    @discardableResult
    public func recordConversionRate(caseID: UUID, from: String, to: String, rate: String, rateDate: String, rateSource: String, method: String,
                                     actor: String, at date: Date = Date()) async throws -> UUID {
        let who = try Self.clean(actor, "Actor"), src = try Self.clean(rateSource, "The rate's source"), how = try Self.clean(method, "The method")
        let f = try Self.clean(from, "From currency").uppercased(), t = try Self.clean(to, "To currency").uppercased()
        guard f != t, let r = FAMoney.value(of: rate), r > 0 else { throw CaseMoneyError.badRate }
        guard CaseMoneyLedger.date(rateDate) != nil else { throw CaseFileError.blank("The rate's date as yyyy-MM-dd") }
        let id = UUID()
        try await write("cf_mfx", caseID: caseID, actor: who, action: "conversionRateRecorded", detail: "1 \(f) = \(rate) \(t)", at: date) { db in
            try db.exec("""
                INSERT INTO case_money_conversions (id, case_id, from_currency, to_currency, rate, rate_date, rate_source, method, recorded_by, recorded_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(id), .uuid(caseID), .text(f), .text(t), .text(rate.trimmingCharacters(in: .whitespaces)), .text(rateDate), .text(src), .text(how), .text(who), .date(date)])
        }
        return id
    }

    // MARK: MONEY-11 proposals

    /// Store the ledger's proposed gaps, each key once (re-running adds nothing it already holds). Returns how many were new.
    @discardableResult
    public func syncMoneyGapProposals(caseID: UUID, actor: String, at date: Date = Date()) async throws -> Int {
        let who = try Self.clean(actor, "Actor")
        let held = Set(try await database.query("SELECT dedupe_key FROM case_money_gap_proposals WHERE case_id = ?;", [.uuid(caseID)]).compactMap { $0.string(0) })
        let gaps = try await moneyLedger(caseID: caseID).proposedGaps().filter { !held.contains($0.key) }
        guard !gaps.isEmpty else { return 0 }
        try await write("cf_mgap", caseID: caseID, actor: who, action: "moneyGapsProposed", detail: "\(gaps.count) gap(s) checked", at: date) { db in
            for g in gaps {
                try db.exec("""
                    INSERT OR IGNORE INTO case_money_gap_proposals (id, case_id, dedupe_key, kind, account_id, period_start, period_end, deliverable, reason, created_by, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?);
                    """, [.uuid(UUID()), .uuid(caseID), .text(g.key), .text(g.kind.rawValue), g.account.map { .uuid($0) } ?? .null, .text(g.start), .text(g.end),
                          .text(g.deliverable), .text(g.reason), .text(who), .date(date)])
            }
        }
        return gaps.count
    }

    public func decideMoneyGapProposal(caseID: UUID, id: UUID, accept: Bool, reason: String, taskID: UUID? = nil, actor: String, at date: Date = Date()) async throws {
        let who = try Self.clean(actor, "Actor"), why = try Self.clean(reason, "The reason")
        try await write("cf_mgapd", caseID: caseID, actor: who, action: accept ? "moneyGapAccepted" : "moneyGapDismissed", detail: why, at: date) { db in
            guard let r = try db.query("SELECT state FROM case_money_gap_proposals WHERE id = ? AND case_id = ?;", [.uuid(id), .uuid(caseID)]).first else {
                throw CaseMoneyError.notFound("proposal")
            }
            guard r.string(0) == CaseMoneyGapProposal.State.proposed.rawValue else { throw CaseMoneyError.alreadyDecided }
            if let t = taskID, !(try Self.taskInCase(db, t, caseID: caseID)) { throw CaseMoneyError.notFound("task") }
            try db.exec("UPDATE case_money_gap_proposals SET state = ?, task_id = ?, decided_by = ?, decided_at = ?, decision_reason = ? WHERE id = ?;",
                        [.text(accept ? "accepted" : "dismissed"), taskID.map { .uuid($0) } ?? .null, .text(who), .date(date), .text(why), .uuid(id)])
        }
    }

    // MARK: Read

    public func moneyLedger(caseID: UUID) async throws -> CaseMoneyLedger {
        var l = CaseMoneyLedger(caseID: caseID)
        let c: [SQLValue] = [.uuid(caseID)]
        l.accounts = try await database.query("""
            SELECT id, identifier, identifier_key, institution, label, currency, source_version_id, quote, recorded_by, recorded_at, withdrawn_at
            FROM case_money_accounts WHERE case_id = ? ORDER BY recorded_at, id;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let ident = r.string(1), let key = r.string(2), let by = r.string(8), let at = r.date(9) else { return nil }
            return CaseMoneyAccount(id: id, identifier: ident, identifierKey: key, institution: r.string(3), label: r.string(4), currency: r.string(5),
                                    sourceVersionID: r.uuid(6), quote: r.string(7), recordedBy: by, recordedAt: at, withdrawnAt: r.date(10))
        }
        l.ownership = try await database.query("""
            SELECT id, account_id, holder_person_id, holder_name, relation, share_text, via_text, valid_from, valid_to, valid_text, basis, source_version_id, quote,
                   supplied_by, recorded_by, recorded_at, withdrawn_at
            FROM case_money_ownership WHERE case_id = ? ORDER BY recorded_at, id;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let a = r.uuid(1), let name = r.string(3), let rel = r.string(4).flatMap(CaseMoneyRelation.init(rawValue:)),
                  let basis = r.string(10).flatMap(CaseMoneyBasis.init(rawValue:)), let by = r.string(14), let at = r.date(15) else { return nil }
            return CaseMoneyOwnership(id: id, accountID: a, holderPersonID: r.string(2).flatMap(UUID.init(uuidString:)), holderName: name, relation: rel,
                                      share: r.string(5), via: r.string(6), validFrom: r.date(7), validTo: r.date(8), validText: r.string(9), basis: basis,
                                      sourceVersionID: r.uuid(11), quote: r.string(12), suppliedBy: r.string(13), recordedBy: by, recordedAt: at, withdrawnAt: r.date(16))
        }
        l.statements = try await database.query("""
            SELECT id, account_id, period_start, period_end, opening_text, closing_text, currency, source_version_id, source_name, recorded_by, recorded_at, withdrawn_at
            FROM case_money_statements WHERE case_id = ? ORDER BY period_start, recorded_at, id;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let a = r.uuid(1), let s = r.string(2), let e = r.string(3), let by = r.string(9), let at = r.date(10) else { return nil }
            return CaseMoneyStatement(id: id, accountID: a, periodStart: s, periodEnd: e, opening: r.string(4), closing: r.string(5), currency: r.string(6) ?? "",
                                      sourceVersionID: r.uuid(7), sourceName: r.string(8), recordedBy: by, recordedAt: at, withdrawnAt: r.date(11))
        }
        l.records = try await database.query("""
            SELECT id, kind, amount_text, amount, amount_basis, currency, record_date, date_text, reference, payer_account_id, payee_account_id, payer_name, payee_name,
                   description, settles_record_id, statement_id, statement_row, amends_record_id, amend_reason, source_version_id, block_id, quote, source_name,
                   disputed_by, disputed_at, dispute_note, recorded_by, recorded_at, withdrawn_at
            FROM case_money_records WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let k = r.string(1).flatMap(CaseMoneyKind.init(rawValue:)), let text = r.string(2), let basis = r.string(4),
                  let by = r.string(26), let at = r.date(27) else { return nil }
            return CaseMoneyRecord(id: id, kind: k, amountText: text, amount: r.string(3).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) },
                                   amountBasis: basis, currency: r.string(5) ?? "", date: r.string(6), dateText: r.string(7), reference: r.string(8),
                                   payerAccountID: r.uuid(9), payeeAccountID: r.uuid(10), payerName: r.string(11), payeeName: r.string(12), description: r.string(13),
                                   settlesRecordID: r.uuid(14), statementID: r.uuid(15), statementRow: r.int(16).map { Int($0) }, amendsRecordID: r.uuid(17),
                                   amendReason: r.string(18), sourceVersionID: r.uuid(19), blockID: r.uuid(20), quote: r.string(21), sourceName: r.string(22),
                                   disputedBy: r.string(23), disputedAt: r.date(24), disputeNote: r.string(25), recordedBy: by, recordedAt: at, withdrawnAt: r.date(28))
        }
        l.decisions = try await database.query("""
            SELECT id, record_a, record_b, decision, reason, decided_by, decided_at FROM case_money_identity_decisions WHERE case_id = ? ORDER BY decided_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let a = r.uuid(1), let b = r.uuid(2), let d = r.string(3).flatMap(CaseMoneyIdentityDecision.Decision.init(rawValue:)),
                  let why = r.string(4), let by = r.string(5), let at = r.date(6) else { return nil }
            return CaseMoneyIdentityDecision(id: id, recordA: a, recordB: b, decision: d, reason: why, decidedBy: by, decidedAt: at)
        }
        l.conversions = try await database.query("""
            SELECT id, from_currency, to_currency, rate, rate_date, rate_source, method, recorded_by, recorded_at, withdrawn_at
            FROM case_money_conversions WHERE case_id = ? ORDER BY recorded_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let f = r.string(1), let t = r.string(2), let rt = r.string(3), let rate = FAMoney.value(of: rt), let d = r.string(4),
                  let src = r.string(5), let m = r.string(6), let by = r.string(7), let at = r.date(8) else { return nil }
            return CaseMoneyConversion(id: id, from: f, to: t, rate: rate, rateText: rt, rateDate: d, rateSource: src, method: m, recordedBy: by, recordedAt: at, withdrawnAt: r.date(9))
        }
        l.proposals = try await database.query("""
            SELECT id, dedupe_key, kind, account_id, period_start, period_end, deliverable, reason, state, task_id, decided_by, decided_at, decision_reason
            FROM case_money_gap_proposals WHERE case_id = ? ORDER BY created_at, rowid;
            """, c).compactMap { r in
            guard let id = r.uuid(0), let key = r.string(1), let k = r.string(2).flatMap(CaseMoneyGapProposal.Kind.init(rawValue:)), let s = r.string(4), let e = r.string(5),
                  let d = r.string(6), let why = r.string(7), let st = r.string(8).flatMap(CaseMoneyGapProposal.State.init(rawValue:)) else { return nil }
            return CaseMoneyGapProposal(id: id, key: key, kind: k, accountID: r.uuid(3), periodStart: s, periodEnd: e, deliverable: d, reason: why, state: st,
                                        taskID: r.uuid(9), decidedBy: r.string(10), decidedAt: r.date(11), decisionReason: r.string(12))
        }
        return l
    }
}
