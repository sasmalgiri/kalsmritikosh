//
//  EvidenceOnTarget.swift
//  Kalsmritikosh
//
//  Real-case v2 interim review (2026-11-04), items 1 and 6: does an evidence-only (rules) reading
//  actually answer the question it was given? Two failures had one root cause — nothing checked it:
//    • online, the cross-check flagged a correct, verified AI answer as "Needs review" because the
//      rules reading it was compared with was off target ("Date: 12/12/2013." for "When was the fire
//      set?", a sentencing sentence for "Who was charged?", an e-mail address for "When did … learn?");
//    • offline, off-target passages shipped at confidence 0.8 (a descent sentence for "How experienced
//      was the pilot?", a report's title line "… recall event 70934 … 5 product record(s)" for a
//      quantity question, a 2021 recall for an April 2015 question).
//  A reading is ON TARGET only when it
//    1. says something — not a heading, a title line, an e-mail header or (cross-check) a labelled
//       field other than the one asked;
//    2. is about the asked record — a reference number, or a year / month and year, in the question is
//       in the passage or its own document;
//    3. is about the asked person — named in full, or by surname in a document naming them in full;
//    4. is about the asked step (charged, pleaded, sentenced, convicted, restitution, judge …) and
//       shares at least one of the question's own topic words;
//    5. carries the asked kind of value (a date for when, a number for how many, an amount for how
//       much, a name for who; "how experienced" → experience or hours);
//    6. (cross-check) states only dates and amounts its own cited quote states.
//  Deterministic, no model, no file-type branching.
//

import Foundation
import os

