//
//  StateQuestionAnswerer.swift
//  Kalsmritikosh
//
//  "Was invoice 432 paid?", "Has contract 7 been signed?", "Is claim 1182 approved?" — a yes/no about the
//  state of ONE identified thing. User evaluation 2026-11-02 (M3): such a question was answered with a dump
//  of three emails, badged as supported, and never said that no payment is recorded.
//
//  Only clauses that name the thing count: "invoice 401 paid; invoice 432 issued … and overdue" says
//  nothing about 432 being paid. A clause that says "this invoice" counts when its passage names the thing
//  and no other thing of that kind. A clause stating the state answers Yes; clauses stating only the
//  opposite ("remains unpaid", "overdue", "not paid") answer that the state is not recorded, quoting them.
//  Neither: nil — the normal pipeline decides. Deterministic, no model, quotes and cites.
//

import Foundation

nonisolated enum StateQuestionAnswerer {

    struct Asked: Equatable {
        let noun: String        // "invoice"
        let number: String      // "432"
        let state: String       // "paid"
    }

    struct Clause {
        let text: String
        let chunk: Chunk
    }

    enum Outcome {
        case stated(Clause)
        case onlyOpposite([Clause])
    }

    /// States and the words that say the opposite of each, beyond "un<state>" and "not <state>".
    static let opposites: [String: [String]] = [
        "paid": ["outstanding", "overdue", "past due", "owing", "in arrears", "unsettled"],
        "approved": ["rejected", "denied", "declined"],
        "signed": ["unsigned"],
        "delivered": ["undelivered", "lost in transit"],
        "completed": ["incomplete", "unfinished", "pending"],
        "settled": ["unsettled", "outstanding"],
        "renewed": ["lapsed", "expired"],
        "accepted": ["rejected", "declined"],
        "shipped": ["backordered", "on hold"],
        "refunded": ["not refunded"],
    ]

    /// "was invoice 432 paid", "has invoice #432 been paid", "is claim no. 1182 approved".
    static func parse(_ question: String) -> Asked? {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "?.!")))
        let pattern = #"^(?:was|were|is|has|have|did)\s+(?:the\s+)?([a-z]{3,20})\s+(?:no\.?\s*|number\s+|#\s*)?([a-z]{0,4}-?\d[\w-]*)\s+(?:been\s+|ever\s+|already\s+|actually\s+|fully\s+)*([a-z]{3,20})$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
              let n = Range(m.range(at: 1), in: q), let d = Range(m.range(at: 2), in: q), let s = Range(m.range(at: 3), in: q) else { return nil }
        return Asked(noun: String(q[n]), number: String(q[d]), state: String(q[s]))
    }

    static func names(_ text: String, _ a: Asked) -> Bool {
        text.range(of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: a.noun) + #"s?\s*(?:no\.?\s*|number\s+|#\s*)?"#
                   + NSRegularExpression.escapedPattern(for: a.number) + #"\b"#, options: .regularExpression) != nil
    }

    /// Another thing of the same kind ("invoice 401") in the text.
    static func namesAnother(_ text: String, _ a: Asked) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: a.noun) + #"s?\s*(?:no\.?\s*|number\s+|#\s*)?([a-z]{0,4}-?\d[\w-]*)\b"#) else { return false }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]).lowercased() != a.number } ?? false
        }
    }

    static func statesOpposite(_ clause: String, _ a: Asked) -> Bool {
        let c = clause.lowercased()
        let s = NSRegularExpression.escapedPattern(for: a.state)
        if c.range(of: #"\bun"# + s + #"\b|\bnot\s+(?:yet\s+|been\s+|yet\s+been\s+|been\s+fully\s+|fully\s+)?"# + s + #"\b|\bnever\s+(?:been\s+)?"# + s + #"\b"#, options: .regularExpression) != nil { return true }
        return (opposites[a.state] ?? []).contains { c.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil }
    }

    static func statesState(_ clause: String, _ a: Asked) -> Bool {
        guard !statesOpposite(clause, a) else { return false }
        let c = clause.lowercased()
        // "will be paid", "to be paid", "if paid", "due to be paid" are not the state.
        guard c.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: a.state) + #"\b"#, options: .regularExpression) != nil else { return false }
        return c.range(of: #"\b(?:will|would|should|must|to|if|unless|once|until|when|expected to|scheduled to)\s+(?:be\s+|have\s+been\s+)?"# + NSRegularExpression.escapedPattern(for: a.state) + #"\b"#, options: .regularExpression) == nil
    }

    static func clauses(of sentence: String) -> [String] {
        sentence.components(separatedBy: CharacterSet(charactersIn: ";\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 8 }
    }

    static func answer(_ a: Asked, chunks: [RetrievedChunk]) -> Outcome? {
        var stated: Clause?
        var opposite: [Clause] = []
        for rc in chunks {
            let text = rc.chunk.text
            let chunkNames = names(text, a)
            guard chunkNames else { continue }
            let soleThing = !namesAnother(text, a)
            for sentence in SentenceQuoteComposer.sentences(of: text) {
                for clause in clauses(of: sentence) {
                    let about = names(clause, a)
                        || (soleThing && clause.range(of: #"(?i)\b(?:this|the|that|said)\s+"# + NSRegularExpression.escapedPattern(for: a.noun) + #"\b"#, options: .regularExpression) != nil)
                    guard about else { continue }
                    if stated == nil, statesState(clause, a) { stated = Clause(text: clause, chunk: rc.chunk) }
                    else if statesOpposite(clause, a), !opposite.contains(where: { $0.text == clause }) { opposite.append(Clause(text: clause, chunk: rc.chunk)) }
                }
            }
        }
        if let stated { return .stated(stated) }
        return opposite.isEmpty ? nil : .onlyOpposite(Array(opposite.prefix(3)))
    }

    static func render(_ outcome: Outcome, _ a: Asked) -> String {
        let thing = "\(a.noun) \(a.number)"
        switch outcome {
        case .stated(let c):
            return "Yes — the documents say \(thing) was \(a.state): \u{201C}\(c.text)\u{201D}"
        case .onlyOpposite(let cs):
            return "No document found records \(thing) as \(a.state). They say: " + cs.map { "\u{201C}\($0.text)\u{201D}" }.joined(separator: " / ")
        }
    }
}
