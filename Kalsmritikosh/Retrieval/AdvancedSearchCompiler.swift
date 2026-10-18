//
//  AdvancedSearchCompiler.swift
//  Kalsmritikosh
//
//  W1-1 — advanced search syntax (ported in spirit from mailin's
//  ArchiveQueryCompiler, rewritten for this ledger). One compiler from what the
//  user types to (a) a validated FTS5 MATCH expression and (b) structured
//  document filters.
//
//    budget AND deadline        both words           budget OR forecast
//    "exact phrase"             phrase               invoice*   prefix
//    budget NEAR/5 deadline     within 5 words       budget NOT draft
//    -draft                     exclude a word       ( … )      grouping
//    type:email  file:report    before:2024-01-31    after:2023-06-01
//    entity:"Jane Doe"          tag:contract         -type:pdf  (exclude)
//
//  Safety (same promise as FTSQuerySanitizer, task #40): every user term is
//  emitted QUOTED, so no user text can ever be read by FTS5 as syntax; the only
//  operators in the output are the ones this compiler writes. Nothing is
//  silently dropped — an unknown `key:value`, an unbalanced bracket or a
//  dangling operator becomes an issue the screen shows. Pure and deterministic.
//

import Foundation

public nonisolated struct AdvancedSearchFilter: Sendable, Equatable {
    public enum Field: String, Sendable, Equatable {
        /// knowledge_objects.source_type
        case type
        /// the file's path or name contains the value
        case file
        /// the file's own date is before / after the value
        case before, after
        /// the document mentions an entity whose name contains the value
        case entity
        /// the document carries a user tag (W1-4)
        case tag
        /// the document is in a group of yours, or in a group beneath it (X-2)
        case group
    }
    public let field: Field
    public let value: String
    public let negated: Bool
    /// Seconds since 1970 for date filters.
    public let epoch: Double?
}

public nonisolated struct CompiledSearch: Sendable, Equatable {
    /// nil when the query has filters only (search by filters alone).
    public let ftsExpression: String?
    public let filters: [AdvancedSearchFilter]
    public let issues: [String]
    /// Plain description of what will be searched.
    public let summary: String
    public var isEmpty: Bool { ftsExpression == nil && filters.isEmpty }
}

