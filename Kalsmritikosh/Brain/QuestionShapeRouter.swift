//
//  QuestionShapeRouter.swift
//  Kalsmritikosh
//
//  P3-U1 (GO 2 REVISED) — explicit question SHAPES, routed deterministically,
//  with the ROUTE TWIN: a second checker using a DISJOINT method re-derives
//  every routing; on disagreement the SAFEST shape wins (order as data) and
//  the mismatch is counted. Shapes here feed the composers (P3-U2); Q0 is
//  behavioral immediately: an out-of-scope question refuses BEFORE retrieval,
//  zero model — the owner's "capital of France" burned 84 seconds through
//  the whole pipeline to earn a refusal it could have had instantly.
//
//  The deadly sin is a FALSE Q0 (refusing an answerable question), so Q0 is
//  high-precision: a world-knowledge pattern must hit AND nothing in the
//  question may look like an archive referent (an identifier-shaped token or
//  a known field word). Uncertain → unresolved → the normal pipeline.
//

import Foundation
import os

public enum QuestionShape: String, Sendable, CaseIterable {
    case unresolved   // the normal pipeline — SAFEST
    case existence    // "is/was/has the X …?" — yes/no from the ledger
    case timeline     // "timeline of …" — the ordered, dated, cited chain
    case count        // "how many …?" — counts from counts
    case story        // P4-U4 — "tell me the story of …" — the reconstruction engine
    case outOfScope   // world knowledge — fixed refusal, zero retrieval/model
}

public struct RoutedShape: Sendable, Equatable {
    public let shape: QuestionShape
    public let twinAgreed: Bool
    /// Plain-language receipt: how the route was decided.
    public let receiptLine: String
}

public enum QuestionShapeRouter {

    /// SAFEST-FIRST order, as data (GO2R): on twin disagreement the shape
    /// EARLIER in this list wins. unresolved is safest (full pipeline);
    /// outOfScope is least safe (it refuses).
    public nonisolated static let safestOrder: [QuestionShape] = [
        .unresolved, .timeline, .story, .existence, .count, .outOfScope,
    ]

    /// Story openers (data): the reconstruction ask.
    nonisolated static let storyOpeners: [String] = [
        "story of", "tell me the story", "tell the story",
    ]

    /// World-knowledge openers — high-precision Q0 patterns (data).
    nonisolated static let worldKnowledgePatterns: [String] = [
        "capital of", "president of", "prime minister of", "population of",
        "currency of", "national anthem", "who won the", "weather in",
        "what time is it", "distance from earth", "speed of light",
        "boiling point of", "square root of", "meaning of life",
    ]

    /// Existence openers (data): a yes/no about the archive.
    nonisolated static let existenceOpeners: [String] = [
        "is the", "is there", "was the", "were the", "has the", "have the",
        "did the", "does the", "are there", "is it true",
    ]

    nonisolated static let countOpeners: [String] = [
        "how many", "how much", "count of", "number of",
    ]

    // MARK: - primary detector (prefix/pattern method)

    public nonisolated static func detect(_ question: String) -> QuestionShape {
        let q = normalized(question)
        if worldKnowledgePatterns.contains(where: { q.contains($0) }), !hasArchiveReferent(q) {
            return .outOfScope
        }
        if storyOpeners.contains(where: { q.contains($0) }) { return .story }
        if ["timeline of", "history of", "chronology of"].contains(where: { q.contains($0) }) { return .timeline }
        if countOpeners.contains(where: { q.hasPrefix($0) }) { return .count }
        if existenceOpeners.contains(where: { q.hasPrefix($0) }) { return .existence }
        return .unresolved
    }

    // MARK: - the twin (disjoint method: token-set scoring, no prefixes)

    /// The twin re-derives the shape by TOKEN MEMBERSHIP — deliberately a
    /// different mechanism from the primary's prefix/substring patterns, so
    /// the two cannot share a blind spot.
    public nonisolated static func twinDetect(_ question: String) -> QuestionShape {
        let tokens = Set(normalized(question).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
        if !tokens.isDisjoint(with: ["capital", "president", "anthem", "weather", "population"]),
           !hasArchiveReferent(normalized(question)) {
            return .outOfScope
        }
        if tokens.contains("story") { return .story }
        if !tokens.isDisjoint(with: ["timeline", "chronology", "history"]) { return .timeline }
        if tokens.contains("many") || tokens.contains("count") { return .count }
        let yesNoLeads: Set<String> = ["is", "was", "were", "has", "have", "did", "does", "are"]
        if let first = normalized(question).components(separatedBy: " ").first,
           yesNoLeads.contains(first) {
            return .existence
        }
        return .unresolved
    }

    /// Route with the twin. Disagreement → the SAFEST of the two, counted.
    public nonisolated static func route(_ question: String) -> RoutedShape {
        let primary = detect(question)
        let twin = twinDetect(question)
        if primary == twin {
            return RoutedShape(shape: primary, twinAgreed: true,
                               receiptLine: "Question shape: \(plain(primary)) (both checkers agreed).")
        }
        let safest = safestOrder.first { $0 == primary || $0 == twin } ?? .unresolved
        KalsmritikoshLog.brain.info("route.twin: MISMATCH primary=\(primary.rawValue, privacy: .public) twin=\(twin.rawValue, privacy: .public) → safest=\(safest.rawValue, privacy: .public)")
        return RoutedShape(shape: safest, twinAgreed: false,
                           receiptLine: "Question shape: \(plain(safest)) (checkers disagreed — the safer reading was taken).")
    }

    /// P5 residual — does the question ask for ONE specific value? Such a
    /// question is never answered by a dump of restated facts: it gets the
    /// value, a quote, or the honest not-found. Data, not code.
    nonisolated static let valueOpeners: [String] = [
        "what is the", "what was the", "what's the", "how much", "how many",
    ]
    public nonisolated static func seeksSpecificValue(_ question: String) -> Bool {
        let q = normalized(question)
        return valueOpeners.contains { q.hasPrefix($0) }
    }

    /// The fixed Q0 refusal — one sentence, plain language, zero model.
    public nonisolated static let outOfScopeRefusal =
        "That looks like general knowledge, not a question about your archive. Kalsmritikosh answers only from your ingested documents — ask about the people, dates, amounts, or events in them."

    // MARK: - pieces

    nonisolated static func normalized(_ q: String) -> String {
        q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Anything identifier-shaped or field-vocabulary-shaped anchors the
    /// question to the ARCHIVE — Q0 must then never fire (the deadly sin
    /// is refusing an answerable question).
    nonisolated static func hasArchiveReferent(_ q: String) -> Bool {
        let tokens = q.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if tokens.contains(where: { $0.count >= 4 && $0.contains(where: \.isNumber) }) { return true }
        let fieldWords: Set<String> = ["patent", "application", "invoice", "contract",
                                       "hearing", "grant", "granted", "filed", "payment"]
        return tokens.contains(where: { fieldWords.contains($0) })
    }

    nonisolated static func plain(_ s: QuestionShape) -> String {
        switch s {
        case .unresolved: return "a general question"
        case .existence:  return "a yes-or-no question"
        case .timeline:   return "a timeline question"
        case .count:      return "a counting question"
        case .story:      return "a story question"
        case .outOfScope: return "outside the archive"
        }
    }
}
