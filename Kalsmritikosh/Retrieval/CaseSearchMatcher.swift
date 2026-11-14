//
//  CaseSearchMatcher.swift
//  Kalsmritikosh
//
//  Living case map M5 — the matching semantics of a case evidence search, and the plan compiled from the
//  query tree. Deterministic text handling; no model, no stemming, no fuzziness, no meaning-based expansion.
//
//  MATCHING SEMANTICS (case search, query version 1)
//  • What is searched: a document's whole text as the ledger holds it (knowledge_objects.content) — not
//    chunk by chunk — so a phrase, AND, NOT and NEAR work across passage boundaries. Passages the person set
//    aside (a rejected chunk) are blanked out first: words in them are not found, and the blank breaks a
//    phrase. Passages are used afterwards only to say where each match is.
//  • Unicode: text and query are both compatibility-normalised (NFKC: "ﬁ" = "fi", full-width "Ａ" = "A",
//    composed and decomposed accents are the same). Letter case is ignored unless "Match case" is on; accents
//    are ignored unless "Match accents" is on.
//  • Words: a word is a run of letters, digits and their combining marks. Everything else — spaces, line
//    breaks, punctuation, symbols — separates words. So the word “invoice” finds “Invoice,” and “(invoice)”
//    but not “invoices”; “invoic*” finds both.
//  • A typed word with punctuation inside it (O'Brien, A-17, 10:30) is matched as its parts in order, the
//    same as a phrase.
//  • Phrase “net 30”: the words in this order, next to each other; the punctuation and spacing between them
//    are ignored (“net-30”, “net, 30” and “net\n30” match).
//  • NEAR/n: both words or phrases, in either order, with at most n other words between them (NEAR = 10).
//  • exact:"…": the exact characters, punctuation included, ignoring word boundaries; a run of spaces and
//    line breaks counts as one space; typographic quotes, apostrophes and dashes count as their plain forms
//    (’ = ', “ = ", – — = -). Case and accents follow the same two switches.
//  • person:"…": a mention the ledger recorded in the document (its words or the person's recorded name)
//    containing the typed words in order, whole words, same normalisation.
//  • file:"…": the file's name contains the typed characters (case and accents per the switches).
//  • type:, tag:: exact names, letter case ignored. Dates: see CaseSearchDate (calendar days in the chosen
//    time zone; before and after exclude the named day, month or year).
//  • amount:… / currency:…: an amount written WITH a currency mark next to it (₹ 50,000 · Rs. 50000 · INR 50,000 ·
//    50,000 INR · $1,200.50 · USD 12 · € 9 · £ 3), compared in its own currency (never converted). A bare number is
//    not an amount ("bag 7"); words such as "lakh" or "fifty thousand" are not read as numbers. On a case record the
//    amount is the record's recorded amount and currency.
//  • NOT never matches a document that was not searched: a document with no readable text is not evaluated
//    against any text clause, and is listed in the receipt instead.
//

import Foundation

// MARK: - Text normalisation

