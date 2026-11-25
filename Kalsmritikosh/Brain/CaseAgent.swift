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
    /// AI split AI-48 — a money record is a fact with this entity type: `role` the AI's classification (payment, receipt …),
    /// `relation` the amount as written, `from` / `to` the parties, `dateText` the date. The app sums it (CaseAIUnderstanding).
    public static let moneyType = "money"

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
    /// ALCOA ALC-02 — who and what made the record: the AI run (case_ai_runs), the model asked for and the model the
    /// provider says answered, the SHA-256 of the request the reply answered (before masking), the agent instructions'
    /// version, and who asked. nil on records made before v211 ("not recorded").
    public var runID: UUID? = nil
    public var modelRequested: String? = nil
    public var modelServed: String? = nil
    public var requestSHA256: String? = nil
    public var promptVersion: String? = nil
    public var requestedBy: String? = nil

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

    /// ALCOA ALC-09 — the reason shown when the loop used every tool step while the AI was still asking for tools.
    public static func stepLimitNote(_ steps: Int) -> String {
        "the AI used all \(steps) tool step\(steps == 1 ? "" : "s") (the step limit) and had to answer with what it had by then"
    }
    /// ALCOA ALC-09 — the reason shown when the cost ceiling stopped further tool steps.
    public static func ceilingNote(_ ceiling: Int, steps: Int) -> String {
        "the cost ceiling (about \(ceiling.formatted()) tokens for this question) was reached after \(steps) tool step\(steps == 1 ? "" : "s"); "
            + "the AI had to answer without more tools"
    }
    /// ALCOA ALC-09 — the reason shown when part of the case picture failed.
    public static func pictureFailedNote(_ documents: Int) -> String {
        "a part of the AI case picture failed — \(documents) document\(documents == 1 ? " was" : "s were") not read for the case picture"
    }

    /// The fingerprint of one document's text (the picture re-reads a document whose fingerprint changed).
    public static func fingerprint(_ text: String) -> String { sha256(text) }

    /// ALCOA ALC-02 — the version of the agent's instructions (the tool guide and the case header), stored on every run and
    /// record: it changes whenever the wording the AI is given changes.
    public static let promptVersion: String = "case-agent/" + String(sha256(guide(write: true) + "\u{1E}" + guide(write: false)
                                                                           + "\u{1E}" + CaseReader.header).prefix(12))

    /// ALCOA ALC-02 — the SHA-256 of one request as the app built it (the case blocks, then the task), before masking.
    public static func requestDigest(prefix: [String], suffix: String) -> String {
        var h = SHA256()
        for block in prefix { h.update(data: Data(block.utf8)); h.update(data: Data([0x1E])) }
        h.update(data: Data(suffix.utf8))
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

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
        /// ISO 4217 code (INR, USD, EUR, GBP, AUD …) or nil when the text names none — or names only an ambiguous symbol.
        public let currency: String?
        /// The text the amount was read from.
        public let text: String
        /// ALCOA ALC-03 — an ambiguous symbol ("$", "Rs", "¥", "kr") with no code: the codes it may stand for. The app never
        /// guesses; a sum reports "currency unclear" unless the document or the AI names the code.
        public var candidates: [String] = []
        /// The ambiguous symbol as written ("$", "Rs.").
        public var symbol: String? = nil
        public var isCurrencyUnclear: Bool { currency == nil && !candidates.isEmpty }
    }

    /// Every ISO 4217 code Foundation knows (plus a few it may lack).
    static let isoCodes: Set<String> = Set(Locale.commonISOCurrencyCodes).union(["INR", "USD", "EUR", "GBP", "AUD", "CAD", "SGD", "HKD", "NZD",
        "JPY", "CNY", "CHF", "SEK", "NOK", "DKK", "ISK", "PKR", "LKR", "NPR", "BDT", "AED", "SAR", "ZAR", "BRL", "MXN", "KRW", "RUB", "TRY"])

    /// Unambiguous symbols and words → code.
    static let clearSymbols: [String: String] = [
        "₹": "INR", "€": "EUR", "£": "GBP", "us$": "USD", "a$": "AUD", "au$": "AUD", "c$": "CAD", "ca$": "CAD", "s$": "SGD",
        "hk$": "HKD", "nz$": "NZD", "r$": "BRL", "₩": "KRW", "₽": "RUB", "₺": "TRY", "₱": "PHP", "₦": "NGN", "₫": "VND", "₪": "ILS",
        "฿": "THB", "zł": "PLN", "kč": "CZK", "৳": "BDT", "euros": "EUR", "euro": "EUR", "pounds sterling": "GBP", "pounds": "GBP",
        "yen": "JPY", "yuan": "CNY", "renminbi": "CNY", "swiss francs": "CHF", "dirhams": "AED", "riyals": "SAR"]

    /// Ambiguous symbols and words → the codes they may stand for.
    static let ambiguousSymbols: [String: [String]] = {
        let dollar = ["USD", "AUD", "CAD", "NZD", "SGD", "HKD", "MXN", "TWD", "ARS", "CLP", "COP"]
        let rupee = ["INR", "PKR", "LKR", "NPR", "MUR", "SCR"]
        return ["$": dollar, "dollars": dollar, "dollar": dollar, "rs": rupee, "rs.": rupee, "₨": rupee, "rupees": rupee, "rupee": rupee,
                "¥": ["JPY", "CNY"], "kr": ["SEK", "NOK", "DKK", "ISK"], "kr.": ["SEK", "NOK", "DKK", "ISK"]]
    }()

    /// A written number in any common style, most specific first (shared by amounts and stated figures).
    static let numberStyles: [String] = [
        #"\d{1,3}(?:\.\d{3})+,\d{1,2}(?!\d)"#,                          // 1.234,56
        #"\d{1,3}(?:\.\d{3}){2,}(?![\d,.]\d)"#,                         // 1.234.567
        #"\d{1,3}(?:[ \x{00A0}\x{202F}\x{2009}]\d{3})+(?:[,.]\d{1,2})?(?!\d)"#, // 1 234,56 · 1 234.56
        #"\d{1,3}(?:['’]\d{3})+(?:\.\d+)?(?!\d)"#,                      // Swiss 1'234.56
        #"\d{1,3}(?:,\d{2})*,\d{3}(?:,\d{3})*(?:\.\d+)?(?!\d)"#,        // 1,234,567.89 · Indian 1,23,456.78
        #"\d+,\d{1,2}(?![\d,])"#,                                       // 1234,56 · 12,50
        #"\d+(?:\.\d+)?"#,
    ]

    /// Accuracy (universality, 2026-11-25): every decimal digit of any script ("٣٠٠", "۳۰۰", "३००") read as its ASCII digit,
    /// and the Arabic decimal and thousands separators as "." and "," — one UTF-16 unit for one, so ranges stay valid.
    static func asciiDigits(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value > 0x7F && ($0.properties.numericType == .decimal || $0.value == 0x066B || $0.value == 0x066C) }) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value == 0x066B { out.append(".") } else if u.value == 0x066C { out.append(",") }
            else if u.value > 0x7F, u.properties.numericType == .decimal, u.utf16.count == 1,
                    let v = u.properties.numericValue, let d = Unicode.Scalar(UInt32(48 + Int(v))) { out.append(d) }
            else { out.append(u) }
        }
        return String(out)
    }

    static let amountPattern: NSRegularExpression? = {
        // Codes are matched upper-case only ("all 500 items" is not Albanian lek); symbols in any case.
        let cur = #"((?-i:[A-Z]{3})(?![A-Za-z])|US\$|AU?\$|CA?\$|S\$|HK\$|NZ\$|R\$|Rs\.?|₨|₹|\$|€|£|¥|₩|₽|₺|₱|₦|₫|₪|฿|৳|zł|Kč|kr\.?)"#
        let num = "(" + numberStyles.joined(separator: "|") + ")"
        let scale = #"(?:\s*(trillion|tn|billion|bn|mrd|million|mio|mn|thousand|k|lakhs?|lacs?|crores?|cr)\b\.?)?"#
        let after = #"(?:\s*((?-i:[A-Z]{3})(?![A-Za-z])|rupees?|dollars?|euros?|pounds sterling|pounds|yen|yuan|renminbi|swiss francs|dirhams|riyals)\b)?"#
        do { return try NSRegularExpression(pattern: "(?:" + cur + #"\s*)?"# + num + scale + after, options: [.caseInsensitive]) } catch {
            KalsmritikoshLog.brain.error("agent: the amount pattern does not compile: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    static func scaleFactor(_ s: String?) -> Decimal {
        switch s?.lowercased() {
        case "thousand", "k": return 1_000
        case "lakh", "lakhs", "lac", "lacs": return 100_000
        case "million", "mn", "mio": return 1_000_000
        case "crore", "crores", "cr": return 10_000_000
        case "billion", "bn", "mrd": return 1_000_000_000
        case "trillion", "tn": return 1_000_000_000_000
        default: return 1
        }
    }

    /// A clear currency code for a code, symbol or word; nil for an ambiguous symbol or none.
    static func currencyCode(_ s: String?) -> String? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.count == 3, raw == raw.uppercased(), isoCodes.contains(raw) { return raw }
        return clearSymbols[raw.lowercased()]
    }

    /// The codes an ambiguous symbol or word may stand for (empty when clear or none).
    static func currencyCandidates(_ s: String?) -> [String] {
        guard let raw = s?.trimmingCharacters(in: .whitespaces).lowercased() else { return [] }
        return ambiguousSymbols[raw] ?? []
    }

    /// The number as written, in any of the common styles: 1,234.56 · 1.234,56 · 1 234,56 · 1'234.56 · 1,23,456.78 · 12,50.
    static func parseNumber(_ written: String) -> Decimal? {
        posixNumber(written).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
    }

    /// The number as a plain "1234.56" string (digits, at most one "."), in any of the styles `parseNumber` reads.
    static func posixNumber(_ written: String) -> String? {
        var s = asciiDigits(written).filter { !" \u{00A0}\u{202F}\u{2009}'’".contains($0) }
        let lastDot = s.lastIndex(of: "."), lastComma = s.lastIndex(of: ",")
        if let d = lastDot, let c = lastComma {
            if c > d { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }   // 1.234,56
            else { s = s.replacingOccurrences(of: ",", with: "") }                                                  // 1,234.56
        } else if let c = lastComma {
            let tail = s[s.index(after: c)...]
            let commas = s.filter { $0 == "," }.count
            if commas == 1, (1...2).contains(tail.count) { s = s.replacingOccurrences(of: ",", with: ".") }       // 12,50 → 12.50
            else { s = s.replacingOccurrences(of: ",", with: "") }                                                  // 50,000 · 1,00,000
        } else if s.filter({ $0 == "." }).count > 1 {
            s = s.replacingOccurrences(of: ".", with: "")                                                           // 1.234.567
        }
        let sign = s.hasPrefix("-") ? "-" : ""
        let body = s.drop { $0 == "-" || $0 == "+" }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), body.filter({ $0 == "." }).count <= 1 else { return nil }
        return sign + body
    }

    /// Every amount in `text`, in order ("INR 50,000", "$2.75 million", "5 lakh", "Rs 1,00,000", "€1.234,56", "CHF 1'234.50").
    public static func amounts(in written: String) -> [Amount] {
        guard let re = amountPattern else { return [] }
        let text = asciiDigits(written)
        let ns = text as NSString
        var out: [Amount] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let written = g(2), let base = parseNumber(written) else { continue }
            let before = g(1), after = g(4)
            // A three-letter word that is not an ISO code ("INV 500") names no currency.
            let currency = currencyCode(before) ?? currencyCode(after)
            let candidates = currency == nil ? (currencyCandidates(before).isEmpty ? currencyCandidates(after) : currencyCandidates(before)) : []
            let scale = g(3)
            // A bare number with neither currency nor scale is a count, a year or a reference — not an amount.
            guard currency != nil || !candidates.isEmpty || scale != nil else { continue }
            var shown = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            // An unmatched 3-letter word before the number is not part of the amount's text.
            if let before, currency == nil, candidates.isEmpty, before.count == 3, shown.hasPrefix(before) {
                shown = String(shown.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            var a = Amount(value: base * scaleFactor(scale), currency: currency, text: shown)
            if !candidates.isEmpty { a.candidates = candidates; a.symbol = currencyCandidates(before).isEmpty ? after : before }
            out.append(a)
        }
        return out
    }

    /// The first amount of a term; a bare number counts when nothing else is there ("50000").
    public static func amount(_ term: String) -> Amount? {
        if let a = amounts(in: term).first { return a }
        guard let v = parseNumber(term.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Amount(value: v, currency: nil, text: term.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// ALCOA ALC-03 — the one code an ambiguous amount stands for, when the AI names it or the documents holding the amount
    /// name exactly one of its candidates (by code or clear symbol). nil: still unclear.
    static func resolve(_ a: Amount, hint: String?, contexts: [String]) -> String? {
        guard a.isCurrencyUnclear else { return a.currency }
        if let h = hint?.trimmingCharacters(in: .whitespaces).uppercased(), a.candidates.contains(h) { return h }
        var named: Set<String> = []
        for text in contexts {
            for code in a.candidates where text.range(of: #"(?<![A-Za-z])"# + code + #"(?![A-Za-z])"#, options: .regularExpression) != nil { named.insert(code) }
            for (symbol, code) in clearSymbols where a.candidates.contains(code)
                && text.range(of: #"(?<![A-Za-z])"# + NSRegularExpression.escapedPattern(for: symbol), options: [.regularExpression, .caseInsensitive]) != nil {
                named.insert(code)
            }
        }
        return named.count == 1 ? named.first : nil
    }

    static func format(_ v: Decimal, _ currency: String?) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal; f.usesGroupingSeparator = true
        f.groupingSeparator = ","; f.groupingSize = 3; f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
        let n = f.string(from: v as NSDecimalNumber) ?? "\(v)"
        if let currency, currency.hasPrefix(unclearPrefix) {
            return String(currency.dropFirst(unclearPrefix.count)) + n + " (currency unclear)"
        }
        return (currency.map { $0 + " " } ?? "") + n
    }

    /// The totals key of an amount whose symbol is ambiguous ("?$", "?Rs") — never added to any named currency.
    static let unclearPrefix = "?"

    /// The exact total of `plus` minus `minus` (each a text with one amount). Mixed currencies are never added together:
    /// one total per currency. Terms naming no currency take the one currency the others name, said so. An ambiguous
    /// symbol ("$", "Rs") takes the code the AI gives (`currency`), or the one code the documents holding the term name
    /// (`context`), or the one compatible code the other terms name — else it is reported "currency unclear" and kept
    /// apart. Returns the result text and the totals (currency → value) — nil when no term holds an amount.
    public static func sum(plus: [String], minus: [String], currency hint: String? = nil,
                           context: (String) -> [String] = { _ in [] }) -> (text: String, totals: [String: Decimal], expression: String)? {
        var terms: [(sign: Int, amount: Amount, term: String)] = []
        var unread: [String] = []
        for (sign, list) in [(1, plus), (-1, minus)] {
            for t in list {
                if let a = amount(t) { terms.append((sign, a, t)) } else { unread.append(t) }
            }
        }
        guard !terms.isEmpty else { return nil }
        var resolvedNotes: [String] = []
        // Resolve ambiguous symbols from the AI's code or the documents.
        var codes: [String?] = terms.map { t in
            guard t.amount.isCurrencyUnclear else { return t.amount.currency }
            let r = resolve(t.amount, hint: hint, contexts: context(t.term))
            if let r { resolvedNotes.append("\u{201C}\(t.amount.text)\u{201D} read as \(r)") }
            return r
        }
        let named = Set(codes.compactMap { $0 })
        // An ambiguous symbol whose candidates include the one code the other terms name takes it (said so).
        for (i, t) in terms.enumerated() where codes[i] == nil && t.amount.isCurrencyUnclear {
            if named.count == 1, let only = named.first, t.amount.candidates.contains(only) {
                codes[i] = only; resolvedNotes.append("\u{201C}\(t.amount.text)\u{201D} read as \(only), the currency the other terms name")
            }
        }
        let clearNamed = Set(codes.compactMap { $0 })
        let hasUnclear = terms.indices.contains { codes[$0] == nil && terms[$0].amount.isCurrencyUnclear }
        let adopted = clearNamed.count == 1 && !hasUnclear && terms.indices.contains { codes[$0] == nil } ? clearNamed.first : nil
        var totals: [String: Decimal] = [:]
        var expression = ""
        var unclear: [String] = []
        for (i, t) in terms.enumerated() {
            let cur: String
            if let c = codes[i] { cur = c }
            else if t.amount.isCurrencyUnclear {
                let sym = t.amount.symbol ?? "?"
                cur = unclearPrefix + sym
                let line = "\u{201C}\(sym)\u{201D} may be " + t.amount.candidates.prefix(6).joined(separator: ", ") + (t.amount.candidates.count > 6 ? " …" : "")
                if !unclear.contains(line) { unclear.append(line) }
            } else { cur = adopted ?? "" }
            totals[cur, default: 0] += t.sign > 0 ? t.amount.value : -t.amount.value
            let shown = format(t.amount.value, cur.isEmpty ? nil : cur)
            expression += i == 0 ? (t.sign < 0 ? "− " + shown : shown) : (t.sign < 0 ? " − " : " + ") + shown
        }
        let totalText = totals.keys.sorted().map { format(totals[$0] ?? 0, $0.isEmpty ? nil : $0) }.joined(separator: "; ")
        var text = expression + " = " + totalText
        if totals.count > 1 { text += " (different currencies are never added together; one total per currency)" }
        if !unclear.isEmpty { text += " — currency unclear: " + unclear.joined(separator: "; ") + " (give the currency code, e.g. \"currency\": \"USD\")" }
        if !resolvedNotes.isEmpty { text += " (" + resolvedNotes.joined(separator: "; ") + ")" }
        if let adopted { text += " (terms naming no currency were taken as \(adopted), the currency the other terms name)" }
        if !unread.isEmpty { text += " — no amount read in: " + unread.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") }
        return (text, totals, expression + " = " + totalText)
    }

    // MARK: Rounding (EXACT) — Accuracy G5 (FAIR4 design gap, 2026-11-25)

    /// A figure as written and the precision it is stated to: "about 170 knots" → 170, stated to the nearest 10;
    /// "$1.6 million" → 1,600,000, to the nearest 100,000; "approximately $2 million" → to the nearest 1,000,000;
    /// "$1,985,754" or "167" → exact to the last digit written; "nearly 3 years" → 36 months, to the nearest 12;
    /// "2 years 11 months" → 35 months, to the nearest 1. Any number style the amounts read (1,234.56 · 1.234,56 · 1 234,56 ·
    /// 1'234.56 · 1,23,456 · any script's digits), any currency, scale words (thousand, million, lakh, crore, bn, m, k).
    /// A hedge ("about", "approximately", "around", "roughly", "nearly", "almost", "some", "circa", "~", "-odd", "or so")
    /// makes a whole number's trailing zeros imprecise; a bound ("more than", "over", "under", "at least") does not.
    /// Exact Decimal arithmetic.
    public struct StatedFigure: Sendable, Equatable {
        public let value: Decimal
        /// The rounding unit: the stated value covers value ± unit / 2.
        public let unit: Decimal
        public let currency: String?
        public let text: String
        /// ALCOA ALC-03 — the codes an ambiguous symbol ("$", "Rs", "¥") may stand for.
        public var candidates: [String] = []
        /// What is counted: "month" or "day" for a duration (value in that unit), the unit word after the number ("knot",
        /// "percent"), or nil.
        public var measure: String? = nil
        public var hedged: Bool = false
        /// A bound, not a rounded figure: "more" ("over", "more than", "at least", "exceeding") or "less" ("under", "less
        /// than", "at most", "up to").
        public var bound: String? = nil
    }

    static let boundBefore = #"(?i)(?<![\p{L}])(more than|over|above|exceeding|in excess of|at least|upwards of|not less than|no less than|under|below|less than|fewer than|at most|up to|not more than|no more than)[\s\p{Sc}A-Z.]{0,6}$"#

    static let hedgeBefore = #"(?i)(?:(?<![\p{L}])(?:about|approximately|approx\.?|around|roughly|nearly|almost|some|circa|ca\.|c\.|close to|an estimated|estimated|in the region of|of the order of|just under|just over)|~|≈)[\s\p{Sc}A-Z.]{0,6}$"#
    static let hedgeAfter = #"(?i)^(?:\s*[\p{L}%]+){0,2}?(?:\s*-?\s*odd\b|ish\b|\s+or so\b)"#
    static let scaleWords = #"trillion|billion|million|thousand|lakhs?|lacs?|crores?|mio|mrd|bn|mn|tn|cr"#
    static let durationUnits: [String: (measure: String, factor: Decimal)] = [
        "year": ("month", 12), "years": ("month", 12), "yr": ("month", 12), "yrs": ("month", 12),
        "month": ("month", 1), "months": ("month", 1), "mo": ("month", 1), "mos": ("month", 1),
        "week": ("day", 7), "weeks": ("day", 7), "wk": ("day", 7), "wks": ("day", 7), "day": ("day", 1), "days": ("day", 1),
    ]
    static let figurePattern: NSRegularExpression? = {
        let num = "(" + numberStyles.joined(separator: "|") + ")"
        let units = durationUnits.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        // A duration "2 years 11 months" / "3 years and 2 months" first; else a number with an optional scale.
        let duration = num + #"\s*("# + units + #")\b(?:,?\s*(?:and\s+)?"# + num + #"\s*("# + units + #")\b)?"#
        let plain = num + #"(?:\s*("# + scaleWords + #")\b\.?|([kmb])(?![\p{L}\d]))?"#
        do { return try NSRegularExpression(pattern: #"(?<![\p{L}\d.,'’])(?:"# + duration + "|" + plain + ")", options: [.caseInsensitive]) } catch {
            KalsmritikoshLog.brain.error("agent: the figure pattern does not compile: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }()
    /// Dates and lone years are not figures ("13 March 2026", "2026-03-13", "03/13/26", "in 2025").
    static let notFigures = #"(?i)\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b|\b\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}\b|\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?"#
        + VerifiedAnswerComposer.monthAlternation + #"(?:,?\s+\d{4})?|"# + VerifiedAnswerComposer.monthAlternation
        + #"\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?\b|"# + VerifiedAnswerComposer.monthAlternation + #",?\s+\d{4}\b|"#
        + #"\b(?:in|since|of|by|from|until|till|to|year|fy|during|early|late|mid-?|before|after|q[1-4]|h[12])\s+(?:19|20)\d{2}\b(?![\d,.])"#

    /// The precision unit of a written number: 1 / 10^(decimals); for a hedged whole number, 10^(trailing zeros), keeping
    /// one significant digit.
    static func precision(_ written: String, hedged: Bool) -> Decimal? {
        guard let posix = posixNumber(written) else { return nil }
        let parts = posix.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts.first ?? "").replacingOccurrences(of: "-", with: "")
        let decimals = parts.count > 1 ? parts[1].count : 0
        var unit: Decimal = 1
        for _ in 0..<decimals { unit /= 10 }
        if hedged, decimals == 0 {
            var zeros = 0
            for ch in whole.reversed() { if ch == "0" && zeros < whole.count - 1 { zeros += 1 } else { break } }
            for _ in 0..<zeros { unit *= 10 }
        }
        return unit
    }

    /// Every figure in `text`, in order (dates and lone years left out).
    public static func figures(in written: String) -> [StatedFigure] {
        guard let re = figurePattern else { return [] }
        let t = asciiDigits(written)
        // Blank dates and years (same length) so their digits are not read as figures.
        let blanked: String = {
            guard let d = try? NSRegularExpression(pattern: notFigures) else { return t }
            var out = t as NSString
            for m in d.matches(in: t, range: NSRange(location: 0, length: out.length)).reversed() {
                out = out.replacingCharacters(in: m.range, with: String(repeating: " ", count: m.range.length)) as NSString
            }
            return out as String
        }()
        let ns = blanked as NSString, original = t as NSString
        var out: [StatedFigure] = []
        for m in re.matches(in: blanked, range: NSRange(location: 0, length: ns.length)) {
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let before = original.substring(to: m.range.location)
            let afterText = original.substring(from: m.range.location + m.range.length)
            let boundWord = before.range(of: boundBefore, options: .regularExpression).map { String(before[$0]).lowercased() }
            let bound: String? = boundWord.map { w in
                ["under", "below", "less", "fewer", "at most", "up to", "not more", "no more"].contains { w.hasPrefix($0) } ? "less" : "more"
            }
            let hedged = bound == nil && (before.range(of: hedgeBefore, options: .regularExpression) != nil
                || afterText.range(of: hedgeAfter, options: .regularExpression) != nil)
            // The figure's text: a hedge or currency right before it, the match, and a unit word after it.
            let lead = before.range(of: #"(?i)(?:(?:about|approximately|approx\.?|around|roughly|nearly|almost|some|circa|ca\.|c\.|close to|estimated|~|≈)\s*)?(?:[\p{Sc}]|(?-i:\b[A-Z]{3}\b)|\bRs\.?|(?-i:\bUS\$|\b[ACNSHR]\$))?\s*$"#,
                                     options: .regularExpression).map { String(before[$0]) } ?? ""
            let unitWord = afterText.range(of: #"^\s*(%|per\s?cent|[\p{L}]+(?:/[\p{L}]+)?)"#, options: .regularExpression)
                .map { String(afterText[$0]).trimmingCharacters(in: .whitespaces) }
            if let n1 = g(1), let u1 = g(2).map({ $0.lowercased() }), let d1 = durationUnits[u1], let base1 = parseNumber(n1) {
                // A duration: in months (years, months) or days (weeks, days); a year mixed with days is not compared exactly.
                var value = base1 * d1.factor
                var unit = (precision(n1, hedged: hedged) ?? 1) * d1.factor
                var measure = d1.measure
                if let n2 = g(3), let u2 = g(4).map({ $0.lowercased() }), let d2 = durationUnits[u2], let base2 = parseNumber(n2) {
                    if d2.measure == d1.measure { value += base2 * d2.factor; unit = (precision(n2, hedged: false) ?? 1) * d2.factor }
                    else { measure = "mixed" }
                }
                let text = (lead + ns.substring(with: m.range)).trimmingCharacters(in: .whitespaces)
                out.append(StatedFigure(value: value, unit: unit, currency: nil, text: text, measure: measure, hedged: hedged, bound: bound))
                continue
            }
            guard let n = g(5), let base = parseNumber(n), let p = precision(n, hedged: hedged) else { continue }
            let scaleWord = (g(6) ?? g(7))?.lowercased()
            let scale: Decimal = scaleWord == "m" ? 1_000_000 : scaleWord == "k" ? 1_000 : scaleWord == "b" ? 1_000_000_000 : scaleFactor(scaleWord)
            let text = (lead + ns.substring(with: m.range)).trimmingCharacters(in: .whitespaces)
            // The currency the text names around the number (code, symbol or word), as the sum tool reads it.
            let amount = amounts(in: text + (unitWord.map { " " + $0 } ?? "")).first
            let currencyWord = amount?.currency != nil || !(amount?.candidates.isEmpty ?? true)
            var measure: String? = nil
            if let w = unitWord?.lowercased(), !currencyWord, w.count > 0 {
                let stop: Set<String> = ["in", "and", "of", "to", "the", "a", "an", "on", "or", "was", "were", "is", "are", "for", "by",
                                         "at", "from", "with", "as", "per", "each", "than", "that", "which", "who", "has", "had"]
                let firstWord = String(w.split(separator: " ").first ?? "")
                if !stop.contains(firstWord), scaleFactor(firstWord) == 1 {
                    measure = firstWord.hasPrefix("%") || firstWord.hasPrefix("per") ? "percent"
                        : (firstWord.count > 3 && firstWord.hasSuffix("s") ? String(firstWord.dropLast()) : firstWord)
                }
            }
            var f = StatedFigure(value: base * scale, unit: p * scale, currency: amount?.currency, text: text, measure: measure, hedged: hedged)
            f.candidates = amount?.candidates ?? []
            f.bound = bound
            out.append(f)
        }
        return out
    }

    public static func statedFigure(_ written: String) -> StatedFigure? { figures(in: written).first }

    /// Two figures name different currencies: two clear codes that differ, or a clear code an ambiguous symbol cannot be,
    /// or two ambiguous symbols with no code in common.
    static func differentCurrencies(_ x: StatedFigure, _ y: StatedFigure) -> Bool {
        switch (x.currency, y.currency) {
        case let (a?, b?): return a != b
        case let (a?, nil): return !y.candidates.isEmpty && !y.candidates.contains(a)
        case let (nil, b?): return !x.candidates.isEmpty && !x.candidates.contains(b)
        default: return !x.candidates.isEmpty && !y.candidates.isEmpty && Set(x.candidates).isDisjoint(with: y.candidates)
        }
    }

    static func currencyText(_ f: StatedFigure) -> String { f.currency ?? f.candidates.first.map { _ in "currency unclear" } ?? "none" }

    /// Durations in different units (months vs days) or a mixed one are never compared exactly.
    static func incomparableMeasures(_ x: StatedFigure, _ y: StatedFigure) -> Bool {
        let durations: Set<String> = ["month", "day", "mixed"]
        let a = x.measure, b = y.measure
        if a == "mixed" || b == "mixed" { return true }
        if let a, let b, durations.contains(a) || durations.contains(b) { return a != b }
        return (a.map(durations.contains) ?? false) != (b.map(durations.contains) ?? false)
    }

    /// Accuracy G5 — two written figures compared exactly: equal, different only by rounding at the stated precision, or
    /// different by more than rounding. Never a conclusion about what the difference means.
    public static func compareFigures(_ a: String, _ b: String) -> String {
        guard let x = statedFigure(a) else { return "no figure read in \u{201C}\(a)\u{201D}" }
        guard let y = statedFigure(b) else { return "no figure read in \u{201C}\(b)\u{201D}" }
        if differentCurrencies(x, y) {
            return "\u{201C}\(a)\u{201D} and \u{201C}\(b)\u{201D} are in different currencies (\(currencyText(x)), \(currencyText(y))); not compared"
        }
        if incomparableMeasures(x, y) {
            return "\u{201C}\(a)\u{201D} and \u{201C}\(b)\u{201D} are in different units (\(x.measure ?? "a number"), \(y.measure ?? "a number")); not compared exactly"
        }
        let diff = x.value > y.value ? x.value - y.value : y.value - x.value
        var unitsNote = ""
        if let u = x.measure, let v = y.measure, u != v {
            unitsNote = " (the figures name different units, \(u) and \(v) — check they measure the same thing)"
        }
        let unitName = x.measure == "month" ? " months" : x.measure == "day" ? " days" : ""
        // A bound ("over $2 million") is not a rounded figure: say on which side of it the other figure lies.
        let boundPair: (StatedFigure, StatedFigure)? = x.bound != nil ? (x, y) : y.bound != nil ? (y, x) : nil
        if let pair = boundPair, let kind = pair.0.bound {
            let b = pair.0, other = pair.1
            let side = other.value > b.value ? "above" : other.value < b.value ? "below" : "equal to"
            let inside = (kind == "more" && other.value > b.value) || (kind == "less" && other.value < b.value)
            return "\u{201C}\(b.text)\u{201D} is a bound (\(kind) than " + format(b.value, nil) + unitName + "), not a rounded figure: \u{201C}\(other.text)\u{201D} is "
                + side + " it (" + (inside ? "within" : "outside") + " the bound; difference " + format(diff, nil) + unitName + ")" + unitsNote
        }
        if diff == 0 { return "\u{201C}\(a)\u{201D} and \u{201C}\(b)\u{201D} are the same figure" + unitsNote }
        return "\u{201C}\(a)\u{201D} and \u{201C}\(b)\u{201D} differ by " + format(diff, nil) + unitName + " — " + (roundingNote(x, y) ?? "more than rounding at the stated precision ("
            + [x, y].map { "\u{201C}\($0.text)\u{201D} is stated to the nearest " + format($0.unit, nil) + unitName }.joined(separator: "; ") + ")") + unitsNote
    }

    /// "these differ only by rounding at the stated precision (…)" when the two figures' ranges overlap (|a − b| is at most
    /// half the coarser figure's rounding unit, and they differ); nil otherwise.
    public static func roundingNote(_ a: String, _ b: String) -> String? {
        guard let x = statedFigure(a), let y = statedFigure(b) else { return nil }
        return roundingNote(x, y)
    }

    static func roundingNote(_ x: StatedFigure, _ y: StatedFigure) -> String? {
        if differentCurrencies(x, y) || incomparableMeasures(x, y) || x.bound != nil || y.bound != nil { return nil }
        let diff = x.value > y.value ? x.value - y.value : y.value - x.value
        let coarse = x.unit >= y.unit ? x : y
        guard diff > 0, diff * 2 <= coarse.unit else { return nil }
        let unitName = coarse.measure == "month" ? " months" : coarse.measure == "day" ? " days" : ""
        let low = coarse.value - coarse.unit / 2, high = coarse.value + coarse.unit / 2
        return "these differ only by rounding at the stated precision (\u{201C}\(coarse.text)\u{201D} is stated to the nearest "
            + format(coarse.unit, nil) + unitName + ", so it covers " + format(low, nil) + " to " + format(high, nil) + unitName + ")"
    }

    /// Accuracy G5 — for two texts that disagree (a conflict's two quotes): the first pair of figures, one from each, that
    /// differ only by rounding at their stated precision, as a note; nil when none does.
    public static func roundingNote(between a: String, and b: String) -> String? {
        let xs = figures(in: a), ys = figures(in: b)
        guard !xs.isEmpty, !ys.isEmpty, xs.count <= 12, ys.count <= 12 else { return nil }
        // Only figures that are not the same in both texts (a figure both quote is not the disagreement).
        let xv = Set(xs.map(\.value)), yv = Set(ys.map(\.value))
        for x in xs where !yv.contains(x.value) {
            for y in ys where !xv.contains(y.value) {
                if let note = roundingNote(x, y) { return "\u{201C}\(x.text)\u{201D} vs \u{201C}\(y.text)\u{201D}: " + note }
            }
        }
        return nil
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
        {"tool": "compare_dates", "a": "...", "b": "..."} · {"tool": "compare", "a": "about 170 knots", "b": "167 knots"} (two \
        figures as written: the exact difference, and whether they differ only by rounding at the precision each is stated to) · \
        {"tool": "count", "items": [...]} or {"tool": "count", "words": "..."}.
        """
        if write {
            s += """

            WRITE (each is checked: the quote must be copied EXACTLY from the cited document, every date, amount and number \
            of the text must be in the quote, and the names must be in the quote; a rejected write comes back with the reason \
            so you can correct it): {"tool": "record_fact", "text": "...", "quote": "...", "document": N} · \
            {"tool": "record_entity", "name": "...", "type": "person|organisation|place|account|other", "role": "...", \
            "role_kind": "subject|witness|complainant|custodian|source|accountHolder|investigator|reporter|other", \
            "also_written_as": ["other spellings of the same name, each as written in a document"], \
            "quote": "...", "document": N} · {"tool": "record_money", "kind": "payment|receipt|transfer|refund|reversal|fee|invoice|claim|balance|estimate|allegation", \
            "amount": "as written", "from": "...", "to": "...", "date": "as written", "reference": "...", "quote": "...", "document": N} \
            (you classify the money; the app sums it) · {"tool": "record_event", "date": "date text as written", "what": "...", \
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
    private var stops: [String] = []
    /// ALCOA ALC-18 — each write the checker refused, with its reason (kept with the run, shown in Review AI findings).
    public struct RejectedWrite: Sendable, Equatable {
        public let tool: String
        public let document: Int?
        public let text: String?
        public let quote: String?
        public let reason: String
        public let modelServed: String?
    }
    private var rejections: [RejectedWrite] = []
    public var rejectedWrites: [RejectedWrite] { lock.withLock { rejections } }

    /// ALCOA ALC-09 — why the loop stopped before the AI was done (step limit, cost ceiling), shown as "Stopped early: …".
    public var stoppedEarly: [String] { lock.withLock { stops } }
    func noteStopped(_ why: String) { lock.withLock { if !stops.contains(why) { stops.append(why) } } }

    /// ALCOA ALC-02 — the run this loop belongs to (who asked, the model asked for, the instructions' version), stamped on
    /// every record it stores. nil = no run recorded (a test or a caller without a ledger).
    public struct RunStamp: Sendable, Equatable {
        public let runID: UUID
        public let modelRequested: String
        public let requestedBy: String
        public let promptVersion: String
        public init(runID: UUID, modelRequested: String, requestedBy: String, promptVersion: String = CaseAgent.promptVersion) {
            self.runID = runID; self.modelRequested = modelRequested; self.requestedBy = requestedBy; self.promptVersion = promptVersion
        }
    }
    private var stamp: RunStamp?
    private var usages: [CloudCallUsage] = []
    public func setRun(_ s: RunStamp?) { lock.withLock { stamp = s } }
    public var runStamp: RunStamp? { lock.withLock { stamp } }
    /// Every step's usage (the run's model calls, tokens and served models).
    public var usage: [CloudCallUsage] { lock.withLock { usages } }
    /// One step's usage (the run's totals and served models).
    func noteReply(usage: CloudCallUsage?) { if let usage { lock.withLock { usages.append(usage) } } }

    /// ALCOA ALC-14 — one exchange of the run, in order: an AI reply body, the tool calls it made, the app's results.
    public struct Exchange: Sendable, Equatable {
        public enum Kind: String, Sendable { case reply, toolCalls, toolResults }
        public let step: Int
        public let kind: Kind
        public let body: String
        public let modelServed: String?
    }
    private var exchanges: [Exchange] = []
    /// The run's exchanges so far (kept with the run: reply bodies and tool calls/results).
    public var transcript: [Exchange] { lock.withLock { exchanges } }
    func noteExchange(step: Int, _ kind: Exchange.Kind, _ body: String, served: String? = nil) {
        lock.withLock { exchanges.append(Exchange(step: step, kind: kind, body: body, modelServed: served)) }
    }
    /// The calls of one step as a readable line each (tool and its arguments).
    static func describe(_ calls: [CaseAgent.Call]) -> String {
        calls.enumerated().map { i, c in
            let args = c.fields.keys.sorted().map { k in "\(k)=\(c.fields[k]?.string ?? c.fields[k]?.strings.joined(separator: ",") ?? "…")" }
            return "#\(i + 1) \(c.tool)" + (args.isEmpty ? "" : " " + args.joined(separator: " "))
        }.joined(separator: "\n")
    }
    /// The reply a round's requests came in: the model the provider says answered it and the request it answered (the
    /// records written from it carry both).
    public struct ReplyMark: Sendable, Equatable {
        public let served: String?
        public let request: String?
        public init(served: String?, request: String?) { self.served = served; self.request = request }
    }
    func stamped(_ r: CaseAIRecord, _ mark: ReplyMark?) -> CaseAIRecord {
        let s = runStamp
        var r = r
        r.runID = s?.runID; r.modelRequested = s?.modelRequested; r.requestedBy = s?.requestedBy
        r.promptVersion = s?.promptVersion; r.modelServed = mark?.served; r.requestSHA256 = mark?.request
        return r
    }

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
    public func run(_ calls: [CaseAgent.Call], reply mark: ReplyMark? = nil) async -> String {
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
            case "compare_dates":
                let a = call.string("a") ?? "", b = call.string("b") ?? ""
                out.append(head + ": " + CaseAgent.compareDates(a, b))
                // Accuracy D2 (FAIR5 §6 item 2): a day count between two dates the case's documents write is the app's
                // arithmetic, like a sum — shown under the answer, and a conclusion's "9 days" may come from it.
                if let line = dateArithmetic(a, b) { lock.withLock { if !arithmeticLines.contains(line) { arithmeticLines.append(line) } } }
            case "compare", "compare_figures", "compare_amounts":
                let a = call.string("a") ?? call.strings("items").first ?? "", b = call.string("b") ?? call.strings("items").dropFirst().first ?? ""
                let text = CaseAgent.compareFigures(a, b)
                lock.withLock { if !arithmeticLines.contains(text) { arithmeticLines.append(text) } }
                out.append(head + ": " + text)
            case "count": out.append(head + ": " + count(call))
            case "history", "passages", "shelf":
                if let ledger { out.append(head + ": " + (await ledger([CaseReader.ToolRequest(tool: call.tool, arg: call.words)]))) }
                else { out.append(head + ": the ledger tools are not available") }
            case let t where t.hasPrefix("record_") || t == "ask_person":
                guard writesAllowed else { out.append(head + ": not available in this task"); continue }
                switch verify(call) {
                case .success(let found):
                    let record = stamped(found, mark)
                    toStore.append(record); storeLines.append(out.count)
                    out.append(head + ": stored as \(record.shortID) (\(CaseAIRecord.checkedLabel))")
                case .failure(let why):
                    let kept = RejectedWrite(tool: call.tool, document: call.int("document") ?? call.int("passage"),
                                             text: call.string("text") ?? call.string("name") ?? call.string("question"),
                                             quote: call.string("quote"), reason: why.reason, modelServed: mark?.served)
                    lock.withLock { rejectedCount += 1; rejections.append(kept) }
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
        // ALCOA ALC-03 — an ambiguous symbol takes the code the AI names, or the one code the documents holding it name.
        let texts = documents.map(\.text)
        guard let result = CaseAgent.sum(plus: p.map(\.term), minus: m.map(\.term), currency: call.string("currency"),
                                         context: { term in texts.filter { $0.contains(term) } })
        else { return "no amount could be read in the items" }
        // Where each term is written (exact text found in a case document), so the AI and the person can check it.
        let whereLines = (p.map { ("+", $0) } + m.map { ("−", $0) }).map { sign, t -> String in
            let docs = documents.enumerated().filter { $0.element.text.contains(t.term) }.map { "D\($0.offset + 1)" }
            let at = docs.isEmpty ? (t.from.isEmpty ? "not found verbatim in the documents" : t.from) : "in " + docs.prefix(6).joined(separator: ", ")
            return "  \(sign) \u{201C}\(t.term)\u{201D} — \(at)"
        }
        lock.withLock { if !arithmeticLines.contains(result.expression) { arithmeticLines.append(result.expression) } }
        // Accuracy G5: one figure minus another — say whether they differ only by rounding at their stated precision.
        var rounding = ""
        if p.count == 1, m.count == 1, let note = CaseAgent.roundingNote(p[0].term, m[0].term) { rounding = "\n" + note }
        return result.text + rounding + "\n" + whereLines.joined(separator: "\n")
    }

    /// Accuracy D2 — the app's arithmetic line for two dates ("“3 Mar 2026” → “13 Mar 2026” = 10 days", earlier first), or
    /// nil when a day count cannot be made (a day or year missing) or a date is not written in any of the case's documents
    /// (the line backs a conclusion's dates, so each must be one the documents write).
    func dateArithmetic(_ a: String, _ b: String) -> String? {
        guard let x = CaseAgent.day(a), let y = CaseAgent.day(b), x.day != nil, y.day != nil, x.year != nil, y.year != nil,
              let days = CaseLedgerBriefing.days(from: x, to: y) else { return nil }
        let written = documentDays()
        func inDocuments(_ d: VerifiedAnswerComposer.Day) -> Bool { written.contains { w in d.matches(w) { $0 == w.year } } }
        guard inDocuments(x), inDocuments(y) else { return nil }
        let (first, second) = days >= 0 ? (a, b) : (b, a)
        let n = abs(days)
        return "\u{201C}\(first)\u{201D} → \u{201C}\(second)\u{201D} = \(n) day\(n == 1 ? "" : "s")"
    }

    private var daysWritten: [VerifiedAnswerComposer.Day]?
    /// Every full date the case's documents write (read once per run).
    func documentDays() -> [VerifiedAnswerComposer.Day] {
        if let cached = lock.withLock({ daysWritten }) { return cached }
        let all = documents.flatMap { VerifiedAnswerComposer.values(in: $0.text).dates.filter { $0.day != nil && $0.year != nil } }
        lock.withLock { daysWritten = all }
        return all
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

    /// AI-48 — the money kinds the AI classifies into (CaseMoneyKind's raw values).
    static let moneyKinds = ["payment", "receipt", "transfer", "refund", "reversal", "fee", "invoice", "claim", "reserve", "balance",
                             "quotation", "allegation", "estimate", "asset"]
    /// AI-48 — the role kinds of a person in a case (CasePersonRoleKind's raw values).
    static let roleKinds = ["subject", "witness", "complainant", "custodian", "source", "accountHolder", "investigator", "reporter", "other"]

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
                // AI split AI-48: the AI's role kind (stored in `relation`) and the other spellings it says are the same
                // (stored in `supporting`; each must be written in some document of the case).
                var roleKind: String?
                if let k = call.string("role_kind") {
                    guard let kind = Self.roleKinds.first(where: { $0.lowercased() == k.lowercased() }) else {
                        return fail("role_kind must be one of " + Self.roleKinds.joined(separator: ", "))
                    }
                    roleKind = kind
                }
                let aliases = call.strings("also_written_as").filter { VerifiedRecordExtractor.normalized($0) != VerifiedRecordExtractor.normalized(name) }
                for a in aliases where !documents.contains(where: { contains($0.text, a) }) {
                    return fail("\u{201C}\(a)\u{201D} is not written in any document of the case")
                }
                return .success(CaseAIRecord(kind: .entity, text: name, entityType: type, role: call.string("role"), relation: roleKind, quote: q,
                                             document: documents[n - 1].objectID, supporting: aliases, origin: origin, documentFingerprint: fp(n)))
            }
        case "record_money":
            guard let amount = call.string("amount") else { return fail("no amount") }
            let rawKind = (call.string("kind") ?? "").lowercased()
            guard let kind = Self.moneyKinds.first(where: { $0 == rawKind }) else { return fail("kind must be one of " + Self.moneyKinds.joined(separator: ", ")) }
            guard CaseAgent.amount(amount) != nil else { return fail("no amount could be read in \u{201C}\(amount)\u{201D}") }
            let date = call.string("date")
            switch checkQuote(text: amount + (date.map { " " + $0 } ?? ""), quote: quote, document: doc) {
            case .failure(let r): return .failure(r)
            case .success(let (n, q)):
                guard contains(q, amount) else { return fail("the amount \u{201C}\(amount)\u{201D} is not in the quote as written") }
                if let date, !contains(q, date) { return fail("the date text \u{201C}\(date)\u{201D} is not in the quote as written") }
                let from = call.string("from"), to = call.string("to")
                let text = [from, to].compactMap { $0 }.joined(separator: " → ") + (from == nil && to == nil ? "" : ": ") + amount + " (\(kind))"
                    + (call.string("reference").map { ", ref " + $0 } ?? "")
                return .success(CaseAIRecord(kind: .fact, text: text, entityType: CaseAIRecord.moneyType, role: kind, dateText: date, from: from, to: to,
                                             relation: amount, quote: q, document: documents[n - 1].objectID, origin: origin, documentFingerprint: fp(n)))
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

// MARK: - ALCOA ALC-09: picture parts that failed

/// The documents whose case-picture part failed (case → document → when), so the next answer says "Stopped early: … K
/// documents not read". In memory only (no document text; ids alone); cleared when a later picture read succeeds, when
/// the case is erased, and at quit.
public nonisolated final class CasePictureFailures: @unchecked Sendable {
    public static let shared = CasePictureFailures()
    private let lock = NSLock()
    private var failed: [UUID: Set<UUID>] = [:]

    public init() {}

    public func record(caseID: UUID, documents: [UUID]) {
        guard !documents.isEmpty else { return }
        lock.withLock { failed[caseID, default: []].formUnion(documents) }
    }
    public func clear(caseID: UUID, documents: [UUID]) {
        lock.withLock {
            failed[caseID]?.subtract(documents)
            if failed[caseID]?.isEmpty == true { failed[caseID] = nil }
        }
    }
    public func forget(caseID: UUID) { lock.withLock { failed[caseID] = nil } }
    public func documents(caseID: UUID) -> Set<UUID> { lock.withLock { failed[caseID] ?? [] } }
}
