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
        question.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"(?i)^(?:is|was|are|were|does|did|do|has|have|had)\s"#, options: .regularExpression) != nil
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
        guard !value.isEmpty, value.count <= 160 else { return nil }
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
        if let d = isoDates(in: value).first { return isoDates(in: question).contains(d) }
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
        return out
    }

    public static func apply(question: String, _ answer: VerifiedAnswer) -> VerifiedAnswer {
        guard asksYesNo(question), !answer.refused else { return answer }
        let said = answer.answerText ?? answer.body
        guard let lv = labeledValue(said) else { return answer }
        // Only when the question is about that field: its label words appear in the question.
        let labelWords = normalized(lv.label).split(separator: " ").filter { $0.count >= 3 }
        guard !labelWords.isEmpty, labelWords.allSatisfy({ normalized(question).contains($0) }) else { return answer }
        let text = questionStates(lv.value, in: question)
            ? "Yes — \(lv.label): \(lv.value)."
            : "No — the documents give \(lv.label.lowercased()): \(lv.value)."
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: false,
                              refusalReason: nil, report: answer.report, walkSteps: answer.walkSteps, source: answer.source,
                              reasoningTrace: answer.reasoningTrace, answerState: answer.answerState,
                              ledgerAnswerID: answer.ledgerAnswerID)
    }
}
