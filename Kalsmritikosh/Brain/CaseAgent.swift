//
//  CaseAgent.swift
//  Kalsmritikosh
//
//  AI split AI-44 (owner 2026-11-23) — the agent loop's tools. The AI does the thinking; the app does the exact work.
//  The relay never forwards a provider's own "tools", so the reader asks for tools in its JSON reply
//  ({"status": "need_tools", "requests": [...]}) and the app answers them here, on this Mac, in the next request's task.
//
//    READ   search(words) · read(document, start/end or page) · list_documents · timeline(subject) · field(name)
//           (+ the older ledger tools: history, passages, shelf — answered by the injected ledger closure)
//    EXACT  sum(items, minus) — the app parses each amount (currency, scale words: thousand, million, billion, lakh,
//           crore) and returns the exact total with every term · compare_dates(a, b) · count(items | words)
//    WRITE  record_fact · record_entity · record_event · record_relationship · record_conflict · record_hypothesis ·
//           record_task · ask_person
//
//  Every WRITE passes the mechanical verifier before it is stored (`CaseAIRecord`, "found by AI, quote checked"): the
//  quote verbatim in the cited document (VerifiedAnswerComposer.whyNot — at least 12 characters, every date, amount and
//  number of the text inside the quote), and the names / date text it states present in the quote. A rejected write goes
//  back to the AI with the reason, so it can correct it in its next step. Nothing here decides what is true.
//
//  No model names here (capability discipline). Document text never goes to the log.
//

import Foundation
import CryptoKit
import os

// MARK: - A record the AI made (stored only after the verifier passed it)

public nonisolated struct CaseAIRecord: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case fact, entity, event, relationship, conflict, hypothesis, task, question
    }
    public static let checkedLabel = "found by AI, quote checked"

    public var id: UUID
    public var kind: Kind
    /// The statement (fact), name (entity), what happened (event), the relation sentence, the conflict's why, the
    /// hypothesis, the task or the question for the person.
    public var text: String
    public var entityType: String?
    public var role: String?
    public var dateText: String?
    public var from: String?
    public var to: String?
    public var relation: String?
    public var quote: String?
    public var document: UUID?
    public var quoteB: String?
    public var documentB: UUID?
    /// A hypothesis's quotes for and against (each found verbatim in a case document).
    public var supporting: [String]
    public var against: [String]
    /// "picture" (the background case picture) or "question" (written while answering a question).
    public var origin: String
    /// SHA-256 of the cited document's text when recorded.
    public var documentFingerprint: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, entityType: String? = nil, role: String? = nil, dateText: String? = nil,
                from: String? = nil, to: String? = nil, relation: String? = nil, quote: String? = nil, document: UUID? = nil,
                quoteB: String? = nil, documentB: UUID? = nil, supporting: [String] = [], against: [String] = [],
                origin: String = "question", documentFingerprint: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.entityType = entityType; self.role = role; self.dateText = dateText
        self.from = from; self.to = to; self.relation = relation; self.quote = quote; self.document = document
        self.quoteB = quoteB; self.documentB = documentB; self.supporting = supporting; self.against = against
        self.origin = origin; self.documentFingerprint = documentFingerprint; self.createdAt = createdAt
    }

    /// One row per statement: the same kind, words, quote and document is not stored twice.
    public var keyDigest: String {
        let parts = [kind.rawValue, VerifiedRecordExtractor.normalized(text), VerifiedRecordExtractor.normalized(quote ?? ""),
                     document?.uuidString ?? "", VerifiedRecordExtractor.normalized(quoteB ?? ""), documentB?.uuidString ?? "",
                     VerifiedRecordExtractor.normalized(dateText ?? ""), VerifiedRecordExtractor.normalized(from ?? ""),
                     VerifiedRecordExtractor.normalized(to ?? "")]
        return CaseAgent.sha256(parts.joined(separator: "\u{1E}"))
    }

    /// The short id the AI may name in `sum` ("R-1a2b3c4d").
    public var shortID: String { "R-" + id.uuidString.prefix(8).lowercased() }
}

// MARK: - The agent's tools

