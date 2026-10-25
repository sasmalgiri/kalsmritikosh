//
//  SentenceQuoteComposer.swift
//  Kalsmritikosh
//
//  P3-U4 (GO 2 REVISED, SR-7's deterministic floor) — the QUOTE composer:
//  when a question's answer lives in PROSE no extraction pack carries
//  ("at least 24 hours' notice", "born 23 August 1897"), the honest
//  deterministic answer is the SENTENCE ITSELF, quoted verbatim with its
//  citation. A verbatim quote cannot hallucinate — the words are the
//  evidence. This is the labeled deterministic fallback the AI paraphrase
//  (FM, when available) sits above; on FM-less Macs it IS the answer
//  (RC-2: deterministic mode is a state, not an error).
//
//  Precision law: the quote fires only on a STRONG match — enough of the
//  question's content words in one sentence, sized like a sentence — else
//  it abstains and the normal pipeline runs. A weak quote is fact-spam in
//  a gown; the gold wall's tripwires watch for it.
//

import Foundation

public struct QuotedAnswer: Sendable, Equatable {
    public let sentence: String
    public let objectID: KnowledgeObject.ID
    public let chunkID: Chunk.ID
    public let receiptLine: String
    /// True when the sentence is the document's own account under a heading ("Summary:",
    /// "Findings:"…) — the document answering the account question in its own words.
    public var underAccountHeading: Bool = false
}

extension SentenceQuoteComposer {
    /// The document's own account (text under its Summary/Findings heading), for an account
    /// question — nil when the question isn't one or no matching document has such a heading.
    public nonisolated static func headedAccount(question: String, chunks: [RetrievedChunk]) -> QuotedAnswer? {
        guard asksWhatHappened(question), let q = compose(question: question, chunks: chunks), q.underAccountHeading else { return nil }
        return q
    }
}

public enum SentenceQuoteComposer {

    /// Words that carry no content — never count toward a match.
    nonisolated static let stopwords: Set<String> = [
        "the", "a", "an", "of", "in", "on", "at", "to", "for", "and", "or",
        "is", "was", "were", "are", "what", "when", "who", "how", "which",
        "did", "does", "do", "many", "much", "must", "s", "from", "with",
        "be", "been", "that", "this", "it", "its", "their", "there",
    ]

    /// Minimum content-word overlap for a quote to fire.
    nonisolated static let minOverlap = 2
    /// A quotable sentence is sentence-sized.
    nonisolated static let maxSentenceLength = 320

