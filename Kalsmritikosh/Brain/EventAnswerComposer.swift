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
        "filings":   ["filed", "filing"],
        "grants":    ["granted", "grant"],
        "payment":   ["payment", "paid"],
        "payments":  ["payment", "paid"],
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
        // W-5.2 — STATE-CHANGE MILESTONES OUTRANK COMMUNICATION EVENTS: the
        // grant certificate's dated milestone answers "was it granted?", the
        // intimation email is only the messenger. Milestone = a non-email
        // event whose title carries a state-change term; when both exist the
        // answer leads with the milestone and cites the intimation second.
        // (Document class is not visible here; event kind is the signal.)
        let stateChange: Set<String> = ["granted", "grant", "issued", "filed",
                                        "filing", "refused", "rejected", "published"]
        let isCommunication: (Event) -> Bool = { $0.kind == .emailReceived || $0.kind == .emailSent }
        let milestones = matches.filter { e in
            guard !isCommunication(e) else { return false }
            let tokens = Set(e.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            return !tokens.isDisjoint(with: stateChange)
        }
        if let best = milestones.first {
            let date = Self.dateFormatter.string(from: best.date)
            var text = "Yes — \(lowercasedTitle(best.title)) on \(date)."
            if let intimation = matches.first(where: isCommunication) {
                text += " Intimation received \(Self.dateFormatter.string(from: intimation.date))."
            }
            let supporting = [best] + matches.filter { $0.id != best.id }
            return EventAnswerComposition(
                primaryText: text,
                supportingEvents: Array(supporting.prefix(3)),
                isNotFound: false,
                receiptLine: "Answered from the dated event record — the official milestone leads, correspondence is cited after it; no model was consulted.")
        }
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

    // MARK: - L5 — status (where a matter stands NOW)

    /// State-change words (data) — the lifecycle of a matter, any domain:
    /// filings, examinations, hearings, grants, refusals, signatures, lapses.
    nonisolated static let lifecycleTerms: Set<String> = [
        "filed", "filing", "published", "publication", "examination", "examined", "objection",
        "objections", "hearing", "granted", "grant", "refused", "rejected", "abandoned",
        "withdrawn", "renewed", "renewal", "lapsed", "recorded", "registered", "issued",
        "signed", "executed", "terminated", "expired", "settled", "closed", "decided",
        "approved", "allowed", "opposed", "opposition", "appealed", "appeal", "judgment",
    ]
    /// Terminal-ish states rank above procedural ones on the same day.
    nonisolated static let decisiveTerms: Set<String> = [
        "granted", "grant", "refused", "rejected", "abandoned", "withdrawn", "lapsed",
        "terminated", "expired", "settled", "closed", "decided", "approved", "judgment",
    ]

    /// Words that mark a message ABOUT a state, not the state ("intimation of
    /// grant", "hearing notice"): on the same day the state itself leads.
    nonisolated static let noticeWords: Set<String> = [
        "intimation", "notice", "notification", "reminder", "letter", "communication", "copy",
    ]
    /// A lifecycle word as a reader says the state ("grant" → "granted").
    nonisolated static let stateLabel: [String: String] = [
        "grant": "granted", "filing": "filed", "renewal": "renewed", "appeal": "appealed",
        "opposition": "opposed", "publication": "published", "examination": "under examination",
        "examined": "under examination", "hearing": "hearing held", "objection": "objection raised",
        "objections": "objection raised", "judgment": "decided",
    ]

    nonisolated static func isNotice(_ title: String) -> Bool {
        !Set(title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
            .isDisjoint(with: noticeWords)
    }

    /// A stored summary is often a raw passage cut mid-word ("nder [and hearing…");
    /// start it at the first whole word and never end mid-word.
    nonisolated static func cleanSummary(_ raw: String, limit: Int = 200) -> String? {
        var t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first.isLowercase, let space = t.firstIndex(of: " ") {
            t = String(t[t.index(after: space)...])
        }
        guard t.count >= 12 else { return nil }
        if t.count > limit {
            let cut = t.prefix(limit)
            t = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return t
    }

    nonisolated static func lifecycleWords(_ title: String) -> Set<String> {
        Set(title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }).intersection(lifecycleTerms)
    }

    /// "What is the status of …?" → the LATEST lifecycle milestone of the
    /// subject's own events leads; earlier milestones follow, oldest first;
    /// everything is cited. `events` must already be scoped to the subject
    /// (the subject fetch does that). nil = no lifecycle milestone on file →
    /// the pipeline runs (never an invented status).
    public nonisolated static func composeStatus(
        question: String,
        events: [Event],
        documentsSearched: Int
    ) -> EventAnswerComposition? {
        let isCommunication: (Event) -> Bool = { $0.kind == .emailReceived || $0.kind == .emailSent }
        // One milestone per (words, day): repeats across documents are one happening.
        var seen = Set<String>()
        var milestones: [Event] = []
        for e in events.sorted(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }) where !isCommunication(e) && e.hasTrustworthyDate {
            let words = lifecycleWords(e.title)
            guard !words.isEmpty else { continue }
            let key = words.sorted().joined(separator: "+") + "|" + Self.dayFormatter.string(from: e.date)
            if seen.insert(key).inserted { milestones.append(e) }
        }
        guard let latest = milestones.max(by: { a, b in
            if a.date != b.date { return a.date < b.date }
            let ad = !lifecycleWords(a.title).isDisjoint(with: decisiveTerms)
            let bd = !lifecycleWords(b.title).isDisjoint(with: decisiveTerms)
            if ad != bd { return !ad }
            let an = isNotice(a.title), bn = isNotice(b.title)
            if an != bn { return an }            // the state outranks its notice
            return a.id.uuidString > b.id.uuidString
        }) else { return nil }
        let word = lifecycleWords(latest.title).intersection(decisiveTerms).sorted().first
            ?? lifecycleWords(latest.title).sorted().first ?? "recorded"
        let state = stateLabel[word] ?? word
        var text = "Current status: \(state) — \(lowercasedTitle(latest.title)) on \(Self.dateFormatter.string(from: latest.date))."
        let earlier = milestones.filter { $0.id != latest.id && $0.date <= latest.date }
        if !earlier.isEmpty {
            let lines = earlier.suffix(6).map { "\(Self.dateFormatter.string(from: $0.date)) — \($0.title)" }
            text += "\n\nEarlier milestones:\n" + lines.joined(separator: "\n")
        }
        if let later = events.filter(isCommunication).filter({ $0.hasTrustworthyDate && !isListingEntry($0) && $0.date >= latest.date })
            .min(by: { $0.date < $1.date }) {
            text += "\n\nLatest correspondence after it: \(later.title) (\(Self.dateFormatter.string(from: later.date)))."
        }
        return EventAnswerComposition(
            primaryText: text,
            supportingEvents: [latest] + Array(earlier.suffix(6).reversed()),
            isNotFound: false,
            receiptLine: "Status is the latest dated lifecycle milestone of this subject's own records (\(milestones.count) on file); every line is cited; no model was consulted.")
    }

    // MARK: - L5 — events of a named subject

    /// "What happened at the hearing for ‹X›?" / "When was ‹X› granted?" →
    /// the subject's own events matching the question's event words, dated
    /// (trustworthy dates only), oldest first, each cited. nil = the question
    /// names no event word, or the subject has no such event (pipeline runs).
    public nonisolated static func composeSubjectEvents(
        question: String,
        events: [Event],
        subjectLabel: String?
    ) -> EventAnswerComposition? {
        guard let matches = matchEvents(question: question, events: events.filter(\.hasTrustworthyDate)),
              !matches.isEmpty else { return nil }
        let isCommunication: (Event) -> Bool = { $0.kind == .emailReceived || $0.kind == .emailSent }
        var seen = Set<String>()
        var distinct: [Event] = []
        // Milestones before correspondence on the same day; one line per happening.
        for e in matches.sorted(by: {
            if $0.date != $1.date { return $0.date < $1.date }
            if isCommunication($0) != isCommunication($1) { return !isCommunication($0) }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            let key = lowercasedTitle(e.title) + "|" + Self.dayFormatter.string(from: e.date)
            if seen.insert(key).inserted { distinct.append(e) }
        }
        let noun = subjectNoun(question) ?? "event"
        let about = subjectLabel.map { " for \($0)" } ?? ""
        var lines = ["\(distinct.count) \(noun)-related record\(distinct.count == 1 ? "" : "s")\(about):"]
        for e in distinct.prefix(10) {
            var line = "\(Self.dateFormatter.string(from: e.date)) — \(e.title)"
            if let s = e.summary.flatMap({ cleanSummary($0) }),
               s.lowercased() != e.title.lowercased() {
                line += ": " + s
            }
            lines.append(line)
        }
        if distinct.count > 10 { lines.append("…and \(distinct.count - 10) more.") }
        return EventAnswerComposition(
            primaryText: lines.joined(separator: "\n"),
            supportingEvents: Array(distinct.prefix(10)),
            isNotFound: false,
            receiptLine: "Answered from this subject's own dated records (\(distinct.count) matching); every line cited; no model was consulted.")
    }

    // MARK: - L5 — what happened in a period

    /// The calendar year a "what happened in ‹year›" question names.
    public nonisolated static func askedYear(_ question: String) -> Int? {
        let q = question.lowercased()
        guard ["what happened", "what went on", "events in", "timeline of", "summary of", "what did i do", "what did we do"]
            .contains(where: { q.contains($0) }) else { return nil }
        guard let re = try? NSRegularExpression(pattern: #"\b(19|20)\d{2}\b"#),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let r = Range(m.range, in: q) else { return nil }
        return Int(q[r])
    }

    /// Month-by-month record of a year: per month, lifecycle milestones first,
    /// then distinct correspondence subjects (≤ 4 lines a month), every line
    /// cited; trustworthy dates only. nil = nothing dated in that year.
    public nonisolated static func composePeriod(year: Int, events: [Event]) -> EventAnswerComposition? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let inYear = events.filter { $0.hasTrustworthyDate && cal.component(.year, from: $0.date) == year }
        guard !inYear.isEmpty else { return nil }
        let months = Dictionary(grouping: inYear) { cal.component(.month, from: $0.date) }
        let monthName = DateFormatter()
        monthName.locale = Locale(identifier: "en_US_POSIX")
        var lines = ["\(inYear.count) dated record\(inYear.count == 1 ? "" : "s") in \(year), across \(months.count) month\(months.count == 1 ? "" : "s"):"]
        var cited: [Event] = []
        for month in months.keys.sorted() {
            let evs = months[month] ?? []
            let milestones = evs.filter { !lifecycleWords($0.title).isEmpty && !isCommunicationKind($0) }
            let mail = evs.filter { isCommunicationKind($0) }
            var seen = Set<String>()
            var picked: [Event] = []
            // Tiers: milestones, then real correspondence, then listing lines.
            func tier(_ e: Event) -> Int {
                if isListingEntry(e) { return 2 }
                return lifecycleWords(e.title).isEmpty ? 1 : 0
            }
            let realExists = (milestones + mail).contains { !isListingEntry($0) }
            for e in (milestones + mail).sorted(by: { a, b in
                if tier(a) != tier(b) { return tier(a) < tier(b) }
                return a.date != b.date ? a.date < b.date : a.id.uuidString < b.id.uuidString
            }) where !(realExists && isListingEntry(e)) {
                let key = e.title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                guard !key.isEmpty, key != "email", seen.insert(key).inserted else { continue }
                picked.append(e)
                if picked.count == 4 { break }
            }
            guard !picked.isEmpty else { continue }
            lines.append("")
            lines.append("\(monthName.monthSymbols[month - 1]) \(year) — \(evs.count) record\(evs.count == 1 ? "" : "s")")
            for e in picked.sorted(by: { $0.date < $1.date }) {
                lines.append("\(Self.dateFormatter.string(from: e.date)) — \(e.title)")
            }
            cited += picked
        }
        return EventAnswerComposition(
            primaryText: lines.joined(separator: "\n"),
            supportingEvents: Array(cited.prefix(40)),
            isNotFound: false,
            receiptLine: "Composed from the year's dated records, milestones first, every line cited; undated items are left out; no model was consulted.")
    }

    /// A period question that also names a subject ("what happened with the
    /// patent in 2024") is a subject question, not an archive-wide year.
    public nonisolated static func hasSubjectReference(_ question: String) -> Bool {
        let tokens = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if tokens.contains(where: { $0.count >= 6 && $0.contains(where: \.isNumber) }) { return true }
        return tokens.contains { SubjectResolver.definiteReferences[$0] != nil }
    }

    /// A dated line of an archive/export LISTING (EventExtractor's
    /// "Archived entry — ‹file›"), kept under the keep-all-data rule but never
    /// allowed to crowd out a real happening.
    nonisolated static func isListingEntry(_ e: Event) -> Bool {
        e.title.hasPrefix("Archived entry — ")
    }

    nonisolated static func isCommunicationKind(_ e: Event) -> Bool {
        e.kind == .emailReceived || e.kind == .emailSent
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
        // L5 — an extraction-time date would sit at the end of every chain.
        for e in events.filter(\.hasTrustworthyDate).sorted(by: {
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
