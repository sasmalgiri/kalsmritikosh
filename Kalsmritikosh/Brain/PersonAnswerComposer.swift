//
//  PersonAnswerComposer.swift
//  Kalsmritikosh
//
//  L5 (2026-09-27) — questions ABOUT A PERSON answered from the ledger's own
//  person records, deterministically:
//
//    "Who is ‹name› (and what did we discuss)?" — the correspondence ledger
//      (email_participant_occurrences): the address, how often and in which
//      roles they appear, the date span, and the subjects discussed, cited.
//    "What jobs have I held?" — the OWNER's own facts: the owner is the
//      address the mailbox is delivered to, and the owner's facts are the
//      subject whose facts state that address (a résumé saying so). Other
//      people's CVs in the same mailbox are never mistaken for "I".
//
//  Pure: callers fetch; this file only decides and renders. nil = cannot
//  answer honestly from what was fetched → the pipeline runs.
//

import Foundation

public enum PersonAnswerComposer {

    // MARK: - question reading

    nonisolated static let whoOpeners = ["who is ", "who's ", "who was ", "tell me about ", "what do we know about "]
    nonisolated static let nameStops: Set<String> = [
        "and", "what", "did", "do", "we", "i", "me", "my", "the", "a", "an", "is", "was", "of", "at", "in",
        "about", "with", "from", "to", "discuss", "discussed", "talk", "talked",
    ]