    public nonisolated static func compose(
        question: String,
        chunks: [RetrievedChunk]
    ) -> QuotedAnswer? {
        let queryWords = contentWords(question)
        guard queryWords.count >= minOverlap else { return nil }
        let asksForValue = question.lowercased().contains("how many")
            || question.lowercased().contains("when ")
            || question.lowercased().contains("how much")

        // Case bench 2026-10-21: "Why was FDA recall Z-2366-2021 issued?" quoted the report's
        // title line ("FDA Enforcement Report — recall Z-2366-2021"), which repeats the
        // question's reference word for word and says nothing about why. For a why-question
        // the reference only names the matter; the answer is the sentence that gives a reason.
        let asksWhy = Self.asksWhy(question)
        let matchWords = asksWhy ? queryWords.filter { !$0.contains(where: \.isNumber) && $0 != "why" } : queryWords
        // Case bench 2026-10-22: "What happened in the case "Former White House Advisor
        // Convicted of Contempt of Congress"?" quoted the headline back — the title names the
        // matter, it does not tell what happened. When the question names its matter by a
        // quoted title, a sentence that is the title (or carries it whole, as a cover note
        // does) is skipped; the account is the sentence that adds to it, often the long lead.
        // "What did NHTSA find in investigation PE86068?" names its matter by a reference, not a
        // title: there the sentence that only repeats the question ("NHTSA defect investigation
        // PE86068") is the title.
        let asksAccount = Self.asksWhatHappened(question)
        var titles = asksAccount ? IdentifierAnchoredRetriever.quotedTitles(in: question) : []
        if asksAccount, titles.isEmpty { titles = [question] }
        let titleWords = titles.reduce(into: Set<String>()) { $0.formUnion(contentWords($1)) }
        let sentenceLimit = titles.isEmpty ? maxSentenceLength : 600

        if asksAccount, let lead = Self.leadSentence(question: question, chunks: chunks, titles: titles, titleWords: titleWords) {
            return QuotedAnswer(
                sentence: lead.sentence, objectID: lead.chunk.objectID, chunkID: lead.chunk.id,
                receiptLine: "Quoted verbatim from the cited document; no model was consulted.",
                underAccountHeading: lead.headed)
        }

        var best: (score: Int, tiebreak: String, sentence: String, chunk: Chunk)?
        for rc in chunks {
            // Chunk-level context: a record document ("Date of birth: 23 August
            // 1897") often splits the NAME and the VALUE across lines — the
            // chunk carrying both is the context that licenses the line quote.
            let chunkOverlap = queryWords.intersection(contentWords(rc.chunk.text)).count
            var previous = ""
            for raw in sentences(of: rc.chunk.text) {
                let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                defer { previous = sentence }
                guard sentence.count >= 20, sentence.count <= sentenceLimit else { continue }
                let words = contentWords(sentence)
                if !titles.isEmpty, Self.restatesTitle(sentence, words: words, titles: titles, titleWords: titleWords) { continue }
                let overlap = matchWords.intersection(words).count
                // The question's own reference numbers ("OSHA accident 220850044") are not a value.
                let hasValue = sentence.contains(where: \.isNumber)
                    && !Self.numbersOnlyFromQuestion(sentence, question: question)
                if asksForValue && !hasValue { continue }
                // A why-question's answer: the line under a "Reason …:" / "Cause:" label, or a
                // sentence that states a reason.
                let reason = asksWhy ? Self.reasonWeight(sentence, previous: previous) : 0
                // Fire on: strong sentence overlap, OR one topical word in the
                // sentence with the REST of the question's words in the chunk.
                let strong = overlap >= minOverlap || reason >= 4
                let contextual = (overlap >= 1 || reason > 0) && chunkOverlap >= 3
                guard strong || contextual else { continue }
                let score = overlap * 2 + (hasValue ? 1 : 0) + (contextual && !strong ? 2 : 0) + reason
                // Total order: score, then the sentence text (stable content key).
                if best == nil || score > best!.score
                    || (score == best!.score && sentence < best!.tiebreak) {
                    best = (score, sentence, sentence, rc.chunk)
                }
            }
        }
        guard let hit = best, hit.score >= minOverlap * 2 + 1 else { return nil }
        // Case bench 2026-10-22: "What was the probable cause of NTSB case SEA03LA084?" quoted
        // the heading "NTSB SEA03LA084 — probable cause" — every word of it is the question's.
        // A heading answers nothing; what it heads does: the next substantive sentence.
        if Self.restatesTitle(hit.sentence, words: contentWords(hit.sentence), titles: [question], titleWords: queryWords),
           let body = Self.sentence(after: hit.sentence, in: hit.chunk.text) {
            return QuotedAnswer(sentence: body, objectID: hit.chunk.objectID, chunkID: hit.chunk.id,
                                receiptLine: "Quoted verbatim from the cited document; no model was consulted.")
        }
        return QuotedAnswer(
            sentence: hit.sentence,
            objectID: hit.chunk.objectID,
            chunkID: hit.chunk.id,
            receiptLine: "Quoted verbatim from the cited document; no model was consulted.")
    }

