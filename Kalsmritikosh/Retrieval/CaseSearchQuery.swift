//
//  CaseSearchQuery.swift
//  Kalsmritikosh
//
//  Living case map M5 (plan 2026-11-06 §8) — the versioned query tree of a case evidence search.
//  One tree is parsed from the text the person types (the existing advanced-search syntax), shown back
//  as a readable explanation, edited as visual rule groups, stored with a saved search, and compiled into
//  the predicates that run (CaseSearchPlan: text predicates here, parameterised SQL for the stored fields in
//  CaseSearchRepository). Nothing is evaluated from any other representation.
//
//  Strict mode: an unsupported or malformed clause REJECTS the query with a plain message. A repaired query
//  may be offered — shown, with what was changed and whether it searches more broadly — but it runs only if
//  the person chooses it. Nothing here calls a model; it is deterministic text handling.
//
//  Syntax (case search):
//    budget deadline            both words (adjacent terms are joined by AND)
//    budget AND deadline        both · budget OR forecast  either · NOT draft / -draft  without
//    "net 30"                   the words in this order        invoic*   a word starting with "invoic"
//    budget NEAR/5 deadline     at most 5 other words between them (either order; NEAR alone = 10)
//    ( … )                      grouping; operators are written in capitals (a lowercase and/or/not is a word)
//    exact:"A-17/B"             the exact characters, punctuation included
//    person:"Jane Doe"          a mention of a person or organisation (also entity:, org:)
//    type:email  file:report    the document type; the file name contains
//    tag:contract               the document, or one of its passages, carries the tag
//    modified-before:2024-01-31 the file's modified date · stated-on:2024-03  the date the document itself
//    event-after:2023           states (an email's Date) · an extracted event's date. before/on/after each.
//
//  Precedence: NEAR binds tightest, then NOT, then AND (written or implied), then OR — so
//  `a b OR c` means (a AND b) OR c. The explanation always shows the grouping that will run.
//

import Foundation

// MARK: - Options

/// How a case search matches. Fuzzy matching, stemming and semantic expansion are OFF and not available in
/// case search: they are listed so that a saved search records that they were off, and turning one on is
/// refused rather than silently ignored.
public nonisolated struct CaseSearchOptions: Codable, Sendable, Equatable, Hashable {
    /// Off: "Invoice" and "invoice" match each other. On: letter case must match.
    public var matchCase: Bool
    /// Off: "José" and "Jose" match each other. On: accents must match.
    public var matchAccents: Bool
    public var stemming: Bool
    public var fuzzy: Bool
    public var semanticExpansion: Bool
    /// The calendar used for date clauses (a day starts at midnight in this time zone).
    public var timeZoneID: String
    /// Results per page.
    public var pageSize: Int
    /// At most this many documents are searched in one run; the rest are listed as not searched.
    public var maxDocuments: Int
    /// A longer document is searched up to this many characters and listed as partly searched.
    public var maxCharactersPerDocument: Int
    /// The run stops after this long; the documents not reached are listed as not searched.
    public var timeLimitSeconds: Double
    /// Witness passages shown per document (the counts are always complete).
    public var witnessesPerDocument: Int

    public init(matchCase: Bool = false, matchAccents: Bool = false, stemming: Bool = false, fuzzy: Bool = false,
                semanticExpansion: Bool = false, timeZoneID: String = TimeZone.current.identifier, pageSize: Int = 50,
                maxDocuments: Int = 20_000, maxCharactersPerDocument: Int = 8_000_000, timeLimitSeconds: Double = 30,
                witnessesPerDocument: Int = 3) {
        self.matchCase = matchCase; self.matchAccents = matchAccents; self.stemming = stemming; self.fuzzy = fuzzy
        self.semanticExpansion = semanticExpansion; self.timeZoneID = timeZoneID; self.pageSize = pageSize
        self.maxDocuments = maxDocuments; self.maxCharactersPerDocument = maxCharactersPerDocument
        self.timeLimitSeconds = timeLimitSeconds; self.witnessesPerDocument = witnessesPerDocument
    }

    /// Why these options cannot run (empty: they can).
    public var problems: [String] {
        var out: [String] = []
        if stemming { out.append("Word-ending matching (stemming) is not available in case search; it is off so that only the words you typed are found.") }
        if fuzzy { out.append("Approximate (fuzzy) matching is not available in case search; it is off.") }
        if semanticExpansion { out.append("Matching by meaning is not available in case search; it is off.") }
        if TimeZone(identifier: timeZoneID) == nil { out.append("The time zone “\(timeZoneID)” is not known.") }
        if pageSize < 1 || pageSize > 500 { out.append("A page holds 1 to 500 results.") }
        if maxDocuments < 1 { out.append("The document limit must be at least 1.") }
        if maxCharactersPerDocument < 1 { out.append("The per-document character limit must be at least 1.") }
        if !(timeLimitSeconds > 0) { out.append("The time limit must be more than zero seconds.") }
        return out
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "UTC") ?? .current }

    /// One line for a receipt: what the matching did and did not do.
    public var summary: String {
        var parts = [matchCase ? "letter case must match" : "any letter case",
                     matchAccents ? "accents must match" : "accents ignored",
                     "no word-ending, approximate or meaning-based matching"]
        parts.append("dates in \(timeZoneID)")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Dates

public nonisolated enum CaseSearchDateKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// The file's own modified date, as the file system recorded it.
    case fileModified
    /// The date the document itself states in its own date field (an email's Date header).
    case documentStated
    /// The date of an event extracted from the document's text.
    case event

    public var keyword: String {
        switch self {
        case .fileModified: return "modified"
        case .documentStated: return "stated"
        case .event: return "event"
        }
    }

    public var label: String {
        switch self {
        case .fileModified: return "File modified date"
        case .documentStated: return "Date the document states"
        case .event: return "Event date in the text"
        }
    }
}

