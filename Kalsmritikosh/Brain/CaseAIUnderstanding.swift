//
//  CaseAIUnderstanding.swift
//  Kalsmritikosh
//
//  AI split AI-48 (owner 2026-11-23) — understanding moves to the AI. The AI's quote-checked records (case_ai_records, the
//  case picture and the records written while answering) are what the case's understanding consumers read: people and their
//  roles, organisations, dated events, statements (who said what), relationships, conflicts, money (the AI classifies, the
//  app sums), merge decisions (the app proposes alias candidates, the AI decides) and fact status. The app does only the exact
//  work here: sorting by date, sums per currency (CaseAgent.sum), counting. Nothing here guesses or calls a model.
//
//  The rule extractors stay as a search index and hints; while a case has AI records, the rule output is not shown as truth.
//  RetiredPaths.ruleUnderstanding on restores the rule deciders.
//

import Foundation

public nonisolated enum CaseAIUnderstanding {

    /// Whether the rule understanding still decides (the retired path switched back on).
    public static var rulesDecide: Bool { RetiredPaths.isOn(.ruleUnderstanding) }

    // MARK: - People and organisations (roles)

    public struct Party: Sendable, Equatable, Identifiable {
        public var id: String { key }
        public let key: String
        public let name: String
        /// person, organisation, place, account, other — as the AI typed it.
        public let type: String
        /// The roles in the AI's words, in order recorded.
        public let roles: [String]
        /// The AI's role kinds (CasePersonRoleKind raw values).
        public let roleKinds: [String]
        /// Other spellings the AI said are the same (each written in a case document).
        public let alsoWrittenAs: [String]
        public let records: [UUID]
    }

    static func key(_ s: String) -> String { VerifiedRecordExtractor.normalized(s) }

    /// Every person, organisation, place and account the AI recorded, one per name (its other spellings joined to it).
    public static func parties(_ records: [CaseAIRecord]) -> [Party] {
        var order: [String] = [], byKey: [String: (name: String, type: String, roles: [String], kinds: [String], aliases: [String], ids: [UUID])] = [:]
        var aliasOf: [String: String] = [:]
        for r in records where r.kind == .entity {
            let k = aliasOf[key(r.text)] ?? key(r.text)
            var e = byKey[k] ?? (r.text, r.entityType ?? "other", [], [], [], [])
            if let role = r.role, !role.isEmpty, !e.roles.contains(role) { e.roles.append(role) }
            if let kind = r.relation, !e.kinds.contains(kind) { e.kinds.append(kind) }
            for a in r.supporting where !e.aliases.contains(a) && key(a) != k {
                e.aliases.append(a); aliasOf[key(a)] = k
            }
            e.ids.append(r.id)
            if byKey[k] == nil { order.append(k) }
            byKey[k] = e
        }
        return order.compactMap { k in
            byKey[k].map { Party(key: k, name: $0.name, type: $0.type, roles: $0.roles, roleKinds: $0.kinds, alsoWrittenAs: $0.aliases, records: $0.ids) }
        }
    }

    public static func people(_ records: [CaseAIRecord]) -> [Party] { parties(records).filter { $0.type == "person" } }
    public static func organisations(_ records: [CaseAIRecord]) -> [Party] { parties(records).filter { $0.type == "organisation" } }

    // MARK: - Events (timeline, history and story)

    public static func sortKey(_ dateText: String?) -> (Int, Int, Int) {
        let d = dateText.flatMap { VerifiedAnswerComposer.values(in: $0).dates.first }
        return (d?.year ?? 9_999, d?.month ?? 13, d?.day ?? 32)
    }

    /// The AI's dated events, earliest first (undated last), with the app reading each date exactly as written.
    public static func timeline(_ records: [CaseAIRecord]) -> [CaseAIRecord] {
        records.filter { $0.kind == .event }.sorted { a, b in
            let ka = sortKey(a.dateText), kb = sortKey(b.dateText)
            return ka != kb ? ka < kb : a.createdAt < b.createdAt
        }
    }

    /// The case's story as the AI's dated events in order — one line each, with its quote (the history / dossier text).
    public static func story(_ records: [CaseAIRecord]) -> [String] {
        timeline(records).map { "\($0.dateText ?? "undated") — \($0.text) (\u{201C}\(($0.quote ?? "").prefix(200))\u{201D}; \(CaseAIRecord.checkedLabel))" }
    }

    public static func relationships(_ records: [CaseAIRecord]) -> [CaseAIRecord] { records.filter { $0.kind == .relationship } }
    public static func conflicts(_ records: [CaseAIRecord]) -> [CaseAIRecord] { records.filter { $0.kind == .conflict } }
    /// Statements: the facts the AI recorded (who said what is in the fact's text, its quote and document).
    public static func statements(_ records: [CaseAIRecord]) -> [CaseAIRecord] {
        records.filter { $0.kind == .fact && $0.entityType != CaseAIRecord.moneyType }
    }

    // MARK: - Fact status

    public enum FactStatus: String, Sendable { case foundByAI = "found by AI, quote checked", inConflict = "in conflict (both quotes checked)", hypothesis = "AI hypothesis — not a finding" }

    /// A record's status as shown: a fact or money record whose quote is a side of a recorded conflict is "in conflict".
    public static func status(of r: CaseAIRecord, in records: [CaseAIRecord]) -> FactStatus {
        if r.kind == .hypothesis { return .hypothesis }
        let q = key(r.quote ?? "")
        let conflicted = !q.isEmpty && conflicts(records).contains { key($0.quote ?? "") == q || key($0.quoteB ?? "") == q }
        return conflicted ? .inConflict : .foundByAI
    }

    // MARK: - Money (the AI classifies, the app sums)

    public struct MoneyFigure: Sendable, Equatable {
        public let figure: String
        /// The app's exact sum ("INR 50,000 + INR 50,000 = INR 100,000"), nil when no record holds the figure.
        public let sum: String?
        public let totals: [String: Decimal]
        public let records: [UUID]
    }

    public struct Money: Sendable, Equatable {
        public let records: [CaseAIRecord]
        public let figures: [MoneyFigure]
        public var isEmpty: Bool { records.isEmpty }
    }

    static let paidKinds: Set<String> = ["payment", "transfer"]
    static let returnedKinds: Set<String> = ["refund", "reversal"]

    /// The AI's money records and the app's figures: paid (payments, transfers), received, returned (refunds, reversals),
    /// fees, and net outflow = paid + fees − returned (never called a loss). Mentions (invoice, claim, balance, estimate …)
    /// are listed, never added into a movement figure. Each figure is CaseAgent.sum over the amounts as written.
    public static func money(_ records: [CaseAIRecord]) -> Money {
        let m = records.filter { $0.kind == .fact && $0.entityType == CaseAIRecord.moneyType }
        func amounts(_ kinds: Set<String>) -> [CaseAIRecord] { m.filter { kinds.contains($0.role ?? "") } }
        func figure(_ name: String, plus: [CaseAIRecord], minus: [CaseAIRecord] = []) -> MoneyFigure {
            let s = CaseAgent.sum(plus: plus.compactMap(\.relation), minus: minus.compactMap(\.relation))
            return MoneyFigure(figure: name, sum: s?.expression, totals: s?.totals ?? [:], records: (plus + minus).map(\.id))
        }
        let paid = amounts(paidKinds), fees = amounts(["fee"]), returned = amounts(returnedKinds), received = amounts(["receipt"])
        var figures = [figure("Paid", plus: paid), figure("Received", plus: received), figure("Returned", plus: returned), figure("Fees", plus: fees)]
        if !paid.isEmpty || !fees.isEmpty { figures.append(figure("Net outflow (paid + fees − returned)", plus: paid + fees, minus: returned)) }
        return Money(records: m, figures: figures.filter { $0.sum != nil })
    }

    /// The AI's classification for a money record of the case's money ledger: the AI money record citing the same document
    /// with the same amount (exactly, as the app reads it). nil: the AI recorded no such amount there (the record stays
    /// unclassified — a candidate — until the AI or a person classifies it).
    public static func classification(amount: String, document: UUID?, in records: [CaseAIRecord]) -> String? {
        guard let a = CaseAgent.amount(amount) else { return nil }
        return records.first { r in
            guard r.kind == .fact, r.entityType == CaseAIRecord.moneyType, r.document == document || document == nil,
                  let b = r.relation.flatMap(CaseAgent.amount) else { return false }
            return b.value == a.value && (a.currency == nil || b.currency == nil || a.currency == b.currency)
        }?.role
    }

    // MARK: - Merge decisions (the app proposes, the AI decides)

    public enum MergeDecision: String, Sendable, Equatable {
        /// The AI recorded both spellings as one person or organisation.
        case same
        /// The AI recorded both as separate people or organisations, neither naming the other.
        case different
        /// The AI has not said: nothing is merged.
        case undecided
    }

    /// The AI's decision on one alias candidate the app proposed (a lone spelling and a corroborated one).
    public static func mergeDecision(_ a: String, _ b: String, records: [CaseAIRecord]) -> MergeDecision {
        let ka = key(a), kb = key(b)
        guard ka != kb else { return .same }
        let all = parties(records)
        if all.contains(where: { p in
            let names = Set([p.key] + p.alsoWrittenAs.map(key))
            return names.contains(ka) && names.contains(kb)
        }) { return .same }
        let hasA = all.contains { $0.key == ka || $0.alsoWrittenAs.map(key).contains(ka) }
        let hasB = all.contains { $0.key == kb || $0.alsoWrittenAs.map(key).contains(kb) }
        return hasA && hasB ? .different : .undecided
    }

    // MARK: - Causal language (the AI judges)

    /// Whether a source states the cause, as the AI judged it: the AI's quote-checked relationship or fact records whose
    /// quote is in the evidence and whose relation or text says it caused, led to or resulted in something. nil: the AI has
    /// not judged it (the causal-marker rule is then only a hint).
    public static func sourceStatesCause(claim: String, evidenceTexts: [String], records: [CaseAIRecord]) -> Bool? {
        let evidence = evidenceTexts.map(key)
        let judged = records.filter { r in
            guard let q = r.quote, !q.isEmpty else { return false }
            let kq = key(q)
            return evidence.contains { $0.contains(kq) }
        }
        guard !judged.isEmpty else { return nil }
        let causal = ["caused", "cause", "led to", "resulted in", "because", "due to"]
        return judged.contains { r in
            let said = ((r.relation ?? "") + " " + r.text).lowercased()
            return causal.contains { said.contains($0) }
        }
    }
}
