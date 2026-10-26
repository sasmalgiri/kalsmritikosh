//
//  CaseRecordGates.swift
//  Kalsmritikosh
//
//  Two checks found by the conclusion-withheld closed-case simulation (2026-10-26): real NTSB
//  investigations handed to the app with their factual record but WITHOUT the probable-cause
//  finding, as an investigator holds them before the final report.
//
//  RecordLineGate — a record's own labeled line answers its when / how-many-killed question
//  ("Date: December 18, 2009", "Injuries: 4 fatal, 0 serious, 0 minor"). The answers had been the
//  record's passage (the reader still had to find the value) or a date of another event ("An FAA
//  publication dated May 14, 2008 …").
//
//  ConclusionGate — "What did the NTSB conclude caused the accident?" was answered, 16 times of 16,
//  with a sentence of the factual narrative quoted as if it were the finding. A question about an
//  investigation's CONCLUSION is answered only from text the documents label as one (a probable
//  cause, a finding, a determination); otherwise the answer says no document on file states it.
//  An evidence tool that "solves" a case by quoting the narrative as its verdict is the one failure
//  an investigator cannot afford.
//

import Foundation

public nonisolated enum RecordLineGate {

    /// The question's own record identifiers ("ANC11FA071", "220850044"): tokens of five or more
    /// characters that carry a digit.
    static func identifiers(in question: String) -> [String] {
        question.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { $0.count >= 5 && $0.contains(where: \.isNumber) && $0.contains(where: \.isLetter) || ($0.count >= 7 && $0.allSatisfy(\.isNumber)) }
    }

    static func asksKilled(_ question: String) -> Bool {
        question.range(of: #"(?i)\bhow many\b[^?]{0,40}\b(?:killed|died|dead|fatalit|lost their lives|perished)|\bnumber of (?:fatalities|deaths|dead)\b"#,
                       options: .regularExpression) != nil
    }

    static func labeledLine(_ pattern: String, in texts: [String]) -> String? {
        for t in texts {
            if let r = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return String(t[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    public static func apply(question: String, _ answer: VerifiedAnswer, sourceTexts: [String]) -> VerifiedAnswer {
        let ids = identifiers(in: question)
        guard !ids.isEmpty else { return answer }
        // Only the record the question names: every identifier it asks about must be in the text.
        let pool = sourceTexts.filter { t in ids.allSatisfy { t.localizedCaseInsensitiveContains($0) } }
        guard !pool.isEmpty else { return answer }
        let said = answer.answerText ?? answer.body
        if DateQuestionGate.asksWhen(question), !DateQuestionGate.asksPublicationDate(question),
           let line = labeledLine(#"(?m)^\s*(?:date(?:\s*(?:&|and)\s*time)?|event date|accident date|incident date|date of (?:the )?(?:accident|incident|event|occurrence))\s*:\s*[^\n]{4,60}$"#, in: pool) {
            // An answer that already states that day, briefly, stands.
            let value = line.replacingOccurrences(of: #"^[^:]+:\s*"#, with: "", options: .regularExpression)
            let day = value.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if said.count <= 240, DateQuestionGate.containsDay(said), said.localizedCaseInsensitiveContains(day) { return answer }
            // Another day stated for the same event (a narrative in local time against a record in
            // UTC) is a conflict: shown with both, never settled silently.
            let stated = line.hasSuffix(".") ? line : line + "."
            if let other = said.range(of: #"(?i)\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2},\s+\d{4}\b"#, options: .regularExpression)
                .map({ String(said[$0]) }), !day.localizedCaseInsensitiveContains(other), said.range(of: #"(?i)\b(?:occurred|happened|accident|crash|collided|took place)\b"#, options: .regularExpression) != nil {
                return replaced(answer, with: "\(stated) The narrative gives \(other) — the documents differ on the day.")
            }
            return replaced(answer, with: stated)
        }
        if asksKilled(question),
           let line = labeledLine(#"(?m)^\s*injuries\s*:\s*[^\n]{3,80}$"#, in: pool),
           let n = line.range(of: #"(?i)(\d+)\s+fatal"#, options: .regularExpression).map({ String(line[$0]).components(separatedBy: " ").first ?? "" }) {
            return replaced(answer, with: "\(n) killed — the record gives \(line.hasSuffix(".") ? line : line + ".")")
        }
        return answer
    }

    static func replaced(_ answer: VerifiedAnswer, with text: String) -> VerifiedAnswer {
        VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                       confidence: answer.confidence, contradictions: answer.contradictions, refused: false,
                       refusalReason: nil, report: answer.report, walkSteps: answer.walkSteps, source: answer.source,
                       reasoningTrace: answer.reasoningTrace, answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}

public nonisolated enum ConclusionGate {

    /// "What did the NTSB conclude caused …", "What was the official cause / finding / verdict …",
    /// "What did investigators determine …" — the investigation's own conclusion.
    public static func asksConclusion(_ question: String) -> Bool {
        question.range(of: #"(?i)\b(?:conclud(?:e|ed|es)|conclusion|determin(?:e|ed|es|ation)|probable cause|official cause|findings?|ruled|verdict)\b"#,
                       options: .regularExpression) != nil
            && question.range(of: #"(?i)\b(?:cause|caused|why|reason|conclu|finding|determin|ruled|verdict)\w*"#, options: .regularExpression) != nil
    }

    /// Text the documents label as a conclusion: a probable-cause line or heading, a finding, a
    /// determination, a verdict or disposition.
    static let labels = #"(?i)\b(?:probable cause|probable-cause|findings?\s*:|conclusions?\s*:|determined that|determines that|the (?:board|ntsb|agency|investigat\w+) (?:determined|found|concluded)|disposition\s*:|verdict)\b"#

    public static func apply(question: String, _ answer: VerifiedAnswer, sourceTexts: [String] = []) -> VerifiedAnswer {
        guard !answer.refused, asksConclusion(question) else { return answer }
        let said = answer.answerText ?? answer.body
        if said.range(of: labels, options: .regularExpression) != nil { return answer }
        // The quoted sentence counts as a conclusion when the document labels it as one: a label in
        // the sentence, or just before it ("NTSB X — probable cause\nThe pilot did not …").
        let quoted = said.range(of: #"“([^”]{20,})"#, options: .regularExpression).map { String(said[$0].dropFirst()).prefix(80) }
        for text in sourceTexts + answer.citations.map(\.snippet) {
            guard let quoted, let r = text.range(of: String(quoted)) else { continue }
            let before = text[text.index(r.lowerBound, offsetBy: -min(300, text.distance(from: text.startIndex, to: r.lowerBound)))..<r.lowerBound]
            if String(before).range(of: labels, options: .regularExpression) != nil { return answer }
        }
        let text = "None of the documents on file states the investigators' conclusion; they hold the factual record only."
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: true,
                              refusalReason: "A question about a conclusion whose evidence states none.",
                              report: answer.report, walkSteps: answer.walkSteps, source: answer.source,
                              reasoningTrace: answer.reasoningTrace, answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}
