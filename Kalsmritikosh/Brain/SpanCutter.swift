//
//  SpanCutter.swift
//  Kalsmritikosh
//
//  A2.4 (closing spec) — the SPAN CUTTER: per-shape selection of the few
//  sentences an answer may stand on, cut from retrieved chunks under laws:
//
//    · per-shape selection policy AS DATA (a role question wants sentences
//      carrying person + role terms; a date question wants dated sentences;
//      an amount question wants money; existence wants milestone terms)
//    · winner sentences first (highest term hits), whole-meaning windows
//      (±1 sentence, budgeted) so a pronoun never dangles
//    · use-once dedupe, unit-A total order, hard budget cap
//    · every span carries an id ("S1", "S2", …) and its block reference —
//      A3's fetchSpans tool returns exactly these, so a model can cite S‹n›
//      and the sweep can resolve it to a real block
//

import Foundation

public struct CutSpan: Sendable, Equatable, Identifiable {
    public let id: String                    // "S1", "S2", …
    public let text: String
    public let objectID: KnowledgeObject.ID
    public let chunkID: Chunk.ID
    public let score: Int                    // term hits (receipt material)
}

public enum SpanCutter {

    /// The per-shape selection policy — DATA, not code. Terms are matched
    /// whole-word, case-insensitive; `wantsDigits`/`wantsMoney` add shape
    /// requirements a sentence must meet to win.
    public struct Policy: Sendable {
        public let terms: [String]
        public let wantsDigits: Bool
        public let wantsMoney: Bool
        public init(terms: [String], wantsDigits: Bool = false, wantsMoney: Bool = false) {
            self.terms = terms; self.wantsDigits = wantsDigits; self.wantsMoney = wantsMoney
        }
    }

    public nonisolated static func policy(for shape: QuestionShape, question: String) -> Policy {
        let qTerms = contentTerms(of: question)
        switch shape {
        case .role:
            return Policy(terms: qTerms + ["applicant", "inventor", "proprietor", "agent", "attorney", "authorize"])
        case .aggregation:
            return Policy(terms: qTerms, wantsMoney: true)
        case .count, .existence, .timeline, .list:
            return Policy(terms: qTerms + ["granted", "filed", "hearing", "issued", "paid"])
        default:
            return Policy(terms: qTerms)
        }
    }

    /// Cut the winning spans. Deterministic: score desc → chunk id → sentence
    /// index (unit-A total order); use-once; hard cap.
    public nonisolated static func cut(
        question: String,
        shape: QuestionShape,
        chunks: [RetrievedChunk],
        budget: Int = 6
    ) -> [CutSpan] {
        let policy = Self.policy(for: shape, question: question)
        guard !policy.terms.isEmpty else { return [] }
        let wanted = Set(policy.terms.map { $0.lowercased() })

        struct Candidate { let text: String; let score: Int; let objectID: UUID; let chunkID: UUID; let order: String }
        var candidates: [Candidate] = []
        var seenText = Set<String>()

        for rc in chunks.prefix(20) {
            let sentences = rc.chunk.text
                .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 12 }
            for (i, sentence) in sentences.enumerated() {
                let words = Set(sentence.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
                let hits = words.intersection(wanted).count
                guard hits >= 1 else { continue }
                if policy.wantsDigits, !sentence.contains(where: \.isNumber) { continue }
                if policy.wantsMoney,
                   !sentence.contains("₹"), !sentence.contains("$"), !sentence.contains("€"),
                   !sentence.lowercased().contains("rs") { continue }
                // Whole-meaning window: pull the PREVIOUS sentence in when this
                // one opens with a dangling reference (budgeted: one neighbor).
                var text = sentence
                let leads = ["it ", "this ", "that ", "he ", "she ", "they ", "the same "]
                if let prev = i > 0 ? sentences[i-1] : nil,
                   leads.contains(where: { sentence.lowercased().hasPrefix($0) }) {
                    text = prev + ". " + sentence
                }
                guard seenText.insert(text.lowercased()).inserted else { continue }   // use-once
                candidates.append(Candidate(text: text, score: hits,
                                            objectID: rc.chunk.objectID, chunkID: rc.chunk.id,
                                            order: "\(rc.chunk.id.uuidString)#\(i)"))
            }
        }
        let winners = candidates.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order
        }.prefix(budget)
        return winners.enumerated().map { n, c in
            CutSpan(id: "S\(n + 1)", text: c.text, objectID: c.objectID, chunkID: c.chunkID, score: c.score)
        }
    }

    nonisolated static func contentTerms(of question: String) -> [String] {
        let stop: Set<String> = ["what", "who", "when", "where", "which", "how", "is", "the", "a", "an",
                                 "of", "was", "were", "did", "does", "are", "in", "on", "to", "for",
                                 "this", "that", "my", "me", "tell", "many", "much"]
        var seen = Set<String>()
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
    }
}
