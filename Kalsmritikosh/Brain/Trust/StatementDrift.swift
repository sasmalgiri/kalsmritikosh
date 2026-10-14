//
//  StatementDrift.swift
//  Kalsmritikosh
//
//  I-9 — how one person's account changed. Contradiction detection compares
//  documents; lawyers and journalists need to compare one PERSON over time.
//
//  Input: passages that name the person, each with its document date. Every
//  sentence that names the person AND the topic becomes a statement; statements
//  are put in date order and each is compared with the earlier ones. A change is
//  flagged when a later statement on the same subject (2+ shared topic terms)
//  gives a different date or amount, or flips between asserting and denying.
//  Both quotes are kept. Deterministic, no model call; a flag is a lead to read,
//  not a finding of inconsistency.
//

import Foundation

public nonisolated struct PersonStatement: Sendable, Equatable, Identifiable {
    public var id: String { "\(objectID.uuidString)#\(sentence.hashValue)" }
    public let objectID: KnowledgeObject.ID
    public let date: Date?
    public let sentence: String
}

public nonisolated struct StatementShift: Sendable, Equatable, Identifiable {
    public var id: String { earlier.id + "→" + later.id }
    public let earlier: PersonStatement
    public let later: PersonStatement
    public let what: String
}

public nonisolated struct DriftReport: Sendable, Equatable {
    public let statements: [PersonStatement]
    public let shifts: [StatementShift]
}

public nonisolated enum StatementDrift {

    public struct Passage: Sendable {
        public let objectID: KnowledgeObject.ID
        public let date: Date?
        public let text: String
        public init(objectID: KnowledgeObject.ID, date: Date?, text: String) {
            self.objectID = objectID; self.date = date; self.text = text
        }
    }

    public static func analyze(person: String, topic: String, passages: [Passage], maxShifts: Int = 20) -> DriftReport {
        let name = person.lowercased().trimmingCharacters(in: .whitespaces)
        // A surname alone often carries the reference ("Patel said…").
        let nameParts = name.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        let topicTerms = DisconfirmationScanner.subjectTerms(question: topic, answer: "")
        guard !name.isEmpty else { return DriftReport(statements: [], shifts: []) }

        var statements: [PersonStatement] = []
        var seen = Set<String>()
        for p in passages {
            for s in DisconfirmationScanner.sentences(p.text) {
                let lower = s.lowercased()
                let namesPerson = lower.contains(name) || nameParts.contains { lower.contains($0) }
                let onTopic = topicTerms.isEmpty || topicTerms.contains { lower.contains($0) }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if namesPerson, onTopic, seen.insert(trimmed.lowercased()).inserted {
                    statements.append(PersonStatement(objectID: p.objectID, date: p.date, sentence: trimmed))
                }
            }
        }
        statements.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        var shifts: [StatementShift] = []
        outer: for (j, later) in statements.enumerated() {
            for earlier in statements[..<j] where earlier.objectID != later.objectID {
                let a = earlier.sentence.lowercased(), b = later.sentence.lowercased()
                let shared = topicTerms.filter { a.contains($0) && b.contains($0) }.count
                guard shared >= min(2, max(1, topicTerms.count)) else { continue }
                let d1 = Set(DisconfirmationScanner.dates(in: earlier.sentence)), d2 = Set(DisconfirmationScanner.dates(in: later.sentence))
                let m1 = Set(DisconfirmationScanner.amounts(in: earlier.sentence)), m2 = Set(DisconfirmationScanner.amounts(in: later.sentence))
                var what: String?
                if !d1.isEmpty, !d2.isEmpty, d1.isDisjoint(with: d2) {
                    what = "Date changed: \(d1.sorted().joined(separator: ", ")) → \(d2.sorted().joined(separator: ", "))"
                } else if !m1.isEmpty, !m2.isEmpty, m1.isDisjoint(with: m2) {
                    what = "Amount changed: \(m1.sorted().map(DisconfirmationScanner.formatAmount).joined(separator: ", ")) → \(m2.sorted().map(DisconfirmationScanner.formatAmount).joined(separator: ", "))"
                } else if DisconfirmationScanner.hasNegation(earlier.sentence) != DisconfirmationScanner.hasNegation(later.sentence) {
                    what = DisconfirmationScanner.hasNegation(later.sentence) ? "Later denies what was stated earlier" : "Later states what was denied earlier"
                }
                if let what {
                    shifts.append(StatementShift(earlier: earlier, later: later, what: what))
                    if shifts.count >= maxShifts { break outer }
                    break
                }
            }
        }
        return DriftReport(statements: statements, shifts: shifts)
    }
}
