//
//  IssuingOfficeGate.swift
//  Kalsmritikosh
//
//  Q-3 (docs/INVESTIGATIONS_MADE_EASY_TODO.md) — "Which office announced / issued …?" is answered
//  with the office, as the release names it, or with an honest "the release doesn't name the office".
//  Case bench round 4: answers pasted the release's closing paragraph, named a partner agency, or
//  said "a U.S. Attorney office" while the passage named the district. A government release names
//  its office in a few fixed forms; this reads those forms from the answer and its cited passages.
//  An answer that already names a specific office is never touched.
//

import Foundation

public nonisolated enum IssuingOfficeGate {

    public static func asksIssuingOffice(_ question: String) -> Bool {
        let q = question.lowercased()
        return q.range(of: #"\b(?:which|what)\b[^?]{0,40}\b(?:office|agency|component|department|division|unit)\b[^?]{0,40}\b(?:announc|issu|publish|releas)"#,
                       options: .regularExpression) != nil
    }

    /// "the Middle District of Pennsylvania", "the Southern District of New York", "the District of Columbia".
    static let district = #"(?:Northern|Southern|Eastern|Western|Middle|Central)?\s?District of [A-Z][a-z]+(?:\s[A-Z][a-z]+)?"#

    /// The office as a release names it, normalised to one form.
    public static func office(in text: String) -> String? {
        let forms: [(String, (String) -> String)] = [
            (#"(?:United States|U\.S\.)\s+Attorney[’']s\s+Office\s+(?:for|in)\s+the\s+("# + district + ")", { "the U.S. Attorney's Office for the \($0)" }),
            (#"(?:United States|U\.S\.)\s+Attorney\s+(?:for|of)\s+the\s+("# + district + ")", { "the U.S. Attorney's Office for the \($0)" }),
            (#"\b(Criminal|Civil|Tax|Antitrust|Civil Rights|National Security|Environment and Natural Resources)\s+Division\b"#, { "the Justice Department's \($0) Division" }),
        ]
        let ns = text as NSString
        for (pattern, render) in forms {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            let captured = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            return render(captured)
        }
        return nil
    }

    /// True when the answer already names a specific office (a district office or a division).
    static func namesOffice(_ text: String) -> Bool { office(in: text) != nil }

    public static func apply(question: String, _ answer: VerifiedAnswer) -> VerifiedAnswer {
        guard asksIssuingOffice(question), !answer.refused, !namesOffice(answer.answerText ?? answer.body) else { return answer }
        let pool = ([answer.body] + answer.citations.map(\.snippet)).joined(separator: "\n")
        let text: String
        let refused: Bool
        if let found = office(in: pool) {
            text = "\(found.prefix(1).uppercased() + found.dropFirst()) announced it."
            refused = false
        } else {
            text = "The release doesn't name the office that announced it."
            refused = true
        }
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: refused,
                              refusalReason: refused ? "The evidence names no issuing office." : nil, report: answer.report,
                              walkSteps: answer.walkSteps, source: answer.source, reasoningTrace: answer.reasoningTrace,
                              answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}