public nonisolated enum CaseSearchDateRelation: String, Codable, Sendable, CaseIterable, Hashable {
    case before, on, after
    public var label: String {
        switch self {
        case .before: return "before"
        case .on: return "on / in"
        case .after: return "after"
        }
    }
}

/// A date clause: which date, how it compares, and the calendar day, month or year typed (canonical
/// yyyy-MM-dd, yyyy-MM or yyyy). `before` excludes the named day/month/year; `after` excludes it too;
/// `on` is within it.
public nonisolated struct CaseSearchDate: Codable, Sendable, Hashable {
    public var kind: CaseSearchDateKind
    public var relation: CaseSearchDateRelation
    public var value: String

    public init(kind: CaseSearchDateKind, relation: CaseSearchDateRelation, value: String) {
        self.kind = kind; self.relation = relation; self.value = value
    }

    /// The typed value in canonical form, or nil when it is not a calendar date this search reads
    /// (2024-01-31, 2024-01, 2024 or 31/01/2024).
    public static func canonical(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts: [Int]
        if let m = s.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/) {
            parts = [Int(m.1) ?? 0, Int(m.2) ?? 0, Int(m.3) ?? 0]
        } else if let m = s.wholeMatch(of: /(\d{1,2})\/(\d{1,2})\/(\d{4})/) {
            parts = [Int(m.3) ?? 0, Int(m.2) ?? 0, Int(m.1) ?? 0]
        } else if let m = s.wholeMatch(of: /(\d{4})-(\d{1,2})/) {
            parts = [Int(m.1) ?? 0, Int(m.2) ?? 0]
        } else if let m = s.wholeMatch(of: /(\d{4})/) {
            parts = [Int(m.1) ?? 0]
        } else { return nil }
        guard parts[0] >= 1000, parts[0] <= 9999 else { return nil }
        if parts.count >= 2 { guard (1...12).contains(parts[1]) else { return nil } }
        if parts.count == 3 {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
            guard let d = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  cal.component(.day, from: d) == parts[2], cal.component(.month, from: d) == parts[1] else { return nil }
            return String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
        }
        if parts.count == 2 { return String(format: "%04d-%02d", parts[0], parts[1]) }
        return String(format: "%04d", parts[0])
    }

    /// The span [start, end) the canonical value covers in `zone`.
    public func span(in zone: TimeZone) -> (start: Date, end: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let p = value.split(separator: "-").compactMap { Int($0) }
        guard let year = p.first else { return nil }
        let start: Date?
        let unit: Calendar.Component
        switch p.count {
        case 3: start = cal.date(from: DateComponents(year: year, month: p[1], day: p[2])); unit = .day
        case 2: start = cal.date(from: DateComponents(year: year, month: p[1], day: 1)); unit = .month
        default: start = cal.date(from: DateComponents(year: year, month: 1, day: 1)); unit = .year
        }
        guard let s = start, let e = cal.date(byAdding: unit, value: 1, to: s) else { return nil }
        return (s, e)
    }

    /// Whether `date` satisfies the clause.
    public func holds(_ date: Date, in zone: TimeZone) -> Bool {
        guard let (s, e) = span(in: zone) else { return false }
        switch relation {
        case .before: return date < s
        case .on: return date >= s && date < e
        case .after: return date >= e
        }
    }

    /// "31 January 2024", "January 2024" or "2024".
    public var readableValue: String {
        let p = value.split(separator: "-").compactMap { Int($0) }
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        switch p.count {
        case 3: return "\(p[2]) \(months[max(0, min(11, p[1] - 1))]) \(p[0])"
        case 2: return "\(months[max(0, min(11, p[1] - 1))]) \(p[0])"
        default: return value
        }
    }

    var isDay: Bool { value.split(separator: "-").count == 3 }
}

// MARK: - The tree