public nonisolated enum CaseSearchText {

    /// The folded form of one character for matching (NFKC, then case and accents per the options).
    static func fold(_ s: String, _ o: CaseSearchOptions) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        var opts: String.CompareOptions = [.widthInsensitive]
        if !o.matchCase { opts.insert(.caseInsensitive) }
        if !o.matchAccents { opts.insert(.diacriticInsensitive) }
        t = t.folding(options: opts, locale: nil)
        return t
    }

    @inline(__always) static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        let p = u.properties
        if p.isAlphabetic { return true }
        if p.numericType != nil { return true }
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// The folded word tokens of `s` (used for query values).
    public static func tokens(of s: String, options: CaseSearchOptions) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            for f in fold(String(ch), options) {
                if f.unicodeScalars.allSatisfy(isWordScalar) { cur.append(f) } else if !cur.isEmpty { out.append(cur); cur = "" }
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// The first word of `s` exactly as typed (nil when there is none).
    static func firstTokenText(of s: String) -> String? {
        var cur = ""
        for ch in s {
            if ch.unicodeScalars.allSatisfy(isWordScalar) { cur.append(ch) } else if !cur.isEmpty { break }
        }
        return cur.isEmpty ? nil : cur
    }

    /// The literal-matching form of `s`: folded, typographic marks mapped to their plain forms, spacing runs
    /// collapsed to one space, outer spacing trimmed.
    public static func literalForm(_ s: String, options: CaseSearchOptions) -> String {
        var out = ""
        var lastSpace = true
        for ch in s {
            if ch.isWhitespace {
                if !lastSpace { out.append(" "); lastSpace = true }
                continue
            }
            out += plainMarks(fold(String(ch), options))
            lastSpace = false
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    static func plainMarks(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x2018, 0x2019, 0x201A, 0x201B, 0x02BC, 0x2032: out.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: out.append("\"")
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212: out.append("-")
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// One document's text prepared for matching: its folded words with their positions (UTF-16 offsets into
/// the original text), and — when a literal clause needs it — its literal form with an offset map.
public nonisolated struct CaseSearchDocumentText: Sendable {
    public let utf16Count: Int
    /// Folded words; a blanked-out passage leaves a barrier ("\u{0}") that no word equals.
    let words: [String]
    let starts: [Int]
    let ends: [Int]
    let positions: [String: [Int]]
    let literal: String?
    /// For each UTF-16 unit of `literal`, the UTF-16 offset in the original it came from.
    let literalOrigin: [Int]
    /// S4 (SEARCH-02) — amounts written with a currency, when an amount clause needs them.
    let amounts: [CaseSearchAmounts.Found]

    static let barrier = "\u{0}"

    /// `masked`: UTF-16 ranges blanked out before matching (sorted, non-overlapping).
    public init(_ text: String, options: CaseSearchOptions, masked: [Range<Int>] = [], needsLiteral: Bool = false, needsAmounts: Bool = false) {
        self.amounts = needsAmounts ? CaseSearchAmounts.scan(text).filter { a in !masked.contains { $0.overlaps(a.range) } } : []
        var words: [String] = [], starts: [Int] = [], ends: [Int] = []
        var positions: [String: [Int]] = [:]
        var lit = "", litOrigin: [Int] = []
        var cur = "", curStart = 0, curEnd = 0
        var offset = 0
        var maskIndex = 0
        var inMask = false
        var lastLitSpace = true
        var lastWasBarrier = false
        func flush() {
            guard !cur.isEmpty else { return }
            positions[cur, default: []].append(words.count)
            words.append(cur); starts.append(curStart); ends.append(curEnd)
            cur = ""
            lastWasBarrier = false
        }
        for ch in text {
            let width = ch.utf16.count
            while maskIndex < masked.count, masked[maskIndex].upperBound <= offset { maskIndex += 1 }
            let masks = maskIndex < masked.count && masked[maskIndex].lowerBound < offset + width
            if masks {
                if !inMask {
                    flush()
                    if !lastWasBarrier && !words.isEmpty {
                        words.append(Self.barrier); starts.append(offset); ends.append(offset)
                        lastWasBarrier = true
                    }
                    if needsLiteral, !lastLitSpace { lit.append(" "); litOrigin.append(offset); lastLitSpace = true }
                    inMask = true
                }
                offset += width
                continue
            }
            inMask = false
            if ch.isASCII, let a = ch.asciiValue {
                let isWord = (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122)
                if isWord {
                    let c = (!options.matchCase && a >= 65 && a <= 90) ? Character(Unicode.Scalar(a + 32)) : ch
                    if cur.isEmpty { curStart = offset }
                    cur.append(c); curEnd = offset + width
                    if needsLiteral { lit.append(c); litOrigin.append(offset); lastLitSpace = false }
                } else {
                    flush()
                    if needsLiteral {
                        if ch.isWhitespace {
                            if !lastLitSpace { lit.append(" "); litOrigin.append(offset); lastLitSpace = true }
                        } else { lit.append(ch); litOrigin.append(offset); lastLitSpace = false }
                    }
                }
                offset += width
                continue
            }
            let folded = CaseSearchText.fold(String(ch), options)
            for f in folded {
                if f.unicodeScalars.allSatisfy(CaseSearchText.isWordScalar) {
                    if cur.isEmpty { curStart = offset }
                    cur.append(f); curEnd = offset + width
                } else {
                    flush()
                }
            }
            if needsLiteral {
                if ch.isWhitespace {
                    if !lastLitSpace { lit.append(" "); litOrigin.append(offset); lastLitSpace = true }
                } else {
                    let plain = CaseSearchText.plainMarks(folded)
                    for _ in 0..<plain.utf16.count { litOrigin.append(offset) }
                    lit += plain
                    lastLitSpace = false
                }
            }
            offset += width
        }
        flush()
        self.utf16Count = offset
        self.words = words; self.starts = starts; self.ends = ends; self.positions = positions
        self.literal = needsLiteral ? lit : nil
        self.literalOrigin = litOrigin
    }

    /// Word spans (first word index, last word index) where `needle` (folded words) occurs in order.
    func spans(of needle: [String]) -> [(Int, Int)] {
        guard let first = needle.first, let at = positions[first] else { return [] }
        if needle.count == 1 { return at.map { ($0, $0) } }
        var out: [(Int, Int)] = []
        for p in at where p + needle.count <= words.count {
            var ok = true
            for k in 1..<needle.count where words[p + k] != needle[k] { ok = false; break }
            if ok { out.append((p, p + needle.count - 1)) }
        }
        return out
    }

    func prefixSpans(_ prefix: String) -> [(Int, Int)] {
        var at: [Int] = []
        for (w, ps) in positions where w.hasPrefix(prefix) { at += ps }
        return at.sorted().map { ($0, $0) }
    }

    /// UTF-16 ranges of the literal needle in the original text.
    func literalRanges(_ needle: String) -> [Range<Int>] {
        guard let literal, !needle.isEmpty else { return [] }
        let hay = literal as NSString
        var out: [Range<Int>] = []
        var from = 0
        while from < hay.length {
            let r = hay.range(of: needle, options: .literal, range: NSRange(location: from, length: hay.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            let s = literalOrigin[r.location]
            // The match ends where the next original character begins (a character folded into several
            // units, such as "ﬁ", is covered whole).
            let lastOrigin = literalOrigin[r.location + r.length - 1]
            var j = r.location + r.length
            while j < literalOrigin.count, literalOrigin[j] == lastOrigin { j += 1 }
            let e = j < literalOrigin.count ? literalOrigin[j] : utf16Count
            out.append(s..<max(s + 1, min(e, utf16Count)))
            from = r.location + r.length
        }
        return out
    }

    func range(_ span: (Int, Int)) -> Range<Int> { starts[span.0]..<ends[span.1] }
}

// MARK: - The compiled plan

/// A leaf as it runs. Text leaves run in Swift over the document's text; `stored` leaves run as
/// parameterised SQL over the case's documents (CaseSearchRepository.predicate); person, file name and the
/// document-stated date run in Swift over what the ledger records about the document.
public nonisolated enum CaseSearchLeafKind: Sendable, Equatable {
    case words([String])
    case prefix(String)
    case literal(String)
    case near(left: [String], leftPrefix: Bool, right: [String], rightPrefix: Bool, distance: Int)
    case person([String])
    case fileName(String)
    case statedDate(CaseSearchDate)
    case stored(CaseSearchStoredField)
    /// S4 (SEARCH-02): an amount with its currency (text: written with a currency mark; a record: its recorded amount).
    case amount(CaseSearchAmount)
}

/// S4 (SEARCH-03) — what a clause matched against, so a result says what kind of match it is. Case search matches only
/// the first three; `similarity` names what a meaning-based (embedding / AI) result would be, and is never an exact
/// occurrence or a verified identity.
public nonisolated enum CaseSearchMatchBasis: String, Sendable, Codable, CaseIterable, Hashable {
    /// The words or characters occur in the searched text.
    case literalText
    /// A value the reader extracted from the text (a recorded mention of a name, an extracted event date) — what the
    /// reader recorded, not a verified identity or a verified date.
    case extractedField
    /// A value recorded about the document or record (type, file name, tag, a date field, a recorded amount).
    case recordedField
    /// Similar meaning (embeddings or AI) — not produced by case search.
    case similarity

    public var label: String {
        switch self {
        case .literalText: return "Exact text — the words occur in the searched text"
        case .extractedField: return "Extracted by the reader — a recorded mention or date, not a verified identity"
        case .recordedField: return "Recorded field — a value recorded about the item"
        case .similarity: return "Similar meaning — not an exact occurrence and not a verified identity"
        }
    }
}

/// The leaves compiled to SQL: the document type, a tag, the file's modified date, an extracted event's date.
public nonisolated enum CaseSearchStoredField: Sendable, Equatable, Hashable {
    case type(String)
    case tag(String)
    case modified(CaseSearchDate)
    case event(CaseSearchDate)
}

public nonisolated struct CaseSearchPlan: Sendable {
    public indirect enum Node: Sendable, Equatable {
        case leaf(Int)
        case all([Node])
        case any([Node])
        case not(Node)
    }

    public let query: CaseSearchQuery
    public let options: CaseSearchOptions
    public let leaves: [CaseSearchLeafKind]
    /// The clause text of each leaf (from the same tree the explanation is rendered from).
    public let clauseText: [String]
    /// The same clauses worded as absent ("do not contain the word …"), for a NOT clause a hit lacks.
    public let absentText: [String]
    /// Whether the leaf counts towards a match (under an even number of NOTs) or must be absent.
    public let positive: [Bool]
    public let root: Node

    public var hasTextLeaves: Bool { leaves.contains { if case .words = $0 { return true }; if case .prefix = $0 { return true }; if case .literal = $0 { return true }; if case .near = $0 { return true }; if case .amount = $0 { return true }; return false } }
    public var needsAmounts: Bool { leaves.contains { if case .amount = $0 { return true }; return false } }
    public var needsLiteral: Bool { leaves.contains { if case .literal = $0 { return true }; return false } }
    public var needsMentions: Bool { leaves.contains { if case .person = $0 { return true }; return false } }
    public var storedFields: [CaseSearchStoredField] {
        var seen = Set<CaseSearchStoredField>(), out: [CaseSearchStoredField] = []
        for l in leaves { if case .stored(let f) = l, seen.insert(f).inserted { out.append(f) } }
        return out
    }
    public var usesStatedDate: Bool { leaves.contains { if case .statedDate = $0 { return true }; return false } }
    public var usesModifiedDate: Bool { storedFields.contains { if case .modified = $0 { return true }; return false } }
    public var usesEventDate: Bool { storedFields.contains { if case .event = $0 { return true }; return false } }

    public init(query: CaseSearchQuery, options: CaseSearchOptions) {
        self.query = query; self.options = options
        var leaves: [CaseSearchLeafKind] = [], text: [String] = [], absent: [String] = [], positive: [Bool] = []
        func toks(_ s: String) -> [String] { CaseSearchText.tokens(of: s, options: options) }
        func compile(_ n: CaseSearchNode, negations: Int) -> Node {
            switch n {
            case .all(let c): return .all(c.map { compile($0, negations: negations) })
            case .any(let c): return .any(c.map { compile($0, negations: negations) })
            case .not(let x): return .not(compile(x, negations: negations + 1))
            default:
                let kind: CaseSearchLeafKind
                switch n {
                case .word(let w), .phrase(let w): kind = .words(toks(w))
                case .prefix(let p): kind = .prefix(toks(p).first ?? "")
                case .literal(let l): kind = .literal(CaseSearchText.literalForm(l, options: options))
                case .near(let a, let b, let d):
                    func side(_ x: CaseSearchNode) -> ([String], Bool) {
                        switch x {
                        case .prefix(let p): return ([toks(p).first ?? ""], true)
                        case .word(let w), .phrase(let w): return (toks(w), false)
                        default: return ([], false)
                        }
                    }
                    let (l, lp) = side(a), (r, rp) = side(b)
                    kind = .near(left: l, leftPrefix: lp, right: r, rightPrefix: rp, distance: d)
                case .person(let v): kind = .person(toks(v))
                case .file(let v): kind = .fileName(CaseSearchText.literalForm(v, options: options))
                case .date(let d):
                    switch d.kind {
                    case .documentStated: kind = .statedDate(d)
                    case .fileModified: kind = .stored(.modified(d))
                    case .event: kind = .stored(.event(d))
                    }
                case .amount(let a): kind = .amount(a)
                case .type(let v): kind = .stored(.type(v))
                case .tag(let v): kind = .stored(.tag(v))
                default: kind = .words([])
                }
                leaves.append(kind)
                text.append(CaseSearchRenderer.leaf(n, negated: false))
                absent.append(CaseSearchRenderer.leaf(n, negated: true))
                positive.append(negations % 2 == 0)
                return .leaf(leaves.count - 1)
            }
        }
        let root = compile(query.root, negations: 0)
        self.leaves = leaves; self.clauseText = text; self.absentText = absent; self.positive = positive; self.root = root
    }

    /// Three-valued evaluation: nil leaves are unknown. Returns nil when the result depends on them.
    public func evaluate(_ value: (Int) -> Bool?) -> Bool? {
        func ev(_ n: Node) -> Bool? {
            switch n {
            case .leaf(let i): return value(i)
            case .not(let x): return ev(x).map { !$0 }
            case .all(let c):
                var unknown = false
                for k in c { switch ev(k) { case false?: return false; case nil: unknown = true; default: break } }
                return unknown ? nil : true
            case .any(let c):
                var unknown = false
                for k in c { switch ev(k) { case true?: return true; case nil: unknown = true; default: break } }
                return unknown ? nil : false
            }
        }
        return ev(root)
    }
}

// MARK: - Evaluating one document

/// What the ledger records about one document, for the field clauses.
public nonisolated struct CaseSearchDocumentFacts: Sendable {
    public var fileName: String
    public var statedDate: Date?
    public var statedDateText: String?
    /// The mentions recorded in the document (their words and the recorded names).
    public var mentions: [String]
    /// The stored-field clauses this document satisfies (from SQL).
    public var stored: Set<CaseSearchStoredField>
    /// S4 — a case record's recorded amounts (a money movement), each in its own currency.
    public var recordedMoney: [(amount: Decimal, currency: String)] = []
    /// S4 (SEARCH-07) — recorded mention → the canonical entity it was recorded as (when known).
    public var mentionEntities: [String: UUID] = [:]

    public init(fileName: String, statedDate: Date? = nil, statedDateText: String? = nil, mentions: [String] = [], stored: Set<CaseSearchStoredField> = []) {
        self.fileName = fileName; self.statedDate = statedDate; self.statedDateText = statedDateText; self.mentions = mentions; self.stored = stored
    }
}

public nonisolated struct CaseSearchLeafOutcome: Sendable, Equatable {
    public var matched: Bool
    /// UTF-16 ranges of the matches in the document's text (text leaves only).
    public var ranges: [Range<Int>]
    /// What field matched, for the witness ("file name: invoice-17.pdf").
    public var detail: String?
    /// S4 (SEARCH-03) — what the clause matched against.
    public var basis: CaseSearchMatchBasis = .literalText
    /// S4 (SEARCH-07) — the canonical entities a person clause matched (by their recorded mentions).
    public var entities: [UUID] = []
}

public nonisolated enum CaseSearchEvaluator {

    /// The outcome of each leaf for one document. `text` is nil when the document has no readable text:
    /// text leaves are then unknown (nil) — never "absent".
    public static func leafOutcomes(_ plan: CaseSearchPlan, text: CaseSearchDocumentText?, facts: CaseSearchDocumentFacts)
        -> [CaseSearchLeafOutcome?] {
        plan.leaves.map { leaf -> CaseSearchLeafOutcome? in
            switch leaf {
            case .words(let w):
                guard let text else { return nil }
                guard !w.isEmpty else { return CaseSearchLeafOutcome(matched: false, ranges: [], detail: nil) }
                let r = text.spans(of: w).map(text.range)
                return CaseSearchLeafOutcome(matched: !r.isEmpty, ranges: r, detail: nil)
            case .prefix(let p):
                guard let text else { return nil }
                guard !p.isEmpty else { return CaseSearchLeafOutcome(matched: false, ranges: [], detail: nil) }
                let r = text.prefixSpans(p).map(text.range)
                return CaseSearchLeafOutcome(matched: !r.isEmpty, ranges: r, detail: nil)
            case .literal(let l):
                guard let text else { return nil }
                let r = text.literalRanges(l)
                return CaseSearchLeafOutcome(matched: !r.isEmpty, ranges: r, detail: nil)
            case .near(let a, let ap, let b, let bp, let d):
                guard let text else { return nil }
                let r = near(text, a, ap, b, bp, d)
                return CaseSearchLeafOutcome(matched: !r.isEmpty, ranges: r, detail: nil)
            case .person(let needle):
                guard !needle.isEmpty else { return CaseSearchLeafOutcome(matched: false, ranges: [], detail: nil) }
                var first: String?
                var entities = Set<UUID>()
                for m in facts.mentions {
                    let t = CaseSearchText.tokens(of: m, options: plan.options)
                    if containsRun(t, needle) {
                        if first == nil { first = m }
                        if let e = facts.mentionEntities[m] { entities.insert(e) }
                    }
                }
                if let first {
                    return CaseSearchLeafOutcome(matched: true, ranges: [], detail: "a recorded mention “\(first)” (extracted by the reader — not a verified identity)",
                                                 basis: .extractedField, entities: entities.sorted { $0.uuidString < $1.uuidString })
                }
                return CaseSearchLeafOutcome(matched: false, ranges: [], detail: nil, basis: .extractedField)
            case .fileName(let v):
                let hit = !v.isEmpty && CaseSearchText.literalForm(facts.fileName, options: plan.options).contains(v)
                return CaseSearchLeafOutcome(matched: hit, ranges: [], detail: hit ? "file name: \(facts.fileName)" : nil, basis: .recordedField)
            case .statedDate(let d):
                guard let date = facts.statedDate else { return CaseSearchLeafOutcome(matched: false, ranges: [], detail: nil) }
                let hit = d.holds(date, in: plan.options.timeZone)
                return CaseSearchLeafOutcome(matched: hit, ranges: [], detail: hit ? "states its date as \(facts.statedDateText ?? "")" : nil, basis: .recordedField)
            case .stored(let f):
                let hit = facts.stored.contains(f)
                if case .event = f { return CaseSearchLeafOutcome(matched: hit, ranges: [], detail: hit ? "an event the reader extracted from the text" : nil, basis: .extractedField) }
                return CaseSearchLeafOutcome(matched: hit, ranges: [], detail: nil, basis: .recordedField)
            case .amount(let a):
                // A record's recorded amount decides first; then amounts written in the text.
                if let m = facts.recordedMoney.first(where: { a.holds($0.amount, currency: $0.currency) }) {
                    return CaseSearchLeafOutcome(matched: true, ranges: [], detail: "recorded amount: \(NSDecimalNumber(decimal: m.amount).stringValue) \(m.currency)", basis: .recordedField)
                }
                guard let text else { return facts.recordedMoney.isEmpty ? nil : CaseSearchLeafOutcome(matched: false, ranges: [], detail: nil, basis: .recordedField) }
                let r = text.amounts.filter { a.holds($0.value, currency: $0.currency) }.map(\.range)
                return CaseSearchLeafOutcome(matched: !r.isEmpty, ranges: r, detail: nil)
            }
        }
    }

    static func containsRun(_ hay: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return true }
        return false
    }

    static func near(_ text: CaseSearchDocumentText, _ a: [String], _ ap: Bool, _ b: [String], _ bp: Bool, _ d: Int) -> [Range<Int>] {
        func spans(_ w: [String], _ p: Bool) -> [(Int, Int)] {
            guard !w.isEmpty else { return [] }
            return p ? text.prefixSpans(w[0]) : text.spans(of: w)
        }
        let A = spans(a, ap), B = spans(b, bp).sorted { $0.0 < $1.0 }
        guard !A.isEmpty, !B.isEmpty else { return [] }
        let bStarts = B.map(\.0)
        func firstIndex(atLeast x: Int) -> Int {
            var lo = 0, hi = bStarts.count
            while lo < hi { let mid = (lo + hi) / 2; if bStarts[mid] < x { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        // A barrier (blanked-out passage) between the two sides breaks the pair.
        func barrierBetween(_ x: Int, _ y: Int) -> Bool {
            guard y > x + 1 else { return false }
            for k in (x + 1)..<y where text.words[k] == CaseSearchDocumentText.barrier { return true }
            return false
        }
        var seen = Set<Range<Int>>(), out: [Range<Int>] = []
        for s in A {
            // B after A: b.start in [a.end + 1, a.end + 1 + d].
            var k = firstIndex(atLeast: s.1 + 1)
            while k < B.count, B[k].0 <= s.1 + 1 + d {
                if !barrierBetween(s.1, B[k].0) {
                    let r = text.starts[s.0]..<text.ends[B[k].1]
                    if seen.insert(r).inserted { out.append(r) }
                    break
                }
                k += 1
            }
            // B before A: b.end in [a.start - 1 - d, a.start - 1].
            k = firstIndex(atLeast: max(0, s.0 - 1 - d - max(1, b.count)))
            while k < B.count, B[k].0 < s.0 {
                if B[k].1 < s.0, B[k].1 >= s.0 - 1 - d, !barrierBetween(B[k].1, s.0) {
                    let r = text.starts[B[k].0]..<text.ends[s.1]
                    if seen.insert(r).inserted { out.append(r) }
                }
                k += 1
            }
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }
}

// MARK: - Amounts written with a currency (S4, SEARCH-02)

public nonisolated enum CaseSearchAmounts {
    public struct Found: Sendable, Equatable, Hashable {
        /// UTF-16 range of the amount with its currency mark.
        public let range: Range<Int>
        public let value: Decimal
        public let currency: String?
    }

    static let number = #"(\d{1,3}(?:,\d{2,3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#
    static let codes = "INR|USD|EUR|GBP|JPY|AUD|CAD|CHF|CNY|SGD|AED|HKD|NZD"
    static let before: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(₹|Rs\.?|US\$|\$|€|£|¥|"# + codes + #")\s?"# + number + #"(?![0-9])"#, options: [.caseInsensitive])
    static let after: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![0-9.,])"# + number + #"\s?("# + codes + #"|rupees|rupee)(?![A-Za-z])"#, options: [.caseInsensitive])

    /// Every amount written with a currency mark next to it, in text order (an amount matched by both forms counts once).
    public static func scan(_ text: String) -> [Found] {
        let ns = text as NSString
        var out: [Found] = []
        var taken: [Range<Int>] = []
        func add(_ m: NSTextCheckingResult, mark: Int, num: Int) {
            let r = m.range.location..<(m.range.location + m.range.length)
            guard !taken.contains(where: { $0.overlaps(r) }),
                  let v = CaseSearchAmount.number(ns.substring(with: m.range(at: num))),
                  let code = CaseSearchAmount.currencyCode(ns.substring(with: m.range(at: mark)).trimmingCharacters(in: .whitespaces)) else { return }
            taken.append(r)
            out.append(Found(range: r, value: v, currency: code))
        }
        let all = NSRange(location: 0, length: ns.length)
        for m in before?.matches(in: text, range: all) ?? [] { add(m, mark: 1, num: 2) }
        for m in after?.matches(in: text, range: all) ?? [] { add(m, mark: 2, num: 1) }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