    /// The person a "who is ‹name›…" question names — the words after the
    /// opener up to the first stop word. nil for role questions ("who is THE
    /// applicant of …") and for anything that is not a who-is question.
    public nonisolated static func personName(in question: String) -> String? {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opener = whoOpeners.first(where: { q.hasPrefix($0) }) else { return nil }
        let rest = q.dropFirst(opener.count)
        var words: [String] = []
        for raw in rest.split(whereSeparator: { $0.isWhitespace }) {
            let w = raw.trimmingCharacters(in: .punctuationCharacters)
            guard !w.isEmpty, !nameStops.contains(w) else { break }
            guard w.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "." }) else { return nil }
            words.append(w)
            if words.count == 3 { break }
        }
        guard let first = words.first, first.count >= 3 else { return nil }
        return words.joined(separator: " ")
    }

    nonisolated static let jobWords: Set<String> = [
        "job", "jobs", "worked", "work", "employer", "employers", "employed", "employment", "career",
        "companies", "company", "positions", "position", "roles", "designation", "designations",
    ]
    nonisolated static let firstPerson: Set<String> = ["i", "my", "me", "i've", "ive"]

    public nonisolated static func asksOwnJobs(_ question: String) -> Bool {
        let tokens = Set(question.lowercased().components(separatedBy: CharacterSet.letters.union(.init(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty })
        return !tokens.isDisjoint(with: firstPerson) && !tokens.isDisjoint(with: jobWords)
    }

    // MARK: - who is ‹name›

    public struct Correspondence: Sendable {
        public let address: String
        public let displayName: String?
        public let sourceObjectID: UUID
        public let role: String
        public init(address: String, displayName: String?, sourceObjectID: UUID, role: String) {
            self.address = address; self.displayName = displayName
            self.sourceObjectID = sourceObjectID; self.role = role
        }
    }

    /// `rows` = correspondence rows for the name; `emailEvents` = the dated
    /// email events of those messages (subjects + dates).
    public nonisolated static func composeWhoIs(
        name: String, rows: [Correspondence], emailEvents: [Event]
    ) -> EventAnswerComposition? {
        guard !rows.isEmpty else { return nil }
        // The person = the address that carries the name most often.
        var byAddress: [String: [Correspondence]] = [:]
        for r in rows { byAddress[r.address, default: []].append(r) }
        guard let (address, mine) = byAddress.max(by: { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count : a.key > b.key
        }) else { return nil }
        var nameCounts: [String: Int] = [:]
        for r in mine { if let d = r.displayName?.trimmingCharacters(in: .whitespaces), !d.isEmpty { nameCounts[d, default: 0] += 1 } }
        let display = nameCounts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key
        let messages = Set(mine.map(\.sourceObjectID))
        let sent = Set(mine.filter { $0.role == "from" || $0.role == "sender" }.map(\.sourceObjectID)).count
        let received = messages.count - sent

        let theirs = emailEvents.filter { messages.contains($0.sourceObjectID) && $0.hasTrustworthyDate }
            .sorted { $0.date != $1.date ? $0.date < $1.date : $0.id.uuidString < $1.id.uuidString }
        var head = "\(display ?? name.capitalized) <\(address)>"
        if let domain = address.split(separator: "@").last { head += " — \(domain)" }
        head += " — appears in \(messages.count) email\(messages.count == 1 ? "" : "s")"
        head += " (sent \(sent), received or copied \(received))"
        if let first = theirs.first, let last = theirs.last {
            head += ", \(EventAnswerComposer.dateFormatter.string(from: first.date))"
            if last.date != first.date { head += " – \(EventAnswerComposer.dateFormatter.string(from: last.date))" }
        }
        head += "."
        // What was discussed: one line per distinct subject, oldest first.
        var seen = Set<String>()
        var topics: [Event] = []
        for e in theirs {
            let key = e.title.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !key.isEmpty, key != "email", seen.insert(key).inserted else { continue }
            topics.append(e)
        }
        var text = head
        if !topics.isEmpty {
            text += "\n\nWhat was discussed:\n" + topics.prefix(8)
                .map { "\(EventAnswerComposer.dateFormatter.string(from: $0.date)) — \($0.title)" }
                .joined(separator: "\n")
            if topics.count > 8 { text += "\n…and \(topics.count - 8) more subjects." }
        }
        return EventAnswerComposition(
            primaryText: text,
            supportingEvents: Array(topics.prefix(8)),
            isNotFound: false,
            receiptLine: "Answered from the correspondence record (who appears in which email, in which role) and the emails' own dated subjects; no model was consulted.")
    }

    // MARK: - what jobs have I held

    nonisolated static let employerFields: Set<String> = ["employer", "company", "organisation", "organization"]
    nonisolated static let roleFields: Set<String> = ["role", "designation", "position", "jobtitle"]
    /// Label residue a résumé line leaves on a value ("Current Organization  Hospira…").
    nonisolated static let valuePrefixes = ["current organization", "current organisation", "present employer",
                                            "employer", "company", "organization", "organisation", "designation"]

    nonisolated static func cleanValue(_ raw: String) -> String {
        var v = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for p in valuePrefixes where v.lowercased().hasPrefix(p) {
            v = String(v.dropFirst(p.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :-–"))
        }
        return v
    }

    /// `facts` = the OWNER subject's employer/role facts (the caller resolved
    /// the owner by address). A value that is only a legal suffix is dropped.
    public nonisolated static func composeOwnJobs(ownerLabel: String, facts: [GenericFact]) -> (text: String, facts: [GenericFact])? {
        func keep(_ f: GenericFact) -> Bool {
            let v = cleanValue(f.value)
            let letters = v.filter(\.isLetter)
            // A value made only of legal-suffix words ("Pvt. Ltd") names no one.
            let words = v.lowercased().split(whereSeparator: { $0.isWhitespace })
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
            let onlySuffixes = words.allSatisfy { EntityQualityGate.legalSuffixes.contains($0) }
            return letters.count >= 3 && !onlySuffixes
        }
        var seen = Set<String>()
        let employers = facts.filter { employerFields.contains($0.field.lowercased()) && keep($0) }
            .filter { seen.insert("e|" + cleanValue($0.value).lowercased()).inserted }
        let roles = facts.filter { roleFields.contains($0.field.lowercased()) && keep($0) }
            .filter { seen.insert("r|" + cleanValue($0.value).lowercased()).inserted }
        guard !employers.isEmpty || !roles.isEmpty else { return nil }
        var lines = ["From \(ownerLabel)'s own records (the documents that state your address):"]
        if !employers.isEmpty {
            lines.append("Employers: " + employers.prefix(10).map { cleanValue($0.value) }.joined(separator: " · "))
        }
        if !roles.isEmpty {
            lines.append("Roles: " + roles.prefix(10).map { cleanValue($0.value) }.joined(separator: " · "))
        }
        return (lines.joined(separator: "\n"), Array((employers + roles).prefix(12)))
    }
}
