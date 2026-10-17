//
//  DisconfirmationScanner.swift
//  Kalsmritikosh
//
//  I-4 — the devil's-advocate check. Before an answer is trusted, look for
//  evidence AGAINST it among passages the answer did not cite. Deterministic,
//  no model call (so it never spends the generative budget):
//
//   * the answer's own dates and amounts, and its subject terms, are extracted;
//   * an uncited passage is a POSSIBLE conflict only when ONE sentence both
//     shares at least two subject terms with the answer AND either gives a
//     different date/amount of the same kind, or states the opposite (a
//     negation cue the answer lacks, or the reverse).
//
//  Every finding is labelled a possible conflict with the sentence and its
//  source — never presented as fact, never used to change the answer. When
//  nothing is found the report still says how much was searched, so silence is
//  visible ("searched 38 passages in 12 sources: none contradict this").
//

import Foundation

public nonisolated struct DisconfirmationReport: Sendable, Equatable {
    public struct PossibleConflict: Sendable, Equatable, Identifiable {
        public var id: Chunk.ID { chunkID }
        public let objectID: KnowledgeObject.ID
        public let chunkID: Chunk.ID
        public let sentence: String
        public let reason: String
    }
    public let checkedPassages: Int
    public let checkedSources: Int
    public let conflicts: [PossibleConflict]

    public var headline: String {
        if conflicts.isEmpty {
            return "Searched \(checkedPassages) other passage\(checkedPassages == 1 ? "" : "s") in \(checkedSources) source\(checkedSources == 1 ? "" : "s"): none contradict this answer"
        }
        return "\(conflicts.count) passage\(conflicts.count == 1 ? " may contradict" : "s may contradict") this answer — check \(conflicts.count == 1 ? "it" : "them")"
    }
}

