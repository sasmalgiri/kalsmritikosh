//
//  OfflineSearchResults.swift
//  Kalsmritikosh
//
//  Plan A (owner, 2026-11-04) — without an AI reader (no plan, no key, Online off, AI switched off) Ask
//  does not write free-form answers: it returns SEARCH RESULTS — the best matching passages, the
//  question's words highlighted, each with its source to open. The real-case evaluation showed the
//  rules-written prose was wrong or off target far too often to be shown as "the answer".
//
//  One exception: a verified exact field value — the answer's value is the value of a labelled line of
//  the cited record ("Classification: Class II") — is shown as "Found in the record: …" with that line.
//  Refusals stay refusals. The deterministic case tools (custody, chronology, cast, rules
//  contradictions, reports) are not touched by this.
//

import Foundation

public nonisolated enum OfflineSearchResults {
    public static let searchKind = "offlineSearchResults"
    public static let recordValueKind = "offlineRecordValue"
    static let maxResults = 8

    /// What Ask shows offline for `answer`.
    public static func present(_ answer: VerifiedAnswer, question: String) -> VerifiedAnswer {
        if answer.intentKind == searchKind || answer.intentKind == recordValueKind { return answer }
        // An answer an AI reading wrote and verified is not an offline answer.
        if VerifiedAnswerComposer.wrote(answer) { return answer }
        if let line = recordValueLine(answer) {
            let value = valuePart(of: answer)
            let body = "Found in the record: \(value)\n• \(ProceedingAnswerer.quote(line))\n\n(The value of a labelled line in the cited record. No AI is set up, so no answer was written; open the source to check it.)"
            return rebuilt(answer, body: body, answerText: value, kind: recordValueKind,
                           citations: Array(answer.citations.filter { $0.snippet.contains(line) }.prefix(1)), refused: false)
        }
        var seen = Set<UUID>(), results: [VerifiedAnswer.Citation] = []
        for c in answer.citations where seen.insert(c.objectID).inserted && !c.snippet.isEmpty {
            results.append(c)
            if results.count == maxResults { break }
        }
        guard !results.isEmpty else {
            let body = "Search results for \u{201C}\(question)\u{201D}: no matching passage was found in the documents searched."
            return rebuilt(answer, body: body, answerText: nil, kind: searchKind, citations: [], refused: true)
        }
        let terms = highlightTerms(question)
        var body = "Search results for \u{201C}\(question)\u{201D} — the \(results.count == 1 ? "best matching passage" : "\(results.count) best matching passages"). No AI is set up, so no answer is written; open a source to read it in full.\n"
        for (i, c) in results.enumerated() {
            body += "\n\(i + 1). \u{201C}\(highlight(String(c.snippet.prefix(300)), terms: terms))\u{201D}"
        }
        return rebuilt(answer, body: body, answerText: nil, kind: searchKind, citations: results, refused: false)
    }

    // MARK: - Exact field values

    /// The answer's own value, without its receipt lines and a closing period.
    static func valuePart(of a: VerifiedAnswer) -> String {
        VerifiedAnswerComposer.answerPart(of: a).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// A labelled line ("Label: value") of a cited snippet whose value is the answer's value.
    static func recordValueLine(_ a: VerifiedAnswer) -> String? {
        guard !a.refused, !a.citations.isEmpty, a.contradictions.isEmpty else { return nil }
        let answer = valuePart(of: a)
        guard !answer.isEmpty, answer.count <= 160, !answer.contains("\n") else { return nil }
        let lowered = answer.lowercased()
        for c in a.citations {
            for raw in c.snippet.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard let colon = line.firstIndex(of: ":") else { continue }
                let label = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard (2...40).contains(label.count), label.first?.isUppercase == true,
                      label.range(of: #"^[\p{L}][\p{L}\d /()'&-]*$"#, options: .regularExpression) != nil,
                      value.count >= 2, value.count <= 120 else { continue }
                // The whole answer is the value, or the value is said in the answer as a whole phrase.
                let v = value.lowercased()
                if lowered == v || lowered.range(of: #"(?<![\p{L}\d])"# + NSRegularExpression.escapedPattern(for: v) + #"(?![\p{L}\d])"#,
                                                 options: .regularExpression) != nil, answer.count <= value.count + 80 {
                    return line
                }
            }
        }
        return nil
    }

    // MARK: - Highlights

    static let stopWords: Set<String> = ["the", "a", "an", "of", "in", "on", "at", "to", "for", "and", "or", "was", "were", "is", "are",
                                         "did", "does", "do", "what", "when", "who", "whom", "which", "why", "how", "many", "much", "with",
                                         "by", "from", "that", "this", "it", "as", "be", "been", "has", "have", "had", "any", "there"]

    static func highlightTerms(_ question: String) -> [String] {
        let words = question.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !stopWords.contains($0.lowercased()) }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }.sorted { $0.count > $1.count }
    }

    /// The question's words in bold (Markdown), whole words only, case-insensitive.
    static func highlight(_ text: String, terms: [String]) -> String {
        guard !terms.isEmpty else { return text }
        let pattern = #"(?<![\p{L}\d])("# + terms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + #")(?![\p{L}\d])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "**$1**")
    }

    static func rebuilt(_ a: VerifiedAnswer, body: String, answerText: String?, kind: String,
                        citations: [VerifiedAnswer.Citation], refused: Bool) -> VerifiedAnswer {
        var out = VerifiedAnswer(body: body, answerText: answerText, intentKind: kind, citations: citations,
                                 confidence: refused ? .zero : a.confidence, contradictions: [], refused: refused,
                                 refusalReason: refused ? (a.refusalReason ?? "No matching passage was found.") : nil,
                                 report: nil, walkSteps: [], source: a.source, reasoningTrace: a.reasoningTrace,
                                 answerState: refused ? .notFound : a.answerState, ledgerAnswerID: a.ledgerAnswerID)
        out.ledgerState = a.ledgerState
        out.resolvedQuestion = a.resolvedQuestion
        return out
    }
}
