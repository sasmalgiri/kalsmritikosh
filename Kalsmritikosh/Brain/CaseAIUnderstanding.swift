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
        /// Accuracy F2 — each party's own in, out and kept.
        public var flows: [PartyFlow] = []
        public var isEmpty: Bool { records.isEmpty }
    }

    static let paidKinds: Set<String> = ["payment", "transfer"]
    static let returnedKinds: Set<String> = ["refund", "reversal"]

    /// The AI's money records and the app's figures: paid (payments, transfers), received, returned (refunds, reversals) and
    /// fees. Mentions (invoice, claim, balance, estimate …) are listed, never added into a movement figure. Each figure is
    /// CaseAgent.sum over the amounts as written.
    /// Accuracy F2 (FAIR3 root cause, 2026-11-25): the cross-party "Net outflow" (paid + fees − returned over EVERY party —
    /// harbor's 180,000 + 95,000 − 60,000 mixed three payers) is gone; `flows` gives each party's own in, out and kept.
    public static func money(_ records: [CaseAIRecord]) -> Money {
        let m = records.filter { $0.kind == .fact && $0.entityType == CaseAIRecord.moneyType }
        func amounts(_ kinds: Set<String>) -> [CaseAIRecord] { m.filter { kinds.contains($0.role ?? "") } }
        func figure(_ name: String, plus: [CaseAIRecord], minus: [CaseAIRecord] = []) -> MoneyFigure {
            let s = CaseAgent.sum(plus: plus.compactMap(\.relation), minus: minus.compactMap(\.relation))
            return MoneyFigure(figure: name, sum: s?.expression, totals: s?.totals ?? [:], records: (plus + minus).map(\.id))
        }
        let paid = amounts(paidKinds), fees = amounts(["fee"]), returned = amounts(returnedKinds), received = amounts(["receipt"])
        let figures = [figure("Paid", plus: paid), figure("Received", plus: received), figure("Returned", plus: returned), figure("Fees", plus: fees)]
        return Money(records: m, figures: figures.filter { $0.sum != nil }, flows: partyFlows(records))
    }

    // MARK: - Accuracy F2: each party's own money (the AI classified who paid whom; the app sums per party)

    /// One party's money: what came in, what went out, what it kept (in − out), each the app's exact sum per currency, and
    /// the balances its documents quote. Built from the AI's money movements (payment, transfer, receipt, refund, reversal,
    /// fee) by their `from` (payer) and `to` (payee).
    public struct PartyFlow: Sendable, Equatable {
        /// The name as the AI first wrote it, and every other way it was written for this party.
        public let name: String
        public let names: [String]
        /// Account tails written with the name ("****2218" → "2218").
        public let accounts: [String]
        public let moneyIn: String?
        public let moneyOut: String?
        /// in − out, only when the party both received and paid out.
        public let kept: String?
        public let keptTotals: [String: Decimal]
        public let inTotals: [String: Decimal]
        public let outTotals: [String: Decimal]
        /// "30/09/2026 1,800,000.00 (closing balance)" — balance records naming the party.
        public let balances: [String]
        public let records: [UUID]
        public let documents: [UUID]
        public var isIntermediary: Bool { moneyIn != nil && moneyOut != nil }
    }

    static let movementKinds: Set<String> = paidKinds.union(returnedKinds).union(["receipt", "fee"])
    static let legalSuffixes: Set<String> = ["ltd", "limited", "pty", "llc", "inc", "bv", "plc", "co", "corp", "gmbh", "sa", "ag", "the", "and"]

    /// A written party name split into its name key tokens and account tails: "Pemberton Wholesale (Westpac ****6610)" →
    /// (["pemberton", "wholesale"], ["6610"]). Matching uses the money model's normalisation (CaseMoneyLedger.norm).
    static func partyKey(_ written: String) -> (tokens: [String], accounts: [String]) {
        let ns = written as NSString
        var accounts: [String] = []
        // Account tails: masked ("****2218", "XXXX0457"), an IBAN, or a 4+ digit number in brackets.
        if let re = try? NSRegularExpression(pattern: #"[*xX•]{2,}\s?(\d{3,})|\b[A-Z]{2}\d{2}[A-Z0-9]{8,30}\b|\((?:[^()]*?\s)?(\d{4,})\)"#) {
            for m in re.matches(in: written, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : (m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range)
                let t = ns.substring(with: r)
                let digits = String(t.filter(\.isNumber).suffix(4))
                if digits.count >= 3, !accounts.contains(digits) { accounts.append(digits) }
            }
        }
        // The name: before any bracket, letters and digits only; dotted initials join ("B.V." → "bv").
        let base = written.components(separatedBy: "(").first ?? written
        let joined = base.replacingOccurrences(of: #"(?<=\b[A-Za-z])\.(?=[A-Za-z]\b)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ".", with: "")
        let tokens = CaseMoneyLedger.norm(joined).split(separator: " ").map(String.init).filter { !legalSuffixes.contains($0) }
        return (tokens, accounts)
    }

    /// Each party of the AI's money movements, one per real party: the same account tail, the same name (legal suffixes
    /// aside), one name's words all inside the other's (at least two words), or the AI's own "also written as" join them.
    public static func partyFlows(_ records: [CaseAIRecord]) -> [PartyFlow] {
        let money = records.filter { $0.kind == .fact && $0.entityType == CaseAIRecord.moneyType }
        let movements = money.filter { movementKinds.contains($0.role ?? "") }
        guard !movements.isEmpty else { return [] }
        // Every written name, in first-seen order.
        var written: [String] = []
        for r in movements { for n in [r.from, r.to].compactMap({ $0?.trimmingCharacters(in: .whitespaces) }) where !n.isEmpty && !written.contains(n) { written.append(n) } }
        // The AI's own spellings of one party.
        var aliasGroups: [Set<String>] = []
        for p in parties(records) { aliasGroups.append(Set(([p.name] + p.alsoWrittenAs).map { partyKey($0).tokens.joined(separator: " ") })) }
        var parent = Array(written.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        func union(_ a: Int, _ b: Int) { let x = find(a), y = find(b); if x != y { parent[max(x, y)] = min(x, y) } }
        let keys = written.map(partyKey)
        for i in written.indices {
            for j in written.indices where j > i {
                let a = keys[i], b = keys[j]
                let ta = a.tokens.joined(separator: " "), tb = b.tokens.joined(separator: " ")
                let sameAccount = !Set(a.accounts).isDisjoint(with: b.accounts)
                let sameName = !ta.isEmpty && ta == tb
                let (small, large) = a.tokens.count <= b.tokens.count ? (a.tokens, b.tokens) : (b.tokens, a.tokens)
                let contained = small.count >= 2 && Set(small).isSubset(of: Set(large))
                let aliased = aliasGroups.contains { $0.contains(ta) && $0.contains(tb) }
                // Two different account tails are two parties, whatever the names say.
                let differentAccounts = !a.accounts.isEmpty && !b.accounts.isEmpty && !sameAccount
                if sameAccount || (!differentAccounts && (sameName || contained || aliased)) { union(i, j) }
            }
        }
        var order: [Int] = []
        for i in written.indices where !order.contains(find(i)) { order.append(find(i)) }
        func member(_ name: String?, of root: Int) -> Bool {
            guard let n = name?.trimmingCharacters(in: .whitespaces), let i = written.firstIndex(of: n) else { return false }
            return find(i) == root
        }
        return order.map { root in
            let names = written.indices.filter { find($0) == root }.map { written[$0] }
            let incoming = movements.filter { member($0.to, of: root) }
            let outgoing = movements.filter { member($0.from, of: root) }
            let inSum = CaseAgent.sum(plus: incoming.compactMap(\.relation), minus: [])
            let outSum = CaseAgent.sum(plus: outgoing.compactMap(\.relation), minus: [])
            let keptSum = !incoming.isEmpty && !outgoing.isEmpty
                ? CaseAgent.sum(plus: incoming.compactMap(\.relation), minus: outgoing.compactMap(\.relation)) : nil
            let balanceRecords = money.filter { $0.role == "balance" && (member($0.to, of: root) || ($0.to == nil && member($0.from, of: root))) }
            let balances = balanceRecords.map { r -> String in
                let t = r.text.lowercased()
                let label = t.contains("opening") ? " (opening balance)" : t.contains("closing") ? " (closing balance)" : " (balance)"
                return "\(r.dateText ?? "undated") \(r.relation ?? "")\(label)"
            }
            let used = incoming + outgoing + balanceRecords
            var accounts: [String] = []
            for n in names { for a in partyKey(n).accounts where !accounts.contains(a) { accounts.append(a) } }
            var docs: [UUID] = []
            for r in used { if let d = r.document, !docs.contains(d) { docs.append(d) } }
            return PartyFlow(name: names[0], names: names, accounts: accounts, moneyIn: inSum?.expression, moneyOut: outSum?.expression,
                             kept: keptSum?.expression, keptTotals: keptSum?.totals ?? [:],
                             inTotals: inSum?.totals ?? [:], outTotals: outSum?.totals ?? [:], balances: balances,
                             records: used.map(\.id), documents: docs)
        }
    }

    /// One party's line, for the briefing and the question task: "Ardmore Project Services Ltd (****2218; also written …):
    /// money in 600,000 = 600,000; money out 550,000 = 550,000; kept (in − out) 600,000 − 550,000 = 50,000 [D10] [D11]".
    public static func flowLine(_ f: PartyFlow, number: [UUID: Int]) -> String {
        var head = f.name
        let others = f.names.dropFirst()
        if !others.isEmpty { head += " (also written: " + others.prefix(3).joined(separator: "; ") + ")" }
        func total(_ t: [String: Decimal]) -> String {
            t.keys.sorted().map { CaseAgent.format(t[$0] ?? 0, $0.isEmpty ? nil : $0) }.joined(separator: "; ")
        }
        var parts: [String] = []
        // Kept first (the line may be shortened for length; the per-party result must survive).
        if f.kept != nil {
            if f.inTotals.count == 1, f.outTotals.count == 1, f.keptTotals.count == 1 {
                parts.append("kept (in − out) " + total(f.inTotals) + " − " + total(f.outTotals) + " = " + total(f.keptTotals))
            } else {
                parts.append("kept (in − out, per currency) " + total(f.keptTotals))
            }
        }
        parts.append("money in " + (f.moneyIn ?? "none recorded"))
        parts.append("money out " + (f.moneyOut ?? "none recorded"))
        if !f.balances.isEmpty { parts.append("balances quoted: " + f.balances.joined(separator: ", ")) }
        let tags = Array(Set(f.documents.compactMap { number[$0] })).sorted().map { "[D\($0)]" }.joined(separator: " ")
        return "- \(head): " + parts.joined(separator: "; ") + (tags.isEmpty ? "" : " " + tags)
    }

    /// Accuracy F2 — a question that asks where money went, to trace it, or what was kept or net.
    public static func asksMoneyTrace(_ question: String) -> Bool {
        let q = question.lowercased()
        let cues = ["trace", "where did", "where has", "where have", "where was", "where the money", "where it went", "go?", "net", "kept",
                    "keep", "retain", "end up", "ended up", "round trip", "round-trip", "flow", "came back", "come back"]
        return cues.contains { cue in
            q.range(of: #"(?<![a-z])"# + NSRegularExpression.escapedPattern(for: cue) + (cue.hasSuffix("?") ? "" : #"(?![a-z])"#),
                    options: .regularExpression) != nil
        }
    }

    /// Accuracy F2 — for a trace / where-did-it-go / net / kept question, the money lines of the parties it names (any of
    /// their written names, by name tokens), else of every party that both received and paid out (at most 10). Empty for
    /// any other question. Question-specific: goes in the question task, never in the stable prefix.
    public static func questionMoneyLines(_ question: String, records: [CaseAIRecord], number: [UUID: Int]) -> [String] {
        guard asksMoneyTrace(question) else { return [] }
        let flows = partyFlows(records)
        guard !flows.isEmpty else { return [] }
        let qTokens = Set(VerifiedAnswerComposer.nameTokens(question))
        let named = flows.filter { f in
            f.names.contains { n in
                let t = partyKey(n).tokens.filter { $0.count > 2 }
                return !t.isEmpty && t.allSatisfy(qTokens.contains)
            } || f.names.contains { n in
                // A distinctive first word of the name ("Pemberton", "Bluewater") is enough.
                guard let first = partyKey(n).tokens.first, first.count >= 5 else { return false }
                return qTokens.contains(first)
            }
        }
        var chosen = named
        for f in flows where f.isIntermediary && !chosen.contains(f) { chosen.append(f) }
        return chosen.prefix(10).map { flowLine($0, number: number) }
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
