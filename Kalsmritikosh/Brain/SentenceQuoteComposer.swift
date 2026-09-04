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

        var best: (score: Int, tiebreak: String, sentence: String, chunk: Chunk)?
        for rc in chunks {
            // Chunk-level context: a record document ("Date of birth: 23 August
            // 1897") often splits the NAME and the VALUE across lines — the
            // chunk carrying both is the context that licenses the line quote.
            let chunkOverlap = queryWords.intersection(contentWords(rc.chunk.text)).count
            for raw in sentences(of: rc.chunk.text) {
                let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard sentence.count >= 20, sentence.count <= maxSentenceLength else { continue }
                let words = contentWords(sentence)
                let overlap = queryWords.intersection(words).count
                let hasValue = sentence.contains(where: \.isNumber)
                if asksForValue && !hasValue { continue }
                // Fire on: strong sentence overlap, OR one topical word in the
                // sentence with the REST of the question's words in the chunk.
                let strong = overlap >= minOverlap
                let contextual = overlap >= 1 && chunkOverlap >= 3
                guard strong || contextual else { continue }
                let score = overlap * 2 + (hasValue ? 1 : 0) + (contextual && !strong ? 2 : 0)
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
    nonisolated static func sentences(of text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
