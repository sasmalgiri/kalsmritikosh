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

    /// A verdict reached at trial: "a federal jury convicted", "convicted by a jury", "found guilty at
    /// trial", "following a three-week jury trial … was convicted", "a jury verdict".
    static let trialVerdict = #"\bjury (?:convicted|found|verdict|trial)\b|\b(?:convicted|found guilty)\s+(?:\w+\s+){0,6}?by (?:a |the )?(?:federal |trial )?(?:jury|judge|court)\b|\b(?:at|after|following) (?:a |the )?(?:\w+[- ]){0,3}(?:jury |bench )?trial\b|\bbench trial\b"#

    /// The step a question's verb names.
    static let stepWords: [(String, ProceedingEventExtractor.Step)] = [
        // Noun forms first ("when X's sentencing took place", "the date of the guilty plea") —
        // Claude-reworded closed-case questions, 2026-10-26.
        ("sentencing", .sentenced), ("guilty plea", .pleaded), ("indictment", .charged), ("conviction", .convicted),
        ("acquittal", .acquitted), ("arraignment", .arraigned), ("charges", .charged), ("charging", .charged),
        ("sentenced", .sentenced), ("sentence", .sentenced), ("indicted", .charged), ("charged", .charged), ("indict", .charged),
        ("charge", .charged), ("arrested", .arrested), ("arrest", .arrested), ("arraigned", .arraigned), ("plead guilty", .pleaded), ("pleaded guilty", .pleaded),
        ("plead", .pleaded), ("pleaded", .pleaded), ("pled guilty", .pleaded), ("pled", .pleaded), ("convicted", .convicted), ("convict", .convicted), ("found guilty", .convicted),
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
            // "Christi Machala's sentencing": the possessive is not part of the name.
            if let last = words.last, let r = last.range(of: #"['’]s$"#, options: .regularExpression), r.lowerBound > last.startIndex {
                words[words.count - 1] = String(last[..<r.lowerBound])
            }
            while let f = words.first, skip.contains(f) { words.removeFirst() }
            if words.count >= 2, !words.contains(where: { skip.contains($0) }) { return words.joined(separator: " ") }
        }
        return nil
    }

    /// The question without a leading courtesy wrapper ("I need to confirm: …", "For the record, …",
    /// "I'm trying to confirm …", "Can you tell me …"), so the anchored patterns below see the question.
    static func unwrap(_ q: String) -> String {
        let wrapper = #"^(?:(?:so|ok|okay|hi|hello|quick question|for the record|just to (?:confirm|check)|i(?:'m|’m| am) (?:trying|hoping|looking) to (?:confirm|verify|find out|figure out|establish|pin down|check)|i (?:need|want|would like|'d like|’d like) to (?:know|confirm|verify|find out|check)|i need|can you (?:tell me|confirm|check|let me know)|could you (?:tell me|confirm|check|let me know)|do you know|please (?:tell me|confirm))\s*[:,—–-]?\s*)+"#
        guard let r = q.range(of: wrapper, options: .regularExpression), r.upperBound < q.endIndex else { return q }
        return String(q[r.upperBound...])
    }

    public static func parse(_ question: String) -> Parsed? {
        let full = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let q = unwrap(full)
        // A quoted title names a release, not a person.
        guard !question.contains("\""), !question.contains("“"), let name = person(in: question) else { return nil }
        let step = stepWords.first { q.range(of: #"\b"# + $0.0 + #"\b"#, options: .regularExpression) != nil }?.1
        if q.range(of: #"\btimeline\b|\bchronology\b|\bchronological\b|\bsequence of events\b|\bin (?:chronological )?order\b|\bwhat happened (?:to|with)\b|\b(?:rundown|run-through|walk-through)\b.*\b(?:case|proceedings?|prosecution)\b|\bfrom start to finish\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .timeline)
        }
        // "How many (separate) press releases …", "the total count of press releases about X", "a count of
        // the press releases that mention X" — anywhere in the question, after any courtesy wrapper.
        let documents = #"(?:separate\s+|different\s+|distinct\s+|individual\s+)?(?:press releases|releases|documents|files|records|reports|articles|announcements)\b"#
        if q.range(of: #"^(?:roughly\s+|approximately\s+|about\s+|around\s+)?how many\s+"# + documents, options: .regularExpression) != nil
            || q.range(of: #"\b(?:total\s+)?(?:count|number|tally)\s+of\s+(?:the\s+|all\s+(?:the\s+)?)?"# + documents, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .documentCount)
        }
        // "What was the sentence handed down to X?", "the sentence that X received", "what sentence X got".
        if q.range(of: #"^what\s+(?:sentence|prison (?:term|sentence)|punishment|penalty)\b|^what\s+(?:was|is|were)\s+(?:the\s+)?(?:\w+\s+)?(?:sentence|prison term|punishment|penalty)\b|^(?:the\s+)?(?:\w+\s+)?sentence\s+(?:that\s+)?\S+.*\b(?:received|got|was given|was handed|was imposed)\b|\bhow long (?:was|is|will)\b.*\bsentenced\b|^how much (?:prison )?time\b|^(?:the\s+)?(?:\w+\s+)?sentence\s+(?:handed down|given|imposed|meted out)\s+(?:to|on)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .sentenceImposed)
        }
        // "Which office prosecuted X?" — the office the person's own releases name.
        if q.range(of: #"^\s*(?:which|what)\s+(?:u\.s\. attorney'?s\s+|united states attorney'?s\s+|federal\s+|prosecuting\s+)?(?:office|agency|prosecutors?|district|division|department)\b.*\b(?:prosecut\w*|handl\w*|brought|charg\w*|tried|pursued|responsible)\b|\bwho prosecuted\b|\bprosecuting (?:office|agency)\b|^(?:the\s+)?office\s+(?:that|which)\s+(?:prosecuted|handled|brought)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .office)
        }
        // "What was X charged with?" — the offence, as the charging (or plea) sentence states it.
        // "What were the charges brought against X?", "What exact charges were filed against X?"
        if q.range(of: #"^what\b.*\b(?:charged with|indicted (?:for|on)|accused of)\b|^what\s+(?:(?:were|was|are|is)\s+)?(?:the\s+)?(?:(?:exact|specific|actual|precise|federal|criminal)\s+)*(?:crimes?|offen[cs]es?|charges?)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .chargedWith)
        }
        guard let step else { return nil }
        // "What was the sentencing date for X?", "Which day was X charged?" are when-questions too.
        if q.range(of: #"^(?:when|on what (?:date|day)|what (?:date|day)|on which (?:date|day))\b|^(?:what|which)(?:'s|’s|\s+(?:was|is|were))\s+the\s+(?:\w+\s+)?(?:date|day)\b|^(?:the\s+)?(?:\w+\s+)?(?:date|day)\s+(?:of|for)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .when(step))
        }
        if q.range(of: #"^(?:did|was|were|has|have|is)\b"#, options: .regularExpression) != nil {
            return Parsed(person: name, ask: .whether(step))
        }
        // The same yes/no question behind a courtesy wrapper: "I'm trying to confirm: did X plead
        // guilty?", "I need to know—did X …", "For the record, can you confirm whether X pleaded
        // guilty?" (held-out rewordings, dev set 2026-10-28).
        if full.range(of: #"(?:[:;,—–]|\s-)\s*(?:did|was|were|has|have)\s|\b(?:whether|if)\s+(?!.*\b(?:when|what date|which day)\b)"#, options: .regularExpression) != nil {
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

    /// Surnames the texts declare as the same person's ("A B, aka C D", "C D, also known as A B"), lower-cased.
    static func aliasSurnames(of surname: String, in texts: [String]) -> [String] {
        let name = #"([A-Z][\w'’-]+(?:\s+[A-Z][\w'’.-]+)*)"#
        guard let re = try? NSRegularExpression(pattern: name + #",?\s+(?:aka|a/k/a|also known as)\s+"# + name) else { return [] }
        var out: [String] = []
        for text in texts {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let a = ns.substring(with: m.range(at: 1)).split(separator: " ").last.map { $0.lowercased() } ?? ""
                let b = ns.substring(with: m.range(at: 2)).split(separator: " ").last.map { $0.lowercased() } ?? ""
                if a == surname, !b.isEmpty, !out.contains(b) { out.append(b) }
                if b == surname, !a.isEmpty, !out.contains(a) { out.append(a) }
            }
        }
        return out
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

    /// A prior record in a sentence, not the offence charged ("possession of ammunition by a
    /// convicted felon" and "a firearm for a person she knew to be a convicted felon" are offences).
    static let priorRecord = #"(?i)\b(?:previously (?:been )?convicted|prior (?:felony )?convictions?|(?<!by a )(?<!to be a )(?<!by an )(?<!as a )convicted felon|criminal history|was on (?:probation|parole)|registered sex offender)\b"#

    /// The answer, or nil when the question isn't one of these (the normal pipeline runs).
    /// `complete` is false when the documents searched were capped: a count is then a floor.
    public static func answer(_ parsed: Parsed, sources: [Source], complete: Bool = true) -> VerifiedAnswer? {
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
            VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: about.prefix(3).map { VerifiedAnswer.Citation(objectID: $0.objectID, snippet: String($0.text.prefix(200))) },
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
                    return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite([near]), confidence: Confidence(0.6))
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
            return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite([best]), confidence: Confidence(0.8))
        case .whether(let step):
            if let hit = found.first(where: { $0.1.step == step }) {
                let text = "Yes — \(quote(hit.1.sentence))"
                return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite([hit]), confidence: Confidence(0.8))
            }
            // Brief §8: an absent plea record is not proof there was no plea, and a guilty plea is not
            // "not convicted". Only a verdict reached AT TRIAL answers "did X plead guilty?" with No; a
            // bare "was convicted" (which follows a plea as often as a trial) is reported as what it is.
            // A sentence that says the verdict came at trial, from any of the person's documents,
            // outranks a headline that only says "convicted".
            let convictions = found.filter { $0.1.step == .convicted }
            let trialHit = convictions.first { $0.1.sentence.range(of: Self.trialVerdict, options: [.regularExpression, .caseInsensitive]) != nil }
            if step == .pleaded, let hit = trialHit ?? convictions.first {
                let atTrial = hit.1.sentence.range(of: Self.trialVerdict, options: [.regularExpression, .caseInsensitive]) != nil
                let text = atTrial
                    ? "No — the documents say \(name) was found guilty at trial: \(quote(hit.1.sentence))"
                    : "The documents that name \(name) don't record a guilty plea. They say \(name) was convicted: \(quote(hit.1.sentence))"
                return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite([hit]), confidence: Confidence(atTrial ? 0.75 : 0.6))
            }
            if step == .convicted, let hit = found.first(where: { $0.1.step == .pleaded }) {
                let text = "The documents that name \(name) don't report a verdict. They say \(name) pleaded guilty: \(quote(hit.1.sentence))"
                return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite([hit]), confidence: Confidence(0.6))
            }
            return refuse("The documents that name \(name) don't say whether \(name) was \(step.phrase).")
        case .sentenceImposed:
            guard let hit = found.first(where: { $0.1.step == .sentenced && $0.1.detail != nil }) else {
                return refuse("The documents that name \(name) don't state a sentence for \(name).")
            }
            let text = "\(name) was sentenced to \(hit.1.detail ?? ""). The document says: \(quote(hit.1.sentence))"
            return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite([hit]), confidence: Confidence(0.8))
        case .chargedWith:
            // The charging sentence names the offence; failing that, the plea or verdict does.
            // The sentence that STATES the offence ("charges Romano with seven counts of wire fraud",
            // "pleaded guilty to four counts of …") over one that only mentions the charge ("After
            // Canty was charged in the above crimes, detectives …").
            // An initial or "U.S." keeps the clause going ("pled guilty today before Chief U.S. District
            // Judge Daniel P. Jordan III to commercial driver's license fraud").
            let statesOffence = #"(?i)\bcharg(?:ed|es|ing)\b(?:[^.]|(?<=\b[a-z])\.|(?<=\b[js]r)\.){0,80}\bwith\b|\b(?:pleaded|pled|pleads) guilty\b(?:[^.]|(?<=\b[a-z])\.|(?<=\b[js]r)\.){0,120}\bto\b|\b(?:convicted|found guilty)\b(?:[^.]|(?<=\b[a-z])\.|(?<=\b[js]r)\.){0,120}\bof\b|\bindicted (?:for|on)\b|\bcounts? of\b"#
            // A prior record ("a previously convicted felon", "prior felony convictions") is not this charge;
            // "possession of a firearm by a convicted felon" IS the charge.
            let prior = Self.priorRecord
            let rank: [ProceedingEventExtractor.Step: Int] = [.charged: 3, .pleaded: 2, .convicted: 2, .sentenced: 1]
            let surname = parsed.person.split(separator: " ").last.map { $0.lowercased() } ?? ""
            struct Candidate { let sentence: String; let objectID: UUID; let rank: Int }
            var candidates: [Candidate] = found.compactMap { hit in
                rank[hit.1.step].map { Candidate(sentence: hit.1.sentence, objectID: hit.0, rank: $0) }
            }
            // Any sentence of the person's documents that states the offence with the person named
            // before the verb ("CHARLESTON – James Lomax, 33, … pleaded guilty today to theft of public
            // money") — not only the sentences the step reader kept (held-out chronology 2026-10-27).
            for src in about {
                for sent in ProceedingEventExtractor.sentences(of: src.text) {
                    let low = sent.lowercased()
                    guard let verb = low.range(of: statesOffence, options: .regularExpression),
                          let at = low.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: surname) + #"\b"#, options: .regularExpression),
                          at.lowerBound < verb.lowerBound else { continue }
                    if !candidates.contains(where: { $0.sentence == sent }) { candidates.append(Candidate(sentence: sent, objectID: src.objectID, rank: 2)) }
                }
            }
            // A statement of the person's charge names the person: a group lead ("Two men pleaded
            // guilty …", "… and six others were charged …") gives the case's charges, not necessarily
            // this person's, and answers only when no sentence naming the person states an offence.
            // A surname the person's own documents give as an alias ("Christi Romano, aka Christi
            // Machala") names the person too.
            let surnames = surname.isEmpty ? [] : [surname] + Self.aliasSurnames(of: surname, in: about.map(\.text))
            let namesPerson = #"\b(?:"# + surnames.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
            func score(_ c: Candidate) -> Int {
                (c.sentence.range(of: statesOffence, options: .regularExpression) != nil ? 10 : 0) + c.rank
                    - (c.sentence.range(of: prior, options: .regularExpression) != nil ? 8 : 0)
                    + (!surnames.isEmpty && c.sentence.lowercased().range(of: namesPerson, options: .regularExpression) != nil ? 5 : 0)
            }
            // Only a sentence that STATES an offence answers; one that merely mentions a charge does not.
            guard let hit = candidates.filter({ $0.sentence.count > 40 && score($0) >= 10 }).max(by: { score($0) < score($1) }) else {
                return refuse("The documents that name \(name) don't state what \(name) was charged with.")
            }
            let text = "The documents say: \(quote(hit.sentence))"
            return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind,
                                  citations: [VerifiedAnswer.Citation(objectID: hit.objectID, snippet: String(hit.sentence.prefix(200)))],
                                  confidence: Confidence(0.75))
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
            return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind,
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
            return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind, citations: cite(dated), confidence: Confidence(0.8))
        case .documentCount:
            let n = about.count
            let lines = about.map { s in "• " + (s.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.count > 25 && ProceedingEventExtractor.fullDate(in: $0) == nil && !$0.hasPrefix("U.S. Department") && !$0.hasPrefix("FOR IMMEDIATE") } ?? "document") }
            var text = "\(complete ? "\(n)" : "At least \(n)") of the documents found name \(name):\n" + lines.joined(separator: "\n")
            if !complete { text += "\n\nThe search stopped at its limit, so there may be more." }
            return VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind,
                                  citations: about.map { VerifiedAnswer.Citation(objectID: $0.objectID, snippet: String($0.text.prefix(200))) },
                                  confidence: Confidence(0.75))
        }
    }
}
