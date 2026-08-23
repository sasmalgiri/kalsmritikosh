//
//  QueryNaturalParser.swift
//  Kalsmritikosh
//
//  Turns a plain-language phrase into a LedgerQuery by FILLING the safe builder
//  — it only ever chooses a subject + filters from the fixed catalog, never
//  emits SQL. Deterministic and on-device (works in Lightning mode). This is
//  also the exact structured shape an optional on-device LLM would produce, so
//  it's the safe slot AI can plug into later without changing the safety model.
//
//  Examples it understands:
//    "documents added last month"
//    "organizations with confidence over 0.8"
//    "events in 2024"
//    "open conflicts"
//    "top 5 relationships"
//    "people named Alice"
//

import Foundation

public enum QueryNaturalParser {

    public struct Parsed: Sendable {
        public let query: LedgerQuery
        public let summary: String        // "Documents · added last month"
    }

    public static func parse(_ raw: String,
                             now: Date = Date(),
                             calendar: Calendar = Calendar(identifier: .gregorian)) -> Parsed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        let subject = detectSubject(lower)
        let dateField = subject.fields.first { $0.kind == .date }
        let numberField = subject.fields.first { $0.kind == .number }
        let textField = subject.fields.first { $0.kind == .text || $0.kind == .fileName }

        var filters: [QueryFilter] = []
        var parts: [String] = []
        var limit = 100
        var sortKey: String? = nil
        var sortDesc = subject.defaultSortDescending

        // "top N" → limit N + sort by the number field descending.
        if let n = firstInt(after: #"top\s+"#, in: lower), n > 0, n <= 1000 {
            limit = n
            if let nf = numberField { sortKey = nf.key; sortDesc = true }
            parts.append("top \(n)")
        }

        // Dates.
        if let df = dateField, let (op, v, v2, label) = detectDate(lower, now: now, calendar: calendar) {
            filters.append(QueryFilter(fieldKey: df.key, op: op, value: v, value2: v2))
            parts.append("\(df.label.lowercased()) \(label)")
        }

        // Numbers (confidence / weight).
        if let nf = numberField {
            if let n = firstDecimal(after: #"(?:over|above|greater than|more than|at least|>)\s*"#, in: lower) {
                filters.append(QueryFilter(fieldKey: nf.key, op: .greaterThan, value: n))
                parts.append("\(nf.label.lowercased()) over \(n)")
            } else if let n = firstDecimal(after: #"(?:under|below|less than|<)\s*"#, in: lower) {
                filters.append(QueryFilter(fieldKey: nf.key, op: .lessThan, value: n))
                parts.append("\(nf.label.lowercased()) under \(n)")
            }
        }

        // Choice (kind / status / severity).
        for cf in subject.fields where cf.kind == .choice {
            if let match = cf.options.first(where: { optionMentioned($0, cf.key, in: lower) }) {
                filters.append(QueryFilter(fieldKey: cf.key, op: .isEqual, value: match))
                parts.append("\(cf.label.lowercased()) is \(match)")
            }
        }

        // Free text: quoted phrase, or after named/called/containing/about.
        if let tf = textField, let phrase = detectTextPhrase(text) {
            filters.append(QueryFilter(fieldKey: tf.key, op: .contains, value: phrase))
            parts.append("\(tf.label.lowercased()) contains “\(phrase)”")
        }

