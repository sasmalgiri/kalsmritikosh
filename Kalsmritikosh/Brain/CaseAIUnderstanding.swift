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
    /// Accuracy G1 (FAIR4 §5 item 3, 2026-11-25): one transfer recorded in several documents (the sender's statement, the
    /// receiver's statement, a ledger) counts ONCE (`Movement`, listing every document); currencies are never mixed.
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
        /// Accuracy G1 — the de-duplicated movements in and out.
        public var incoming: [Movement] = []
        public var outgoing: [Movement] = []
        public var isIntermediary: Bool { moneyIn != nil && moneyOut != nil }
    }

    /// Accuracy G1 — one money movement, however many documents record it.
    public struct Movement: Sendable, Equatable {
        public let value: Decimal
        /// ISO code, "?<symbol>" for an unclear symbol, "" for none named anywhere in the case.
        public let currency: String
        /// The date as the app read it (each document's own day/month order), nil when undated or unreadable.
        public let date: String?
        public let reference: String?
        public let records: [UUID]
        public let documents: [UUID]
        /// The amount as a sum term ("EUR 600,000").
        public var term: String { CaseAgent.format(value, currency.isEmpty ? nil : currency) }
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

    /// Accuracy G1 — every token of the shorter name is a token of the longer one, or an initial of one ("B KERR" ⊂
    /// "BRADLEY J KERR"); at least two tokens, and one of them a whole word of three or more letters.
    static func nameContained(_ a: [String], _ b: [String]) -> Bool {
        let (small, large) = a.count <= b.count ? (a, b) : (b, a)
        guard small.count >= 2 else { return false }
        var wholeWord = false
        for t in small {
            if large.contains(t) { if t.count >= 3 { wholeWord = true }; continue }
            guard t.count == 1, large.contains(where: { $0.count > 1 && $0.hasPrefix(t) }) else { return false }
        }
        return wholeWord
    }

    /// Accuracy G1 — the reference the AI gave a money record ("…, ref VQ-REL-01 site services").
    static func reference(of r: CaseAIRecord) -> String? {
        guard let range = r.text.range(of: ", ref ", options: .backwards) else { return nil }
        let ref = r.text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return ref.isEmpty ? nil : ref
    }

    /// Accuracy G1 — two references name the same transfer: a shared code ("VQ-REL-01" in "VQ-REL-01 site services"), or
    /// the same words.
    static func sameReference(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let ca = Set(VerifiedAnswerComposer.identifiers(in: a).map { $0.token.uppercased() })
        let cb = Set(VerifiedAnswerComposer.identifiers(in: b).map { $0.token.uppercased() })
        if !ca.isEmpty, !cb.isEmpty { return !ca.isDisjoint(with: cb) }
        let na = CaseMoneyLedger.norm(a), nb = CaseMoneyLedger.norm(b)
        return !na.isEmpty && na == nb
    }

    /// The most days a sender's debit and the receiver's credit of one referenced transfer may lie apart.
    static let settlementDays = 3

    /// Each party of the AI's money movements, one per real party: the same account tail, the same name (legal suffixes
    /// aside), one name's words all inside the other's (at least two words; an initial matches its word), or the AI's own
    /// "also written as" join them.
    /// Accuracy G1 (FAIR4 §5 item 3, 2026-11-25): movements are de-duplicated first — the same amount, a compatible currency,
    /// the same payer and payee, from different documents, on the same day (each document's own day/month order; both
    /// readings when a document's order is unknown) or with the same reference within `settlementDays` → one movement
    /// listing every document. An amount naming no currency takes its duplicates' currency, else the case's only currency.
    /// Sums are per currency: different currencies are never added or subtracted.
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
                let contained = nameContained(a.tokens, b.tokens)
                let aliased = aliasGroups.contains { $0.contains(ta) && $0.contains(tb) }
                // Two different account tails are two parties, whatever the names say.
                let differentAccounts = !a.accounts.isEmpty && !b.accounts.isEmpty && !sameAccount
                if sameAccount || (!differentAccounts && (sameName || contained || aliased)) { union(i, j) }
            }
        }
        var order: [Int] = []
        for i in written.indices where !order.contains(find(i)) { order.append(find(i)) }
        func root(_ name: String?) -> Int? {
            guard let n = name?.trimmingCharacters(in: .whitespaces), let i = written.firstIndex(of: n) else { return nil }
            return find(i)
        }
        func member(_ name: String?, of r: Int) -> Bool { root(name) == r }

        // Each document's day/month order, read from the dates its money records carry.
        var datesByDoc: [UUID: [String]] = [:]
        for r in money { if let d = r.document { datesByDoc[d, default: []].append([r.dateText, r.relation].compactMap { $0 }.joined(separator: " ")) } }
        let orderByDoc = datesByDoc.mapValues { DateOrder.dayFirst($0.joined(separator: "\n")) }

        // One entry per record, then clusters of the same movement.
        struct Entry { let record: CaseAIRecord; let value: Decimal; let currency: String?; let payer: Int?; let payee: Int?; let day: VerifiedAnswerComposer.Day?; let ref: String? }
        let entries: [Entry] = movements.compactMap { r in
            guard let a = r.relation.flatMap(CaseAgent.amount) else { return nil }
            let cur = a.currency ?? (a.isCurrencyUnclear ? CaseAgent.unclearPrefix + (a.symbol ?? "?") : nil)
            let day = VerifiedAnswerComposer.values(in: r.dateText ?? "").dates.first(where: { $0.day != nil })
                .map { DateOrder.resolved($0, dayFirst: r.document.flatMap { orderByDoc[$0] ?? nil }) }
            return Entry(record: r, value: a.value < 0 ? -a.value : a.value, currency: cur, payer: root(r.from), payee: root(r.to), day: day, ref: reference(of: r))
        }
        func duplicate(_ a: Entry, _ b: Entry) -> Bool {
            guard a.value == b.value, a.payer == b.payer, a.payee == b.payee, a.payer != nil || a.payee != nil else { return false }
            if let x = a.currency, let y = b.currency, x != y { return false }
            if let x = a.day, let y = b.day, DateOrder.sameDay(x, y) { return true }
            guard sameReference(a.ref, b.ref) else { return false }
            guard let x = a.day, let y = b.day else { return true }
            return DateOrder.daysApart(x, y).map { $0 <= settlementDays } ?? false
        }
        var clusters: [[Entry]] = []
        for e in entries {
            if let i = clusters.firstIndex(where: { c in
                c.allSatisfy { duplicate($0, e) && ($0.record.document == nil || $0.record.document != e.record.document) }
            }) { clusters[i].append(e) } else { clusters.append([e]) }
        }
        // Currency: a cluster's named currency; else the one currency every named movement of the case uses.
        let clusterCurrency: [String?] = clusters.map { c in c.compactMap(\.currency).first }
        let named = Set(clusterCurrency.compactMap { $0 }.filter { !$0.hasPrefix(CaseAgent.unclearPrefix) })
        let unclearAny = clusterCurrency.contains { $0?.hasPrefix(CaseAgent.unclearPrefix) ?? false }
        let caseCurrency = named.count == 1 && !unclearAny ? named.first : nil
        struct Cluster { let movement: Movement; let payer: Int?; let payee: Int? }
        let merged: [Cluster] = clusters.enumerated().map { i, c in
            let first = c[0]
            var docs: [UUID] = []
            for e in c { if let d = e.record.document, !docs.contains(d) { docs.append(d) } }
            let day = c.compactMap(\.day).first
            let m = Movement(value: first.value, currency: clusterCurrency[i] ?? caseCurrency ?? "", date: day.map(DateOrder.show),
                             reference: c.compactMap(\.ref).first, records: c.map(\.record.id), documents: docs)
            return Cluster(movement: m, payer: first.payer, payee: first.payee)
        }

        func totals(_ ms: [Movement]) -> [String: Decimal] {
            var t: [String: Decimal] = [:]
            for m in ms { t[m.currency, default: 0] += m.value }
            return t
        }
        func expression(_ ms: [Movement]) -> String? {
            guard !ms.isEmpty else { return nil }
            let byCurrency = Dictionary(grouping: ms, by: \.currency)
            return byCurrency.keys.sorted().compactMap { cur in
                CaseAgent.sum(plus: (byCurrency[cur] ?? []).map(\.term), minus: [])?.expression
            }.joined(separator: "; ")
        }
        return order.map { r in
            let names = written.indices.filter { find($0) == r }.map { written[$0] }
            // A movement inside one party (payer and payee the same) is neither in nor out.
            let incoming = merged.filter { $0.payee == r && $0.payer != r }.map(\.movement)
            let outgoing = merged.filter { $0.payer == r && $0.payee != r }.map(\.movement)
            let inT = totals(incoming), outT = totals(outgoing)
            var keptT: [String: Decimal] = [:]
            var keptText: String?
            if !incoming.isEmpty && !outgoing.isEmpty {
                for cur in Set(inT.keys).union(outT.keys) { keptT[cur] = (inT[cur] ?? 0) - (outT[cur] ?? 0) }
                keptText = keptT.keys.sorted().map { cur in
                    CaseAgent.format(inT[cur] ?? 0, cur.isEmpty ? nil : cur) + " − " + CaseAgent.format(outT[cur] ?? 0, cur.isEmpty ? nil : cur)
                        + " = " + CaseAgent.format(keptT[cur] ?? 0, cur.isEmpty ? nil : cur)
                }.joined(separator: "; ")
            }
            let balanceRecords = money.filter { $0.role == "balance" && (member($0.to, of: r) || ($0.to == nil && member($0.from, of: r))) }
            let balances = balanceRecords.map { b -> String in
                let t = b.text.lowercased()
                let label = t.contains("opening") ? " (opening balance)" : t.contains("closing") ? " (closing balance)" : " (balance)"
                return "\(b.dateText ?? "undated") \(b.relation ?? "")\(label)"
            }
            var recordIDs: [UUID] = (incoming + outgoing).flatMap(\.records)
            recordIDs += balanceRecords.map(\.id)
            var accounts: [String] = []
            for n in names { for a in partyKey(n).accounts where !accounts.contains(a) { accounts.append(a) } }
            var docs: [UUID] = []
            for d in (incoming + outgoing).flatMap(\.documents) + balanceRecords.compactMap(\.document) where !docs.contains(d) { docs.append(d) }
            var flow = PartyFlow(name: names[0], names: names, accounts: accounts, moneyIn: expression(incoming), moneyOut: expression(outgoing),
                                 kept: keptText, keptTotals: keptT, inTotals: inT, outTotals: outT, balances: balances,
                                 records: recordIDs, documents: docs)
            flow.incoming = incoming; flow.outgoing = outgoing
            return flow
        }
    }

    /// One party's line, for the briefing and the question task: "Ardmore Project Services Ltd (also written …): kept (in −
    /// out) EUR 600,000 − EUR 550,000 = EUR 50,000; money in EUR 600,000 (2026-09-03, recorded in [D2] [D3] [D5]); …".
    /// Accuracy G1: each movement once, with every document that records it; one column per currency.
    public static func flowLine(_ f: PartyFlow, number: [UUID: Int]) -> String {
        var head = f.name
        let others = f.names.dropFirst()
        if !others.isEmpty { head += " (also written: " + others.prefix(3).joined(separator: "; ") + ")" }
        func docTags(_ ids: [UUID]) -> String {
            Array(Set(ids.compactMap { number[$0] })).sorted().map { "[D\($0)]" }.joined(separator: " ")
        }
        func list(_ ms: [Movement]) -> String {
            guard !ms.isEmpty else { return "none recorded" }
            let byCurrency = Dictionary(grouping: ms, by: \.currency)
            return byCurrency.keys.sorted().map { cur in
                let items = byCurrency[cur] ?? []
                let terms = items.map { m -> String in
                    let tags = docTags(m.documents)
                    let detail = [m.date, tags.isEmpty ? nil : (m.documents.count > 1 ? "recorded in " + tags : tags)].compactMap { $0 }.joined(separator: ", ")
                    return m.term + (detail.isEmpty ? "" : " (\(detail))")
                }
                let total = CaseAgent.format(items.reduce(Decimal(0)) { $0 + $1.value }, cur.isEmpty ? nil : cur)
                return terms.joined(separator: " + ") + (items.count > 1 ? " = " + total : "")
            }.joined(separator: "; ")
        }
        var parts: [String] = []
        // Kept first (the line may be shortened for length; the per-party result must survive).
        if let kept = f.kept {
            parts.append(f.keptTotals.count == 1 ? "kept (in − out) " + kept : "kept (in − out, per currency) " + kept + " (currencies never added together)")
        }
        parts.append("money in " + list(f.incoming))
        parts.append("money out " + list(f.outgoing))
        if !f.balances.isEmpty { parts.append("balances quoted: " + f.balances.joined(separator: ", ")) }
        let tags = docTags(f.documents)
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

// MARK: - Accuracy G2: each document's own day/month order

/// Accuracy G2 (FAIR4 §5 item 4, 2026-11-25) — a numeric date such as "03/09/2026" is read in its document's own order:
/// day-first when the document writes a day over 12 first ("13/03/2026", "30/09/2026") or day-month words ("13 Mar",
/// "08 Jul 26"), or — with no date evidence — names a non-US currency or bank format (€, £, ₹, EUR, GBP, INR, AUD, IBAN,
/// BSB …); month-first only when the document writes a month first that cannot be a day ("09/30/2026") or month-day words
/// ("March 13, 2026"), or with no date evidence is US-styled (USD, "U.S."). Unknown: both readings are kept (`Day.readings`).
public nonisolated enum DateOrder {
    typealias Day = VerifiedAnswerComposer.Day

    /// true = day-first, false = month-first, nil = cannot tell.
    public static func dayFirst(_ text: String) -> Bool? {
        func count(_ pattern: String, in text: String = text, _ test: ([String]) -> Bool) -> Int {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
            let ns = text as NSString
            return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { m in
                test((0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) })
            }.count
        }
        let numeric = #"(?<![\d.])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?![\d])"#
        let dayFirstNumeric = count(numeric) { g in (Int(g[1]) ?? 0) > 12 && (1...12).contains(Int(g[2]) ?? 0) }
        let monthFirstNumeric = count(numeric) { g in (Int(g[2]) ?? 0) > 12 && (1...12).contains(Int(g[1]) ?? 0) }
        if dayFirstNumeric > 0 && monthFirstNumeric == 0 { return true }
        if monthFirstNumeric > 0 && dayFirstNumeric == 0 { return false }
        if dayFirstNumeric > 0 && monthFirstNumeric > 0 { return nil }
        let month = VerifiedAnswerComposer.monthAlternation
        let dayWordPattern = #"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?"# + month + #"(?:,?\s*\d{4}\b|\s+\d{2}\b)?"#
        let dayWord = count(dayWordPattern) { _ in true }
        // "08 Jul 26" is day-month-year, never "Jul 26": month-day words are read with the day-month ones taken out.
        let rest = text.replacingOccurrences(of: dayWordPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        let wordDay = count(#"\b"# + month + #"\s+\d{1,2}(?:st|nd|rd|th)?\b(?![,.]?\d{3})"#, in: rest) { _ in true }
        if dayWord > wordDay { return true }
        if wordDay > dayWord { return false }
        // No date evidence: the document's currency or bank format.
        let nonUS = #"[€£₹]|\b(?:EUR|GBP|INR|AUD|NZD|SGD|IBAN|BSB|SEPA|Rs\.?)\b"#
        let us = #"\bUSD\b|\bU\.S\.|\bUS\$"#
        let n = text.range(of: nonUS, options: .regularExpression) != nil, u = text.range(of: us, options: .regularExpression) != nil
        if n && !u { return true }
        if u && !n { return false }
        return nil
    }

    /// The date in its document's order: a swappable date is fixed when the order is known.
    static func resolved(_ d: Day, dayFirst: Bool?) -> Day {
        guard d.swappable, let day = d.day, let df = dayFirst else { return d }
        return df ? Day(year: d.year, month: day, day: d.month) : Day(year: d.year, month: d.month, day: day)
    }

    /// The same day under some reading of each (a missing year matches any year).
    static func sameDay(_ a: Day, _ b: Day) -> Bool {
        a.readings.contains { x in b.readings.contains { y in x.month == y.month && x.day == y.day } } && (a.year == nil || b.year == nil || a.year == b.year)
    }

    /// The fewest days between some reading of each (nil when a day is missing).
    static func daysApart(_ a: Day, _ b: Day) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var best: Int?
        for x in a.readings { for y in b.readings {
            guard let dx = x.day, let dy = y.day,
                  let da = cal.date(from: DateComponents(year: a.year ?? b.year ?? 2000, month: x.month, day: dx)),
                  let db = cal.date(from: DateComponents(year: b.year ?? a.year ?? 2000, month: y.month, day: dy)),
                  let n = cal.dateComponents([.day], from: da, to: db).day else { continue }
            best = min(best ?? Int.max, abs(n))
        } }
        return best
    }

    /// "2026-09-03"; an unresolved swappable date shows both readings ("2026-03-09 or 2026-09-03").
    static func show(_ d: Day) -> String {
        func one(_ m: Int, _ day: Int?) -> String {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            guard let y = d.year else { return "\(day.map(String.init) ?? "") \(months[max(0, min(11, m - 1))]) (no year)" }
            return String(format: "%04ld-%02ld-%02ld", y, m, day ?? 1)
        }
        return d.readings.map { one($0.month, $0.day) }.joined(separator: " or ")
    }
}