public nonisolated enum CaseAgent {

    /// At most this many tool rounds per question (then the AI must answer).
    public static let maxRounds = 8
    /// At most this many tool rounds for one part of the case picture.
    public static let pictureRounds = 6
    /// The reply budget of one picture step (many WRITE requests).
    public static let pictureReplyTokens = 8_000
    /// At most this many requests answered per round.
    public static let maxRequestsPerRound = 40

    /// The most tokens one question may send, counting every round (a cost ceiling from the plan's limit): three
    /// readings of the case at its size, never less than three readings of the plan's limit's tenth.
    public static func tokenCeiling(caseTokens: Int, limit: Int) -> Int {
        max(3 * caseTokens, 3 * max(limit / 10, 20_000)) + 60_000
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The fingerprint of one document's text (the picture re-reads a document whose fingerprint changed).
    public static func fingerprint(_ text: String) -> String { sha256(text) }

    // MARK: JSON values

    public indirect enum Value: Sendable, Hashable {
        case string(String), number(Double), bool(Bool), array([Value]), object([String: Value]), null

        init(_ any: Any) {
            switch any {
            case let s as String: self = .string(s)
            case let n as NSNumber:
                if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
            case let a as [Any]: self = .array(a.map(Value.init))
            case let o as [String: Any]: self = .object(o.mapValues(Value.init))
            default: self = .null
            }
        }
        var string: String? {
            switch self {
            case .string(let s): return s
            case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
            default: return nil
            }
        }
        var int: Int? {
            switch self {
            case .number(let n): return Int(n)
            case .string(let s):
                let digits = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Document", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "D", with: "").trimmingCharacters(in: .whitespaces)
                return Int(digits)
            default: return nil
            }
        }
        var strings: [String] {
            switch self {
            case .array(let a): return a.compactMap(\.string)
            case .string(let s): return [s]
            default: return []
            }
        }
        var object: [String: Value]? { if case .object(let o) = self { return o } else { return nil } }
    }

    /// One tool request from the AI.
    public struct Call: Sendable, Hashable {
        public let tool: String
        public let fields: [String: Value]
        public init(tool: String, fields: [String: Value]) { self.tool = tool; self.fields = fields }
        func string(_ k: String) -> String? {
            fields[k]?.string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ k: String) -> Int? { fields[k]?.int }
        func strings(_ k: String) -> [String] { fields[k]?.strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? [] }
        func object(_ k: String) -> [String: Value]? { fields[k]?.object }
        /// The words of a read tool: "words", "subject", "name", "arg" or "query".
        var words: String? { string("words") ?? string("subject") ?? string("name") ?? string("arg") ?? string("query") }
    }

    /// The reply's status and tool requests (nil: not a JSON object).
    public static func parse(_ reply: String) -> (status: String, calls: [Call])? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        let root: [String: Any]
        do {
            guard let r = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            root = r
        } catch {
            KalsmritikoshLog.brain.info("agent: a reply is not JSON (\(error.localizedDescription, privacy: .public))")
            return nil
        }
        let status = (root["status"] as? String ?? "answered").lowercased()
        let raw = (root["requests"] as? [Any]) ?? (root["tools"] as? [Any]) ?? []
        let calls: [Call] = raw.compactMap { item in
            guard let o = item as? [String: Any], let tool = (o["tool"] as? String)?.trimmingCharacters(in: .whitespaces), !tool.isEmpty else { return nil }
            var fields = o.filter { $0.key != "tool" }.mapValues(Value.init)
            // A nested "args" object is flattened (some readers put the arguments there).
            if let args = fields["args"]?.object { fields.removeValue(forKey: "args"); fields.merge(args) { a, _ in a } }
            return Call(tool: tool.lowercased(), fields: fields)
        }
        return (status, calls)
    }

    // MARK: Amounts (EXACT)

    public struct Amount: Sendable, Equatable {
        public let value: Decimal
        /// ISO-like code (INR, USD, EUR, GBP) or nil when the text names none.
        public let currency: String?
        /// The text the amount was read from.
        public let text: String
    }

    static let amountPattern: NSRegularExpression? = {
        let cur = #"(INR|USD|EUR|GBP|US\$|Rs\.?|₹|\$|€|£)"#
        let num = #"(\d{1,3}(?:,\d{2,3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#
        let scale = #"(?:\s*(million|mn|billion|bn|thousand|k|lakhs?|lacs?|crores?|cr)\b\.?)?"#
        let after = #"(?:\s*(INR|USD|EUR|GBP|rupees|dollars|euros|pounds)\b)?"#
        do { return try NSRegularExpression(pattern: "(?:" + cur + #"\s*)?"# + num + scale + after, options: [.caseInsensitive]) } catch {
            KalsmritikoshLog.brain.error("agent: the amount pattern does not compile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func scaleFactor(_ s: String?) -> Decimal {
        switch s?.lowercased() {
        case "thousand", "k": return 1_000
        case "lakh", "lakhs", "lac", "lacs": return 100_000
        case "million", "mn": return 1_000_000
        case "crore", "crores", "cr": return 10_000_000
        case "billion", "bn": return 1_000_000_000
        default: return 1
        }
    }

    static func currencyCode(_ s: String?) -> String? {
        guard let s = s?.lowercased() else { return nil }
        switch s {
        case "inr", "rs", "rs.", "₹", "rupees": return "INR"
        case "usd", "us$", "$", "dollars": return "USD"
        case "eur", "€", "euros": return "EUR"
        case "gbp", "£", "pounds": return "GBP"
        default: return nil
        }
    }

    /// Every amount in `text`, in order ("INR 50,000", "$2.75 million", "5 lakh", "Rs 1,00,000", "€3,400.50").
    public static func amounts(in text: String) -> [Amount] {
        guard let re = amountPattern else { return [] }
        let ns = text as NSString
        var out: [Amount] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let digits = g(2)?.replacingOccurrences(of: ",", with: ""), let base = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { continue }
            let currency = currencyCode(g(1)) ?? currencyCode(g(4))
            let scale = g(3)
            // A bare number with neither currency nor scale is a count, a year or a reference — not an amount.
            guard currency != nil || scale != nil else { continue }
            out.append(Amount(value: base * scaleFactor(scale), currency: currency, text: ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    /// The first amount of a term; a bare number counts when nothing else is there ("50000").
    public static func amount(_ term: String) -> Amount? {
        if let a = amounts(in: term).first { return a }
        let digits = term.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        guard let v = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return Amount(value: v, currency: nil, text: term.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func format(_ v: Decimal, _ currency: String?) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal; f.usesGroupingSeparator = true
        f.groupingSeparator = ","; f.groupingSize = 3; f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
        let n = f.string(from: v as NSDecimalNumber) ?? "\(v)"
        return (currency.map { $0 + " " } ?? "") + n
    }

    /// The exact total of `plus` minus `minus` (each a text with one amount). Mixed currencies are never added together:
    /// one total per currency. Terms naming no currency take the one currency the others name, said so. Returns the
    /// result text and the totals (currency → value) — nil when no term holds an amount.
    public static func sum(plus: [String], minus: [String]) -> (text: String, totals: [String: Decimal], expression: String)? {
        var terms: [(sign: Int, amount: Amount)] = []
        var unread: [String] = []
        for (sign, list) in [(1, plus), (-1, minus)] {
            for t in list {
                if let a = amount(t) { terms.append((sign, a)) } else { unread.append(t) }
            }
        }
        guard !terms.isEmpty else { return nil }
        let named = Set(terms.compactMap(\.amount.currency))
        let adopted = named.count == 1 && terms.contains { $0.amount.currency == nil } ? named.first : nil
        var totals: [String: Decimal] = [:]
        var expression = ""
        for (i, t) in terms.enumerated() {
            let cur = t.amount.currency ?? adopted ?? ""
            totals[cur, default: 0] += t.sign > 0 ? t.amount.value : -t.amount.value
            let shown = format(t.amount.value, cur.isEmpty ? nil : cur)
            expression += i == 0 ? (t.sign < 0 ? "− " + shown : shown) : (t.sign < 0 ? " − " : " + ") + shown
        }
        let totalText = totals.keys.sorted().map { format(totals[$0] ?? 0, $0.isEmpty ? nil : $0) }.joined(separator: "; ")
        var text = expression + " = " + totalText
        if totals.count > 1 { text += " (different currencies are never added together; one total per currency)" }
        if let adopted { text += " (terms naming no currency were taken as \(adopted), the currency the other terms name)" }
        if !unread.isEmpty { text += " — no amount read in: " + unread.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") }
        return (text, totals, expression + " = " + totalText)
    }

    // MARK: Dates (EXACT)

    static func day(_ text: String) -> VerifiedAnswerComposer.Day? { VerifiedAnswerComposer.values(in: text).dates.first }

    public static func compareDates(_ a: String, _ b: String) -> String {
        guard let x = day(a) else { return "no date read in \u{201C}\(a)\u{201D}" }
        guard let y = day(b) else { return "no date read in \u{201C}\(b)\u{201D}" }
        var ca = DateComponents(), cb = DateComponents()
        ca.year = x.year; ca.month = x.month; ca.day = x.day
        cb.year = y.year; cb.month = y.month; cb.day = y.day
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        if x.year != nil, x.day != nil, y.year != nil, y.day != nil, let da = cal.date(from: ca), let db = cal.date(from: cb) {
            let days = cal.dateComponents([.day], from: da, to: db).day ?? 0
            if days == 0 { return "\u{201C}\(a)\u{201D} and \u{201C}\(b)\u{201D} are the same day" }
            return days > 0 ? "\u{201C}\(a)\u{201D} is \(days) day\(days == 1 ? "" : "s") before \u{201C}\(b)\u{201D}"
                            : "\u{201C}\(a)\u{201D} is \(-days) day\(days == -1 ? "" : "s") after \u{201C}\(b)\u{201D}"
        }
        if let ya = x.year, let yb = y.year, ya != yb {
            return "\u{201C}\(a)\u{201D} is in \(ya), \u{201C}\(b)\u{201D} in \(yb): " + (ya < yb ? "the first is earlier" : "the first is later") + " (a day or year is missing, so no day count)"
        }
        if x.year == y.year || x.year == nil || y.year == nil, x.month != y.month {
            return "by month alone \u{201C}\(a)\u{201D} is " + (x.month < y.month ? "earlier" : "later") + " (a day or year is missing, so no day count)"
        }
        return "cannot tell which is earlier: a day or year is missing"
    }

    // MARK: The tools' guide (the task text the AI reads)

    public static func guide(write: Bool) -> String {
        var s = """
        Tools (answered by the app on this Mac): instead of answering you may reply ONLY \
        {"status": "need_tools", "requests": [{"tool": "...", ...}]} with at most \(maxRequestsPerRound) requests; the results come \
        back in your next task. At most \(maxRounds) steps; then you must answer.
        READ: {"tool": "search", "words": "..."} · {"tool": "read", "document": N, "start": 0, "end": 6000} or "page": P · \
        {"tool": "list_documents"} · {"tool": "timeline", "subject": "..."} · {"tool": "field", "name": "..."}.
        EXACT (use these instead of doing arithmetic yourself): {"tool": "sum", "items": ["INR 50,000", "R-1a2b3c4d"], \
        "minus": ["INR 50,000"]} (each item an amount copied from a document, or a record id; the app reads the currency and \
        scale words such as million, lakh, crore and returns the exact total with every term) · \
        {"tool": "compare_dates", "a": "...", "b": "..."} · {"tool": "count", "items": [...]} or {"tool": "count", "words": "..."}.
        """
        if write {
            s += """

            WRITE (each is checked: the quote must be copied EXACTLY from the cited document, every date, amount and number \
            of the text must be in the quote, and the names must be in the quote; a rejected write comes back with the reason \
            so you can correct it): {"tool": "record_fact", "text": "...", "quote": "...", "document": N} · \
            {"tool": "record_entity", "name": "...", "type": "person|organisation|place|account|other", "role": "...", \
            "quote": "...", "document": N} · {"tool": "record_event", "date": "date text as written", "what": "...", \
            "quote": "...", "document": N} · {"tool": "record_relationship", "from": "...", "to": "...", "kind": "...", \
            "quote": "...", "document": N} · {"tool": "record_conflict", "a": {"quote": "...", "document": N}, \
            "b": {"quote": "...", "document": M}, "why": "..."} · {"tool": "record_hypothesis", "text": "...", \
            "for": ["quote", ...], "against": ["quote", ...]} · {"tool": "record_task", "text": "..."} · \
            {"tool": "ask_person", "question": "..."}.
            """
        }
        return s
    }
}

// MARK: - The executor (one question, or one picture run)

/// Answers the AI's tool requests over the case's documents (numbered as the reader sees them) and the ledger. Holds the
/// app-computed arithmetic of the run, shown under the answer.
public nonisolated final class CaseAgentTools: @unchecked Sendable {
    public let documents: [CaseReader.Document]
    /// The older ledger tools (history, field, timeline, passages, shelf), already limited to the case's documents.
    let ledger: (@Sendable ([CaseReader.ToolRequest]) async -> String)?
    /// The case's stored AI records (for timeline, field and record ids in sum).
    let storedRecords: (@Sendable () async -> [CaseAIRecord])?
    /// Store verified records; returns false when they could not be stored (the AI is told).
    let store: (@Sendable ([CaseAIRecord]) async -> Bool)?
    let origin: String
    let writesAllowed: Bool

    private let lock = NSLock()
    private var arithmeticLines: [String] = []
    private var written: [CaseAIRecord] = []
    private var rejectedCount = 0

    public init(documents: [CaseReader.Document], origin: String = "question", writesAllowed: Bool = true,
                ledger: (@Sendable ([CaseReader.ToolRequest]) async -> String)? = nil,
                storedRecords: (@Sendable () async -> [CaseAIRecord])? = nil,
                store: (@Sendable ([CaseAIRecord]) async -> Bool)? = nil) {
        self.documents = documents; self.origin = origin; self.writesAllowed = writesAllowed
        self.ledger = ledger; self.storedRecords = storedRecords; self.store = store
    }

    /// The exact sums computed in this run (shown under the answer as the app's arithmetic).
    public var arithmetic: [String] { lock.withLock { arithmeticLines } }
    /// The records verified and stored in this run.
    public var recorded: [CaseAIRecord] { lock.withLock { written } }
    public var rejected: Int { lock.withLock { rejectedCount } }

    var passages: [VerifiedAnswerComposer.Passage] { CaseReader.passages(documents) }

    func name(_ n: Int) -> String { "Document \(n)" + (documents[n - 1].fileName.map { " (\($0))" } ?? "") }

    /// Answer one round's requests: one result block per request, numbered as asked.
    public func run(_ calls: [CaseAgent.Call]) async -> String {
        var out: [String] = []
        var toStore: [CaseAIRecord] = []
        var storeLines: [Int] = []
        for (i, call) in calls.prefix(CaseAgent.maxRequestsPerRound).enumerated() {
            let head = "#\(i + 1) \(call.tool)"
            switch call.tool {
            case "search": out.append(head + ": " + search(call.words ?? ""))
            case "read": out.append(head + ": " + read(call))
            case "list_documents", "list": out.append(head + ":\n" + listDocuments())
            case "timeline": out.append(head + ": " + (await timeline(call.words ?? "")))
            case "field": out.append(head + ": " + (await field(call.words ?? "")))
            case "sum": out.append(head + ": " + (await sum(call)))
            case "compare_dates": out.append(head + ": " + CaseAgent.compareDates(call.string("a") ?? "", call.string("b") ?? ""))
            case "count": out.append(head + ": " + count(call))
            case "history", "passages", "shelf":
                if let ledger { out.append(head + ": " + (await ledger([CaseReader.ToolRequest(tool: call.tool, arg: call.words)]))) }
                else { out.append(head + ": the ledger tools are not available") }
            case let t where t.hasPrefix("record_") || t == "ask_person":
                guard writesAllowed else { out.append(head + ": not available in this task"); continue }
                switch verify(call) {
                case .success(let record):
                    toStore.append(record); storeLines.append(out.count)
                    out.append(head + ": stored as \(record.shortID) (\(CaseAIRecord.checkedLabel))")
                case .failure(let why):
                    lock.withLock { rejectedCount += 1 }
                    out.append(head + ": REJECTED — \(why.reason). Correct it and send it again, or leave it out.")
                }
            default: out.append(head + ": unknown tool")
            }
        }
        if calls.count > CaseAgent.maxRequestsPerRound {
            out.append("(\(calls.count - CaseAgent.maxRequestsPerRound) more requests were not answered: at most \(CaseAgent.maxRequestsPerRound) per step.)")
        }
        if !toStore.isEmpty {
            let ok = await store?(toStore) ?? false
            if ok {
                lock.withLock { written.append(contentsOf: toStore) }
            } else {
                for i in storeLines { out[i] = out[i].replacingOccurrences(of: ": stored as", with: ": checked but NOT stored (the ledger is not available) —") }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: READ

    func search(_ words: String) -> String {
        let terms = words.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return "no words given" }
        let phrase = words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var hits: [String] = []
        for (i, d) in documents.enumerated() {
            for line in d.text.split(separator: "\n") where hits.count < 20 {
                let l = line.lowercased()
                guard l.contains(phrase) || terms.allSatisfy({ l.contains($0) }) else { continue }
                hits.append("- [D\(i + 1)] " + String(line.trimmingCharacters(in: .whitespaces).prefix(300)))
            }
        }
        return hits.isEmpty ? "no line of the case's documents holds all of these words" : "\n" + hits.joined(separator: "\n")
    }

    static let pageCharacters = 6_000

    func read(_ call: CaseAgent.Call) -> String {
        guard let n = call.int("document") ?? call.int("arg"), n >= 1, n <= documents.count else {
            return "no such document (the case has Documents 1–\(documents.count))"
        }
        let text = documents[n - 1].text
        let pages: [Substring] = text.contains("\u{0C}") ? text.split(separator: "\u{0C}", omittingEmptySubsequences: false) : []
        if let p = call.int("page") {
            if !pages.isEmpty {
                guard p >= 1, p <= pages.count else { return "\(name(n)) has pages 1–\(pages.count)" }
                return "\(name(n)), page \(p) of \(pages.count):\n" + pages[p - 1]
            }
            let start = (p - 1) * Self.pageCharacters
            guard p >= 1, start < text.count else { return "\(name(n)) has \(max(1, (text.count + Self.pageCharacters - 1) / Self.pageCharacters)) page(s) of \(Self.pageCharacters) characters" }
            let s = text.index(text.startIndex, offsetBy: start)
            return "\(name(n)), characters \(start)–\(min(text.count, start + Self.pageCharacters)) of \(text.count):\n" + text[s...].prefix(Self.pageCharacters)
        }
        let start = max(0, min(call.int("start") ?? 0, text.count))
        let end = max(start, min(call.int("end") ?? (start + Self.pageCharacters), text.count, start + Self.pageCharacters))
        let s = text.index(text.startIndex, offsetBy: start), e = text.index(text.startIndex, offsetBy: end)
        return "\(name(n)), characters \(start)–\(end) of \(text.count):\n" + text[s..<e]
    }

    func listDocuments() -> String {
        documents.enumerated().map { i, d in
            "- Document \(i + 1)" + (d.fileName.map { ": \($0)" } ?? "") + " — \(d.text.count.formatted()) characters"
        }.joined(separator: "\n")
    }

    func number(of id: UUID?) -> Int? { id.flatMap { id in documents.firstIndex { $0.objectID == id }.map { $0 + 1 } } }

    func allRecords() async -> [CaseAIRecord] {
        var seen = Set<UUID>(), out: [CaseAIRecord] = []
        for r in (await storedRecords?() ?? []) + recorded where seen.insert(r.id).inserted { out.append(r) }
        return out
    }

    func timeline(_ subject: String) async -> String {
        let words = subject.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 }
        let events = await allRecords().filter { $0.kind == .event }.filter { r in
            words.isEmpty || words.contains { w in [r.text, r.dateText ?? "", r.quote ?? ""].contains { $0.lowercased().contains(w) } }
        }
        func key(_ r: CaseAIRecord) -> (Int, Int, Int) {
            let d = CaseAgent.day(r.dateText ?? "")
            return (d?.year ?? 9_999, d?.month ?? 13, d?.day ?? 32)
        }
        var lines = events.sorted { key($0) != key($1) ? key($0) < key($1) : $0.text < $1.text }.prefix(40).map { r in
            "- \(r.dateText ?? "undated"): \(r.text)" + (number(of: r.document).map { " [D\($0)]" } ?? "") + " (\(CaseAIRecord.checkedLabel))"
        }
        if let ledger {
            let rule = await ledger([CaseReader.ToolRequest(tool: "timeline", arg: subject)])
            if !rule.contains("nothing in this case's documents") { lines.append("Rule-made, unverified: " + rule) }
        }
        return lines.isEmpty ? "nothing recorded yet for this subject" : "\n" + lines.joined(separator: "\n")
    }

    func field(_ name: String) async -> String {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        let facts = await allRecords().filter { $0.kind == .fact || $0.kind == .entity }.filter { r in
            !words.isEmpty && words.allSatisfy { w in [r.text, r.role ?? "", r.entityType ?? ""].contains { $0.lowercased().contains(w) } }
        }
        var lines = facts.prefix(30).map { r in
            "- \(r.text)" + (r.kind == .entity ? " — \(r.entityType ?? "other")\(r.role.map { ", " + $0 } ?? "")" : "")
                + (number(of: r.document).map { " [D\($0)]" } ?? "") + " (\(r.shortID))"
        }
        if let ledger {
            let rule = await ledger([CaseReader.ToolRequest(tool: "field", arg: name)])
            if !rule.contains("nothing in this case's documents") { lines.append("Rule-made, unverified: " + rule) }
        }
        return lines.isEmpty ? "nothing recorded for \u{201C}\(name)\u{201D}" : "\n" + lines.joined(separator: "\n")
    }

    // MARK: EXACT

    func sum(_ call: CaseAgent.Call) async -> String {
        let records = await allRecords()
        func resolve(_ term: String) -> (term: String, from: String) {
            let t = term.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("r-"), let r = records.first(where: { $0.shortID.lowercased() == t.lowercased() }) {
                let source = [r.text, r.quote ?? ""].first { !CaseAgent.amounts(in: $0).isEmpty } ?? r.text
                return (CaseAgent.amounts(in: source).first?.text ?? source, "record \(r.shortID)")
            }
            return (t, "")
        }
        var plus = call.strings("items")
        if plus.isEmpty { plus = call.strings("amounts") }
        if plus.isEmpty, let arg = call.string("arg") { plus = arg.components(separatedBy: ";") }
        let minus = call.strings("minus")
        let p = plus.map(resolve), m = minus.map(resolve)
        guard let result = CaseAgent.sum(plus: p.map(\.term), minus: m.map(\.term)) else { return "no amount could be read in the items" }
        // Where each term is written (exact text found in a case document), so the AI and the person can check it.
        let whereLines = (p.map { ("+", $0) } + m.map { ("−", $0) }).map { sign, t -> String in
            let docs = documents.enumerated().filter { $0.element.text.contains(t.term) }.map { "D\($0.offset + 1)" }
            let at = docs.isEmpty ? (t.from.isEmpty ? "not found verbatim in the documents" : t.from) : "in " + docs.prefix(6).joined(separator: ", ")
            return "  \(sign) \u{201C}\(t.term)\u{201D} — \(at)"
        }
        lock.withLock { if !arithmeticLines.contains(result.expression) { arithmeticLines.append(result.expression) } }
        return result.text + "\n" + whereLines.joined(separator: "\n")
    }

    func count(_ call: CaseAgent.Call) -> String {
        let items = call.strings("items")
        if !items.isEmpty {
            let distinct = Set(items.map { VerifiedRecordExtractor.normalized($0) })
            return "\(items.count) item\(items.count == 1 ? "" : "s") given, \(distinct.count) distinct"
        }
        guard let words = call.words?.lowercased(), !words.isEmpty else { return "nothing to count" }
        var per: [String] = [], total = 0
        for (i, d) in documents.enumerated() {
            let n = d.text.lowercased().components(separatedBy: words).count - 1
            if n > 0 { per.append("D\(i + 1) ×\(n)"); total += n }
        }
        return "\u{201C}\(words)\u{201D} appears \(total) time\(total == 1 ? "" : "s") in \(per.count) document\(per.count == 1 ? "" : "s")" + (per.isEmpty ? "" : ": " + per.joined(separator: ", "))
    }

    // MARK: WRITE — the mechanical verifier

    public struct Rejected: Error, Equatable { public let reason: String }

    static let entityTypes: [String: String] = ["person": "person", "organisation": "organisation", "organization": "organisation",
                                                "company": "organisation", "place": "place", "location": "place", "account": "account",
                                                "other": "other"]

    func contains(_ haystack: String, _ needle: String) -> Bool {
        let n = VerifiedAnswerComposer.collapsedSpaces(needle)
        guard !n.isEmpty else { return false }
        return VerifiedAnswerComposer.collapsedSpaces(VerifiedRecordExtractor.normalized(haystack))
            .range(of: VerifiedRecordExtractor.normalized(n), options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The cited document and the quote, verified (verbatim, at least 12 characters, every value of `text` in the quote).
    func checkQuote(text: String, quote: String?, document: Int?) -> Result<(Int, String), Rejected> {
        guard let quote, !quote.isEmpty else { return .failure(Rejected(reason: "no quote")) }
        guard let n = document, n >= 1, n <= documents.count else { return .failure(Rejected(reason: "no such document (the case has Documents 1–\(documents.count))")) }
        let claim = VerifiedAnswerComposer.Claim(text: text, quote: quote, passage: n, about: nil)
        if let why = VerifiedAnswerComposer.whyNot(claim, passages: passages) {
            return .failure(Rejected(reason: why.replacingOccurrences(of: "passage \(n)", with: "Document \(n)")))
        }
        return .success((n, VerifiedAnswerComposer.cleanQuote(quote)))
    }

    /// The document holding a quote verbatim (any document of the case), or nil.
    func documentHolding(_ quote: String) -> Int? {
        let q = VerifiedAnswerComposer.normalized(quote)
        guard q.count >= 12 else { return nil }
        return documents.firstIndex { VerifiedAnswerComposer.normalized($0.text).contains(q) }.map { $0 + 1 }
    }

    func fp(_ n: Int) -> String { CaseAgent.fingerprint(documents[n - 1].text) }

    public func verify(_ call: CaseAgent.Call) -> Result<CaseAIRecord, Rejected> {
        func fail(_ s: String) -> Result<CaseAIRecord, Rejected> { .failure(Rejected(reason: s)) }
        let quote = call.string("quote"), doc = call.int("document") ?? call.int("passage")
        switch call.tool {
        case "record_fact":
            guard let text = call.string("text") else { return fail("no text") }
            switch checkQuote(text: text, quote: quote, document: doc) {
            case .failure(let r): return .failure(r)
            case .success(let (n, q)):
                return .success(CaseAIRecord(kind: .fact, text: text, quote: q, document: documents[n - 1].objectID, origin: origin, documentFingerprint: fp(n)))
            }
        case "record_entity":
            guard let name = call.string("name") ?? call.string("text") else { return fail("no name") }
            let rawType = (call.string("type") ?? "other").lowercased()
            guard let type = Self.entityTypes[rawType] else { return fail("type must be person, organisation, place, account or other") }
            switch checkQuote(text: name, quote: quote, document: doc) {
            case .failure(let r): return .failure(r)
            case .success(let (n, q)):
                guard contains(q, name) else { return fail("the name \u{201C}\(name)\u{201D} is not in the quote") }
                return .success(CaseAIRecord(kind: .entity, text: name, entityType: type, role: call.string("role"), quote: q,
                                             document: documents[n - 1].objectID, origin: origin, documentFingerprint: fp(n)))
            }
        case "record_event":
            guard let what = call.string("what") ?? call.string("text") else { return fail("no \"what\"") }
            guard let date = call.string("date") else { return fail("no date") }
            switch checkQuote(text: date + ": " + what, quote: quote, document: doc) {
            case .failure(let r): return .failure(r)
            case .success(let (n, q)):
                guard contains(q, date) else { return fail("the date text \u{201C}\(date)\u{201D} is not in the quote as written") }
                return .success(CaseAIRecord(kind: .event, text: what, dateText: date, quote: q, document: documents[n - 1].objectID,
                                             origin: origin, documentFingerprint: fp(n)))
            }
        case "record_relationship":
            guard let from = call.string("from"), let to = call.string("to") else { return fail("both \"from\" and \"to\" are needed") }
            let kind = call.string("kind") ?? call.string("relation") ?? "related to"
            switch checkQuote(text: "\(from) \(kind) \(to)", quote: quote, document: doc) {
            case .failure(let r): return .failure(r)
            case .success(let (n, q)):
                let text = documents[n - 1].text
                guard contains(q, from) || contains(text, from) else { return fail("\u{201C}\(from)\u{201D} is not in Document \(n)") }
                guard contains(q, to) || contains(text, to) else { return fail("\u{201C}\(to)\u{201D} is not in Document \(n)") }
                guard contains(q, from) || contains(q, to) else { return fail("neither \u{201C}\(from)\u{201D} nor \u{201C}\(to)\u{201D} is in the quote") }
                return .success(CaseAIRecord(kind: .relationship, text: "\(from) — \(kind) — \(to)", from: from, to: to, relation: kind, quote: q,
                                             document: documents[n - 1].objectID, origin: origin, documentFingerprint: fp(n)))
            }
        case "record_conflict":
            guard let a = call.object("a"), let b = call.object("b") else { return fail("both sides \"a\" and \"b\" are needed, each {\"quote\", \"document\"}") }
            guard let why = call.string("why") ?? call.string("text") else { return fail("no \"why\"") }
            let qa = a["quote"]?.string, qb = b["quote"]?.string
            let da = (a["document"] ?? a["doc"])?.int, db = (b["document"] ?? b["doc"])?.int
            guard case .success(let (na, sa)) = checkQuote(text: "side a", quote: qa, document: da) else {
                if case .failure(let r) = checkQuote(text: "side a", quote: qa, document: da) { return fail("side a: " + r.reason) }
                return fail("side a does not check out")
            }
            guard case .success(let (nb, sb)) = checkQuote(text: "side b", quote: qb, document: db) else {
                if case .failure(let r) = checkQuote(text: "side b", quote: qb, document: db) { return fail("side b: " + r.reason) }
                return fail("side b does not check out")
            }
            guard !(na == nb && VerifiedRecordExtractor.normalized(sa) == VerifiedRecordExtractor.normalized(sb)) else { return fail("the two sides are the same quote") }
            return .success(CaseAIRecord(kind: .conflict, text: why, quote: sa, document: documents[na - 1].objectID, quoteB: sb,
                                         documentB: documents[nb - 1].objectID, origin: origin, documentFingerprint: fp(na)))
        case "record_hypothesis":
            guard let text = call.string("text") else { return fail("no text") }
            let pro = call.strings("for"), con = call.strings("against")
            guard !pro.isEmpty else { return fail("a hypothesis needs at least one quote \"for\" it") }
            for q in pro + con where documentHolding(q) == nil {
                return fail("the quote \u{201C}\(q.prefix(80))\u{201D} is not in any document of the case (copy it exactly, at least 12 characters)")
            }
            let first = documentHolding(pro[0])
            return .success(CaseAIRecord(kind: .hypothesis, text: text, quote: pro[0], document: first.map { documents[$0 - 1].objectID },
                                         supporting: pro.map(VerifiedAnswerComposer.cleanQuote), against: con.map(VerifiedAnswerComposer.cleanQuote),
                                         origin: origin, documentFingerprint: first.map(fp)))
        case "record_task", "ask_person":
            guard let text = call.string("text") ?? call.string("question"), text.count <= 600 else { return fail("no text (at most 600 characters)") }
            return .success(CaseAIRecord(kind: call.tool == "ask_person" ? .question : .task, text: text, origin: origin))
        default:
            return fail("unknown write tool")
        }
    }
}