        let summary = parts.isEmpty ? subject.label : "\(subject.label) · " + parts.joined(separator: ", ")
        let query = LedgerQuery(subjectID: subject.id, filters: filters,
                                sortFieldKey: sortKey, sortDescending: sortDesc, limit: limit)
        return Parsed(query: query, summary: summary)
    }

    // MARK: - Subject

    private static func detectSubject(_ lower: String) -> QuerySubject {
        let table: [(id: String, keys: [String])] = [
            ("relationships", ["relationship", "connection", "who paid", "linked", "network", "between"]),
            ("conflicts", ["conflict", "contradiction", "disagree", "inconsistenc"]),
            ("gaps", ["gap", "missing", "absent", "not ingested", "follow-up", "follow up", "to-do", "todo"]),
            ("events", ["event", "timeline", "happened", "meeting", "invoice", "delivery", "contract signed", "when did"]),
            ("people", ["person", "people", "individual", "organization", "organisation", "company", "companies",
                        "org", "vendor", "client", "who is", "named", "entities", "entity"]),
            ("documents", ["document", "file", "pdf", "email", "spreadsheet", "source", "added", "ingested"])
        ]
        for row in table where row.keys.contains(where: { lower.contains($0) }) {
            if let s = LedgerQueryCatalog.subject(row.id) { return s }
        }
        return LedgerQueryCatalog.subject("documents") ?? LedgerQueryCatalog.subjects[0]
    }

    // MARK: - Dates

    private static func detectDate(_ lower: String, now: Date, calendar: Calendar)
        -> (QueryOperator, String, String, String)? {
        func range(_ comp: Calendar.Component, offset: Int) -> (String, String)? {
            guard let base = calendar.date(byAdding: comp, value: offset, to: now),
                  let interval = calendar.dateInterval(of: comp, for: base),
                  let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return (ymd(interval.start), ymd(last))
        }
        if lower.contains("today"), let i = calendar.dateInterval(of: .day, for: now) {
            let d = ymd(i.start); return (.onDate, d, "", "today")
        }
        if lower.contains("yesterday"), let y = calendar.date(byAdding: .day, value: -1, to: now),
           let i = calendar.dateInterval(of: .day, for: y) {
            return (.onDate, ymd(i.start), "", "yesterday")
        }
        if lower.contains("last month"), let (a, b) = range(.month, offset: -1) { return (.between, a, b, "last month") }
        if lower.contains("this month"), let (a, b) = range(.month, offset: 0) { return (.between, a, b, "this month") }
        if lower.contains("last week"), let (a, b) = range(.weekOfYear, offset: -1) { return (.between, a, b, "last week") }
        if lower.contains("this week"), let (a, b) = range(.weekOfYear, offset: 0) { return (.between, a, b, "this week") }
        if lower.contains("last year"), let (a, b) = range(.year, offset: -1) { return (.between, a, b, "last year") }
        if lower.contains("this year"), let (a, b) = range(.year, offset: 0) { return (.between, a, b, "this year") }
        // "in 2024"
        if let year = firstMatch(#"in\s+((?:19|20)\d\d)"#, group: 1, in: lower) {
            return (.between, "\(year)-01-01", "\(year)-12-31", "in \(year)")
        }
        // "before/after yyyy-mm-dd"
        if let d = firstMatch(#"before\s+(\d{4}-\d{2}-\d{2})"#, group: 1, in: lower) {
            return (.before, d, "", "before \(d)")
        }
        if let d = firstMatch(#"after\s+(\d{4}-\d{2}-\d{2})"#, group: 1, in: lower) {
            return (.after, d, "", "after \(d)")
        }
        return nil
    }

    // MARK: - Text

    private static func detectTextPhrase(_ text: String) -> String? {
        // Quoted phrase wins.
        if let q = firstMatch(#"[“\"']([^“\"']{2,})[”\"']"#, group: 1, in: text) { return q }
        let lower = text.lowercased()
        for kw in ["named ", "called ", "containing ", "contains ", "about ", "mentioning "] {
            if let r = lower.range(of: kw) {
                let tail = String(text[text.index(text.startIndex, offsetBy: text.distance(from: lower.startIndex, to: r.upperBound))...])
                let phrase = tail.trimmingCharacters(in: .whitespacesAndNewlines)
                if phrase.count >= 2 { return phrase }
            }
        }
        return nil
    }

    private static func optionMentioned(_ option: String, _ fieldKey: String, in lower: String) -> Bool {
        // Direct + a few friendly synonyms.
        if lower.contains(option) { return true }
        switch option {
        case "organization": return lower.contains("organisation") || lower.contains("compan") || lower.contains(" org")
        case "person": return lower.contains("people") || lower.contains("individual")
        case "high": return lower.contains("severe") || lower.contains("critical")
        default: return false
        }
    }

    // MARK: - Regex helpers

    private static func firstMatch(_ pattern: String, group: Int, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, options: [], range: range), m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }
    private static func firstDecimal(after prefix: String, in s: String) -> String? {
        firstMatch(prefix + #"([0-9]+(?:\.[0-9]+)?)"#, group: 1, in: s)
    }
    private static func firstInt(after prefix: String, in s: String) -> Int? {
        firstMatch(prefix + #"([0-9]+)"#, group: 1, in: s).flatMap { Int($0) }
    }
    private static let ymdFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static func ymd(_ d: Date) -> String { ymdFormatter.string(from: d) }
}
