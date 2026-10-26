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
        // A quoted subject with an email word — or with a sender/recipient/sent word, which only an
        // email has ("Who's the sender listed on "TCO MDIQ …"?", "To whom was "…" addressed?").
        if let s = subject(in: question),
           q.range(of: #"\b(?:e-?mail|message|memo|note)\b|\bsender\b|\brecipients?\b|\baddressed\b|\bsent\b|\bwent out\b|\bcc'?d\b"#, options: .regularExpression) != nil {
            if q.range(of: #"^\s*(?:to whom|who|which people)\b.*\b(?:received|got|addressed|recipients?|sent to|cc'?d|copied|on the receiving end)\b|\bsent to whom\b|\bto whom\b|\brecipients?\b"#, options: .regularExpression) != nil { return .recipients(subject: s) }
            if q.range(of: #"^\s*(?:who|which person)\b.*\b(?:sent|wrote|sends|authored|sender|from|responsible for sending)\b|\bwho (?:was|is) the sender\b|\bfrom whom\b|\bthe sender\b"#, options: .regularExpression) != nil { return .sender(subject: s) }
            if q.range(of: #"^\s*(?:when|on what (?:date|day)|what (?:date|day|time)|at what time)\b|\b(?:timestamp|send date|sent date|date/time|date and time|send time)\b"#, options: .regularExpression) != nil { return .sentDate(subject: s) }
            if q.range(of: #"\b(?:say|said|state|says|stated|write|wrote)\b|\b(?:content|contents|body|text)\b|\bsummar"#, options: .regularExpression) != nil { return .content(subject: s) }
            return nil
        }
        // "How many emails did Debra Perlingiere send to Robin Masciangelo?" / "When did A email B?"
        let part = #"(?:Mc|Mac|De|Di|La|Le|O'|O’)?[A-Z][a-z'’\-]+"#
        let name = "(" + part + #"(?:\s+(?:[A-Z]\.|"# + part + #")){1,3})"#
        if let m = firstMatch(#"(?i:how many (?:e-?mails?|messages|times)(?:\s+(?:in\s+)?total)?(?:\s+did)?)\s+"# + name + #"\s+(?i:send|sent|write|wrote|e-?mail(?:ed)?|message(?:d)?)(?:\s+(?i:an?\s+(?:e-?mail|message)))?(?:\s+(?i:to))?\s+"# + name, question)
            ?? firstMatch(#"(?i:(?:count|number) of (?:the )?(?:e-?mails?|messages)(?:\s+that)?)\s+"# + name + #"\s+(?i:sent|wrote|e-?mailed)(?:\s+(?i:to))?\s+"# + name, question)
            // "the total number of emails that went from A to B", "a count of the emails sent from A
            // to B", "How many total emails went from A to B?" (Claude rewordings, Enron mailboxes).
            ?? firstMatch(#"(?i:(?:how many|(?:count|number) of)(?:\s+the)?(?:\s+total)?\s+(?:e-?mails?|messages)(?:\s+in total)?(?:\s+that)?\s+(?:went|were sent|was sent|sent|came|have gone)\s+from)\s+"# + name + #"\s+(?i:to)\s+"# + name, question) {
            return .count(from: m[0], to: m[1])
        }
        // "When Matt Smith sent an email to Zelda Quackenbush?" (after the courtesy wrapper is gone).
        if let m = firstMatch(#"^(?i:when(?: did)?)\s+"# + name + #"\s+(?i:sent (?:an? )?e-?mail to|e-?mailed|wrote to|sent a message to|messaged)\s+"# + name, question) {
            return .when(from: m[0], to: m[1])
        }
        if let m = firstMatch(#"^(?i:when did)\s+"# + name + #"\s+(?i:e-?mail|write to|message|send (?:an )?e-?mail to)\s+"# + name, question) {
            return .when(from: m[0], to: m[1])
        }
        // "When navigator@nisource.com emailed Zelda Quackenbush?" (after "Can you tell me").
        if let m = firstMatch(#"^(?i:when)\s+(\S.{1,80}?)\s+(?i:e-?mailed|wrote to|messaged)\s+(\S.{1,80}?)\s*\?*\s*$"#, question) {
            return .when(from: m[0], to: m[1])
        }
        // A sender that is an address or an organisation ("EDIS Service", "noreply@…"): any words
        // before "email" (closed-case simulation, Enron mailboxes).
        if let m = firstMatch(#"^(?i:when did)\s+(\S.{1,80}?)\s+(?i:e-?mail|write to|message)\s+(\S.{1,80}?)\s*\?*\s*$"#, question) {
            return .when(from: m[0], to: m[1])
        }
        // "On what date did feedback@intcx.com send an email to B?", "When anthony.carroll@… sent an
        // email to B?" — any sender, the date asked for, "send/sent an email to".
        if let m = firstMatch(#"^(?i:(?:when|on what (?:date|day)|what (?:date|day))(?:\s+did)?)\s+(\S.{1,80}?)\s+(?i:send|sent)\s+(?i:(?:an?|any)\s+)?(?i:e-?mails?|messages?)\s+(?i:to)\s+(\S.{1,80}?)\s*\?*\s*$"#, question) {
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
        /// The display names an export keeps apart from the addresses (X-From / X-To), when any.
        public var fromName: String = "", toNames: String = ""
    }

    /// The header lines an email's text opens with, as the email loader writes them.
    public static func message(objectID: UUID, text: String) -> Message? {
        var headers: [String: String] = [:]
        let parts = text.components(separatedBy: "\n\n")
        guard let head = parts.first else { return nil }
        var last: String?
        for line in head.components(separatedBy: .newlines) {
            // A folded header continues on lines that start with white space.
            if let key = last, line.first?.isWhitespace == true {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            last = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard ["from", "to", "cc", "subject", "date", "x-from", "x-to"].contains(key) else { continue }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            last = key
        }
        // An email with no subject is still an email (the loader writes no Subject line for it).
        guard let from = headers["from"], headers["date"] != nil || headers["subject"] != nil else { return nil }
        return Message(objectID: objectID, from: from, to: headers["to"] ?? "", subject: headers["subject"] ?? "", date: headers["date"] ?? "",
                       body: parts.dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
                       fromName: headers["x-from"] ?? "", toNames: headers["x-to"] ?? "")
    }

    static func normalizedSubject(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"^(?:\s*(?:re|fw|fwd)\s*:\s*)+"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func names(_ person: String, in header: String) -> Bool {
        let h = header.lowercased()
        if person.contains("@") { return h.contains(person.lowercased()) }
        let tokens = person.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 && !$0.hasSuffix(".") }
        guard let first = tokens.first, let last = tokens.last else { return false }
        // "Debra Perlingiere", "Perlingiere, Debra", "debra.perlingiere@enron.com" — whole words, so
        // "All Houston" is not "robert.allwein@…" nor "dl-ga-all_enron_houston@…".
        func word(_ w: String) -> Bool { h.range(of: #"(?<![a-z0-9_])"# + NSRegularExpression.escapedPattern(for: w) + #"(?![a-z0-9_])"#, options: .regularExpression) != nil }
        return (word(first) && word(last)) || h.contains("\(first).\(last)@")
    }

    static func answered(_ text: String, _ cites: [Message], refused: Bool = false) -> VerifiedAnswer {
        VerifiedAnswer(body: text, answerText: text, intentKind: VerifiedAnswer.recordAnswerKind,
                       citations: cites.map { VerifiedAnswer.Citation(objectID: $0.objectID, snippet: "From: \($0.from)\nTo: \($0.to)\nSubject: \($0.subject)\nDate: \($0.date)") },
                       confidence: Confidence(refused ? 0.6 : 0.85), refused: refused,
                       refusalReason: refused ? "No email found shows it." : nil)
    }

    /// The answer, or nil when no email among `messages` is the one asked about (the pipeline runs).
    /// `ledgerPairs`: messages the ledger's participant index already matched as from A to B (by the
    /// display name the header line may not carry — "From: m.miller@…" for "Mary Miller").
    public static func answer(_ ask: Ask, messages: [Message], complete: Bool = true, ledgerPairs: Set<UUID> = []) -> VerifiedAnswer? {
        switch ask {
        case .sender(let s), .sentDate(let s), .recipients(let s), .content(let s):
            let wanted = normalizedSubject(s)
            let hits = messages.filter { normalizedSubject($0.subject) == wanted }
            guard !hits.isEmpty else {
                // Emails were searched and none has that subject: said so, not answered from a passage.
                guard messages.count >= 3 else { return nil }
                return answered("None of the emails found has the subject “\(s)”.", [], refused: true)
            }
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
            let fromA = messages.filter { names(a, in: $0.from + " " + $0.fromName) || ledgerPairs.contains($0.objectID) }
            guard !fromA.isEmpty else { return nil }
            var distinct: [Message] = []
            for m in fromA where (names(b, in: m.to + " " + m.toNames) || ledgerPairs.contains(m.objectID)) && !distinct.contains(where: { $0.subject == m.subject && $0.date == m.date }) { distinct.append(m) }
            // A search that stopped at its cap gives a floor, never a total (brief §7 exact aggregates).
            let lead = complete ? "\(distinct.count)" : "At least \(distinct.count)"
            var text = "\(lead) of the emails found are from \(a) to \(b)" + (distinct.isEmpty ? "." : ":\n" + distinct.map { "• \($0.date) — \($0.subject)" }.joined(separator: "\n"))
            if !complete { text += "\n\nThe search stopped at its limit, so there may be more." }
            return answered(text, distinct.isEmpty ? Array(fromA.prefix(3)) : distinct)
        case .when(let a, let b):
            let fromA = messages.filter { names(a, in: $0.from + " " + $0.fromName) || ledgerPairs.contains($0.objectID) }
            guard !fromA.isEmpty else {
                // Nothing found from the sender at all: that is what the emails found show.
                guard !messages.isEmpty else { return nil }
                return answered("None of the emails found is from \(a) to \(b).", [], refused: true)
            }
            let toB = fromA.filter { names(b, in: $0.to + " " + $0.toNames) || ledgerPairs.contains($0.objectID) }
            guard !toB.isEmpty else {
                return answered("None of the emails found from \(a) is addressed to \(b).", Array(fromA.prefix(3)), refused: true)
            }
            return answered("\(a) emailed \(b) on:\n" + toB.map { "• \($0.date) — \($0.subject)" }.joined(separator: "\n"), toB)
        }
    }

}
