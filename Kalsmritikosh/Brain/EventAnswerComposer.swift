//
//  EventAnswerComposer.swift
//  Kalsmritikosh
//
//  P3-U2 (GO 2 REVISED) — the EXISTENCE and COUNT composers: the answer to
//  "is the patent granted?" is a ROW in the events table, and the composer's
//  whole job is to ask that table and say what it holds. No model, no
//  fact-spam — the owner watched "Reported:" lines ship while the granted
//  milestone sat retrieved and unread.
//
//    existence — matching event found → "Yes — <event> on <date>." cited
//                none found            → honest "No record of …" + receipt
//    count     — "how many hearings"   → the COUNT of matching events, each
//                                        occurrence cited; zero is an honest
//                                        zero, never a guess
//
//  Deterministic: same question + same events → same sentence, always.
//  Timeline rendering (rung 2) composes the SAME matches, ordered.
//

import Foundation

public struct EventAnswerComposition: Sendable, Equatable {
    public let primaryText: String
    public let supportingEvents: [Event]
    public let isNotFound: Bool
    public let receiptLine: String
}

public enum EventAnswerComposer {

    /// Event vocabulary (data): question words → the event title/kind words
    /// they name. A match needs ONE of the words in the event's title
    /// (case-insensitive, whole-word) — precision over recall; the honest
    /// not-found covers the rest.
    nonisolated static let eventVocabulary: [String: [String]] = [
        "granted":   ["granted", "grant"],
        "grant":     ["granted", "grant"],
        "filed":     ["filed", "filing"],
        "filing":    ["filed", "filing"],
        "payment":   ["payment", "paid"],
        "hearing":   ["hearing"],
        "hearings":  ["hearing"],
        "objection": ["objection"],
        "objections": ["objection"],
        "examined":  ["examination"],
        "examination": ["examination"],
        "paid":      ["payment", "paid"],
        "issued":    ["issued"],
    ]

    // MARK: - existence

    public nonisolated static func composeExistence(
        question: String,
        events: [Event],
        documentsSearched: Int
    ) -> EventAnswerComposition? {
        guard let matches = matchEvents(question: question, events: events) else { return nil }
        if let best = matches.first {
            let date = Self.dateFormatter.string(from: best.date)
            let extras = matches.count > 1 ? " (and \(matches.count - 1) related event\(matches.count > 2 ? "s" : ""))" : ""
            return EventAnswerComposition(
                primaryText: "Yes — \(lowercasedTitle(best.title)) on \(date).\(extras)",
                supportingEvents: Array(matches.prefix(3)),
                isNotFound: false,
                receiptLine: "Answered from the dated event record; no model was consulted.")
        }
        return EventAnswerComposition(
            primaryText: "No record of that event in the \(documentsSearched) document(s) searched. "
                + "(Receipt: the dated event record was checked directly; no model was consulted.)",
            supportingEvents: [], isNotFound: true,
            receiptLine: "No matching event on file.")
    }

    // MARK: - count

    public nonisolated static func composeCount(
        question: String,
        events: [Event],
        documentsSearched: Int
    ) -> EventAnswerComposition? {
        guard let matches = matchEvents(question: question, events: events) else { return nil }
        // Distinct occurrences: same title + same DAY collapse (the drain can
        // hold one milestone per source; the count is of happenings, not rows).
        var seen = Set<String>()
        var distinct: [Event] = []
        for e in matches {
            let key = "\(lowercasedTitle(e.title))|\(Self.dayFormatter.string(from: e.date))"
            if seen.insert(key).inserted { distinct.append(e) }
        }
        let noun = subjectNoun(question) ?? "matching events"
        if distinct.isEmpty {
            return EventAnswerComposition(
                primaryText: "No \(noun) appear in the \(documentsSearched) document(s) searched. "
                    + "(Receipt: counted from the dated event record; no model was consulted.)",
                supportingEvents: [], isNotFound: true,
                receiptLine: "Zero matching events — an honest zero, counted not guessed.")
        }
        let dates = distinct.prefix(6).map { Self.dateFormatter.string(from: $0.date) }.joined(separator: ", ")
        return EventAnswerComposition(
            primaryText: "\(distinct.count) \(noun): \(dates).",
            supportingEvents: Array(distinct.prefix(6)),
            isNotFound: false,
            receiptLine: "Counted from the dated event record; every occurrence cited; no model was consulted.")
    }