    /// The account of a matter: the first substantive sentence of the matter's own document —
    /// the document whose passages share the most of the question's words — read in order,
    /// skipping the title, label lines ("Make: KENWORTH") and short lines. A sentence longer
    /// than 600 characters is quoted up to a word boundary, marked with an ellipsis.
    nonisolated static func leadSentence(question: String, chunks: [RetrievedChunk], titles: [String],
                                         titleWords: Set<String>) -> (sentence: String, chunk: Chunk, headed: Bool)? {
        let asked = contentWords(question)
        guard let anchor = chunks.max(by: { asked.intersection(contentWords($0.chunk.text)).count
                                            < asked.intersection(contentWords($1.chunk.text)).count }),
              asked.intersection(contentWords(anchor.chunk.text)).count >= 2 else { return nil }
        let own = chunks.filter { $0.chunk.objectID == anchor.chunk.objectID }.sorted { $0.chunk.ordinal < $1.chunk.ordinal }
        // A record states its account under a heading ("Summary:", "Findings:", "Conclusion:",
        // "Synopsis:", "Narrative:") after a block of labels (evidence-only round 2026-10-24: "What
        // did NHTSA find in investigation EA09005?" quoted the label block). That text is the account.
        for rc in own {
            if let account = accountUnderHeading(rc.chunk.text) {
                // Lead with the record's own title line ("Event: Employee crushes hand …") when it has one.
                if let headline = recordHeadline(rc.chunk.text), !account.lowercased().contains(headline.lowercased()) {
                    return ("\(headline). \(account)", rc.chunk, true)
                }
                return (account, rc.chunk, true)
            }
        }
        let label = #"^[A-Z][A-Za-z /&()\-]{0,40}:\s*\S.{0,80}$"#
        for rc in own {
            let all = sentences(of: rc.chunk.text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for (index, raw) in all.enumerated() {
                var sentence = raw
                // A headline with no period after it runs into the lead ("… Sentenced to 30
                // Years in Prison HOUSTON – A 37-year-old Mexican citizen has been …"): the
                // title comes off and the lead stands.
                for t in titles where t.count >= 12 {
                    if let r = sentence.range(of: t, options: [.caseInsensitive]) {
                        let rest = sentence[r.upperBound...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"”’:–—-")))
                        if rest.split(separator: " ").count >= 12 { sentence = rest }
                    }
                }
                guard sentence.split(separator: " ").count >= 12 else { continue }
                if sentence.range(of: label, options: .regularExpression) != nil { continue }
                if isLabelRun(sentence) { continue }
                let words = contentWords(sentence)
                if restatesTitle(sentence, words: words, titles: titles, titleWords: titleWords) { continue }
                // Q-4 — the lead keeps the names. A sentence that only lists the officials who
                // announced ("Benjamin G. Greenberg, Acting United States Attorney …, Rafiq Ahmad,
                // Special Agent in Charge …, announced") tells nothing that happened; and a lead
                // that hides the person ("sentenced a man to 18 years") takes the next sentence,
                // which names them (case bench 2026-10-24).
                if Self.isAnnouncerRoll(sentence) { continue }
                if Self.hidesThePerson(sentence), index + 1 < all.count, all[index + 1].split(separator: " ").count >= 6,
                   Self.namesAPerson(all[index + 1]) {
                    sentence += " " + all[index + 1]
                }
                if sentence.count > 600 {
                    let cut = sentence.prefix(600)
                    sentence = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + " …"
                }
                return (sentence, rc.chunk, false)
            }
        }
        return nil
    }

    /// Two or more officials' titles and an "announced": the sentence that credits the
    /// announcement, not the account.
    nonisolated static func isAnnouncerRoll(_ sentence: String) -> Bool {
        guard sentence.range(of: #"(?i)\bannounc"#, options: .regularExpression) != nil else { return false }
        let titles = #"(?:United States Attorney|U\.S\. Attorney|Special Agent in Charge|Assistant Attorney General|Attorney General|Director|Commissioner|Inspector General)"#
        guard let re = try? NSRegularExpression(pattern: titles) else { return false }
        let matches = re.matches(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length))
        // The roll OPENS with the officials; a lead that tells what happened and credits them at
        // its end ("Herrell … was sentenced today …, U.S. Attorney Scott … announced") is the account.
        guard matches.count >= 2, let first = matches.first, first.range.location <= 80 else { return false }
        // … and ends with the announcing: "… today announced the establishment of a new unit"
        // goes on to say what happened, so it is the account.
        guard let ann = sentence.range(of: #"(?i)\bannounc\w*"#, options: [.regularExpression, .backwards]) else { return false }
        return sentence[ann.upperBound...].split(separator: " ").count <= 6
    }

    /// "sentenced a man", "a 37-year-old woman pleaded …": the person is not named.
    nonisolated static func hidesThePerson(_ sentence: String) -> Bool {
        sentence.range(of: #"(?i)\b(?:a|an)\s+(?:\d{1,3}-year-old\s+)?(?:former\s+|local\s+)?(?:man|woman|men|women|person|individual|resident|defendant)\b"#,
                       options: .regularExpression) != nil
    }

    /// A first-and-last name in capitals ("Joshua Thomas", "Jimmy Wayne Hammonds").
    nonisolated static func namesAPerson(_ sentence: String) -> Bool {
        sentence.range(of: #"\b[A-Z][a-z]+(?:\s[A-Z]\.)?\s[A-Z][a-z]{2,}\b"#, options: .regularExpression) != nil
    }

    /// Headings under which a record states its account.
    nonisolated static let accountHeading = #"(?i)(?:^|[\s.|])(?:summary|findings|conclusions?|synopsis|narrative|abstract|description of (?:the )?(?:incident|event|accident|occurrence))\s*:\s*"#

    /// The text under an account heading, up to 600 characters (cut at a word, marked with …).
    nonisolated static func accountUnderHeading(_ text: String) -> String? {
        guard let r = text.range(of: accountHeading, options: .regularExpression) else { return nil }
        var rest = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // Stop at the next label line ("Recall campaign: …") if one follows the account.
        if let next = rest.range(of: #"\n[A-Z][A-Za-z /&()\-]{0,40}:\s"#, options: .regularExpression) {
            rest = String(rest[..<next.lowerBound])
        }
        guard rest.split(separator: " ").count >= 8 else { return nil }
        if rest.count > 600 {
            let cut = rest.prefix(600)
            return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + " …"
        }
        return rest
    }

    /// A record's title line — the value of an "Event:", "Subject:", "Title:" or "Incident:" label,
    /// up to the next label or line end (3–140 characters).
    nonisolated static func recordHeadline(_ text: String) -> String? {
        let pattern = #"(?:^|[\s|])(?:Event|Subject|Title|Incident)\s*:\s*(.{3,140}?)(?=\s+[A-Z][A-Za-z]{1,20}(?: [a-z][A-Za-z]{0,20}){0,2}\s*(?:\([a-z]\))?:\s|\s*\n|\s*\||$)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        let value = (text as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Several "Label: value" pairs run together — a record's header, not an account.
    nonisolated static func isLabelRun(_ sentence: String) -> Bool {
        let re = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z]{1,20}(?: [A-Za-z]{1,20}){0,2}:\s"#)
        let n = re?.numberOfMatches(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) ?? 0
        return n >= 3
    }

    /// The first sentence of at least five words after `heading` in `text`, cut to 600 characters.
    nonisolated static func sentence(after heading: String, in text: String) -> String? {
        let all = sentences(of: text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let i = all.firstIndex(of: heading) else { return nil }
        for s in all[(i + 1)...] where s.split(separator: " ").count >= 5 {
            guard s.count > 600 else { return s }
            let cut = s.prefix(600)
            return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + " …"
        }
        return nil
    }

    nonisolated static func numbersOnlyFromQuestion(_ sentence: String, question: String) -> Bool {
        func numbers(_ t: String) -> Set<String> {
            Set(t.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
        }
        return numbers(sentence).isSubset(of: numbers(question))
    }

    nonisolated static func asksWhatHappened(_ question: String) -> Bool {
        let q = question.lowercased()
        return q.hasPrefix("what happened") || q.contains(" what happened") || q.hasPrefix("what was the case")
            || q.hasPrefix("describe ") || q.hasPrefix("summarize ") || q.hasPrefix("summarise ")
            || q.range(of: #"^what (?:did|does|do) .{1,60}\b(?:find|found|conclude|determine|report)\b"#, options: .regularExpression) != nil
            || q.hasPrefix("what was found")
    }

    /// A sentence that is the title: it carries a title whole, or at least 80% of its content
    /// words are the title's.
    nonisolated static func restatesTitle(_ sentence: String, words: Set<String>, titles: [String], titleWords: Set<String>) -> Bool {
        let flat = sentence.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        for t in titles {
            let ft = t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
            if ft.count >= 12, flat.contains(ft) { return true }
        }
        guard !words.isEmpty else { return false }
        return Double(words.intersection(titleWords).count) / Double(words.count) >= 0.8
    }

    nonisolated static func asksWhy(_ question: String) -> Bool {
        let q = question.lowercased()
        return q.hasPrefix("why ") || q.contains(" why ") || q.contains("what was the reason") || q.contains("what caused")
    }

    /// How strongly a sentence reads as the stated reason: the line under a reason label scores
    /// highest; a sentence with a causal connective scores some.
    nonisolated static func reasonWeight(_ sentence: String, previous: String) -> Int {
        let prev = previous.lowercased().trimmingCharacters(in: .whitespaces)
        if prev.hasSuffix(":"), prev.contains("reason") || prev.contains("cause") || prev.contains("basis") { return 6 }
        let lower = sentence.lowercased()
        if lower.hasPrefix("reason") || lower.hasPrefix("cause") { return 5 }
        let connectives = ["because", "due to", "as a result", "resulted in", "caused", "failure to", "failed to", "could ", "may "]
        return connectives.contains { lower.contains($0) } ? 3 : 0
    }

    /// Render: the document speaks in its own words, visibly quoted.
    public nonisolated static func render(_ q: QuotedAnswer) -> String {
        "The document states: \u{201C}\(q.sentence)\u{201D}"
    }

    // MARK: - pieces

    /// Tiny stem map so a question's word meets its document form
    /// ("born" ↔ "birth", "married" ↔ "marriage"). Data, not NLP.
    nonisolated static let stems: [String: String] = [
        "born": "birth", "married": "marriage", "died": "death",
        "paid": "payment", "filed": "filing",
    ]
    nonisolated static func contentWords(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
            .map { stems[$0] ?? $0 })
    }

    /// Sentence split on ./!/? and newlines — deterministic, no NLP.
    /// Lines, then sentences within a line. A period ends a sentence only before whitespace and
    /// a capital, digit or quote, and not after an initial or a common abbreviation (case bench
    /// 2026-10-22: "Peter K. Navarro, 72, of Washington, D.C., was found guilty" was cut into
    /// four pieces, so the quote that answered lost the name).
    nonisolated static func sentences(of text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let chars = Array(line)
            var start = 0
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "!" || c == "?" || (c == "." && endsSentence(chars, at: i)) {
                    out.append(String(chars[start...i]))
                    start = i + 1
                }
                i += 1
            }
            if start < chars.count { out.append(String(chars[start...])) }
        }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    nonisolated static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "inc", "co", "corp", "ltd", "no", "nos", "vs", "v",
        "u.s", "d.c", "e.d", "n.d", "s.d", "w.d", "m.d", "gen", "gov", "sen", "rep", "hon", "jan", "feb",
        "mar", "apr", "aug", "sept", "sep", "oct", "nov", "dec", "approx", "dept", "ft", "mt", "lt", "sgt",
    ]

    private nonisolated static func endsSentence(_ chars: [Character], at i: Int) -> Bool {
        // The next non-space character must start a sentence; the end of the line ends one.
        var j = i + 1
        guard j < chars.count else { return true }
        guard chars[j] == " " || chars[j] == "\t" else { return false }
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        guard j < chars.count else { return true }
        let next = chars[j]
        guard next.isUppercase || next.isNumber || "\"“‘(".contains(next) else { return false }
        // The word before the period: an initial ("K.") or an abbreviation ("D.C.", "Inc.") does not end it.
        var k = i - 1
        while k >= 0, chars[k] != " " && chars[k] != "\t" && chars[k] != "(" { k -= 1 }
        let word = String(chars[(k + 1)..<i]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\"“‘,"))
        if word.count == 1, word.first?.isLetter == true { return false }
        return !abbreviations.contains(word)
    }
}