public nonisolated enum DisconfirmationScanner {

    public struct Candidate: Sendable {
        public let chunkID: Chunk.ID
        public let objectID: KnowledgeObject.ID
        public let text: String
        public init(chunkID: Chunk.ID, objectID: KnowledgeObject.ID, text: String) {
            self.chunkID = chunkID; self.objectID = objectID; self.text = text
        }
    }

    public static let maxConflicts = 5

    public static func scan(question: String,
                            answer: String,
                            citedChunkIDs: Set<Chunk.ID>,
                            citedObjectIDs: Set<KnowledgeObject.ID>,
                            candidates: [Candidate]) -> DisconfirmationReport {
        let answerDates = Set(dates(in: answer))
        let answerAmounts = Set(amounts(in: answer))
        let answerNegated = hasNegation(answer)
        let terms = subjectTerms(question: question, answer: answer)

        var conflicts: [DisconfirmationReport.PossibleConflict] = []
        var checked = 0
        var sources = Set<KnowledgeObject.ID>()
        var flaggedChunks = Set<Chunk.ID>()

        for c in candidates where !citedChunkIDs.contains(c.chunkID) {
            checked += 1
            sources.insert(c.objectID)
            guard terms.count >= 2, conflicts.count < maxConflicts else { continue }
            for sentence in sentences(c.text) {
                let lower = sentence.lowercased()
                let shared = terms.filter { lower.contains($0) }.count
                guard shared >= 2 else { continue }
                var reason: String?
                let d = Set(dates(in: sentence))
                let a = Set(amounts(in: sentence))
                if !answerDates.isEmpty, !d.isEmpty, d.isDisjoint(with: answerDates) {
                    reason = "Gives a different date (\(d.sorted().joined(separator: ", "))) for the same subject"
                } else if !answerAmounts.isEmpty, !a.isEmpty, a.isDisjoint(with: answerAmounts) {
                    reason = "Gives a different amount (\(a.sorted().map(formatAmount).joined(separator: ", "))) for the same subject"
                } else if hasNegation(sentence) != answerNegated {
                    reason = answerNegated ? "States it in the positive where the answer denies it"
                                           : "Denies or reverses what the answer states"
                }
                if let reason, flaggedChunks.insert(c.chunkID).inserted {
                    conflicts.append(.init(objectID: c.objectID, chunkID: c.chunkID,
                                           sentence: sentence.trimmingCharacters(in: .whitespacesAndNewlines),
                                           reason: reason))
                    break
                }
            }
        }
        // Uncited passages from documents the answer already cites still count as searched.
        return DisconfirmationReport(checkedPassages: checked, checkedSources: sources.count, conflicts: conflicts)
    }

    // MARK: - Extraction (internal so the final test phase can exercise it)

    static let negationCues = [" not ", " never ", " no longer ", " denied ", " denies ", " deny ",
                               " cancelled ", " canceled ", " revoked ", " rejected ", " refused ",
                               " withdrawn ", " terminated ", " did not ", " didn't ", " wasn't ", " isn't "]

    static func hasNegation(_ text: String) -> Bool {
        let padded = " " + text.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        return negationCues.contains { padded.contains($0) }
    }

    static let stopwords: Set<String> = ["what", "when", "where", "which", "who", "whom", "whose", "with", "from",
        "that", "this", "these", "those", "there", "their", "about", "into", "have", "has", "had", "were", "was",
        "been", "being", "does", "did", "done", "will", "would", "could", "should", "your", "they", "them",
        "then", "than", "also", "only", "very", "much", "many", "more", "most", "such", "some", "other", "each",
        "after", "before", "over", "under", "between", "according", "documents", "document", "answer"]

    /// Subject terms: informative words of the question, plus answer words that also appear in the question's
    /// neighbourhood. Kept small so a match means "same subject", not "same language".
    static func subjectTerms(question: String, answer: String) -> [String] {
        func words(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count >= 4 && !stopwords.contains($0) && !$0.allSatisfy(\.isNumber) }
        }
        var out: [String] = []
        for w in words(question) + words(answer) where !out.contains(w) { out.append(w) }
        return Array(out.prefix(12))
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { s, _, _, _ in
            if let s, s.count > 8 { out.append(s) }
        }
        return out.isEmpty ? [text] : out
    }

    private static let monthIndex: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// Dates normalised to YYYY-MM-DD (day-month-year, month-day-year and ISO forms).
    static func dates(in text: String) -> [String] {
        var out: [String] = []
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        func add(_ y: Int, _ m: Int, _ d: Int) {
            guard (1...12).contains(m), (1...31).contains(d), (1000...2999).contains(y) else { return }
            out.append(String(format: "%04d-%02d-%02d", y, m, d))
        }
        if let iso = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#) {
            for m in iso.matches(in: text, range: full) {
                add(Int(ns.substring(with: m.range(at: 1))) ?? 0, Int(ns.substring(with: m.range(at: 2))) ?? 0,
                    Int(ns.substring(with: m.range(at: 3))) ?? 0)
            }
        }
        let month = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        if let dmy = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?:st|nd|rd|th)?\s+"# + month + #",?\s+(\d{4})\b"#,
                                              options: .caseInsensitive) {
            for m in dmy.matches(in: text, range: full) {
                let mon = monthIndex[ns.substring(with: m.range(at: 2)).lowercased()] ?? 0
                add(Int(ns.substring(with: m.range(at: 3))) ?? 0, mon, Int(ns.substring(with: m.range(at: 1))) ?? 0)
            }
        }
        if let mdy = try? NSRegularExpression(pattern: #"\b"# + month + #"\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#,
                                              options: .caseInsensitive) {
            for m in mdy.matches(in: text, range: full) {
                let mon = monthIndex[ns.substring(with: m.range(at: 1)).lowercased()] ?? 0
                add(Int(ns.substring(with: m.range(at: 3))) ?? 0, mon, Int(ns.substring(with: m.range(at: 2))) ?? 0)
            }
        }
        return out
    }

    /// Money amounts with an explicit currency marker, normalised to a number.
    static func amounts(in text: String) -> [Double] {
        let pattern = #"(?:\$|€|£|₹|\bRs\.?|\bINR|\bUSD|\bEUR|\bGBP)\s?(\d[\d,]*(?:\.\d+)?)|(\d[\d,]*(?:\.\d+)?)\s?(?:USD|EUR|GBP|INR|dollars|euros|pounds|rupees)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        var out: [Double] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for g in [1, 2] where m.range(at: g).location != NSNotFound {
                let raw = ns.substring(with: m.range(at: g)).replacingOccurrences(of: ",", with: "")
                if let v = Double(raw), v > 0 { out.append(v) }
            }
        }
        return out
    }

    static func formatAmount(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}