    // MARK: - timeline (rung 2)

    /// The ordered, dated, cited chain — every line one event, ascending.
    /// Renders ALL dated events in the retrieval set (the timeline layer has
    /// already scoped them); empty → nil (abstain, the pipeline runs).
    public nonisolated static func composeTimeline(
        question: String,
        events: [Event],
        documentsSearched: Int
    ) -> EventAnswerComposition? {
        var seen = Set<String>()
        var distinct: [Event] = []
        for e in events.sorted(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let key = "\(lowercasedTitle(e.title))|\(Self.dayFormatter.string(from: e.date))"
            if seen.insert(key).inserted { distinct.append(e) }
        }
        guard !distinct.isEmpty else { return nil }
        let lines = distinct.prefix(12).map { e in
            "\(Self.dateFormatter.string(from: e.date)) — \(e.title)"
        }
        return EventAnswerComposition(
            primaryText: lines.joined(separator: "\n"),
            supportingEvents: Array(distinct.prefix(12)),
            isNotFound: false,
            receiptLine: "The chain is composed from \(min(distinct.count, 12)) dated event(s), each cited; no model was consulted.")
    }

    // MARK: - A2.1 — list + aggregation

    /// "list all hearings" → the COMPLETE deterministic list of matching
    /// dated events with the honest header ("4 matching records"). nil when
    /// the question names no known event word (the pipeline runs).
    public nonisolated static func composeList(
        question: String,
        events: [Event],
        documentsSearched: Int
    ) -> EventAnswerComposition? {
        guard let matched = matchEvents(question: question, events: events) else { return nil }
        guard !matched.isEmpty else {
            return EventAnswerComposition(
                primaryText: "No matching records in the \(documentsSearched) document(s) searched.",
                supportingEvents: [], isNotFound: true,
                receiptLine: "The event record was searched directly; no model was consulted.")
        }
        var seen = Set<String>()
        let distinct = matched.filter {
            seen.insert("\(lowercasedTitle($0.title))|\(Self.dayFormatter.string(from: $0.date))").inserted
        }
        let lines = distinct.prefix(20).map { "\(Self.dateFormatter.string(from: $0.date)) — \($0.title)" }
        let header = "\(distinct.count) matching record\(distinct.count == 1 ? "" : "s"):"
        return EventAnswerComposition(
            primaryText: ([header] + lines).joined(separator: "\n"),
            supportingEvents: Array(distinct.prefix(20)),
            isNotFound: false,
            receiptLine: "The list is complete over the event record (\(distinct.count) of \(distinct.count) shown\(distinct.count > 20 ? ", first 20 listed" : "")); no model was consulted.")
    }

    /// "what is the total amount paid" → a computed total WITH its operands,
    /// from amount-field facts. Mixed currencies are never summed — each
    /// currency totals separately (shown, not averaged). nil when no amount
    /// facts exist (the pipeline runs).
    public nonisolated static func composeAggregation(
        facts: [GenericFact],
        documentsSearched: Int
    ) -> EventAnswerComposition? {
        let amounts = facts.filter { $0.field.lowercased() == "amount" }
        guard !amounts.isEmpty else { return nil }
        // Parse (currencySymbol, value) from fact values like "₹15,000" / "Rs 7,000".
        var byCurrency: [String: [(Double, String)]] = [:]
        for f in amounts {
            let raw = f.value
            let digits = raw.filter { $0.isNumber || $0 == "." }
            guard let v = Double(digits), v > 0 else { continue }
            let symbol = raw.contains("₹") || raw.lowercased().contains("rs") ? "₹"
                : raw.contains("$") ? "$" : raw.contains("€") ? "€" : "?"
            byCurrency[symbol, default: []].append((v, raw))
        }
        guard !byCurrency.isEmpty else { return nil }
        let parts = byCurrency.sorted { $0.key < $1.key }.map { symbol, entries -> String in
            let total = entries.map(\.0).reduce(0, +)
            let operands = entries.map(\.1).sorted().joined(separator: " + ")
            let formatted = total.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", total) : String(format: "%.2f", total)
            return "Total: \(symbol)\(formatted) (\(operands))"
        }
        return EventAnswerComposition(
            primaryText: parts.joined(separator: "\n"),
            supportingEvents: [], isNotFound: false,
            receiptLine: "The total is computed from \(amounts.count) recorded amount(s); currencies are never mixed; no model was consulted.")
    }

