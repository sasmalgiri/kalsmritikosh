//
//  DateQuestionGate.swift
//  Kalsmritikosh
//
//  Q-3 (docs/INVESTIGATIONS_MADE_EASY_TODO.md) — a "when" question must be answered with a date,
//  or with an honest "the documents don't give a date". Found on the case bench (round 4): press
//  releases say "today" or "yesterday" with no calendar date, and the answer came back as the
//  release's paragraph, which reads like an answer but contains no date. The last step before an
//  answer is recorded checks this: if a when-question's answer carries no date at all, it becomes
//  a plain refusal that quotes the relative wording the source does use. Citations are kept so the
//  reader can open the passage. An answer that has a date is never touched.
//

import Foundation

public nonisolated enum DateQuestionGate {

    /// A calendar date or year in the text: "March 3, 2009", "3 March 2009", "Mar. 3", "03/04/2009",
    /// "2009-03-04", "in 2009".
    static let datePattern = #"(?i)\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+\d{1,2}\b|\b\d{1,2}\s+(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}[/.\-]\d{1,2}[/.\-]\d{2,4}\b|\b\d{4}-\d{2}-\d{2}\b|\b(?:1[6-9]|20)\d{2}\b|\b(?:january|february|march|april|june|july|august|september|october|november|december)\b"#

    /// Words that place an event in time without a date.
    static let relativePattern = #"(?i)\b(?:today|yesterday|tomorrow|this (?:morning|afternoon|evening|week|month|year)|last (?:night|week|month|year)|earlier (?:today|this (?:week|month|year))|recently)\b"#

    public static func asksWhen(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("when ") || q.hasPrefix("when's ") { return true }
        return q.range(of: #"^(?:on |in )?(?:which|what) (?:date|day|year)\b"#, options: .regularExpression) != nil
    }

    public static func containsDate(_ text: String) -> Bool {
        text.range(of: datePattern, options: .regularExpression) != nil
    }

    /// The sentence that carries the source's relative wording ("…pled guilty today…"), if any.
    static func relativeSentence(in text: String) -> String? {
        guard let r = text.range(of: relativePattern, options: .regularExpression) else { return nil }
        let enders: Set<Character> = [".", "!", "?", "\n", "|"]
        var start = r.lowerBound, end = r.upperBound
        while start > text.startIndex, !enders.contains(text[text.index(before: start)]) { start = text.index(before: start) }
        while end < text.endIndex, !enders.contains(text[end]) { end = text.index(after: end) }
        let s = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(220))
    }

    /// "When did X announce …?" / "When was it announced?" — an announcement-date question. Kept to
    /// "announce" on purpose: "When was the patent issued?" is answered by a grant date, which must stand.
    static func asksPublicationDate(_ question: String) -> Bool {
        question.range(of: #"(?i)\bannounc\w*"#, options: .regularExpression) != nil
    }

    /// True when some date in the text sits in a sentence that ties it to the publication itself
    /// ("announced on March 3", "Dated: …", "Released 2014-03-03", or a dateline "WASHINGTON, March 3 —").
    static func hasPublicationAnchoredDate(_ text: String) -> Bool {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n|"))
        return sentences.contains { s in
            guard containsDate(s) else { return false }
            // "… announced that on May 2, 2019, Hutchins pleaded guilty" dates the plea, not the
            // announcement (case bench 2026-10-24): a date only after "announced that" is the event's.
            if let that = s.range(of: #"(?i)\bannounc\w*\s+(?:today\s+)?that\b"#, options: .regularExpression),
               !containsDate(String(s[..<that.lowerBound])) { return false }
            if s.range(of: #"(?i)\b(?:announc|releas|publish|issu|dated)\w*"#, options: .regularExpression) != nil { return true }
            // A dateline carries the date itself ("WASHINGTON, March 3 —"); "NEW ORLEANS, LOUISIANA –
            // X pleaded guilty on April 9" is a dateline whose date belongs to the plea.
            return s.trimmingCharacters(in: .whitespaces)
                .range(of: #"^[A-Z][A-Z .,'\-]{2,40},\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b"#,
                       options: .regularExpression) != nil
        }
    }

    /// The answer as it should be recorded.
    public static func apply(question: String, _ answer: VerifiedAnswer) -> VerifiedAnswer {
        guard asksWhen(question), !answer.refused else { return answer }
        let said = answer.answerText ?? answer.body
        let hasDate = containsDate(said) || containsDate(answer.body)
        // A date that belongs to another event in the source is not the publication date.
        if hasDate, asksPublicationDate(question), !hasPublicationAnchoredDate(answer.body) {
            let text = "The documents don't say when it was announced; the dates they give are for other events."
            return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                                  confidence: answer.confidence, contradictions: answer.contradictions, refused: true,
                                  refusalReason: "A publication-date question whose evidence dates only other events.",
                                  report: answer.report, walkSteps: answer.walkSteps, source: answer.source,
                                  reasoningTrace: answer.reasoningTrace, answerState: answer.answerState,
                                  ledgerAnswerID: answer.ledgerAnswerID)
        }
        guard !hasDate else { return answer }
        var text = "The documents don't give a date for this."
        if let rel = relativeSentence(in: answer.body) {
            text += " The source only says \u{201C}\(rel)\u{201D}, without a calendar date."
        }
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: true,
                              refusalReason: "A when-question whose evidence states no date.", report: answer.report,
                              walkSteps: answer.walkSteps, source: answer.source, reasoningTrace: answer.reasoningTrace,
                              answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}