/// One node of a case search. Text leaves (word, prefix, phrase, literal, near) are matched against the
/// document's text; field leaves (person, type, file, tag, date) against what the ledger records about it.
public nonisolated indirect enum CaseSearchNode: Codable, Sendable, Hashable {
    /// A whole word.
    case word(String)
    /// A word starting with the value.
    case prefix(String)
    /// Words in this order, punctuation and spacing between them ignored.
    case phrase(String)
    /// The exact characters, punctuation included (spacing runs count as one space).
    case literal(String)
    /// Two words or phrases with at most `distance` other words between them, in either order.
    case near(CaseSearchNode, CaseSearchNode, distance: Int)
    case person(String)
    case type(String)
    case file(String)
    case tag(String)
    case date(CaseSearchDate)
    case all([CaseSearchNode])
    case any([CaseSearchNode])
    case not(CaseSearchNode)

    public var isLeaf: Bool {
        switch self {
        case .all, .any, .not: return false
        default: return true
        }
    }

    public var isTextLeaf: Bool {
        switch self {
        case .word, .prefix, .phrase, .literal, .near: return true
        default: return false
        }
    }

    /// The same meaning in the one canonical shape: nested groups of the same kind merged, one-child groups
    /// removed, double negation removed. Every tree is normalised before it is shown, stored or run.
    public func normalized() -> CaseSearchNode {
        switch self {
        case .all(let c):
            let kids = c.map { $0.normalized() }.flatMap { k -> [CaseSearchNode] in if case .all(let g) = k { return g }; return [k] }
            return kids.count == 1 ? kids[0] : .all(kids)
        case .any(let c):
            let kids = c.map { $0.normalized() }.flatMap { k -> [CaseSearchNode] in if case .any(let g) = k { return g }; return [k] }
            return kids.count == 1 ? kids[0] : .any(kids)
        case .not(let x):
            let n = x.normalized()
            if case .not(let inner) = n { return inner }
            return .not(n)
        case .near(let a, let b, let d):
            return .near(a.normalized(), b.normalized(), distance: d)
        default:
            return self
        }
    }

    /// Leaves in depth-first order (the order clauses are numbered in a witness).
    public var leaves: [CaseSearchNode] {
        switch self {
        case .all(let c), .any(let c): return c.flatMap(\.leaves)
        case .not(let x): return x.leaves
        default: return [self]
        }
    }

    /// A word or phrase node for a value typed into a rule: one plain token is a word, anything else a phrase.
    public static func textTerm(_ value: String) -> CaseSearchNode {
        let v = value.trimmingCharacters(in: .whitespaces)
        if CaseSearchText.tokens(of: v, options: CaseSearchOptions()).count == 1, CaseSearchParser.isBareWord(v) { return .word(v) }
        return .phrase(v)
    }
}

/// A versioned query: the tree and the version of its meaning. Bump `currentVersion` only when the meaning
/// of an existing tree changes; a stored query of another version is refused, never reinterpreted.
public nonisolated struct CaseSearchQuery: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public let version: Int
    public let root: CaseSearchNode

    public init(root: CaseSearchNode, version: Int = CaseSearchQuery.currentVersion) {
        self.root = root.normalized(); self.version = version
    }

    /// The canonical expert text of the tree (parsing it gives the same tree).
    public var text: String { CaseSearchRenderer.text(root) }
    /// The readable explanation, one line per clause, indented by group.
    public var explanation: [String] { CaseSearchRenderer.explanation(root) }

    public func encoded() -> String {
        guard let d = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    public static func decode(_ s: String?) -> CaseSearchQuery? {
        guard let s, let d = s.data(using: .utf8) else { return nil }
        do { return try JSONDecoder().decode(CaseSearchQuery.self, from: d) } catch { return nil }
    }
}

// MARK: - Parsing (strict)

/// The result of reading what the person typed: a query, or why it cannot run (and, when one exists, a
/// repaired query to offer — never run without the person choosing it).
public nonisolated struct CaseSearchParse: Sendable, Equatable {
    public struct Repair: Sendable, Equatable {
        public let text: String
        public let query: CaseSearchQuery
        public let changes: [String]
        /// The repair drops or weakens a restriction, so it can find more than was asked for.
        public let broadens: Bool
    }
    public let query: CaseSearchQuery?
    public let errors: [String]
    public let repair: Repair?
    public var isValid: Bool { query != nil && errors.isEmpty }
}

