//
//  ProceedingAnswerer.swift
//  Kalsmritikosh
//
//  Questions about what happened to a PERSON in a proceeding, answered across every document that
//  names them: "When was X sentenced?", "Did X plead guilty?", "What sentence did X receive?",
//  "Give me the timeline of the case against X", "How many documents are about X?", "When was X
//  pardoned?" (a step no document records is said to be unrecorded, never guessed).
//
//  Closed-case simulation, 2026-10-26: these were answered 0–2% of the time — a release came back
//  as a passage. The steps are read with ProceedingEventExtractor from the documents the question
//  retrieved; each answer quotes and cites the sentence that reports the step.
//

import Foundation

public nonisolated enum ProceedingAnswerer {

    public enum Ask: Equatable, Sendable {
        case when(ProceedingEventExtractor.Step)
        case whether(ProceedingEventExtractor.Step)
        case sentenceImposed
        case chargedWith
        case timeline
        case documentCount
    }

    public struct Parsed: Equatable, Sendable {
        public let person: String
        public let ask: Ask
    }

    /// The step a question's verb names.
    static let stepWords: [(String, ProceedingEventExtractor.Step)] = [
        ("sentenced", .sentenced), ("sentence", .sentenced), ("indicted", .charged), ("charged", .charged), ("indict", .charged),
        ("charge", .charged), ("arrested", .arrested), ("arrest", .arrested), ("arraigned", .arraigned), ("plead guilty", .pleaded), ("pleaded guilty", .pleaded),
        ("plead", .pleaded), ("pleaded", .pleaded), ("convicted", .convicted), ("convict", .convicted), ("found guilty", .convicted),
        ("acquitted", .acquitted), ("acquit", .acquitted), ("pardoned", .pardoned), ("pardon", .pardoned),
        ("released from prison", .released), ("released from custody", .released),
    ]

    /// A person's name in the question: two to four capitalised words ("Christi Machala", "Alexandria
    /// Jasmine Estep", "Gary L. Smith"), not the question's own first word.
    static func person(in question: String) -> String? {
        let pattern = #"(?<![A-Za-z])([A-Z][a-z'’\-]+(?:\s+(?:[A-Z]\.|[A-Z][a-z'’\-]+)){1,3})(?:,?\s+(?:Jr|Sr|II|III)\.?)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = question as NSString
        let skip: Set<String> = ["When", "Did", "Was", "Were", "What", "Which", "Who", "How", "Give", "Tell", "Show", "List", "Has", "Is",
                                 "Justice", "Department", "Office", "Attorney", "District", "Court", "United", "States", "The"]
        for m in re.matches(in: question, range: NSRange(location: 0, length: ns.length)) {
            var words = ns.substring(with: m.range(at: 1)).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            while let f = words.first, skip.contains(f) { words.removeFirst() }
            if words.count >= 2, !words.contains(where: { skip.contains($0) }) { return words.joined(separator: " ") }
        }
        return nil
    }

    public static func parse(_ question: String) -> Parsed? {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // A quoted title names a release, not a person.
        guard !question.contains("\""), !question.contains("“"), let name = person(in: question) else { return nil }
        let step = stepWords.first { q.range(of: #"\b"# + $0.0 + #"\b"#, options: .regularExpression) != nil }?.1
        if q.range(of: #"\btimeline\b|\bchronology\b|\bsequence of events\b|\bin (?:chronological )?order\b|\bwhat happened (?:to|with)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .timeline)
        }
        if q.range(of: #"^how many\s+(?:press releases|releases|documents|files|records|reports|articles|announcements)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .documentCount)
        }
        if q.range(of: #"^what\s+(?:sentence|prison (?:term|sentence)|punishment|penalty)\b|\bhow long (?:was|is|will)\b.*\bsentenced\b|^how much (?:prison )?time\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .sentenceImposed)
        }
        // "What was X charged with?" — the offence, as the charging (or plea) sentence states it.
        if q.range(of: #"^what (?:was|were|is|are)\b.*\b(?:charged with|indicted (?:for|on)|accused of)\b|^what (?:crimes?|offen[cs]es?|charges?)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .chargedWith)
        }
        guard let step else { return nil }
        if q.range(of: #"^(?:when|on what (?:date|day)|what (?:date|day)|on which (?:date|day))\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .when(step))
        }
        if q.range(of: #"^(?:did|was|were|has|have|is)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .whether(step))
        }
        return nil
    }

    public struct Source: Sendable {
        public let objectID: UUID
        public let text: String
        public init(objectID: UUID, text: String) { self.objectID = objectID; self.text = text }
    }

    static func render(_ day: DateComponents?) -> String? {
        guard let day, let date = Calendar(identifier: .gregorian).date(from: day) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    static func quote(_ s: String) -> String {
        let t = s.count > 320 ? String(s.prefix(320)) + "…" : s
        return "\u{201C}\(t)\u{201D}"
    }

    static func key(_ f: ProceedingEventExtractor.Finding) -> String {
        guard let d = f.day ?? f.reportedOn, let y = d.year, let m = d.month, let dd = d.day else { return "9999" }
        return String(format: "%04d-%02d-%02d", y, m, dd)
    }

    /// The answer, or nil when the question isn't one of these (the normal pipeline runs).
    public static func answer(_ parsed: Parsed, sources: [Source]) -> VerifiedAnswer? {
        let about = sources.filter { ProceedingEventExtractor.mentionsFully($0.text.lowercased(), tokens: ProceedingEventExtractor.nameTokens(parsed.person)) }
        // One line per step and day across documents (the sentencing release repeats the plea's day).
        var seenSteps = Set<String>()
        let found = about.flatMap { s in ProceedingEventExtractor.findings(in: s.text, person: parsed.person).map { (s.objectID, $0) } }
            .sorted { ($0.1.day == nil ? 1 : 0, key($0.1)) < ($1.1.day == nil ? 1 : 0, key($1.1)) }
            .filter { seenSteps.insert($0.1.step.rawValue + key($0.1)).inserted }
        let name = parsed.person
        func cite(_ items: [(UUID, ProceedingEventExtractor.Finding)]) -> [VerifiedAnswer.Citation] {
            items.map { VerifiedAnswer.Citation(objectID: $0.0, snippet: String($0.1.sentence.prefix(300))) }
        }
        func refuse(_ text: String) -> VerifiedAnswer {
            VerifiedAnswer(body: text, answerText: text, citations: about.prefix(3).map { VerifiedAnswer.Citation(objectID: $0.objectID, snippet: String($0.text.prefix(200))) },
                           confidence: Confidence(0.6), refused: true, refusalReason: "No document records this step for the person.")
        }
        guard !about.isEmpty else { return nil }   // no document names the person: the normal pipeline decides
        switch parsed.ask {
        case .when(let step):
            let hits = found.filter { $0.1.step == step }
            guard let best = hits.first(where: { $0.1.day != nil }) ?? hits.first else {
                // Asked when X was charged, the documents only report the arrest or arraignment:
                // say so, with that day — never present it as the charge.
                if step == .charged, let near = found.first(where: { [.arrested, .arraigned].contains($0.1.step) && ($0.1.day ?? $0.1.reportedOn) != nil }),
                   let day = render(near.1.day ?? near.1.reportedOn) {
                    let text = "The documents don't say when \(name) was charged; they report \(name) was \(near.1.step.phrase) on \(day): \(quote(near.1.sentence))"
                    return VerifiedAnswer(body: text, answerText: text, citations: cite([near]), confidence: Confidence(0.6))
                }
                return refuse("The documents that name \(name) don't record \(name) being \(step.phrase).")
            }
            let text: String
            if let day = render(best.1.day) {
                text = "\(name) was \(step.phrase) on \(day). The document says: \(quote(best.1.sentence))"
            } else if let reported = render(best.1.reportedOn) {
                // The sentence gives no day of its own; the document's printed date is when it was reported.
                text = "The document dated \(reported) reports that \(name) was \(step.phrase); it gives no other day: \(quote(best.1.sentence))"
            } else {
                text = "The documents say \(name) was \(step.phrase) but give no date for it: \(quote(best.1.sentence))"
            }
            return VerifiedAnswer(body: text, answerText: text, citations: cite([best]), confidence: Confidence(0.8))
        case .whether(let step):
            if let hit = found.first(where: { $0.1.step == step }) {
                let text = "Yes — \(quote(hit.1.sentence))"
                return VerifiedAnswer(body: text, answerText: text, citations: cite([hit]), confidence: Confidence(0.8))
            }
            // Asked about a plea, the documents report a jury verdict (or the reverse): that answers it.
            let other: ProceedingEventExtractor.Step? = step == .pleaded ? .convicted : (step == .convicted ? .pleaded : nil)
            if let other, let hit = found.first(where: { $0.1.step == other }) {
                let text = "No — the documents say \(name) \(other == .convicted ? "was convicted" : "pleaded guilty"): \(quote(hit.1.sentence))"
                return VerifiedAnswer(body: text, answerText: text, citations: cite([hit]), confidence: Confidence(0.75))
            }
            return refuse("The documents that name \(name) don't say whether \(name) was \(step.phrase).")
        case .sentenceImposed:
            guard let hit = found.first(where: { $0.1.step == .sentenced && $0.1.detail != nil }) else {
                return refuse("The documents that name \(name) don't state a sentence for \(name).")
            }
            let text = "\(name) was sentenced to \(hit.1.detail ?? ""). The document says: \(quote(hit.1.sentence))"
            return VerifiedAnswer(body: text, answerText: text, citations: cite([hit]), confidence: Confidence(0.8))
        case .chargedWith:
            // The charging sentence names the offence; failing that, the plea or verdict does.
            let order: [ProceedingEventExtractor.Step] = [.charged, .pleaded, .convicted, .sentenced]
            guard let hit = order.lazy.compactMap({ step in found.first { $0.1.step == step && $0.1.sentence.count > 60 } }).first else {
                return refuse("The documents that name \(name) don't state what \(name) was charged with.")
            }
            let text = "The documents say: \(quote(hit.1.sentence))"
            return VerifiedAnswer(body: text, answerText: text, citations: cite([hit]), confidence: Confidence(0.75))
        case .timeline:
            // A step whose sentence gives no day sits at the day its document reports it, marked so.
            let dated = found.filter { ($0.1.day ?? $0.1.reportedOn) != nil }
                .sorted { key($0.1) < key($1.1) }
            guard !dated.isEmpty else {
                return refuse("The documents that name \(name) give no dated step of the case.")
            }
            let lines = dated.map { f -> String in
                let when = f.1.day != nil ? (render(f.1.day) ?? "") : "\(render(f.1.reportedOn) ?? "") (date of the report)"
                return "• \(when) — \(f.1.step.phrase): \(quote(f.1.sentence))"
            }
            let text = "The case against \(name), in date order (\(dated.count) step\(dated.count == 1 ? "" : "s") from \(Set(dated.map(\.0)).count) document\(Set(dated.map(\.0)).count == 1 ? "" : "s")):\n" + lines.joined(separator: "\n")
            return VerifiedAnswer(body: text, answerText: text, citations: cite(dated), confidence: Confidence(0.8))
        case .documentCount:
            let n = about.count
            let lines = about.map { s in "• " + (s.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.count > 25 && ProceedingEventExtractor.fullDate(in: $0) == nil && !$0.hasPrefix("U.S. Department") && !$0.hasPrefix("FOR IMMEDIATE") } ?? "document") }
            let text = "\(n) of the documents found name \(name):\n" + lines.joined(separator: "\n")
            return VerifiedAnswer(body: text, answerText: text,
                                  citations: about.map { VerifiedAnswer.Citation(objectID: $0.objectID, snippet: String($0.text.prefix(200))) },
                                  confidence: Confidence(0.75))
        }
    }
}