    // MARK: - A2.5 — two-part decomposition (deterministic comparison)

    /// "was the patent granted before the fee was paid" → TWO labeled, cited
    /// blocks (one per fact) plus a DERIVED comparison over the cited dates —
    /// pure date arithmetic, never model reasoning. nil unless the question
    /// carries a comparator word AND names two distinct event vocabularies.
    public nonisolated static func composeComparison(
        question: String,
        events: [Event]
    ) -> EventAnswerComposition? {
        let q = question.lowercased()
        let comparators = ["before", "after", "between", "how long", "on time", "within"]
        guard comparators.contains(where: { q.contains($0) }) else { return nil }
        // Two DISTINCT vocabulary groups named in one question.
        let qTokens = q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var groups: [String] = []
        var seenCanon = Set<String>()
        for t in qTokens {
            guard let terms = eventVocabulary[t], let canon = terms.first else { continue }
            if seenCanon.insert(canon).inserted { groups.append(canon) }
        }
        guard groups.count >= 2 else { return nil }
        func earliest(_ term: String) -> Event? {
            events.filter { $0.title.lowercased().contains(term) }
                .sorted { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }
                .first
        }
        guard let a = earliest(groups[0]), let b = earliest(groups[1]) else { return nil }
        let first = a.date <= b.date ? a : b
        let second = a.date <= b.date ? b : a
        let days = Int((second.date.timeIntervalSince(first.date) / 86_400).rounded())
        let lines = [
            "\(Self.dateFormatter.string(from: a.date)) — \(a.title)",
            "\(Self.dateFormatter.string(from: b.date)) — \(b.title)",
            "Derived comparison: \(first.title) came \(days) day\(days == 1 ? "" : "s") before \(second.title).",
        ]
        return EventAnswerComposition(
            primaryText: lines.joined(separator: "\n"),
            supportingEvents: [a, b],
            isNotFound: false,
            receiptLine: "Two dated records compared by date arithmetic only; each is cited; no model was consulted.")
    }

    // MARK: - shared matching

    /// nil = the question names no known event word (the composer abstains —
    /// the normal pipeline runs); [] = named but nothing matches.
    /// The event-title terms this question's vocabulary names — the same map
    /// matchEvents uses, exposed so the shape-aware fetch can ask the event
    /// table for exactly these terms.
    public nonisolated static func vocabularyTerms(in question: String) -> [String] {
        let qTokens = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var seen = Set<String>()
        return qTokens.flatMap { eventVocabulary[$0] ?? [] }.filter { seen.insert($0).inserted }
    }

    nonisolated static func matchEvents(question: String, events: [Event]) -> [Event]? {
        let wanted = vocabularyTerms(in: question)
        guard !wanted.isEmpty else { return nil }
        let matches = events.filter { e in
            let titleTokens = Set(e.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            return wanted.contains { titleTokens.contains($0) }
        }
        // Deterministic order: newest first, then title, then id (total order).
        return matches.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    nonisolated static func subjectNoun(_ question: String) -> String? {
        let tokens = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return tokens.first { eventVocabulary[$0] != nil }
    }

    nonisolated static func lowercasedTitle(_ t: String) -> String {
        guard let first = t.first else { return t }
        return String(first).lowercased() + t.dropFirst()
    }

    nonisolated static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()
    nonisolated static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