/// "How many employees were hurt?" when the record lists them one per entry ("Employee #1:
/// fatality, age 31", "Victim 2 –", "Defendant #3:"). Case bench 2026-10-22: OSHA injury
/// records numbered each employee and the count question quoted the record's title instead.
/// Counts the DISTINCT entry numbers for the question's noun in the one document that lists the
/// most of them, and quotes the entries. Deterministic; nil when nothing is numbered.
public struct NumberedEntryCount: Sendable, Equatable {
    public let count: Int
    public let noun: String
    public let entries: [String]
    public let objectID: KnowledgeObject.ID
    public let chunkID: Chunk.ID

    public nonisolated static func compose(question: String, chunks: [RetrievedChunk]) -> NumberedEntryCount? {
        guard let noun = countedNoun(in: question) else { return nil }
        // An entry starts a line or follows a space / separator (normalized text runs entries
        // together: "… injured employees Employee #1: hospitalized injury, age 35 OSHA …").
        // "How many workers were hurt?" of a record that numbers "Employee #1" (wide case bench 2026-10-25).
        let kin: [String: [String]] = ["worker": ["employee"], "employee": ["worker"], "person": ["employee", "victim"],
                                       "people": ["employee", "victim", "person"], "staff": ["employee"]]
        let n0 = "(?:" + ([noun] + (kin[noun] ?? [])).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
        let patterns = ["(?im)^\\s*(" + n0 + ")s?\\s*#?\\s*(\\d{1,3})\\s*[:\\-–][^\\n|]*",   // a line of its own
                        "(?i)(?<=[\\s|])(" + n0 + ")s?\\s*#\\s*(\\d{1,3})\\s*[:\\-–][^\\n|]*"]  // mid-line: needs the #
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        guard !regexes.isEmpty else { return nil }
        var best: NumberedEntryCount?
        let byObject = Dictionary(grouping: chunks, by: { $0.chunk.objectID })
        for (object, rcs) in byObject {
            var seen: [String: String] = [:]
            var first: Chunk?
            for rc in rcs.sorted(by: { $0.chunk.ordinal < $1.chunk.ordinal }) {
                let ns = rc.chunk.text as NSString
                for m in regexes.flatMap({ $0.matches(in: rc.chunk.text, range: NSRange(location: 0, length: ns.length)) }) {
                    let n = ns.substring(with: m.range(at: 2))
                    if seen[n] == nil {
                        seen[n] = Self.trimEntry(ns.substring(with: m.range), noun: noun)
                        if first == nil { first = rc.chunk }
                    }
                }
            }
                // No listed entries: a record about a harm whose narrative numbers the people it is
            // about ("Event: Employee injured in fall …  Employee #1 was standing on the street …")
            // — the distinct numbered people are counted and each first mention quoted (case bench
            // 2026-10-24: OSHA summaries with no injury list).
            if seen.isEmpty, Self.asksAboutHarm(question) {
                let ordered = rcs.sorted(by: { $0.chunk.ordinal < $1.chunk.ordinal })
                // The record is about a harm (its title or its account says so).
                let aboutHarm = ordered.contains { $0.chunk.text.range(of: Self.harmWords, options: .regularExpression) != nil }
                for rc in ordered where aboutHarm {
                    SentenceQuoteComposer.sentences(of: rc.chunk.text).forEach { sentence in
                        let ns = sentence as NSString
                        guard let re = try? NSRegularExpression(pattern: "(?i)\\b" + n0 + "s?\\s*#\\s*(\\d{1,3})\\b") else { return }
                        for m in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
                            let n = ns.substring(with: m.range(at: 1))
                            if seen[n] == nil {
                                seen[n] = sentence.count > 160 ? String(sentence.prefix(160)) + "…" : sentence
                                if first == nil { first = rc.chunk }
                            }
                        }
                    }
                }
            }
            guard let chunk = first, !seen.isEmpty else { continue }
            if best == nil || seen.count > best!.count {
                let entries = seen.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map(\.value)
                best = NumberedEntryCount(count: seen.count, noun: noun, entries: entries, objectID: object, chunkID: chunk.id)
            }
        }
        return best
    }

    nonisolated static let harmWords = #"(?i)\b(?:injur\w*|hurt|kill\w*|died|death|fatal\w*|hospitali[sz]ed|burn\w*|fractur\w*|amputat\w*|lacerat\w*|crush\w*|struck|fell|sustained)\b"#

    nonisolated static func asksAboutHarm(_ question: String) -> Bool {
        question.range(of: harmWords, options: .regularExpression) != nil
    }

    /// One entry, cut where the next entry or the next label begins ("Employee #1: hospitalized
    /// injury, age 35 OSHA accident investigation summary …" → "Employee #1: hospitalized injury, age 35").
    nonisolated static func trimEntry(_ raw: String, noun: String) -> String {
        var e = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stops = [#"\s+"# + NSRegularExpression.escapedPattern(for: noun) + #"s?\s*#\s*\d"#,   // the next entry
                     #"(?<=\d)\s+[A-Z]{2,}\b"#,                                                 // "… age 35 OSHA …"
                     #"\s+[A-Z][A-Za-z]{1,20}(?: [a-z][A-Za-z]{0,20}){0,2}\s*(?:\([a-z]\))?:\s"#]   // the next label
        for stop in stops {
            if let r = e.range(of: stop, options: [.regularExpression, .caseInsensitive], range: e.index(e.startIndex, offsetBy: min(4, e.count))..<e.endIndex) {
                e = String(e[..<r.lowerBound])
            }
        }
        if e.count > 100 { e = String(e.prefix(100)) + "…" }
        return e.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;")))
    }

    /// The noun after "how many" ("how many employees were hurt" → "employee"), singular.
    nonisolated static func countedNoun(in question: String) -> String? {
        let q = question.lowercased()
        guard let r = q.range(of: #"how many ([a-z]+)"#, options: .regularExpression) else { return nil }
        var word = String(q[r].dropFirst("how many ".count))
        guard word.count >= 3, !["times", "days", "years", "months", "hours", "dollars"].contains(word) else { return nil }
        if word.hasSuffix("ies") { word = String(word.dropLast(3)) + "y" }
        else if word.hasSuffix("s") { word = String(word.dropLast()) }
        return word
    }

    public nonisolated func render() -> String {
        let label = count == 1 ? noun : noun + "s"
        let listed = entries.prefix(12).map { "\u{201C}\($0)\u{201D}" }.joined(separator: "; ")
        return "\(count) \(label) \(count == 1 ? "is" : "are") listed: \(listed)."
    }
}
