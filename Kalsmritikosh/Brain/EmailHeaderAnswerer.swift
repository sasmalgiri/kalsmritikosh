//
//  EmailHeaderAnswerer.swift
//  Kalsmritikosh
//
//  Who knew what, when — questions about an email, answered from the email itself: who sent the
//  email "<subject>", when it was sent, who received it, what it said; how many emails one person
//  sent another; when one person emailed another (or that no email found shows it).
//
//  FOUND BY THE CLOSED-CASE SIMULATION, 2026-10-26: 100 real Enron mailboxes (the FERC release).
//  6.8% of these questions were answered right. "Who sent the email …?" became "The email is
//  ambiguous across the evidence" with every address in the archive (the word "email" was read as
//  the email-address field), and "When was the email … sent?" said "The documents don't give a
//  date" while the message's own Date header was on file.
//
//  An email's headers are part of its text ("From: … To: … Subject: … Date: …", as the email
//  loader writes them); every answer quotes the header line it reads and cites the message.
//

import Foundation

public nonisolated enum EmailHeaderAnswerer {

    public enum Ask: Equatable, Sendable {
        case sender(subject: String)
        case sentDate(subject: String)
        case recipients(subject: String)
        case content(subject: String)
        case count(from: String, to: String)
        case when(from: String, to: String)
    }

    static func subject(in question: String) -> String? {
        guard let r = question.range(of: #"["“]([^"”]{3,200})["”]"#, options: .regularExpression) else { return nil }
        return String(question[r].dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    public static func parse(_ question: String) -> Ask? {
        let q = question.lowercased()
        if let s = subject(in: question), q.range(of: #"\b(?:e-?mail|message|memo|note)\b"#, options: .regularExpression) != nil {
            if q.range(of: #"^\s*(?:who|which person)\s+(?:sent|wrote|sends|authored)\b|\bwho (?:was|is) the sender\b|\bfrom whom\b"#, options: .regularExpression) != nil { return .sender(subject: s) }
            if q.range(of: #"^\s*(?:when|on what (?:date|day)|what (?:date|day))\b"#, options: .regularExpression) != nil { return .sentDate(subject: s) }
            if q.range(of: #"^\s*(?:who|which people)\s+(?:received|got|was|were)\b|\bsent to whom\b|\bto whom\b|\brecipients?\b"#, options: .regularExpression) != nil { return .recipients(subject: s) }
            if q.range(of: #"^\s*what\s+(?:did|does)\b.*\b(?:say|said|state|says)\b|\bwhat (?:was|is) (?:in|the content of)\b|\bwhat did .* write\b"#, options: .regularExpression) != nil { return .content(subject: s) }
            return nil
        }
        // "How many emails did Debra Perlingiere send to Robin Masciangelo?" / "When did A email B?"
        let name = #"([A-Z][a-z'’\-]+(?:\s+(?:[A-Z]\.|[A-Z][a-z'’\-]+)){1,3})"#
        if let m = firstMatch(#"(?i:how many (?:e-?mails?|messages)\s+did)\s+"# + name + #"\s+(?i:send|write)\s+(?i:to)\s+"# + name, question) {
            return .count(from: m[0], to: m[1])
        }
        if let m = firstMatch(#"^(?i:when did)\s+"# + name + #"\s+(?i:e-?mail|write to|message|send (?:an )?e-?mail to)\s+"# + name, question) {
            return .when(from: m[0], to: m[1])
        }
        return nil
    }

    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)), m.numberOfRanges >= 3 else { return nil }
        return (1..<m.numberOfRanges).map { (text as NSString).substring(with: m.range(at: $0)) }
    }

    public struct Message: Sendable {
        public let objectID: UUID
        public let from: String, to: String, subject: String, date: String, body: String
    }

    /// The header lines an email's text opens with, as the email loader writes them.
    public static func message(objectID: UUID, text: String) -> Message? {
        var headers: [String: String] = [:]
        let parts = text.components(separatedBy: "\n\n")
        guard let head = parts.first else { return nil }
        for line in head.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["from", "to", "cc", "subject", "date"].contains(key) else { continue }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let from = headers["from"], let subject = headers["subject"] else { return nil }
        return Message(objectID: objectID, from: from, to: headers["to"] ?? "", subject: subject, date: headers["date"] ?? "",
                       body: parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func normalizedSubject(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"^(?:\s*(?:re|fw|fwd)\s*:\s*)+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func names(_ person: String, in header: String) -> Bool {
        let h = header.lowercased()
        let tokens = person.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 && !$0.hasSuffix(".") }
        guard let first = tokens.first, let last = tokens.last else { return false }
        // "Debra Perlingiere", "Perlingiere, Debra", "debra.perlingiere@enron.com".
        return (h.contains(first) && h.contains(last)) || h.contains("\(first).\(last)@")
    }

    static func answered(_ text: String, _ cites: [Message], refused: Bool = false) -> VerifiedAnswer {
        VerifiedAnswer(body: text, answerText: text,
                       citations: cites.map { VerifiedAnswer.Citation(objectID: $0.objectID, snippet: "From: \($0.from)\nTo: \($0.to)\nSubject: \($0.subject)\nDate: \($0.date)") },
                       confidence: Confidence(refused ? 0.6 : 0.85), refused: refused,
                       refusalReason: refused ? "No email found shows it." : nil)
    }

    /// The answer, or nil when no email among `messages` is the one asked about (the pipeline runs).
    public static func answer(_ ask: Ask, messages: [Message]) -> VerifiedAnswer? {
        switch ask {
        case .sender(let s), .sentDate(let s), .recipients(let s), .content(let s):
            let wanted = normalizedSubject(s)
            let hits = messages.filter { normalizedSubject($0.subject) == wanted }
            guard !hits.isEmpty else { return nil }
            // The same message filed in several mailboxes is one email; different senders or days are several.
            var distinct: [Message] = []
            for m in hits where !distinct.contains(where: { $0.from == m.from && $0.date == m.date }) { distinct.append(m) }
            let several = distinct.count > 1
            let lines: [String]
            switch ask {
            case .sender: lines = distinct.map { "From: \($0.from)" + (several ? " (Date: \($0.date))" : "") }
            case .sentDate: lines = distinct.map { "Date: \($0.date)" + (several ? " (From: \($0.from))" : "") }
            case .recipients: lines = distinct.map { "To: \($0.to.isEmpty ? "(no recipient line)" : $0.to)" + (several ? " (From: \($0.from), Date: \($0.date))" : "") }
            default:
                lines = distinct.map { m in
                    let body = m.body.count > 500 ? String(m.body.prefix(500)) + "…" : m.body
                    return (several ? "From: \(m.from), Date: \(m.date)\n" : "") + "“\(body)”"
                }
            }
            let lead = several ? "\(distinct.count) emails found have that subject:\n" : ""
            return answered(lead + lines.joined(separator: "\n"), distinct)
        case .count(let a, let b):
            let fromA = messages.filter { names(a, in: $0.from) }
            guard !fromA.isEmpty else { return nil }
            var distinct: [Message] = []
            for m in fromA where names(b, in: m.to) && !distinct.contains(where: { $0.subject == m.subject && $0.date == m.date }) { distinct.append(m) }
            let text = "\(distinct.count) of the emails found are from \(a) to \(b)" + (distinct.isEmpty ? "." : ":\n" + distinct.map { "• \($0.date) — \($0.subject)" }.joined(separator: "\n"))
            return answered(text, distinct.isEmpty ? Array(fromA.prefix(3)) : distinct)
        case .when(let a, let b):
            let fromA = messages.filter { names(a, in: $0.from) }
            guard !fromA.isEmpty else { return nil }
            let toB = fromA.filter { names(b, in: $0.to) }
            guard !toB.isEmpty else {
                return answered("None of the emails found from \(a) is addressed to \(b).", Array(fromA.prefix(3)), refused: true)
            }
            return answered("\(a) emailed \(b) on:\n" + toB.map { "• \($0.date) — \($0.subject)" }.joined(separator: "\n"), toB)
        }
    }

}