public nonisolated enum CaseSearchParser {

    enum Tok: Equatable {
        case term(String, quoted: Bool)
        case prefix(String)
        case field(key: String, value: String)
        case and, or, not, minus
        case near(Int)
        case lparen, rparen
    }

    enum FieldKind: Equatable { case literal, person, type, file, tag, date(CaseSearchDateKind, CaseSearchDateRelation) }

    static let fieldKeys: [String: FieldKind] = {
        var m: [String: FieldKind] = [
            "exact": .literal, "literal": .literal,
            "person": .person, "entity": .person, "org": .person,
            "type": .type, "kind": .type,
            "file": .file, "filename": .file, "source": .file,
            "tag": .tag, "label": .tag,
        ]
        for k in CaseSearchDateKind.allCases {
            for r in CaseSearchDateRelation.allCases { m["\(k.keyword)-\(r.rawValue)"] = .date(k, r) }
        }
        return m
    }()

    /// Keys of the archive search that a case search does not take as they are.
    static let ambiguousDateKeys = ["before", "after"]
    static let archiveOnlyKeys = ["group", "folder"]

    /// Whether `s` can be written as a bare word (no quoting needed).
    static func isBareWord(_ s: String) -> Bool {
        guard !s.isEmpty, !["AND", "OR", "NOT", "&&", "||"].contains(s), !s.hasPrefix("NEAR"), !s.hasPrefix("-") else { return false }
        return s.allSatisfy { c in c.isLetter || c.isNumber || c.unicodeScalars.allSatisfy { $0.properties.generalCategory == .nonspacingMark } }
    }

    struct Lexed {
        var tokens: [Tok] = []
        var errors: [String] = []
        /// Token-level repairs available for the lexical errors (applied only to build an offered repair).
        var repaired: [Tok] = []
        var changes: [String] = []
        var broadens = false
    }

    static func lex(_ s: String) -> Lexed {
        var out = Lexed()
        let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]
        var i = s.startIndex
        func emit(_ t: Tok) { out.tokens.append(t); out.repaired.append(t) }
        while i < s.endIndex {
            let c = s[i]
            if c.isWhitespace { i = s.index(after: i); continue }
            if c == "(" { emit(.lparen); i = s.index(after: i); continue }
            if c == ")" { emit(.rparen); i = s.index(after: i); continue }
            if quotes.contains(c) {
                var j = s.index(after: i)
                while j < s.endIndex, !quotes.contains(s[j]) { j = s.index(after: j) }
                let body = String(s[s.index(after: i)..<j]).trimmingCharacters(in: .whitespaces)
                let closed = j < s.endIndex
                if !closed {
                    out.errors.append("A quotation mark is not closed (after “\(body.prefix(30))”).")
                    out.changes.append("closed the quotation mark")
                }
                if CaseSearchText.tokens(of: body, options: CaseSearchOptions()).isEmpty {
                    out.errors.append(body.isEmpty ? "Empty quotation marks — there is nothing in them to search for."
                                                   : "“\(body)” has no letters or digits to search for; use exact:\"\(body)\" to search for those characters.")
                    out.changes.append(body.isEmpty ? "removed the empty quotation marks" : "searched “\(body)” as exact characters")
                    if !body.isEmpty { out.tokens.append(.term(body, quoted: true)); out.repaired.append(.field(key: "exact", value: body)) }
                } else {
                    emit(.term(body, quoted: true))
                }
                i = closed ? s.index(after: j) : j
                continue
            }
            // A bare run up to whitespace, a bracket or a quotation mark.
            var k = i
            while k < s.endIndex, !s[k].isWhitespace, s[k] != "(", s[k] != ")", !quotes.contains(s[k]) { k = s.index(after: k) }
            var word = String(s[i..<k])
            var next = k
            var negated = false
            if word.hasPrefix("-"), word.count > 1 { negated = true; word.removeFirst() }
            // key:value or key:"quoted value"
            if let colon = word.firstIndex(of: ":"), colon != word.startIndex,
               word[..<colon].allSatisfy({ $0.isLetter || $0 == "-" }) {
                let key = word[..<colon].lowercased()
                var value = String(word[word.index(after: colon)...])
                if value.isEmpty, k < s.endIndex, quotes.contains(s[k]) {
                    // The quoted value runs to the closing quotation mark, across spaces and brackets.
                    var j = s.index(after: k)
                    while j < s.endIndex, !quotes.contains(s[j]) { j = s.index(after: j) }
                    value = String(s[s.index(after: k)..<j])
                    if j >= s.endIndex {
                        out.errors.append("A quotation mark after “\(key):” is not closed.")
                        out.changes.append("closed the quotation mark after “\(key):”")
                    }
                    next = j < s.endIndex ? s.index(after: j) : j
                }
                value = value.trimmingCharacters(in: .whitespaces)
                if negated { out.tokens.append(.minus); out.repaired.append(.minus) }
                lexField(key: key, value: value, into: &out)
                i = next
                continue
            }
            if !negated {
                switch word {
                case "AND", "&&": emit(.and); i = next; continue
                case "OR", "||": emit(.or); i = next; continue
                case "NOT": emit(.not); i = next; continue
                default: break
                }
                if word.hasPrefix("NEAR"), word.dropFirst(4).allSatisfy({ $0 == "/" || $0.isNumber || $0.isLetter }) {
                    let rest = word.dropFirst(4)
                    if rest.isEmpty { emit(.near(10)); i = next; continue }
                    if rest.hasPrefix("/"), let n = Int(rest.dropFirst()) {
                        if (1...100).contains(n) { emit(.near(n)) } else {
                            let clamped = max(1, min(n, 100))
                            out.errors.append("NEAR/\(n) is outside 1 to 100 words.")
                            out.changes.append("used NEAR/\(clamped) instead of NEAR/\(n)")
                            if clamped > n { out.broadens = true }
                            out.tokens.append(.near(clamped)); out.repaired.append(.near(clamped))
                        }
                        i = next; continue
                    }
                    if rest.allSatisfy({ $0.isLetter }) == false {
                        out.errors.append("“\(word)” is not a distance I can read (write NEAR/5 for at most 5 words apart).")
                        out.changes.append("used NEAR (10 words) for “\(word)”")
                        out.tokens.append(.near(10)); out.repaired.append(.near(10))
                        i = next; continue
                    }
                }
            }
            if negated { out.tokens.append(.minus); out.repaired.append(.minus) }
            lexWord(word, into: &out)
            i = next
        }
        return out
    }

    static func lexField(key: String, value: String, into out: inout Lexed) {
        if archiveOnlyKeys.contains(key) {
            out.errors.append("“\(key):” works in the archive Search only. A case search covers this case's documents; groups are not part of it.")
            out.changes.append("removed “\(key):\(value)” (searches more broadly)")
            out.broadens = true
            out.tokens.append(.field(key: key, value: value))
            return
        }
        if ambiguousDateKeys.contains(key) {
            out.errors.append("“\(key):” does not say which date. Write modified-\(key): (the file's date), stated-\(key): (the date the document states) or event-\(key): (an event's date in the text).")
            out.changes.append("used modified-\(key): (the file's modified date, as in the archive Search)")
            out.tokens.append(.field(key: key, value: value))
            out.repaired.append(.field(key: "modified-\(key)", value: value))
            return
        }
        guard let kind = fieldKeys[key] else {
            out.errors.append("“\(key):” is not a case search field. To search for the words, put them in quotation marks: \"\(key) \(value)\".")
            out.changes.append("searched “\(key):\(value)” as words in quotation marks")
            out.tokens.append(.field(key: key, value: value))
            out.repaired.append(.term("\(key) \(value)", quoted: true))
            return
        }
        guard !value.isEmpty else {
            out.errors.append("“\(key):” has no value.")
            out.changes.append("removed the empty “\(key):”")
            out.tokens.append(.field(key: key, value: value))
            return
        }
        if value.contains("\"") || value.contains("\u{201C}") || value.contains("\u{201D}") {
            out.errors.append("A value cannot contain quotation marks (“\(key):\(value)”).")
            out.changes.append("removed the quotation marks inside “\(key):”")
            let v = value.filter { !"\"\u{201C}\u{201D}".contains($0) }
            out.tokens.append(.field(key: key, value: value))
            if !v.isEmpty { out.repaired.append(.field(key: key, value: v)) }
            return
        }
        if case .date = kind, CaseSearchDate.canonical(value) == nil {
            out.errors.append("“\(value)” is not a date this search reads — write 2024-01-31, 2024-01, 2024 or 31/01/2024.")
            out.changes.append("removed “\(key):\(value)” (searches more broadly)")
            out.broadens = true
            out.tokens.append(.field(key: key, value: value))
            return
        }
        if kind == .person, CaseSearchText.tokens(of: value, options: CaseSearchOptions()).isEmpty {
            out.errors.append("“\(key):\(value)” has no letters or digits to look for.")
            out.changes.append("removed “\(key):\(value)” (searches more broadly)")
            out.broadens = true
            out.tokens.append(.field(key: key, value: value))
            return
        }
        out.tokens.append(.field(key: key, value: value)); out.repaired.append(.field(key: key, value: value))
    }

    static func lexWord(_ word: String, into out: inout Lexed) {
        var core = word
        var isPrefix = false
        if core.hasSuffix("*") { isPrefix = true; while core.hasSuffix("*") { core.removeLast() } }
        if core.contains("*") || core.contains("?") {
            out.errors.append("“\(word)”: a wildcard works only as * at the end of a word (invoic*).")
            out.changes.append("searched “\(word)” without its wildcards")
            let plain = core.filter { $0 != "*" && $0 != "?" }
            out.tokens.append(.term(word, quoted: false))
            if !plain.isEmpty { out.repaired.append(.term(plain, quoted: false)) }
            return
        }
        let toks = CaseSearchText.tokens(of: core, options: CaseSearchOptions())
        if toks.isEmpty {
            if isPrefix && core.isEmpty {
                out.errors.append("A * on its own has nothing to start with.")
                out.changes.append("removed the lone *")
            } else {
                out.errors.append("“\(word)” has no letters or digits to search for; use exact:\"\(word)\" to search for those characters.")
                out.changes.append("searched “\(word)” as exact characters")
                out.repaired.append(.field(key: "exact", value: word))
            }
            out.tokens.append(.term(word, quoted: false))
            return
        }
        if isPrefix {
            guard toks.count == 1, let core1 = CaseSearchText.firstTokenText(of: core) else {
                out.errors.append("“\(word)”: a word ending in * must be a single word (letters and digits).")
                out.changes.append("searched “\(core)” as words in this order, without the *")
                out.tokens.append(.term(word, quoted: false)); out.repaired.append(.term(core, quoted: true))
                return
            }
            out.tokens.append(.prefix(core1)); out.repaired.append(.prefix(core1))
            return
        }
        if toks.count == 1, let only = CaseSearchText.firstTokenText(of: core) {
            out.tokens.append(.term(only, quoted: false)); out.repaired.append(.term(only, quoted: false))
        } else {
            out.tokens.append(.term(core, quoted: true)); out.repaired.append(.term(core, quoted: true))
        }
    }

    // MARK: Structure

    struct StructuralError: Error, Equatable {
        enum Fix: Equatable { case remove(Int), append(Tok), replace(Int, Tok), removePair(Int, Int) }
        let message: String
        let fix: Fix
        let change: String
        let broadens: Bool
    }

    struct Parser {
        let toks: [Tok]
        var i = 0
        init(_ t: [Tok]) { toks = t }

        var peek: Tok? { i < toks.count ? toks[i] : nil }

        static func startsOperand(_ t: Tok?) -> Bool {
            switch t {
            case .term?, .prefix?, .field?, .lparen?, .minus?, .not?: return true
            default: return false
            }
        }

        static func name(_ t: Tok) -> String {
            switch t {
            case .and: return "AND"
            case .or: return "OR"
            case .not: return "NOT"
            case .minus: return "-"
            case .near(let n): return "NEAR/\(n)"
            case .lparen: return "("
            case .rparen: return ")"
            case .term(let s, _), .prefix(let s): return s
            case .field(let k, let v): return "\(k):\(v)"
            }
        }

        mutating func parseOr() throws -> CaseSearchNode {
            var items = [try parseAnd()]
            while peek == .or {
                let at = i
                i += 1
                guard Self.startsOperand(peek) else { throw dangling(at) }
                items.append(try parseAnd())
            }
            return items.count == 1 ? items[0] : .any(items)
        }

        mutating func parseAnd() throws -> CaseSearchNode {
            var items = [try parseUnary()]
            while let t = peek {
                if t == .and {
                    let at = i
                    i += 1
                    guard Self.startsOperand(peek) else { throw dangling(at) }
                    items.append(try parseUnary())
                } else if Self.startsOperand(t) {
                    items.append(try parseUnary())
                } else { break }
            }
            return items.count == 1 ? items[0] : .all(items)
        }

        mutating func parseUnary() throws -> CaseSearchNode {
            if peek == .not || peek == .minus {
                let at = i
                i += 1
                guard Self.startsOperand(peek) else { throw dangling(at) }
                return .not(try parseUnary())
            }
            return try parseNear()
        }

        mutating func parseNear() throws -> CaseSearchNode {
            let leftAt = i
            let left = try parsePrimary()
            guard case .near(let n)? = peek else { return left }
            let at = i
            i += 1
            guard i < toks.count, toks[i] != .rparen else { throw dangling(at) }
            guard isTermToken(toks[leftAt]), Self.isTextTerm(left), isTermToken(toks[i]) else {
                throw StructuralError(message: "NEAR joins two words or phrases (budget NEAR/5 deadline); it cannot join a field or a group.",
                                      fix: .replace(at, .and), change: "used AND instead of NEAR (searches more broadly)", broadens: true)
            }
            let right = try parsePrimary()
            if case .near? = peek {
                throw StructuralError(message: "NEAR joins exactly two words or phrases; for more, join two NEAR pairs with AND.",
                                      fix: .replace(i, .and), change: "used AND instead of the second NEAR (searches more broadly)", broadens: true)
            }
            return .near(left, right, distance: n)
        }

        func isTermToken(_ t: Tok) -> Bool {
            switch t {
            case .term, .prefix: return true
            default: return false
            }
        }

        static func isTextTerm(_ n: CaseSearchNode) -> Bool {
            switch n {
            case .word, .prefix, .phrase: return true
            default: return false
            }
        }

        mutating func parsePrimary() throws -> CaseSearchNode {
            guard let t = peek else {
                throw StructuralError(message: "Something is missing at the end of the search.", fix: .remove(max(0, toks.count - 1)),
                                      change: "removed the last operator", broadens: false)
            }
            switch t {
            case .term(let s, let quoted):
                i += 1
                return quoted ? .phrase(s) : .word(s)
            case .prefix(let s):
                i += 1
                return .prefix(s)
            case .field(let key, let value):
                i += 1
                guard let kind = CaseSearchParser.fieldKeys[key] else {
                    // Lexing reported it; keep the tree well-formed for the error path.
                    return .phrase(value)
                }
                switch kind {
                case .literal: return .literal(value)
                case .person: return .person(value)
                case .type: return .type(value)
                case .file: return .file(value)
                case .tag: return .tag(value)
                case .date(let k, let r): return .date(CaseSearchDate(kind: k, relation: r, value: CaseSearchDate.canonical(value) ?? value))
                }
            case .lparen:
                let open = i
                i += 1
                if peek == .rparen {
                    throw StructuralError(message: "Empty brackets — there is nothing in them to search for.", fix: .removePair(open, i),
                                          change: "removed the empty brackets", broadens: false)
                }
                guard peek != nil else {
                    throw StructuralError(message: "A bracket is opened at the end and never closed.", fix: .remove(open),
                                          change: "removed the unclosed bracket", broadens: false)
                }
                let inner = try parseOr()
                guard peek == .rparen else {
                    if peek == nil {
                        throw StructuralError(message: "A bracket is not closed.", fix: .append(.rparen), change: "closed the bracket at the end", broadens: false)
                    }
                    throw StructuralError(message: "A bracket is not closed where expected (near “\(Self.name(toks[i]))”).", fix: .append(.rparen),
                                          change: "closed the bracket at the end", broadens: false)
                }
                i += 1
                return inner
            case .rparen:
                throw StructuralError(message: "A closing bracket has no opening one.", fix: .remove(i), change: "removed the extra closing bracket", broadens: false)
            case .and, .or, .near:
                throw StructuralError(message: "“\(Self.name(t))” needs something to search for before it.", fix: .remove(i),
                                      change: "removed the “\(Self.name(t))” that had nothing before it", broadens: false)
            case .not, .minus:
                // Reached only through parseNear after a NEAR; parseUnary handles NOT elsewhere.
                throw StructuralError(message: "“\(Self.name(t))” cannot follow NEAR.", fix: .remove(i), change: "removed the “\(Self.name(t))”", broadens: true)
            }
        }

        func dangling(_ at: Int) -> StructuralError {
            let name = Self.name(toks[at])
            if at + 1 >= toks.count {
                return StructuralError(message: "The search ends with “\(name)” — add what should follow it, or remove it.", fix: .remove(at),
                                       change: "removed the “\(name)” at the end", broadens: name == "NOT" || name == "-")
            }
            if toks[at + 1] == .rparen {
                return StructuralError(message: "“\(name)” has nothing after it before the closing bracket.", fix: .remove(at),
                                       change: "removed the “\(name)” before the closing bracket", broadens: name == "NOT" || name == "-")
            }
            return StructuralError(message: "Two operators in a row: “\(name) \(Self.name(toks[at + 1]))”.", fix: .remove(at + 1),
                                   change: "removed the second operator “\(Self.name(toks[at + 1]))”", broadens: false)
        }
    }

    static func parseTokens(_ toks: [Tok]) -> Result<CaseSearchNode, StructuralError> {
        guard !toks.isEmpty else {
            return .failure(StructuralError(message: "Type what to search for.", fix: .remove(0), change: "", broadens: false))
        }
        var p = Parser(toks)
        do {
            let node = try p.parseOr()
            if p.i < toks.count {
                if toks[p.i] == .rparen {
                    return .failure(StructuralError(message: "A closing bracket has no opening one.", fix: .remove(p.i),
                                                    change: "removed the extra closing bracket", broadens: false))
                }
                return .failure(StructuralError(message: "Could not read the search from “\(Parser.name(toks[p.i]))” on.", fix: .remove(p.i),
                                                change: "removed “\(Parser.name(toks[p.i]))”", broadens: true))
            }
            return .success(node.normalized())
        } catch let e as StructuralError {
            return .failure(e)
        } catch {
            return .failure(StructuralError(message: "The search could not be read.", fix: .remove(0), change: "", broadens: true))
        }
    }

    /// Read `input` strictly. Valid input gives a query; anything unsupported or malformed gives the errors,
    /// and — where one can be made — a repaired query to offer.
    public static func parse(_ input: String) -> CaseSearchParse {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CaseSearchParse(query: nil, errors: ["Type what to search for."], repair: nil) }
        let lexed = lex(trimmed)
        var errors = lexed.errors
        let structural = parseTokens(lexed.tokens)
        if case .failure(let e) = structural, !errors.contains(e.message) { errors.append(e.message) }
        if errors.isEmpty, case .success(let node) = structural {
            return CaseSearchParse(query: CaseSearchQuery(root: node), errors: [], repair: nil)
        }
        return CaseSearchParse(query: nil, errors: errors, repair: repair(lexed))
    }

    /// Repair the token stream step by step (at most 24 steps); nil when no runnable query results.
    static func repair(_ lexed: Lexed) -> CaseSearchParse.Repair? {
        var toks = lexed.repaired
        var changes = lexed.changes
        var broadens = lexed.broadens
        for _ in 0..<24 {
            guard !toks.isEmpty else { return nil }
            switch parseTokens(toks) {
            case .success(let node):
                let q = CaseSearchQuery(root: node)
                return CaseSearchParse.Repair(text: q.text, query: q, changes: changes.filter { !$0.isEmpty }, broadens: broadens)
            case .failure(let e):
                switch e.fix {
                case .remove(let at): if at < toks.count { toks.remove(at: at) } else { return nil }
                case .append(let t): toks.append(t)
                case .replace(let at, let t): if at < toks.count { toks[at] = t } else { return nil }
                case .removePair(let a, let b):
                    guard a < b, b < toks.count else { return nil }
                    toks.remove(at: b); toks.remove(at: a)
                }
                changes.append(e.change)
                broadens = broadens || e.broadens
            }
        }
        return nil
    }
}

