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

    nonisolated static let industryNouns: Set<String> = [
        "pharmaceutical", "pharmaceuticals", "pharma", "chemical", "chemicals", "industries", "industry",
        "solutions", "services", "technologies", "technology", "laboratories", "labs", "healthcare",
        "enterprises", "systems", "consultants", "consultancy", "international", "global", "group", "india",
    ]

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
            // "Pharmaceutical Ltd" — an industry noun plus a suffix is a
            // truncated capture of a real name, not a name.
            let onlyGeneric = words.allSatisfy { EntityQualityGate.legalSuffixes.contains($0) || industryNouns.contains($0) }
            return letters.count >= 3 && !onlySuffixes && !onlyGeneric
        }
        var seen = Set<String>()
        let employers = facts.filter { employerFields.contains($0.field.lowercased()) && keep($0) }
            .filter { seen.insert("e|" + cleanValue($0.value).lowercased()).inserted }
        let roles = facts.filter { roleFields.contains($0.field.lowercased()) && keep($0) }
            .filter { seen.insert("r|" + cleanValue($0.value).lowercased()).inserted }
        guard !employers.isEmpty || !roles.isEmpty else { return nil }
        var lines = ["From your own records (documents named \(ownerLabel) or stating your address):"]
        if !employers.isEmpty {
            lines.append("Employers: " + employers.prefix(10).map { cleanValue($0.value) }.joined(separator: " · "))
        }
        if !roles.isEmpty {
            lines.append("Roles: " + roles.prefix(10).map { cleanValue($0.value) }.joined(separator: " · "))
        }
        return (lines.joined(separator: "\n"), Array((employers + roles).prefix(12)))
    }
}

// MARK: - L5 — what did I pay ‹payee›

public enum PaymentAnswerComposer {

    nonisolated static let openers = ["how much did i pay ", "how much have i paid ", "what did i pay ",
                                      "how much did we pay ", "how much have we paid ", "payments to ",
                                      "total paid to ", "how much was paid to ", "what have i paid "]
    nonisolated static let payeeStops: Set<String> = ["for", "in", "on", "since", "during", "between", "so", "till", "until"]
    nonisolated static let genericPayeeWords: Set<String> = [
        "and", "the", "&", "advocates", "attorneys", "associates", "company", "co", "ltd", "llp", "pvt", "private",
        "limited", "inc", "ip", "law", "firm", "services", "india",
    ]