public nonisolated enum AdvancedSearchCompiler {

    enum Token: Equatable {
        case word(String, prefix: Bool)
        case phrase(String)
        case and, or, not
        case near(Int)
        case lparen, rparen
        case field(key: String, value: String, negated: Bool)
        case excludedWord(String)
    }

    static let knownFields: [String: AdvancedSearchFilter.Field] = [
        "type": .type, "kind": .type,
        "file": .file, "source": .file, "filename": .file,
        "before": .before, "after": .after,
        "entity": .entity, "person": .entity, "org": .entity,
        "tag": .tag, "label": .tag,
        "group": .group, "folder": .group,
    ]

    public static func compile(_ input: String) -> CompiledSearch {
        var issues: [String] = []
        var filters: [AdvancedSearchFilter] = []
        var out: [String] = []          // FTS5 pieces
        var described: [String] = []
        var depth = 0
        var lastWasOperand = false
        var pendingBinary: String?      // "AND" / "OR" / "NOT"
        var pendingNear: Int?

        func emitOperand(_ fts: String, _ text: String) {
            if let n = pendingNear, let prev = out.popLast() {
                out.append("NEAR(\(prev) \(fts), \(n))")
                described.append("within \(n) words of \(text)")
                pendingNear = nil
            } else {
                if lastWasOperand, let op = pendingBinary { out.append(op) }
                else if lastWasOperand { out.append("AND") }
                else if let op = pendingBinary, !out.isEmpty { out.append(op) }
                else if let op = pendingBinary, out.isEmpty {
                    issues.append("“\(op)” needs a word before it — it was ignored")
                }
                if let op = pendingBinary { described.append(op.lowercased()) }
                out.append(fts)
                described.append(text)
            }
            pendingBinary = nil
            lastWasOperand = true
        }

        for token in tokenize(input) {
            switch token {
            case .word(let w, let prefix):
                emitOperand(quote(w) + (prefix ? "*" : ""), prefix ? "words starting “\(w)”" : "“\(w)”")
            case .phrase(let p):
                emitOperand(quote(p), "the phrase “\(p)”")
            case .excludedWord(let w):
                if out.isEmpty {
                    issues.append("“-\(w)” needs a word to search for before it — it was ignored")
                } else {
                    out.append("NOT"); out.append(quote(w))
                    described.append("not “\(w)”")
                    lastWasOperand = true
                }
            case .and, .or, .not:
                let op = token == .and ? "AND" : token == .or ? "OR" : "NOT"
                if pendingBinary != nil || pendingNear != nil {
                    issues.append("Two operators in a row near “\(op)” — the second was ignored")
                } else if !lastWasOperand {
                    issues.append("“\(op)” needs a word before it — it was ignored")
                } else {
                    pendingBinary = op
                    lastWasOperand = false
                }
            case .near(let n):
                if !lastWasOperand || out.isEmpty {
                    issues.append("NEAR/\(n) needs a word on each side — it was ignored")
                } else {
                    pendingNear = n
                    lastWasOperand = false
                }
            case .lparen:
                if lastWasOperand && pendingBinary == nil { out.append("AND") }
                if let op = pendingBinary { out.append(op); pendingBinary = nil }
                out.append("(")
                depth += 1
                lastWasOperand = false
            case .rparen:
                if depth == 0 {
                    issues.append("A closing bracket has no opening one — it was ignored")
                    continue
                }
                if pendingBinary != nil || pendingNear != nil {
                    issues.append("Something is missing before a closing bracket — the operator was ignored")
                    pendingBinary = nil
                    pendingNear = nil
                }
                depth -= 1
                if out.last == "(" {
                    // "( )": an empty group contributes nothing.
                    out.removeLast()
                    lastWasOperand = !(out.last.map { ["AND", "OR", "NOT", "("].contains($0) } ?? true)
                } else {
                    out.append(")")
                    lastWasOperand = true
                }
            case .field(let key, let value, let negated):
                guard let f = knownFields[key] else {
                    issues.append("“\(key):” is not a search filter, so “\(key):\(value)” was searched as words")
                    for w in value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                        emitOperand(quote(String(w)), "“\(w)”")
                    }
                    continue
                }
                guard !value.isEmpty else {
                    issues.append("“\(key):” has no value — it was ignored")
                    continue
                }
                var epoch: Double?
                if f == .before || f == .after {
                    guard let d = parseDate(value) else {
                        issues.append("“\(value)” is not a date I can read (use 2024-01-31) — \(key): was ignored")
                        continue
                    }
                    epoch = d.timeIntervalSince1970
                }
                filters.append(.init(field: f, value: value, negated: negated, epoch: epoch))
                described.append(describe(f, value, negated))
            }
        }
        if pendingBinary != nil || pendingNear != nil {
            issues.append("The search ends with an operator — it was ignored")
        }
        if depth > 0 {
            issues.append("\(depth) bracket\(depth == 1 ? " was" : "s were") not closed — closed automatically")
            out.append(contentsOf: Array(repeating: ")", count: depth))
        }
        // Strip a trailing operator left by recovery.
        while let last = out.last, ["AND", "OR", "NOT", "("].contains(last) { out.removeLast() }
        let fts = out.isEmpty ? nil : out.joined(separator: " ")
        return CompiledSearch(ftsExpression: fts, filters: filters, issues: issues,
                              summary: described.isEmpty ? "" : "Searching for " + described.joined(separator: " "))
    }

    // MARK: - Tokenizer

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var i = s.startIndex
        func peekWord(from j: String.Index) -> (String, String.Index) {
            var k = j
            while k < s.endIndex, !s[k].isWhitespace, s[k] != "(", s[k] != ")" { k = s.index(after: k) }
            return (String(s[j..<k]), k)
        }
        while i < s.endIndex {
            let c = s[i]
            if c.isWhitespace { i = s.index(after: i); continue }
            if c == "(" { tokens.append(.lparen); i = s.index(after: i); continue }
            if c == ")" { tokens.append(.rparen); i = s.index(after: i); continue }
            if c == "\"" || c == "\u{201C}" || c == "\u{201D}" {
                var j = s.index(after: i)
                while j < s.endIndex, s[j] != "\"", s[j] != "\u{201D}", s[j] != "\u{201C}" { j = s.index(after: j) }
                let phrase = s[s.index(after: i)..<j].trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { tokens.append(.phrase(phrase)) }
                i = j < s.endIndex ? s.index(after: j) : j
                continue
            }
            var (word, next) = peekWord(from: i)
            var negated = false
            if word.hasPrefix("-"), word.count > 1 { negated = true; word.removeFirst() }
            if let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                let key = word[word.startIndex..<colon].lowercased()
                var value = String(word[word.index(after: colon)...])
                // key:"quoted value"
                if value.hasPrefix("\"") || value.hasPrefix("\u{201C}") {
                    var j = s.index(i, offsetBy: (negated ? 1 : 0) + key.count + 2, limitedBy: s.endIndex) ?? s.endIndex
                    let start = j
                    while j < s.endIndex, s[j] != "\"", s[j] != "\u{201D}" { j = s.index(after: j) }
                    value = String(s[start..<j])
                    next = j < s.endIndex ? s.index(after: j) : j
                }
                tokens.append(.field(key: key, value: value, negated: negated))
                i = next
                continue
            }
            let upper = word.uppercased()
            if !negated {
                if upper == "AND" || word == "&&" { tokens.append(.and); i = next; continue }
                if upper == "OR" || word == "||" { tokens.append(.or); i = next; continue }
                if upper == "NOT" { tokens.append(.not); i = next; continue }
                if upper.hasPrefix("NEAR") {
                    let n = Int(upper.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? 10
                    tokens.append(.near(max(1, min(n, 100)))); i = next; continue
                }
            }
            // A plain word: keep letters, digits and inner apostrophes/dots of identifiers.
            let prefix = word.hasSuffix("*")
            let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "*?!,;.:"))
            if !core.isEmpty {
                tokens.append(negated ? .excludedWord(core) : .word(core, prefix: prefix))
            }
            i = next
        }
        return tokens
    }

    // MARK: - Helpers

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd", "yyyy-MM", "yyyy", "dd/MM/yyyy", "d MMM yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func describe(_ f: AdvancedSearchFilter.Field, _ v: String, _ negated: Bool) -> String {
        let not = negated ? "not " : ""
        switch f {
        case .type:   return "\(not)of type \(v)"
        case .file:   return "\(not)in files named like “\(v)”"
        case .before: return "\(not)with a file date before \(v)"
        case .after:  return "\(not)with a file date after \(v)"
        case .entity: return "\(not)mentioning “\(v)”"
        case .tag:    return "\(not)tagged “\(v)”"
        case .group:  return "\(not)in the group “\(v)”"
        }
    }
}
