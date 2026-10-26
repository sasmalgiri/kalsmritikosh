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
        case office
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
        // "Jose Garcia-Zamora", "Mary O'Neil-Smith": a hyphen may join two capitalised parts.
        // "McKinney", "DeShawn", "O'Brien": a capital may follow a short prefix inside the name.
        let part = #"(?:Mc|Mac|De|Di|La|Le|O'|O’)?[A-Z][a-z'’]+(?:-[A-Z][a-z'’]+)?"#
        let pattern = #"(?<![A-Za-z])("# + part + #"(?:\s+(?:[A-Z]\.|"# + part + #")){1,3})(?:,?\s+(?:Jr|Sr|II|III)\.?)?"#
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
        // "Which office prosecuted X?" — the office the person's own releases name.
        if q.range(of: #"^\s*(?:which|what)\s+(?:u\.s\. attorney'?s\s+|united states attorney'?s\s+|federal\s+)?(?:office|agency|prosecutors?|district|division|department)\b.*\b(?:prosecut\w*|handl\w*|brought|charg\w*|tried|pursued)\b|\bwho prosecuted\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .office)
        }
        // "What was X charged with?" — the offence, as the charging (or plea) sentence states it.
        if q.range(of: #"^what\b.*\b(?:charged with|indicted (?:for|on)|accused of)\b|^what (?:crimes?|offen[cs]es?|charges?)\b"#, options: .regularExpression) != nil {
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

    /// Offices a release names: a heading line of its own, the announcing office, a "prosecuted by …
    /// for the … District of …" line.
    static func offices(in text: String) -> [String] {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines).prefix(8) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count <= 80, !line.lowercased().hasPrefix("u.s. department of justice"),
                  line.range(of: #"^(?:(?:United States|U\.S\.) Attorney[’']s Office[, ]+(?:for )?(?:the )?)?(?:(?:Northern|Southern|Eastern|Western|Middle|Central) )?District of [A-Z][A-Za-z ]+$|^[A-Z][A-Za-z ,&]+ Division$|^Office of [A-Z][A-Za-z ]+$"#,
                             options: .regularExpression) != nil else { continue }
            out.append(line)
        }
        if let announced = IssuingOfficeGate.office(in: text), !out.contains(where: { announced.contains($0) || $0.contains(announced) }) {
            out.append(announced)
        }
        if let r = text.range(of: #"(?i)\bprosecut\w*\b[^.]{0,120}?\bfor the ((?:Northern|Southern|Eastern|Western|Middle|Central)\s+)?District of [A-Z][A-Za-z]+(?: [A-Z][a-z]+)?"#, options: .regularExpression) {
            let span = String(text[r])
            if let d = span.range(of: #"(?:(?:Northern|Southern|Eastern|Western|Middle|Central)\s+)?District of [A-Z][A-Za-z]+(?: [A-Z][a-z]+)?"#, options: .regularExpression) {
                let district = String(span[d])
                if !out.contains(where: { $0.contains(district) }) { out.append("the U.S. Attorney's Office for the \(district)") }
            }
        }
        return out
    }

    static func key(_ f: ProceedingEventExtractor.Finding) -> String {
        guard let d = f.day ?? f.reportedOn, let y = d.year, let m = d.month, let dd = d.day else { return "9999" }
        return String(format: "%04d-%02d-%02d", y, m, dd)
    }

    /// The answer, or nil when the question isn't one of these (the normal pipeline runs).
    public static func answer(_ parsed: Parsed, sources: [Source]) -> VerifiedAnswer? {
        let about = sources.filter { ProceedingEventExtractor.mentionsFully($0.text.lowercased(), tokens: ProceedingEventExtractor.nameTokens(parsed.person)) }
        // One line per step and day across documents (the sentencing release repeats the plea's day).
        typealias Hit = (UUID, ProceedingEventExtractor.Finding)
        var all: [Hit] = []
        for s in about {
            for f in ProceedingEventExtractor.findings(in: s.text, person: parsed.person) { all.append((s.objectID, f)) }
        }
        func sortKey(_ h: Hit) -> String { (h.1.day == nil ? "1" : "0") + key(h.1) }
        all.sort { sortKey($0) < sortKey($1) }
        var seenSteps = Set<String>()
        var found: [Hit] = []
        for h in all {
            let undated = h.1.day == nil ? String(h.1.sentence.prefix(60)) : ""
            if seenSteps.insert(h.1.step.rawValue + key(h.1) + undated).inserted { found.append(h) }
        }
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
                if step == .charged, let near = found.first(where: { ($0.1.step == .arrested || $0.1.step == .arraigned) && ($0.1.day ?? $0.1.reportedOn) != nil }),
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
            // The sentence that STATES the offence ("charges Romano with seven counts of wire fraud",
            // "pleaded guilty to four counts of …") over one that only mentions the charge ("After
            // Canty was charged in the above crimes, detectives …").
            let statesOffence = #"(?i)\bcharg(?:ed|es|ing)\b[^.]{0,60}\bwith\b|\b(?:pleaded|pled) guilty\b[^.]{0,40}\bto\b|\bconvicted\b[^.]{0,40}\bof\b|\bcounts? of\b"#
            let rank: [ProceedingEventExtractor.Step: Int] = [.charged: 3, .pleaded: 2, .convicted: 2, .sentenced: 1]
            let candidates = found.filter { rank[$0.1.step] != nil && $0.1.sentence.count > 60 }
            guard let hit = candidates.max(by: { a, b in
                let sa = (a.1.sentence.range(of: statesOffence, options: .regularExpression) != nil ? 10 : 0) + (rank[a.1.step] ?? 0)
                let sb = (b.1.sentence.range(of: statesOffence, options: .regularExpression) != nil ? 10 : 0) + (rank[b.1.step] ?? 0)
                return sa < sb
            }) else {
                return refuse("The documents that name \(name) don't state what \(name) was charged with.")
            }
            let text = "The documents say: \(quote(hit.1.sentence))"
            return VerifiedAnswer(body: text, answerText: text, citations: cite([hit]), confidence: Confidence(0.75))
        case .office:
            // The office each release about the person names: its heading line ("District of Rhode
            // Island", "Criminal Division"), the office that announced it, or "prosecuted by … for the
            // Western District of Pennsylvania" (closed-case simulation, judged by Claude: the office
            // questions failed on extraction, retrieval of another case's release, and refusals).
            var offices: [(String, Source)] = []
            for s in about {
                for office in Self.offices(in: s.text) where !offices.contains(where: { $0.0 == office }) { offices.append((office, s)) }
            }
            guard !offices.isEmpty else {
                return refuse("The documents that name \(name) don't say which office prosecuted the case.")
            }
            let text = "The documents about \(name) name: " + offices.map(\.0).joined(separator: "; ") + "."
            return VerifiedAnswer(body: text, answerText: text,
                                  citations: offices.map { VerifiedAnswer.Citation(objectID: $0.1.objectID, snippet: String($0.1.text.prefix(300))) },
                                  confidence: Confidence(0.75))
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