// MARK: - Rendering: canonical text and readable explanation

public nonisolated enum CaseSearchRenderer {

    public static func text(_ node: CaseSearchNode) -> String {
        switch node {
        case .word(let w): return CaseSearchParser.isBareWord(w) ? w : quoted(w)
        case .prefix(let p): return p + "*"
        case .phrase(let p): return quoted(p)
        case .literal(let l): return "exact:" + quoted(l)
        case .near(let a, let b, let d): return text(a) + " NEAR/\(d) " + text(b)
        case .person(let v): return "person:" + fieldValue(v)
        case .type(let v): return "type:" + fieldValue(v)
        case .file(let v): return "file:" + fieldValue(v)
        case .tag(let v): return "tag:" + fieldValue(v)
        case .date(let d): return "\(d.kind.keyword)-\(d.relation.rawValue):\(d.value)"
        case .all(let c):
            return c.map { k -> String in
                if case .any = k { return "(" + text(k) + ")" }
                return text(k)
            }.joined(separator: " AND ")
        case .any(let c):
            return c.map { k -> String in
                if case .all = k { return "(" + text(k) + ")" }
                return text(k)
            }.joined(separator: " OR ")
        case .not(let x):
            switch x {
            case .all, .any, .near: return "NOT (" + text(x) + ")"
            default: return "NOT " + text(x)
            }
        }
    }

    static func quoted(_ s: String) -> String { "\"" + s + "\"" }

    static func fieldValue(_ v: String) -> String {
        v.allSatisfy({ !$0.isWhitespace && $0 != "(" && $0 != ")" }) && !v.isEmpty ? v : quoted(v)
    }

    /// One line per clause; groups indent their clauses. The top line names what is searched.
    public static func explanation(_ node: CaseSearchNode) -> [String] {
        if node.isLeaf { return ["Documents in this case that " + leaf(node, negated: false)] }
        return ["Documents in this case that match " + groupHeading(node) + ":"] + lines(childrenOf(node), depth: 1)
    }

    static func childrenOf(_ node: CaseSearchNode) -> [CaseSearchNode] {
        switch node {
        case .all(let c), .any(let c): return c
        case .not(let x):
            switch x {
            case .any(let c), .all(let c): return c
            default: return [x]
            }
        default: return [node]
        }
    }

    static func groupHeading(_ node: CaseSearchNode) -> String {
        switch node {
        case .all: return "ALL of these"
        case .any: return "AT LEAST ONE of these"
        case .not(.any): return "NONE of these"
        case .not(.all): return "NOT ALL of these together"
        default: return "this"
        }
    }

    static func lines(_ nodes: [CaseSearchNode], depth: Int) -> [String] {
        let pad = String(repeating: "    ", count: depth - 1) + "• "
        var out: [String] = []
        for n in nodes {
            switch n {
            case .not(let x) where x.isLeaf:
                out.append(pad + leaf(x, negated: true))
            case .all, .any, .not:
                out.append(pad + groupHeading(n) + ":")
                out += lines(childrenOf(n), depth: depth + 1)
            default:
                out.append(pad + leaf(n, negated: false))
            }
        }
        return out
    }

    /// A leaf as a clause of "Documents in this case that …".
    public static func leaf(_ node: CaseSearchNode, negated: Bool) -> String {
        let contain = negated ? "do not contain" : "contain"
        switch node {
        case .word(let w): return "\(contain) the word “\(w)”"
        case .prefix(let p): return "\(contain) a word starting with “\(p)”"
        case .phrase(let p):
            let n = CaseSearchText.tokens(of: p, options: CaseSearchOptions()).count
            return n <= 1 ? "\(contain) the word “\(p)”" : "\(contain) the words “\(p)” in this order"
        case .literal(let l): return "\(contain) the exact characters “\(l)”"
        case .near(let a, let b, let d):
            return "\(contain) \(term(a)) and \(term(b)) with at most \(d) other word\(d == 1 ? "" : "s") between them"
        case .person(let v): return (negated ? "do not mention" : "mention") + " a person or organisation named “\(v)”"
        case .type(let v): return (negated ? "are not" : "are") + " of document type “\(v)”"
        case .file(let v): return (negated ? "do not have" : "have") + " a file name containing “\(v)”"
        case .tag(let v): return (negated ? "are not" : "are") + " tagged “\(v)” (the document or one of its passages)"
        case .date(let d):
            let when: String
            switch d.relation {
            case .before: when = "before \(d.readableValue)"
            case .after: when = "after \(d.readableValue)"
            case .on: when = (d.isDay ? "on " : "in ") + d.readableValue
            }
            switch d.kind {
            case .fileModified: return (negated ? "do not have" : "have") + " a file modified date \(when)"
            case .documentStated: return (negated ? "do not state" : "state") + " a date of their own \(when)"
            case .event: return (negated ? "do not have" : "have") + " an event in their text dated \(when)"
            }
        default:
            return text(node)
        }
    }

    static func term(_ n: CaseSearchNode) -> String {
        switch n {
        case .word(let w), .phrase(let w): return "“\(w)”"
        case .prefix(let p): return "a word starting with “\(p)”"
        default: return text(n)
        }
    }
}
