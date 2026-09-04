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

    // MARK: - shared matching

    /// nil = the question names no known event word (the composer abstains —
    /// the normal pipeline runs); [] = named but nothing matches.
    nonisolated static func matchEvents(question: String, events: [Event]) -> [Event]? {
        let qTokens = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let wanted = qTokens.flatMap { eventVocabulary[$0] ?? [] }
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