public nonisolated enum EvidenceOnTarget {
    public enum Mode: Sendable { case crossCheck, passageQuote }
    enum Asked: Hashable { case date, amount, number, person, yesNo }

    /// The lead of a downgraded evidence-only answer.
    public static let closestMarker = "The closest passage found — it may not answer the question"

    // MARK: - The question

    static func asked(_ question: String) -> Set<Asked> {
        let q = question.lowercased()
        var out: Set<Asked> = []
        func has(_ p: String) -> Bool { q.range(of: p, options: .regularExpression) != nil }
        if has(#"\bwhen\b|\bwhat (?:date|day|time|year|month)s?\b|\bon what dates?\b|\bwhich (?:date|day|year)s?\b|\bat what time\b"#) { out.insert(.date) }
        if has(#"\bhow much\b|\bamount\b|\bhow (?:large|big) (?:a|was|were|is)\b.*\b(?:loss|fine|payment|policy|claim)\b|\bcost\b|\bprice\b|\bworth\b"#) { out.insert(.amount) }
        if has(#"\bhow many\b|\bhow old\b|\bhow long\b|\bnumber of\b|\bwhat age\b|\bwhat sentence\b|\bsentence did\b|\bwhat (?:prison )?term\b|\bhow (?:experienced|fast|far|high)\b"#) { out.insert(.number) }
        if has(#"^\s*(?:and\s+)?(?:who|whom)\b|[,;]\s*(?:and\s+)?who\b|\band who\b|\bwhich (?:judge|attorney|prosecutor|agent|defendants?|persons?|people|firms?|compan(?:y|ies)|individuals?|officials?|lawyers?|court|agenc(?:y|ies))\b"#) { out.insert(.person) }
        if has(#"^\s*(?:was|were|did|does|do|is|are|has|have|had|can|could|will|would)\b"#) { out.insert(.yesNo) }
        return out
    }

    static let generic: Set<String> = [
        "why", "where", "whom", "whose", "any", "each", "other", "also", "about", "document", "documents", "say", "says",
        "said", "state", "states", "stated", "record", "records", "file", "files", "archive", "case", "happen",
        "happened", "according", "anyone", "someone", "get", "got", "has", "have", "had", "his", "her", "he", "she", "they",
        "them", "these", "those", "both", "all", "one", "two", "receive", "received", "give", "given", "name", "named",
        "into", "than", "between", "after", "before", "during", "could", "would", "should", "can", "will", "not", "no", "yes",
        "or", "if", "by", "as", "so", "up", "out", "over", "under", "him", "per", "total", "much", "many", "date", "dates",
        "time", "kind", "type", "exactly", "first", "last", "an", "being", "we", "you", "your", "our", "my", "me", "us",
        "does", "did", "do", "was", "were", "is", "are", "be", "been", "who", "what", "when", "which", "how", "there",
    ]

    /// The question's topic words, the asked person's name and reference numbers left out.
    static func focusWords(_ question: String, person: String?) -> [String] {
        let personTokens = Set((person ?? "").lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return SentenceQuoteComposer.contentWords(question)
            .filter { !generic.contains($0) && !personTokens.contains($0) && !$0.contains(where: \.isNumber) && $0.count >= 3 }
            .sorted()
    }

    /// A light stem: common endings off, at most six letters, a doubled final letter undoubled.
    static func stem(_ word: String) -> String {
        var w = word.lowercased()
        for suffix in ["ations", "ation", "ings", "ing", "edly", "ied", "ies", "ers", "ed", "es", "er", "ly", "s"] where w.count - suffix.count >= 3 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count)); break
        }
        if w.count > 6 { w = String(w.prefix(6)) }
        if w.count >= 4, let last = w.last, w.dropLast().last == last { w = String(w.dropLast()) }
        return w
    }

    static func stems(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }.map(stem))
    }

    static func matches(_ focus: String, in textStems: Set<String>) -> Bool {
        let a = stem(focus)
        return textStems.contains { b in
            let n = min(a.count, b.count, 5)
            return n >= 3 && a.prefix(n) == b.prefix(n) && (min(a.count, b.count) >= 4 || a == b)
        }
    }

    /// The legal steps a question asks about, each with the words a passage about it carries.
    static let stepFamilies: [(trigger: String, words: [String])] = [
        (#"charg|indict|accus"#, ["charg", "indict", "complaint", "count"]),
        (#"plead|pled|\bplea\b"#, ["plead", "pled", "plea", "guilty"]),
        (#"sentenc"#, ["sentenc", "prison", "probation", "month", "year"]),
        (#"convict|verdict|\btrial\b"#, ["convict", "verdict", "trial", "jury", "guilty", "acquit"]),
        (#"restitution|forfeit"#, ["restitution", "forfeit", "repay", "reimburs"]),
        (#"acquit"#, ["acquit"]),
        (#"arrest"#, ["arrest"]),
        (#"\bjudge"#, ["judge", "court", "justice"]),
        (#"prosecut|attorney"#, ["prosecut", "attorney"]),
        (#"investigat|\bagenc"#, ["investigat", "agent", "agency", "agencies", "fbi", "inspector", "service", "police", "department"]),
    ]

    /// "How experienced …?" is answered by experience or hours, "How fast …?" by a speed.
    static let attributeWords: [String: [String]] = [
        "experienced": ["experien", "hours", "career", "certificat", "rating", "rated", "years", "employ", "since"],
        "old": ["age", "year-old", "years old", "born", "aged"],
        "fast": ["speed", "knot", "mph", "per hour", "kts", "rate"],
        "far": ["mile", "feet", "ft", " nm", "distance", "kilomet", "meter"],
        "high": ["feet", "ft", "altitude", "elevation", "agl", "msl"],
    ]

    /// Reference numbers in the question ("70738", "ERA15MA259", "F-1614-2018", "7110.65"), not years or clock times.
    static func referenceIDs(in question: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\w$.,:-])[A-Za-z]{0,6}-?\d[\w.\-]*(?![\w:])"#) else { return [] }
        let ns = question as NSString
        return re.matches(in: question, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let token = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            let digits = token.filter(\.isNumber).count
            guard digits >= 4 else { return nil }
            if token.range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil { return nil }
            return token
        }
    }

    /// Years and month-years the question names ("in 2015", "April 2015", "April 7, 2015").
    static func periods(in question: String) -> [(month: Int?, year: Int)] {
        var out: [(Int?, Int)] = []
        let monthYear = #"(?i)\b"# + VerifiedAnswerComposer.monthAlternation + #"(?:\s+\d{1,2}(?:st|nd|rd|th)?)?,?\s+((?:19|20)\d{2})\b"#
        var rest = question
        if let re = try? NSRegularExpression(pattern: monthYear) {
            let ns = question as NSString
            for m in re.matches(in: question, range: NSRange(location: 0, length: ns.length)) {
                let mon = VerifiedAnswerComposer.monthNumbers[String(ns.substring(with: m.range(at: 1)).lowercased().prefix(3))]
                if let y = Int(ns.substring(with: m.range(at: 2))) { out.append((mon, y)) }
            }
            rest = re.stringByReplacingMatches(in: question, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        for id in referenceIDs(in: rest) { rest = rest.replacingOccurrences(of: id, with: " ") }
        if let re = try? NSRegularExpression(pattern: #"(?<![\w-])((?:19|20)\d{2})(?![\w-])"#) {
            let ns = rest as NSString
            for m in re.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                if let y = Int(ns.substring(with: m.range(at: 1))) { out.append((nil, y)) }
            }
        }
        return out
    }

    static func mentions(period p: (month: Int?, year: Int), in text: String) -> Bool {
        let y = String(p.year), yy = String(p.year % 100)
        guard let month = p.month else {
            return text.range(of: #"(?<!\d)"# + y + #"(?!\d)|(?<!\d)"# + y + #"\d{4}(?!\d)|\b\d{1,2}/\d{1,2}/"# + yy + #"\b"#, options: .regularExpression) != nil
        }
        if VerifiedAnswerComposer.values(in: text).dates.contains(where: { $0.month == month && $0.year == p.year }) { return true }
        let mm = String(format: "%02d", month)
        return text.range(of: #"(?<!\d)"# + y + "-?" + mm + #"(?:-?\d{2})?(?!\d)|\b0?"# + String(month) + #"/\d{1,2}/(?:"# + y + "|" + yy + #")\b"#,
                          options: .regularExpression) != nil
    }

    // MARK: - The reading

    /// The answer's own words: receipt lines and the "Also on file" tail off.
    static func statedPart(_ a: VerifiedAnswer) -> String {
        var text = a.answerText ?? a.body
        for cut in ["\n\n(", "\n\n---", "\n---"] {
            if let r = text.range(of: cut) { text = String(text[..<r.lowerBound]) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The spans inside curly quotes, and the text outside them.
    static func split(_ stated: String) -> (inside: [String], outside: String) {
        guard let re = try? NSRegularExpression(pattern: "\u{201C}([^\u{201D}]*)\u{201D}?") else { return ([], stated) }
        let ns = stated as NSString
        let ms = re.matches(in: stated, range: NSRange(location: 0, length: ns.length))
        let inside = ms.map { ns.substring(with: $0.range(at: 1)) }
        let outside = re.stringByReplacingMatches(in: stated, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
            .replacingOccurrences(of: "The document states:", with: " ")
        return (inside, outside.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Why the core text says nothing, or nil.
    static func nonAnswer(_ core: String, question: String, mode: Mode) -> String? {
        let t = core.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return "it says nothing" }
        let firstLine = t.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? t
        if firstLine.range(of: #"^<?[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+>?$"#, options: .regularExpression) != nil || t.contains("JavaMail") {
            return "it is an e-mail header"
        }
        let head = String(t.prefix(260))
        if head.range(of: #"(?i)for immediate release|forwarded (?:release|message)|-{5,}\s*original message"#, options: .regularExpression) != nil {
            return "it is a document heading"
        }
        let words = t.split(whereSeparator: \.isWhitespace).count
        if t.range(of: #"[.!?]["”’)\]]?$"#, options: .regularExpression) == nil, t.contains(" — ") || t.contains(" – "), words <= 30 {
            return "it is a title line"
        }
        if mode == .crossCheck, !t.contains("\n"),
           let re = try? NSRegularExpression(pattern: #"^([A-Z][A-Za-z /&()\-]{0,30}):\s*(.{1,80})$"#),
           let m = re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) {
            let label = (t as NSString).substring(with: m.range(at: 1))
            let value = (t as NSString).substring(with: m.range(at: 2))
            let questionStems = stems(question)
            let labelMatches = label.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 3 }
                .contains { matches($0, in: questionStems) }
            if value.split(separator: " ").count <= 8, !labelMatches { return "it is a labelled field (\(label)) the question does not ask for" }
        }
        return nil
    }

    static func hasDateOrTime(_ text: String) -> Bool {
        !VerifiedAnswerComposer.values(in: text).dates.isEmpty
            || text.range(of: #"\b\d{1,2}:\d{2}\b|\b(?:19|20)\d{2}\b|\b\d{4}\s*(?:hours|local|[ECMP][DS]T|UTC)\b|\babout \d{4}\b"#, options: .regularExpression) != nil
    }

    static func hasName(_ text: String) -> Bool {
        !VerifiedAnswerComposer.names(in: text).isEmpty
            || text.range(of: #"(?<=[a-z,;]\s)[A-Z][a-z]{2,}"#, options: .regularExpression) != nil
    }

    /// Nil when the reading is on target for the question; otherwise why not, in plain words.
    /// `quotes` are the reading's cited snippets; `recordTexts` the text of the documents it cites.
    public static func offTargetReason(question: String, answer: VerifiedAnswer, recordTexts: [String], mode: Mode) -> String? {
        if answer.body.hasPrefix(closestMarker) { return "it was already marked as the closest passage" }
        let stated = statedPart(answer)
        let quotes = answer.citations.map(\.snippet).filter { !$0.isEmpty }
        let (inside, outside) = split(stated)
        let core = inside.isEmpty ? stated : inside.joined(separator: " ")
        if let why = nonAnswer(core, question: question, mode: mode) { return why }
        let evidence = ([stated] + quotes).joined(separator: "\n")
        let record = ([evidence] + recordTexts).joined(separator: "\n")
        // 2. The asked record.
        for id in referenceIDs(in: question) where record.range(of: id, options: .caseInsensitive) == nil {
            return "it is not about \(id)"
        }
        for p in periods(in: question) where !mentions(period: p, in: record) {
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            let label = p.month.map { m in months[m - 1] + " \(p.year)" } ?? String(p.year)
            return "it is about a record from another time than \(label)"
        }
        // 3. The asked person.
        let person = ProceedingAnswerer.person(in: question)
        if let person, !ProceedingAnswerer.namesFully(evidence, person: person) {
            let surname = person.split(separator: " ").last.map(String.init) ?? person
            let bySurname = VerifiedAnswerComposer.mentions(evidence, name: surname)
            if !(bySurname && recordTexts.contains { ProceedingAnswerer.namesFully($0, person: person) }) {
                return "it is not about \(person)"
            }
        }
        // 4. The asked step and the question's own topic.
        let lowerQ = question.lowercased()
        let evidenceStems = stems(evidence)
        let lowerEvidence = evidence.lowercased()
        let families = stepFamilies.filter { lowerQ.range(of: $0.trigger, options: .regularExpression) != nil }
        if !families.isEmpty, !families.contains(where: { $0.words.contains { lowerEvidence.contains($0) } }) {
            return "it is not about the step asked"
        }
        let focus = focusWords(question, person: person)
        if !focus.isEmpty, !focus.contains(where: { matches($0, in: evidenceStems) }) {
            return "it shares none of the question's topic"
        }
        // 5. The asked kind of value.
        if let r = lowerQ.range(of: #"\bhow (experienced|old|fast|far|high)\b"#, options: .regularExpression) {
            let adjective = String(lowerQ[r].split(separator: " ").last ?? "")
            if let words = attributeWords[adjective], !words.contains(where: { lowerEvidence.contains($0) }) {
                return "it does not say how \(adjective)"
            }
        }
        let kinds = asked(question).subtracting([.yesNo])
        if !kinds.isEmpty {
            let values = VerifiedAnswerComposer.values(in: evidence)
            let carries = kinds.contains { kind in
                switch kind {
                case .date: return hasDateOrTime(evidence)
                case .amount: return !values.money.isEmpty || !values.numbers.isEmpty
                case .number: return !values.numbers.isEmpty || !values.money.isEmpty
                case .person: return hasName(core) || hasName(outside)
                case .yesNo: return true
                }
            }
            if !carries { return "it gives no \(kinds.contains(.date) ? "date" : kinds.contains(.person) ? "name" : "number")" }
        }
        // 6. Its own dates and amounts are in its quote.
        if mode == .crossCheck, !outside.isEmpty {
            let said = VerifiedAnswerComposer.values(in: outside)
            let quoted = VerifiedAnswerComposer.values(in: (inside + quotes).joined(separator: "\n"))
            for d in said.dates where !quoted.dates.contains(where: { $0.month == d.month && (d.day == nil || $0.day == nil || $0.day == d.day) && (d.year == nil || $0.year == nil || $0.year == d.year) }) {
                return "the date it gives is not in its quote"
            }
            for m in said.money where !quoted.money.contains(m) && !quoted.numbers.contains(m) {
                return "the amount it gives is not in its quote"
            }
        }
        return nil
    }

    /// The evidence-only answer, said to be only the closest passage, at a confidence well below 0.8.
    public static func downgraded(_ a: VerifiedAnswer, reason: String) -> VerifiedAnswer {
        let body = "\(closestMarker) (\(reason)):\n\n" + a.body
        var out = VerifiedAnswer(body: body, answerText: a.answerText, intentKind: a.intentKind, citations: a.citations,
                                 confidence: Confidence(min(a.confidence.value, 0.3)), contradictions: a.contradictions,
                                 refused: a.refused, refusalReason: a.refusalReason, report: a.report, walkSteps: a.walkSteps,
                                 source: a.source, reasoningTrace: a.reasoningTrace, answerState: a.answerState,
                                 ledgerAnswerID: a.ledgerAnswerID)
        out.resolvedQuestion = a.resolvedQuestion
        out.ledgerState = a.ledgerState
        return out
    }

    /// Offline: an evidence-only passage answer checked against the question; off target → downgraded.
    public static func checked(question: String, _ a: VerifiedAnswer, chunks: [RetrievedChunk]) -> VerifiedAnswer {
        guard !a.refused, !a.citations.isEmpty else { return a }
        let cited = Set(a.citations.map(\.objectID))
        let texts = chunks.filter { cited.contains($0.chunk.objectID) }.map(\.chunk.text)
        guard let why = offTargetReason(question: question, answer: a, recordTexts: texts, mode: .passageQuote) else { return a }
        KalsmritikoshLog.brain.info("evidence-only passage off target (\(why, privacy: .public)) — shown as the closest passage")
        return downgraded(a, reason: why)
    }
}
