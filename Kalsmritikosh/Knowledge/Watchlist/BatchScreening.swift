//
//  BatchScreening.swift
//  Kalsmritikosh
//
//  N2 — batch name screening (the ICIJ Datashare "batch search" / Hunchly "selectors" pattern),
//  built on the N-3 watchlist. Every line of a list is one term: a name, a phone number or an
//  email address. Each term is looked for two ways:
//
//    named entity  the ledger's canonical people / organisations (with their aliases, through the
//                  WatchlistMatcher variant rules) and its extracted phone-number and email entities;
//    text match    the passages themselves, through the safe FTS path (a quoted phrase, never raw
//                  text into MATCH), verified word-for-word in Swift — so a name that was never
//                  extracted as an entity is still found.
//
//  The result is PER TERM, including terms with no hit ("No match in N documents searched" is
//  screening evidence), with documents, mentions and one passage per document to open.
//
//  Phone numbers are compared conservatively. Spaces, dashes, dots, slashes and parentheses are
//  removed and a leading "+" is kept; no country code is ever added or dropped, and a trunk "0" or
//  an "00" prefix is not rewritten. Two numbers match when their digits are identical with the same
//  "+" form, OR when exactly one side is written with "+" and the other side (written without "+")
//  is the trailing part of it AND that trailing part is at least 9 digits long — so "+1 555 123 4567"
//  matches "555-123-4567", but a 7- or 8-digit local number never matches the tail of an
//  international one. Email addresses are compared case-insensitively. A hit is a lead to check,
//  never an identity claim.
//
//  Scope: the whole archive, or one case (the caller passes the case's resolved source-version
//  allow-set; a document outside it is never searched). Sensitive or privileged documents are
//  removed by the caller's screen gate and counted as withheld, never silently.
//

import Foundation
import os

// MARK: - Terms

public nonisolated enum ScreeningTermKind: String, Sendable, Hashable, CaseIterable {
    case name, phone, email

    public var label: String {
        switch self {
        case .name: return "Name"
        case .phone: return "Phone"
        case .email: return "Email"
        }
    }
}

public nonisolated struct ScreeningTerm: Sendable, Hashable, Identifiable {
    /// The line as the person typed it.
    public let raw: String
    public let kind: ScreeningTermKind
    /// Names: `WatchlistMatcher.normalize`; phones: digits with an optional leading "+"; emails: lowercased.
    public let normalized: String
    public var id: String { kind.rawValue + ":" + normalized }
}

public nonisolated enum ScreeningTermClassifier {

    /// One list line → a term, or nil when the line has nothing to look for.
    public static func classify(_ line: String) -> ScreeningTerm? {
        let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let email = normalizeEmail(raw) { return ScreeningTerm(raw: raw, kind: .email, normalized: email) }
        if !looksLikeDate(raw), let phone = normalizePhone(raw) { return ScreeningTerm(raw: raw, kind: .phone, normalized: phone) }
        let name = WatchlistMatcher.normalize(raw)
        guard name.count >= 2 else { return nil }
        return ScreeningTerm(raw: raw, kind: .name, normalized: name)
    }

    /// Classified terms, one per distinct (kind, normalised value), in list order.
    public static func terms(_ lines: [String]) -> [ScreeningTerm] {
        var seen = Set<String>()
        return lines.compactMap(classify).filter { seen.insert($0.id).inserted }
    }

    /// "+1 (555) 123-4567" → "+15551234567"; "555.123.4567" → "5551234567". Only digits, spaces,
    /// "-", ".", "/", "(", ")" and ONE leading "+" are allowed, with 7–15 digits; anything else → nil.
    public static func normalizePhone(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var plus = false
        var digits = ""
        for (i, ch) in t.enumerated() {
            if ch == "+" {
                guard i == 0 else { return nil }
                plus = true
            } else if ch.isASCII, ch.isNumber {
                digits.append(ch)
            } else if !" -./()".contains(ch) {
                return nil
            }
        }
        guard (7...15).contains(digits.count) else { return nil }
        return (plus ? "+" : "") + digits
    }

    /// Two normalised phone numbers (see the file header): identical, or one "+" form whose trailing
    /// digits are the other (non-"+") number, at least 9 digits long.
    public static func phonesMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ap = a.hasPrefix("+"), bp = b.hasPrefix("+")
        guard ap != bp else { return false }
        let intl = String((ap ? a : b).dropFirst()), national = ap ? b : a
        return national.count >= 9 && intl.count > national.count && intl.hasSuffix(national)
    }

    /// The variant wording for two matching phone numbers.
    static func phoneVariant(_ term: String, _ found: String) -> String {
        term == found ? "same number" : "same number, written with/without the country code"
    }

    /// "Jane.Doe@Example.com" → "jane.doe@example.com"; nil when the line is not one address.
    public static func normalizeEmail(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !t.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "<" || $0 == ">" }) else { return nil }
        return t
    }

    /// "2024-01-02", "02/01/2024", "2.1.2024": a date, not a phone number.
    static func looksLikeDate(_ s: String) -> Bool {
        s.range(of: #"^\s*(\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d{1,2}[-./]\d{1,2}[-./]\d{2,4})\s*$"#, options: .regularExpression) != nil
    }
}