    /// The payee a payment question names, and its distinctive tokens.
    public nonisolated static func payee(in question: String) -> (phrase: String, tokens: [String])? {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opener = openers.first(where: { q.hasPrefix($0) }) else { return nil }
        var words: [String] = []
        for raw in q.dropFirst(opener.count).split(whereSeparator: { $0.isWhitespace }) {
            let w = raw.trimmingCharacters(in: .punctuationCharacters)
            if w.isEmpty { continue }
            if payeeStops.contains(w) { break }
            words.append(w)
        }
        let tokens = words.filter { $0.count >= 4 && !genericPayeeWords.contains($0) }
        guard !tokens.isEmpty else { return nil }
        // Show the payee as the question wrote it ("Khurana & Khurana").
        let original = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var phrase = String(original.dropFirst(opener.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!. "))
        if let stop = payeeStops.lazy.compactMap({ phrase.lowercased().range(of: " \($0) ") }).first {
            phrase = String(phrase[..<stop.lowerBound])
        }
        return (phrase, Array(NSOrderedSet(array: tokens).compactMap { $0 as? String }))
    }

    /// A payee fact names a party (not an e-mail address) carrying one of the tokens.
    public nonisolated static func counterpartyMatches(_ value: String, tokens: [String]) -> Bool {
        let v = value.lowercased()
        guard !v.contains("@") else { return false }
        return tokens.contains { v.contains($0) }
    }

    /// `documents` = per payment document (subject label): its amount + date facts.
    public nonisolated static func compose(payeePhrase: String, documents: [(label: String, amounts: [GenericFact], dates: [GenericFact])])
        -> (text: String, facts: [GenericFact])? {
        struct Line { let date: String?; let amount: GenericFact; let label: String }
        var lines: [Line] = []
        for d in documents {
            var seen = Set<String>()
            for a in d.amounts where seen.insert(a.value.lowercased()).inserted {
                lines.append(Line(date: d.dates.first?.value, amount: a, label: d.label))
            }
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { ($0.date ?? "9999") < ($1.date ?? "9999") }
        func number(_ v: String) -> Double? { Double(v.filter { $0.isNumber || $0 == "." }) }
        var totals: [String: Double] = [:]
        for l in lines { if let n = number(l.amount.value) { totals[l.amount.unit ?? "?", default: 0] += n } }
        var text = "Payments to \(payeePhrase) on record (\(lines.count)):\n"
        text += lines.prefix(12).map { l in
            "\(l.date ?? "undated") — \(l.amount.value) (\(l.label))"
        }.joined(separator: "\n")
        let grouping = NumberFormatter()
        grouping.numberStyle = .decimal
        grouping.locale = Locale(identifier: "en_IN")
        grouping.maximumFractionDigits = 2
        let symbols = ["INR": "₹", "USD": "$", "EUR": "€", "GBP": "£"]
        let totalLine = totals.sorted { $0.key < $1.key }.map { unit, sum in
            let formatted = grouping.string(from: NSNumber(value: sum)) ?? String(sum)
            if let sym = symbols[unit] { return sym + formatted }
            return unit == "?" ? formatted : "\(unit) \(formatted)"
        }.joined(separator: " + ")
        text += "\n\nTotal on record: \(totalLine)" + (totals.count > 1 ? " (currencies are never mixed)" : "") + "."
        text += "\nOnly documents that confirm a payment to this payee are counted; a request, quote or invoice is not a payment."
        return (text, lines.map(\.amount))
    }
}

// MARK: - L5 — who ‹did› ‹thing›

/// "Who drafted the claims?" — the party that REPORTED doing it. An action
/// stated in the first person in a message ("we have prepared a draft … in
/// claims") was done by that message's sender; an instruction ("shall be
/// drafted afresh") or a plan ("we shall prepare") is not a report of it.
public enum ActorAnswerComposer {

    /// Action stems a question may name, with the words a report of that
    /// action uses (drafting is reported as "prepared a draft").
    nonisolated static let actionForms: [String: [String]] = [
        "draft":   ["draft", "drafted", "drafting", "prepared"],
        "file":    ["filed", "file", "filing", "submitted", "lodged"],
        "sign":    ["signed", "sign", "executed"],
        "prepar":  ["prepared", "prepare", "draft"],
        "submit":  ["submitted", "submit", "filed"],
        "send":    ["sent", "send", "forwarded", "shared"],
        "pay":     ["paid", "pay", "transferred", "remitted"],
        "review":  ["reviewed", "review", "checked"],
        "approv":  ["approved", "approve", "accepted"],
        "amend":   ["amended", "amend", "amendment", "amendments"],
        "respond": ["responded", "replied", "response", "filed"],
        "attend":  ["attended", "appeared", "represented"],
    ]
    nonisolated static let firstPerson = [
        "we have ", "we've ", "i have ", "i've ", "we had ", "i had ", "we prepared", "i prepared",
        "we filed", "i filed", "we drafted", "i drafted", "we submitted", "i submitted",
        "we signed", "i signed", "we sent", "i sent", "we paid", "i paid", "we attended", "i attended",
        "we are pleased to", "we hereby", "we shall ", "we will ", "i shall ", "i will ",
    ]
    nonisolated static let planMarkers = ["we shall ", "we will ", "i shall ", "i will ", "we would ", "will be "]
    nonisolated static let instructionMarkers = ["shall be ", "should be ", "must be ", "is to be ", "are to be ",
                                                 "needs to be ", "is required", "are required", "may be "]

    public struct Question: Sendable, Equatable {
        public let stem: String
        public let forms: [String]
        public let objectTerms: [String]
    }

    /// The action and its object a who-did question names.
    public nonisolated static func read(_ question: String) -> Question? {
        let tokens = question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard tokens.first == "who" || tokens.first == "whom" else { return nil }
        for t in tokens.dropFirst() {
            guard let (stem, forms) = actionForms.first(where: { t.hasPrefix($0.key) }) else { continue }
            let objects = tokens.drop(while: { $0 != t }).dropFirst()
                .filter { $0.count >= 4 && !FTSQuerySanitizer.stopwords.contains($0) }
            guard !objects.isEmpty else { return nil }
            return Question(stem: stem, forms: forms, objectTerms: Array(objects))
        }
        return nil
    }

    public struct Report: Sendable, Equatable {
        public let sentence: String
        public let completed: Bool
    }

    /// First-person reports of the action on the object in `text`, completed
    /// ones first. Instructions and passives never qualify.
    public nonisolated static func reports(in text: String, for q: Question) -> [Report] {
        let flat = text.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ">", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var out: [Report] = []
        for raw in flat.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
            let sentence = raw.trimmingCharacters(in: .whitespaces)
            let lower = " " + sentence.lowercased() + " "
            guard sentence.count >= 20, sentence.count <= 400 else { continue }
            let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted))
            guard q.forms.contains(where: { words.contains($0) }),
                  q.objectTerms.contains(where: { obj in words.contains(obj) || words.contains(where: { $0.hasPrefix(String(obj.prefix(5))) }) }),
                  firstPerson.contains(where: { lower.contains(" " + $0) }),
                  !instructionMarkers.contains(where: { lower.contains($0) }) else { continue }
            let plan = planMarkers.contains(where: { lower.contains(" " + $0) })
            out.append(Report(sentence: sentence, completed: !plan))
        }
        return out.sorted { $0.completed && !$1.completed }
    }
}
