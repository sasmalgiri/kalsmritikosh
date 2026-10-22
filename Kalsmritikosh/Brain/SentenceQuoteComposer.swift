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
                receiptLine: "Quoted verbatim from the cited document; no model was consulted.")
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
                let hasValue = sentence.contains(where: \.isNumber)
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
                                         titleWords: Set<String>) -> (sentence: String, chunk: Chunk)? {
        let asked = contentWords(question)
        guard let anchor = chunks.max(by: { asked.intersection(contentWords($0.chunk.text)).count
                                            < asked.intersection(contentWords($1.chunk.text)).count }),
              asked.intersection(contentWords(anchor.chunk.text)).count >= 2 else { return nil }
        let own = chunks.filter { $0.chunk.objectID == anchor.chunk.objectID }.sorted { $0.chunk.ordinal < $1.chunk.ordinal }
        let label = #"^[A-Z][A-Za-z /&()\-]{0,40}:\s*\S.{0,80}$"#
        for rc in own {
            for raw in sentences(of: rc.chunk.text) {
                var sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.split(separator: " ").count >= 12 else { continue }
                if sentence.range(of: label, options: .regularExpression) != nil { continue }
                let words = contentWords(sentence)
                if restatesTitle(sentence, words: words, titles: titles, titleWords: titleWords) { continue }
                if sentence.count > 600 {
                    let cut = sentence.prefix(600)
                    sentence = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + " …"
                }
                return (sentence, rc.chunk)
            }
        }
        return nil
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