// MARK: - Results

public nonisolated enum ScreeningFoundBy: String, Sendable, Hashable {
    case namedEntity, textMatch

    public var label: String { self == .namedEntity ? "named entity" : "text match" }
}

/// One document a term was found in.
public nonisolated struct ScreeningDocument: Sendable, Hashable, Identifiable {
    public let objectID: UUID
    public let name: String
    /// Occurrences in this document (the larger of its entity mentions and its text occurrences —
    /// the two usually count the same words, so they are not added).
    public let mentions: Int
    /// A passage around the hit (or the start of the document's first passage when the hit could
    /// not be located in it), and the exact words to highlight when the source opens.
    public let passage: String
    public let highlight: String?
    public let foundBy: [ScreeningFoundBy]
    /// How each way matched ("named entity — similar spelling: “Jon Doe”", "text match — exact words").
    public let variants: [String]
    public var id: UUID { objectID }
    public var howFound: String { variants.joined(separator: "; ") }
}

public nonisolated struct ScreeningTermResult: Sendable, Identifiable {
    public let term: ScreeningTerm
    public let documents: [ScreeningDocument]
    /// Documents with a hit that the screen gate withholds (sensitive / privileged) — counted, never shown.
    public let withheldDocuments: Int
    /// The text search reached its passage limit: there may be more documents than listed.
    public let passageLimitReached: Bool
    public var id: String { term.id }
    public var mentions: Int { documents.reduce(0) { $0 + $1.mentions } }
}

