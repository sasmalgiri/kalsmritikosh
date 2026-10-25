//
//  AbsentAttributeGate.swift
//  Kalsmritikosh
//
//  Wide case bench 2026-10-25: asked about things the documents never mention ("Who was the FDA
//  investigator assigned to FDA recall D-0561-2021?", "What fee did the plaintiff's lawyer charge
//  in …?", "Which prison is the defendant held in …?"), 36% of answers handed back some other value
//  or a passage — the reason for the recall, a list of unrelated amounts. The thing a question asks
//  for is named by its head noun ("investigator", "fee", "prison"). When no word of it appears in
//  the answer, its cited passages or the cited documents themselves, the documents do not speak to
//  it, and the honest answer says so. The question's own reference words (the case's name or
//  number) are not counted as the thing asked for.
//

import Foundation

public nonisolated enum AbsentAttributeGate {

    /// The noun phrase the question asks for: "Who was the FDA investigator assigned to …" →
    /// ["fda", "investigator"]; "What fee did …" → ["fee"]. Nil for account, when, count and
    /// yes/no questions, which name no single thing.
    public static func askedFor(_ question: String) -> [String]? {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"^(?:who|what|which)\s+(?:is|was|are|were)\s+the\s+([a-z' \-]{3,60}?)\s+(?:of|for|in|on|at|to|assigned|who|that|which|did|was|is|behind|named|listed)\b"#,
            #"^(?:what|which)\s+([a-z' \-]{3,40}?)\s+(?:did|does|do|was|were|is|are|has|had)\b"#,
        ]
        for p in patterns {
            guard let r = q.range(of: p, options: .regularExpression) else { continue }
            let span = String(q[r])
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: span, range: NSRange(location: 0, length: (span as NSString).length)) else { continue }
            let phrase = (span as NSString).substring(with: m.range(at: 1))
            let words = phrase.split(separator: " ").map(String.init)
                .map { $0.replacingOccurrences(of: "'s", with: "") }
                .filter { $0.count >= 3 && !Self.generic.contains($0) }
            return words.isEmpty ? nil : words
        }
        return nil
    }

    /// Words too general to show the documents speak to the thing asked ("name", "date", "number"
    /// are answered by any record's fields), so a question built on them is never refused here.
    static let generic: Set<String> = ["name", "names", "date", "number", "value", "status", "type", "kind", "case",
                                       "document", "documents", "record", "report", "result", "outcome", "reason",
                                       "cause", "amount", "total", "the", "and", "this", "that", "main", "first", "last",
                                       // Parts every case record has under some name of its own ("No. 4373" is the
                                       // docket, "BROWN, P. J." the author) — never refused on the word alone.
                                       "docket", "author", "opinion", "court", "firm", "company", "party", "parties",
                                       "judge", "defendant", "plaintiff", "office", "agency", "location", "place"]

    /// The word a record uses for the same thing ("Aircraft:" for "airplane", "Parties:" for
    /// "litigants") — wide case bench 2026-10-25.
    static let kin: [String: [String]] = ["airplane": ["aircraft"], "plane": ["aircraft"], "litigant": ["part"],
                                          "litigants": ["part"], "company": ["firm"], "maker": ["manufactur"],
                                          "vehicle": ["make", "model"], "ruling": ["disposition", "affirm", "revers"],
                                          // Held-out wording set 4 (2026-10-25): "Which part is under
                                          // investigation" ("Component:"), "the two sides" ("Parties:"),
                                          // "the problem that led to" ("Reason for recall:").
                                          "part": ["component"], "system": ["component"], "side": ["part"],
                                          "sides": ["part"], "problem": ["reason", "defect"], "issue": ["reason", "defect"]]

    static func stems(_ w: String) -> [String] {
        var out = [w] + (kin[w] ?? [])
        for suffix in ["ies", "es", "s", "ing", "ed", "er", "or"] where w.hasSuffix(suffix) && w.count > suffix.count + 3 {
            out.append(String(w.dropLast(suffix.count)))
        }
        return out
    }

    /// True when some word asked for (beyond the question's own reference words) appears in the text.
    static func speaksTo(_ asked: [String], question: String, text: String) -> Bool {
        let hay = " " + text.lowercased().components(separatedBy: CharacterSet.letters.inverted).joined(separator: " ") + " "
        return asked.contains { w in stems(w).contains { hay.contains(" " + $0) } }
    }

    public static func apply(question: String, _ answer: VerifiedAnswer, sourceTexts: [String] = []) -> VerifiedAnswer {
        guard !answer.refused, let asked = askedFor(question) else { return answer }
        // The interpreter matched the question to a field on file ("litigants" → parties) and the
        // answer states that field: the documents speak to it under their own word.
        if let chosen = QuestionUnderstanding.interpretedField(for: question),
           let lv = YesNoFieldGate.labeledValue(answer.answerText ?? answer.body),
           YesNoFieldGate.normalized(lv.label).replacingOccurrences(of: " ", with: "")
               .contains(String(chosen.prefix(5))) { return answer }
        // A field the slot law stated whose name carries the thing asked for is the documents
        // speaking to it ("Recalling firm: …" for "Which firm …"). A field of another name ("Reason
        // for recall: …" for "Who was the FDA investigator …") is not, and is checked below.
        if let lv = YesNoFieldGate.labeledValue(answer.answerText ?? answer.body),
           asked.contains(where: { w in stems(w).contains { lv.label.lowercased().contains($0) } }) { return answer }
        // The words the question uses to NAME its matter are not the thing asked for
        // ("FDA investigator … FDA recall": "fda" names the matter).
        let rest = question.lowercased()
        let reference = rest.range(of: #"\b(?:in|for|of|to|on)\s+(?:the\s+)?(.+)$"#, options: .regularExpression)
            .map { String(rest[$0]) } ?? ""
        let thing = asked.filter { !reference.contains($0) }
        guard !thing.isEmpty else { return answer }
        let pool = ([answer.body] + answer.citations.map(\.snippet) + sourceTexts).joined(separator: "\n")
        // A named institution answers a question about one under its own word ("Taft Correctional
        // Institution" for "which prison").
        if let noun = thing.last, Self.institutions.contains(noun), Self.namesAnInstance(of: noun, in: pool) { return answer }
        guard !speaksTo(thing, question: question, text: pool) else {
            // "WHICH prison …" asks for a particular one: the documents must NAME one ("Taft
            // Correctional Institution", "FCI Butner"), not just use the word ("faces up to 30 years
            // in prison"). Wide case bench 2026-10-25: 56 such answers handed back the release.
            if question.lowercased().hasPrefix("which "), let noun = thing.last, Self.institutions.contains(noun),
               !Self.namesAnInstance(of: noun, in: pool) {
                return refusal(answer, "The documents searched don't name a particular \(noun).")
            }
            return answer
        }
        return refusal(answer, "The documents searched don't mention the \(thing.joined(separator: " ")).")
    }

    /// Places a release mentions generically ("up to 30 years in prison") — a "which" question
    /// about one needs a named one.
    static let institutions: Set<String> = ["prison", "hospital", "bank", "school", "jail", "facility"]

    /// A capitalised name of the thing: "Taft Correctional Institution", "Prison Camp Yankton" — the
    /// noun (or a near kin of it) next to capitalised words.
    static func namesAnInstance(of noun: String, in text: String) -> Bool {
        let kin = ["prison": "prison|correctional|penitentiary|detention|jail|fci|usp|facility",
                   "hospital": "hospital|medical center|clinic", "bank": "bank|credit union",
                   "school": "school|college|university|academy"][noun] ?? NSRegularExpression.escapedPattern(for: noun)
        let pattern = "(?:\\b[A-Z][a-zA-Z.]+\\s+){1,4}(?i:" + kin + ")\\b|\\b(?i:" + kin + ")\\s+(?:of\\s+|at\\s+)?[A-Z][a-z]+"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func refusal(_ answer: VerifiedAnswer, _ text: String) -> VerifiedAnswer {
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: true,
                              refusalReason: "The evidence never mentions what the question asks for.", report: answer.report,
                              walkSteps: answer.walkSteps, source: answer.source, reasoningTrace: answer.reasoningTrace,
                              answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}
