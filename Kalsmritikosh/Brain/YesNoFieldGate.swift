//
//  YesNoFieldGate.swift
//  Kalsmritikosh
//
//  Wide case bench 2026-10-25: "Is the recalling firm for FDA recall D-769-2015 Attix
//  Pharmaceuticals?" was answered "Recalling firm: Attix Pharmaceuticals." — the right value, but
//  never a "Yes" (0 of 375 true statements were confirmed), and a false statement got the same
//  shape of answer with no "No". A yes/no question about a field is answered by comparing the value
//  the documents give with the value the question states: "Yes — …" when they match, "No — the
//  documents give …" when they don't. Only an answer that states one labeled value is touched; a
//  passage, a refusal or a list is left as it is.
//

import Foundation

public nonisolated enum YesNoFieldGate {

    public static func asksYesNo(_ question: String) -> Bool {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Was X affirmed or reversed?" offers a choice; its answer is one of them, not yes or no.
        if q.range(of: #"(?i)\b[a-z]+\s+or\s+(?!not\b)[a-z]+[?.!\s]*$"#, options: .regularExpression) != nil { return false }
        return q.range(of: #"(?i)^(?:is|was|are|were|does|did|do|has|have|had)\s"#, options: .regularExpression) != nil
    }

    /// The single "Label: value" the answer states, if that is all it states.
    static func labeledValue(_ answer: String) -> (label: String, value: String)? {
        let first = answer.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let r = first.range(of: #"^([A-Z][^:\n]{1,60}):\s*(.+?)\.?$"#, options: .regularExpression) else { return nil }
        let line = String(first[r])
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(".") { value.removeLast() }
        // A field name is a few words ("Recall initiation date"), not a title line that runs into
        // one ("FDA Enforcement Report — recall D-0561-2021 Recalling firm").
        guard !value.isEmpty, value.count <= 160, label.split(separator: " ").count <= 5,
              !label.contains(where: \.isNumber), !label.contains("—") else { return nil }
        return (label, value)
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Does the question state this value? Word-bounded ("class ii" is not in "class iii"); a date
    /// matches any way it is written.
    static func questionStates(_ value: String, in question: String) -> Bool {
        let q = " " + normalized(question) + " ", v = normalized(value)
        guard !v.isEmpty else { return false }
        if q.contains(" " + v + " ") { return true }
        let valueDates = Set(isoDates(in: value))
        if !valueDates.isEmpty { return !valueDates.isDisjoint(with: isoDates(in: question)) }
        return false
    }

    /// Every calendar date in the text, as yyyy-MM-dd ("2004-11-02", "November 2, 2004", "Nov. 2, 2004").
    static func isoDates(in text: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        if let iso = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#) {
            for m in iso.matches(in: text, range: NSRange(location: 0, length: ns.length)) { out.append(ns.substring(with: m.range)) }
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if let named = try? NSRegularExpression(pattern: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b"#) {
            for m in named.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let mi = months.firstIndex(of: ns.substring(with: m.range(at: 1)).lowercased()),
                      let day = Int(ns.substring(with: m.range(at: 2))) else { continue }
                out.append(String(format: "%@-%02d-%02d", ns.substring(with: m.range(at: 3)), mi + 1, day))
            }
        }
        // "03/05/2019": the app writes dates day first, sources often month first — both readings.
        if let numeric = try? NSRegularExpression(pattern: #"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#) {
            for m in numeric.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let a = Int(ns.substring(with: m.range(at: 1))) ?? 0, b = Int(ns.substring(with: m.range(at: 2))) ?? 0
                let y = ns.substring(with: m.range(at: 3))
                if b <= 12, a <= 31 { out.append(String(format: "%@-%02d-%02d", y, b, a)) }
                if a <= 12, b <= 31 { out.append(String(format: "%@-%02d-%02d", y, a, b)) }
            }
        }
        return out
    }

    /// The "Label: value" line in `texts` whose label the question names (every label word of three
    /// letters or more is in the question) — the longest such label wins ("Recall initiation date"
    /// over "Date"). A record's own field line is the answer to a question about that field even
    /// when no extractor filed it (wide case bench 2026-10-25: "Status: Terminated" sat in the
    /// cited report while the answer was the report's opening passage).
    public static func namedFieldLine(question: String, in texts: [String]) -> (label: String, value: String)? {
        guard let phrase = fieldPhrase(question) else { return nil }
        // "Status: Terminated", "Recall initiation date: 2021-03-15" — the value runs to the end of
        // its line or to the next label ("… Location: Dublin, OH Status: …" on one PDF line).
        let words = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?:^|[\\s|])((?i:" + words.joined(separator: "\\s+") + "))\\s*:\\s*([^\\n|]{1,200}?)(?=\\s+[A-Z][A-Za-z]+(?:\\s[a-z]+){0,3}\\s*:\\s|\\s*\\n|\\s*\\||\\s*$)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for text in texts {
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            var value = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(".") { value.removeLast() }
            guard !value.isEmpty else { continue }
            let label = ns.substring(with: m.range(at: 1))
            return (label.prefix(1).uppercased() + label.dropFirst(), value)
        }
        return nil
    }

    /// The field a question names: "What is the status for …" → "status"; "Is the recall
    /// initiation date for FDA recall X 2021-03-15?" → "recall initiation date".
    static func fieldPhrase(_ question: String) -> String? {
        let q = withoutTitles(question).lowercased()
        guard let r = q.range(of: #"^\s*(?:what|which|is|was|are|were)\s+(?:is\s+|was\s+|are\s+|were\s+)?the\s+([a-z][a-z /&()\-]{1,40}?)\s+(?:for|of|in|on)\s"#,
                              options: .regularExpression) else { return nil }
        let span = String(q[r])
        guard let re = try? NSRegularExpression(pattern: #"the\s+([a-z][a-z /&()\-]{1,40}?)\s+(?:for|of|in|on)\s$"#),
              let m = re.firstMatch(in: span, range: NSRange(location: 0, length: (span as NSString).length)) else { return nil }
        let phrase = (span as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return phrase.count >= 3 ? phrase : nil
    }

    static func withoutTitles(_ q: String) -> String {
        q.replacingOccurrences(of: #""[^"]{3,}"|“[^”]{3,}”"#, with: " ", options: .regularExpression)
    }

    public static func apply(question: String, _ answer: VerifiedAnswer, sourceTexts: [String] = []) -> VerifiedAnswer {
        guard asksYesNo(question), !answer.refused else { return answer }
        let said = answer.answerText ?? answer.body
        // The answer's own labeled value when it is about the asked field; else the record's line.
        func aboutQuestion(_ lv: (label: String, value: String)) -> Bool {
            let labelWords = normalized(lv.label).split(separator: " ").filter { $0.count >= 3 }
            return !labelWords.isEmpty && labelWords.allSatisfy { normalized(question).contains($0) }
        }
        let stated = labeledValue(said).flatMap { aboutQuestion($0) ? $0 : nil }
        guard let lv = stated ?? namedFieldLine(question: question, in: [said] + answer.citations.map(\.snippet) + sourceTexts)
        else { return answer }
        let text = questionStates(lv.value, in: question)
            ? "Yes — \(lv.label): \(lv.value)."
            : "No — the documents give \(lv.label.lowercased()): \(lv.value)."
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: false,
                              refusalReason: nil, report: answer.report, walkSteps: answer.walkSteps, source: answer.source,
                              reasoningTrace: answer.reasoningTrace, answerState: answer.answerState,
                              ledgerAnswerID: answer.ledgerAnswerID)
    }

    /// "What is the status for FDA recall X?" answered with a passage while the record states
    /// "Status: Terminated": the record's own line answers it.
    public static func answerFieldQuestion(question: String, _ answer: VerifiedAnswer, sourceTexts: [String] = []) -> VerifiedAnswer {
        guard !answer.refused,
              question.lowercased().range(of: #"^\s*(?:what|which)\s+(?:is|was|are|were)\s+the\s+"#, options: .regularExpression) != nil
        else { return answer }
        let said = answer.answerText ?? answer.body
        // Kept when it already states the asked field; replaced when it is a passage or another field.
        if let lv = labeledValue(said), let phrase = fieldPhrase(question),
           normalized(lv.label).contains(normalized(phrase)) { return answer }
        guard let lv = namedFieldLine(question: question, in: [said] + answer.citations.map(\.snippet) + sourceTexts) else { return answer }
        let text = "\(lv.label): \(lv.value)."
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: false,
                              refusalReason: nil, report: answer.report, walkSteps: answer.walkSteps, source: answer.source,
                              reasoningTrace: answer.reasoningTrace, answerState: answer.answerState,
                              ledgerAnswerID: answer.ledgerAnswerID)
    }
}