public nonisolated struct ScreeningReport: Sendable {
    public let scopeLabel: String
    public let ranAt: Date
    /// Documents in the screened scope (before the screen gate).
    public let documentsSearched: Int
    public let results: [ScreeningTermResult]

    public static let columns = ["Term", "Kind", "Documents", "Mentions", "Document", "How found", "Passage"]

    /// What a term with no shown hit says.
    public func noMatchText(_ r: ScreeningTermResult) -> String {
        var s = "No match in \(documentsSearched) document\(documentsSearched == 1 ? "" : "s") searched"
        if r.withheldDocuments > 0 {
            s = "No match you can see in \(documentsSearched) document\(documentsSearched == 1 ? "" : "s") searched — "
                + "\(r.withheldDocuments) document\(r.withheldDocuments == 1 ? " is" : "s are") marked sensitive or privileged and not shown"
        }
        return s
    }

    /// The file's first line: what was screened, when, and how much.
    public var headline: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "Name screening — scope: \(scopeLabel) — run \(f.string(from: ranAt)) — \(documentsSearched) document\(documentsSearched == 1 ? "" : "s") searched"
    }

    /// CSV (RFC 4180): the headline, the column header, then one row per (term, document) and one
    /// row for every term with no shown hit.
    public func csv() -> String {
        var lines: [[String]] = [[headline], Self.columns]
        for r in results {
            let base = [r.term.raw, r.term.kind.label, "\(r.documents.count)", "\(r.mentions)"]
            if r.documents.isEmpty {
                lines.append(base + ["", "", noMatchText(r)])
                continue
            }
            for d in r.documents { lines.append(base + [d.name, d.howFound, d.passage]) }
            if r.withheldDocuments > 0 {
                lines.append(base + ["(not shown)", "",
                                     "\(r.withheldDocuments) more document\(r.withheldDocuments == 1 ? " is" : "s are") marked sensitive or privileged and not shown"])
            }
            if r.passageLimitReached {
                lines.append(base + ["(limit reached)", "", "The text search stopped at its passage limit; there may be more documents"])
            }
        }
        return lines.map { $0.map(LedgerExportRenderer.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - CSV import

public nonisolated enum ScreeningListImport {
    /// The rows of a CSV or text file (RFC 4180, shared reader).
    public static func rows(_ text: String) -> [[String]] { WorkbenchCSV.parse(text) }

    /// Column titles for the picker: the header row's cells when `hasHeader`, else "Column 1…n".
    public static func columnTitles(_ rows: [[String]], hasHeader: Bool) -> [String] {
        let width = rows.map(\.count).max() ?? 0
        return (0..<width).map { i in
            if hasHeader, let h = rows.first, i < h.count {
                let t = h[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
            return "Column \(i + 1)"
        }
    }

    /// The non-empty values of `column`, skipping the header row when `hasHeader`.
    public static func values(_ rows: [[String]], column: Int, hasHeader: Bool) -> [String] {
        rows.dropFirst(hasHeader ? 1 : 0).compactMap { row in
            guard column < row.count else { return nil }
            let v = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
    }
}

// MARK: - Engine

public nonisolated struct BatchScreening: Sendable {
    public let database: Database
    public let chunks: ChunksRepository
    public let evidence: EvidenceStore
    /// Passages read per term by the text search.
    public var passageLimit = 500
    /// Entities followed per term (the watchlist's existing cap).
    public var entitiesPerTerm = 20

    public init(database: Database, chunks: ChunksRepository, evidence: EvidenceStore) {
        self.database = database; self.chunks = chunks; self.evidence = evidence
    }

    private struct Candidate { let id: UUID; let value: String; let aliases: [String] }

    private struct Acc {
        var entityMentions = 0
        var textOccurrences = 0
        var passage: String?
        var highlight: String?
        var foundBy: [ScreeningFoundBy] = []
        var variants: [String] = []
        mutating func add(_ way: ScreeningFoundBy, _ variant: String) {
            if !foundBy.contains(way) { foundBy.append(way) }
            if !variants.contains(variant) { variants.append(variant) }
        }
    }

    /// Screen `lines` in `scope`. `visible` is the screen gate: given document (KnowledgeObject) ids,
    /// the ones that may be shown. Hits outside the case scope are never searched; withheld hits are counted.
    public func run(lines: [String], scope: RetrievalSourceScope, scopeLabel: String,
                    visible: @Sendable ([UUID]) async -> Set<UUID>, at date: Date = Date()) async throws -> ScreeningReport {
        let terms = ScreeningTermClassifier.terms(lines)
        let searched = try await documentsInScope(scope)
        let names = terms.contains { $0.kind == .name } ? try await candidates(kinds: ["person", "organization", "vendor", "client"]) : []
        let contacts = terms.contains { $0.kind != .name } ? try await candidates(kinds: ["phoneNumber", "emailAddress"]) : []
        var versionOK: [UUID: Bool] = [:]
        var results: [ScreeningTermResult] = []
        for term in terms {
            var docs: [UUID: Acc] = [:]
            // (a) named entities
            for (entityID, variant) in entityMatches(term, names: names, contacts: contacts) {
                let rows = try await database.query("""
                    SELECT source_object_id, COUNT(*) FROM entity_mentions WHERE entity_id = ?
                    GROUP BY source_object_id LIMIT 2000;
                    """, [.uuid(entityID)])
                for r in rows {
                    guard let ko = r.uuid(0) else { continue }
                    if scope.isActive {
                        if versionOK[ko] == nil {
                            let v = try await evidence.currentVersionID(forObject: ko)
                            versionOK[ko] = v.map { scope.authorizedSourceVersionIDs.contains($0) } ?? false
                        }
                        guard versionOK[ko] == true else { continue }   // outside the case: never searched
                    }
                    docs[ko, default: Acc()].entityMentions += Int(r.int(1) ?? 1)
                    docs[ko, default: Acc()].add(.namedEntity, "named entity — " + variant)
                }
            }
            // (b) text
            let pool = try await textPool(term, scope: scope)
            for chunk in pool {
                guard let hit = Self.textHits(term, in: chunk.text) else { continue }
                var acc = docs[chunk.objectID, default: Acc()]
                acc.textOccurrences += hit.count
                if acc.passage == nil { acc.passage = Self.snippet(chunk.text, around: hit.range); acc.highlight = hit.highlight }
                acc.add(.textMatch, "text match — " + hit.variant)
                docs[chunk.objectID] = acc
            }
            // Passages for entity-only documents.
            for (ko, acc) in docs where acc.passage == nil {
                let p = try await passage(for: term, objectID: ko, scope: scope)
                docs[ko]?.passage = p.passage
                docs[ko]?.highlight = p.highlight
            }
            // Screen gate (sensitive / privileged): fail closed.
            let allowed = docs.isEmpty ? [] : await visible(Array(docs.keys))
            let shownIDs = docs.keys.filter { allowed.contains($0) }
            let docNames = try await documentNames(shownIDs)
            let shown = shownIDs.map { ko -> ScreeningDocument in
                let a = docs[ko] ?? Acc()
                return ScreeningDocument(objectID: ko, name: docNames[ko] ?? "(source not found)",
                                         mentions: max(a.entityMentions, a.textOccurrences, 1),
                                         passage: a.passage ?? "", highlight: a.highlight,
                                         foundBy: a.foundBy, variants: a.variants)
            }.sorted { ($0.mentions, $1.name) > ($1.mentions, $0.name) }
            results.append(ScreeningTermResult(term: term, documents: shown, withheldDocuments: docs.count - shown.count,
                                               passageLimitReached: pool.count >= passageLimit))
        }
        return ScreeningReport(scopeLabel: scopeLabel, ranAt: date, documentsSearched: searched, results: results)
    }

    // MARK: Entities

    private func candidates(kinds: [String]) async throws -> [Candidate] {
        let rows = try await database.query("""
            SELECT e.id, e.value, GROUP_CONCAT(a.alias_normalized, '|')
            FROM entities e LEFT JOIN entity_aliases a ON a.entity_id = e.id
            WHERE e.merged_into IS NULL AND e.kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))
            GROUP BY e.id LIMIT 20000;
            """, kinds.map { .text($0) })
        return rows.compactMap { r in
            guard let id = r.uuid(0), let v = r.string(1) else { return nil }
            return Candidate(id: id, value: v, aliases: (r.string(2) ?? "").split(separator: "|").map(String.init))
        }
    }

    /// Matching entities with the variant wording, strongest first, at most `entitiesPerTerm`.
    private func entityMatches(_ term: ScreeningTerm, names: [Candidate], contacts: [Candidate]) -> [(UUID, String)] {
        switch term.kind {
        case .name:
            let cands = names.map { WatchlistMatcher.Candidate(entityID: $0.id, name: $0.value, aliases: $0.aliases) }
            return WatchlistMatcher.match(terms: [term.raw], candidates: cands, limitPerTerm: entitiesPerTerm)
                .map { ($0.entityID, "\(Self.strengthLabel($0.strength)): “\($0.matchedOn)”") }
        case .phone:
            var out: [(UUID, String)] = []
            for c in contacts {
                for v in [c.value] + c.aliases {
                    if let p = ScreeningTermClassifier.normalizePhone(v), ScreeningTermClassifier.phonesMatch(term.normalized, p) {
                        out.append((c.id, "\(ScreeningTermClassifier.phoneVariant(term.normalized, p)): “\(c.value)”")); break
                    }
                }
                if out.count >= entitiesPerTerm { break }
            }
            return out
        case .email:
            return contacts.filter { c in ([c.value] + c.aliases).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == term.normalized } }
                .prefix(entitiesPerTerm).map { ($0.id, "same address: “\($0.value)”") }
        }
    }

    static func strengthLabel(_ s: WatchlistMatch.Strength) -> String {
        switch s {
        case .exact: return "exact"
        case .reordered: return "same words, other order"
        case .spelling: return "similar spelling"
        case .initials: return "initials match"
        }
    }

    // MARK: Text

    /// Candidate passages from the safe FTS path: a phrase for names and emails; for phones the
    /// number's own digit groups, its digits run together and its last four digits (each a quoted
    /// literal), later verified number-by-number.
    private func textPool(_ term: ScreeningTerm, scope: RetrievalSourceScope) async throws -> [Chunk] {
        let versions = scope.isActive ? scope.authorizedSourceVersionIDs : nil
        switch term.kind {
        case .name, .email:
            return try await chunks.searchFTSPhrase(term.raw, limit: passageLimit, sourceVersionIDs: versions)
        case .phone:
            let digits = term.normalized.filter(\.isNumber)
            var tokens = term.raw.split { !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
            tokens += [digits, String(digits.suffix(4))]
            let query = tokens.joined(separator: " ")
            if let versions { return try await chunks.searchFTS(query, limit: passageLimit, sourceVersionIDs: versions) }
            return try await chunks.searchFTS(query, limit: passageLimit)
        }
    }

    struct TextHit { let count: Int; let range: Range<String.Index>?; let highlight: String?; let variant: String }

    /// The term's occurrences in `text`, verified (FTS only proposes passages), or nil when none.
    static func textHits(_ term: ScreeningTerm, in text: String) -> TextHit? {
        switch term.kind {
        case .name:
            let n = " " + WatchlistMatcher.normalize(text) + " ", t = " " + term.normalized + " "
            let count = n.components(separatedBy: t).count - 1
            guard count > 0 else { return nil }
            let r = nameRange(term.normalized, in: text)
            return TextHit(count: count, range: r, highlight: r.map { String(text[$0]) }, variant: "exact words")
        case .email:
            let lower = text.lowercased()
            guard lower.count == text.count else {   // lowercasing changed the length: compare safely
                let c = text.components(separatedBy: term.normalized).count - 1
                return c > 0 ? TextHit(count: c, range: nil, highlight: nil, variant: "same address") : nil
            }
            var count = 0, first: Range<String.Index>?
            var from = lower.startIndex
            while let r = lower.range(of: term.normalized, range: from..<lower.endIndex) {
                if emailBounded(lower, r) {
                    count += 1
                    if first == nil { first = r }
                }
                from = r.upperBound
            }
            guard count > 0, let first else { return nil }
            let range = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: first.lowerBound))
                ..< text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: first.upperBound))
            return TextHit(count: count, range: range, highlight: String(text[range]), variant: "same address")
        case .phone:
            var count = 0, first: (Range<String.Index>, String)?
            for (range, number) in phoneCandidates(in: text) where ScreeningTermClassifier.phonesMatch(term.normalized, number) {
                count += 1
                if first == nil { first = (range, number) }
            }
            guard count > 0, let first else { return nil }
            return TextHit(count: count, range: first.0, highlight: String(text[first.0]),
                           variant: ScreeningTermClassifier.phoneVariant(term.normalized, first.1))
        }
    }

    /// The exact words in the original text for a normalised name (case-insensitive, any punctuation
    /// or spacing between the words), or nil when the source spells it with other characters.
    static func nameRange(_ normalized: String, in text: String) -> Range<String.Index>? {
        let words = normalized.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"[^\p{L}\p{N}]+"#) + #"(?![\p{L}\p{N}])"#
        if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return r }
        if words.count == 1 { return text.range(of: normalized, options: [.caseInsensitive, .diacriticInsensitive]) }
        return nil
    }

    static func emailBounded(_ s: String, _ r: Range<String.Index>) -> Bool {
        let localChars = Set("abcdefghijklmnopqrstuvwxyz0123456789._%+-")
        if r.lowerBound > s.startIndex, localChars.contains(s[s.index(before: r.lowerBound)]) { return false }
        guard r.upperBound < s.endIndex else { return true }
        let next = s[r.upperBound]
        if next.isLetter || next.isNumber || next == "-" || next == "_" { return false }
        if next == "." {
            let after = s.index(after: r.upperBound)
            if after < s.endIndex, s[after].isLetter || s[after].isNumber { return false }   // jane@acme.com.au
        }
        return true
    }

    /// Phone-shaped numbers written in `text`: digit groups joined by 1–3 of " .-/()" (no line break);
    /// every contiguous run of groups with 7–15 digits is a candidate, normalised. A group written after
    /// "+" starts a new number, and only the whole "+…" form is offered from it (its tail alone is not).
    static func phoneCandidates(in text: String) -> [(Range<String.Index>, String)] {
        struct Group { let start: String.Index; let end: String.Index; let digits: String; let plus: Bool }
        var groups: [Group] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isASCII, text[i].isNumber else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, text[j].isASCII, text[j].isNumber { j = text.index(after: j) }
            var plusAt: String.Index?
            if i > text.startIndex {
                let b = text.index(before: i)
                if text[b] == "+" { plusAt = b }
                else if text[b] == "(", b > text.startIndex, text[text.index(before: b)] == "+" { plusAt = text.index(before: b) }
            }
            groups.append(Group(start: plusAt ?? i, end: j, digits: String(text[i..<j]), plus: plusAt != nil))
            i = j
        }
        // Split into runs.
        var runs: [[Group]] = []
        for g in groups {
            if let last = runs.last?.last, !g.plus, last.end <= g.start {
                let gap = text[last.end..<g.start]
                if (1...3).contains(gap.count), gap.allSatisfy({ " .-/()".contains($0) }) {
                    runs[runs.count - 1].append(g); continue
                }
            }
            runs.append([g])
        }
        var out: [(Range<String.Index>, String)] = []
        for run in runs {
            let starts = run.first?.plus == true ? [0] : Array(run.indices)
            for s in starts {
                var digits = ""
                for e in s..<run.count {
                    digits += run[e].digits
                    if digits.count > 15 { break }
                    if digits.count >= 7 { out.append((run[s].start..<run[e].end, (run[s].plus ? "+" : "") + digits)) }
                }
            }
        }
        return out
    }

    /// About 240 characters around the hit, whitespace collapsed.
    static func snippet(_ text: String, around range: Range<String.Index>?) -> String {
        let window = 120
        let s: String
        if let range {
            let lo = text.index(range.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
            let hi = text.index(range.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
            s = (lo > text.startIndex ? "…" : "") + text[lo..<hi] + (hi < text.endIndex ? "…" : "")
        } else {
            s = String(text.prefix(2 * window)) + (text.count > 2 * window ? "…" : "")
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Documents

    /// A passage of `objectID` for an entity-only hit: the first live passage stating the term, else
    /// the first live passage (case scope: only passages whose version is in scope, or unversioned).
    private func passage(for term: ScreeningTerm, objectID: UUID, scope: RetrievalSourceScope) async throws -> (passage: String, highlight: String?) {
        let rows = try await database.query("""
            SELECT text, source_version_id FROM chunks
            WHERE object_id = ? AND review_status IS NULL AND superseded_by_run IS NULL
            ORDER BY ordinal LIMIT 400;
            """, [.uuid(objectID)])
        let texts = rows.compactMap { r -> String? in
            if scope.isActive, let v = r.uuid(1), !scope.authorizedSourceVersionIDs.contains(v) { return nil }
            return r.string(0)
        }
        for t in texts { if let h = Self.textHits(term, in: t) { return (Self.snippet(t, around: h.range), h.highlight) } }
        return (texts.first.map { Self.snippet($0, around: nil) } ?? "", nil)
    }

    private func documentNames(_ ids: [UUID]) async throws -> [UUID: String] {
        var names: [UUID: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 400) {
            let slice = Array(ids[start..<min(start + 400, ids.count)])
            let rows = try await database.query("""
                SELECT ko.id, f.url FROM knowledge_objects ko JOIN files f ON f.id = ko.file_id
                WHERE ko.id IN (\(slice.map { _ in "?" }.joined(separator: ",")));
                """, slice.map { .uuid($0) })
            for r in rows {
                guard let id = r.uuid(0), let u = r.string(1) else { continue }
                names[id] = URL(string: u)?.lastPathComponent ?? u
            }
        }
        return names
    }

    /// Documents with live passages in the scope.
    private func documentsInScope(_ scope: RetrievalSourceScope) async throws -> Int {
        guard scope.isActive else {
            return Int(try await database.query("""
                SELECT COUNT(DISTINCT object_id) FROM chunks WHERE review_status IS NULL AND superseded_by_run IS NULL;
                """).first?.int(0) ?? 0)
        }
        var ids = Set<UUID>()
        let versions = scope.authorizedSourceVersionIDs.sorted { $0.uuidString < $1.uuidString }
        for start in stride(from: 0, to: versions.count, by: 400) {
            let slice = versions[start..<min(start + 400, versions.count)]
            let rows = try await database.query("""
                SELECT DISTINCT object_id FROM chunks
                WHERE review_status IS NULL AND superseded_by_run IS NULL AND source_version_id IN (\(slice.map { _ in "?" }.joined(separator: ",")));
                """, slice.map { .uuid($0) })
            for r in rows { if let id = r.uuid(0) { ids.insert(id) } }
        }
        return ids.count
    }
}
