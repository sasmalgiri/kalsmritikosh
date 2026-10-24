//
//  CountQuestionGate.swift
//  Kalsmritikosh
//
//  Evidence-only round 2026-10-24: "How many employees were hurt in OSHA investigation 221257512?"
//  came back as the record's header passage — no count in it. A how-many question is answered with
//  a count, or with an honest "the documents don't give a count". The question's own reference
//  numbers (the investigation number) and dates are not a count. An answer that has one is never touched.
//

import Foundation

public nonisolated enum CountQuestionGate {

    public static func asksCount(_ question: String) -> Bool {
        let q = question.lowercased()
        return q.hasPrefix("how many ") || q.contains(" how many ")
    }

    static let numberWords = #"(?i)\b(?:no|none|zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|twenty|thirty|forty|fifty|hundred|thousand|single|a dozen|several|nobody|no one)\b"#

    /// True when the text states a count: a number word, or a number that isn't one of the
    /// question's own numbers and isn't part of a date.
    static func containsCount(_ text: String, question: String) -> Bool {
        if text.range(of: numberWords, options: .regularExpression) != nil { return true }
        let own = Set(question.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
        // Drop dates so "February 11, 2020" or "2020-02-11" don't pass for a count.
        var t = text
        for p in [#"\b\d{4}-\d{2}-\d{2}\b"#, #"\b\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}\b"#,
                  #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:,\s*\d{4})?"#,
                  #"\b(?:1[6-9]|20)\d{2}\b"#] {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        let numbers = t.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        // Five or more digits is an identifier (an inspection or case number), not a count.
        return numbers.contains { !own.contains($0) && $0.count <= 4 }
    }

    public static func apply(question: String, _ answer: VerifiedAnswer) -> VerifiedAnswer {
        guard asksCount(question), !answer.refused else { return answer }
        let said = answer.answerText ?? answer.body
        guard !containsCount(said, question: question) else { return answer }
        let text = "The documents don't give a count for this."
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: true,
                              refusalReason: "A how-many question whose evidence states no count.", report: answer.report,
                              walkSteps: answer.walkSteps, source: answer.source, reasoningTrace: answer.reasoningTrace,
                              answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}
