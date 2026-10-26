//
//  VerifiedRecordExtractor.swift
//  Kalsmritikosh
//
//  Online mode, AI on (2026-10-27, owner: "with your Claude key only 90 %? … we need at least 99 %").
//  The rules read a person's proceeding from fixed sentence shapes; the held-out triage showed their
//  remaining misses are reading misses — which sentence states the charge, which term is the
//  sentence, which date belongs to which step. Here the person's chosen model READS the person's own
//  documents and proposes the answer with a verbatim quote and the document it came from; the app
//  then VERIFIES it deterministically and shows it only if every check holds:
//    • the quote is in that document, verbatim (spacing, quotes and dashes normalised);
//    • the document names the person in full, and the quote names them (or is that document's lead);
//    • a date is stated in the quote, or the quote says "today"/"yesterday" and the document's printed
//      date gives the day; a sentence term appears in the quote; a charge quote states an offence;
//    • "No" to "did X plead guilty" only with a verdict at trial in the quote.
//  Anything unverified is dropped and the rules' answer stands. The model never adds a fact the
//  documents do not state verbatim. No model names here (capability discipline): the caller supplies
//  `generate`, which runs through the Online provider and its consent and masking.
//

import Foundation

public nonisolated struct VerifiedRecordExtractor: Sendable {
    private let generate: @Sendable (String) async throws -> String
    public init(generate: @escaping @Sendable (String) async throws -> String) { self.generate = generate }

    /// The asks the extractor answers; others stay with the rules.
    static func handles(_ ask: ProceedingAnswerer.Ask) -> Bool {
        switch ask {
        case .when, .sentenceImposed, .chargedWith, .whether: return true
        default: return false
        }
    }

    struct Proposal: Decodable { let answer: String?; let quote: String?; let doc: Int?; let value: String? }

    static func prompt(question: String, person: String, documents: [String]) -> String {
        var p = """
        You read official documents about one person and answer one question about that person ONLY from them.
        Person: \(person)
        Question: \(question)

        Rules:
        - Use only these documents. Never use outside knowledge. Never guess.
        - The answer must be about \(person), not a co-defendant, relative or anyone else.
        - "quote" must be ONE sentence copied EXACTLY, character for character, from the document that states the answer.
        - "doc" is that document's number.
        - For a date, "value" is YYYY-MM-DD. If the sentence says "today" or "yesterday", use the date the document prints at its top.
        - For a charge, quote the sentence that states what \(person) was charged with, pleaded guilty to, or was convicted of — not a prior record.
        - For a sentence, quote the sentence that states the prison term or probation imposed on \(person); "value" is the term as written.
        - For yes/no, "answer" starts with "Yes" or "No". Say "No" to a guilty plea only if the documents state a verdict at trial.
        - If the documents do not state the answer, reply {"answer": null}.
        Reply with JSON only: {"answer": "...", "quote": "...", "doc": 1, "value": "..."}

        """
        for (i, d) in documents.enumerated() { p += "\n[Document \(i + 1)]\n\(d)\n" }
        return p
    }

    static func parse(_ reply: String) -> Proposal? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Proposal.self, from: data)
    }

    /// Spacing, curly quotes and dashes made uniform so a faithful copy matches.
    static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "[“”″]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[‘’′]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[–—]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The verified answer, or nil (the rules answer stands).
    public func answer(question: String, parsed: ProceedingAnswerer.Parsed, sources: [ProceedingAnswerer.Source]) async -> VerifiedAnswer? {
        guard Self.handles(parsed.ask) else { return nil }
        let tokens = ProceedingEventExtractor.nameTokens(parsed.person)
        let about = sources.filter { ProceedingEventExtractor.mentionsFully($0.text.lowercased(), tokens: tokens) }.prefix(8)
        guard !about.isEmpty else { return nil }
        let docs = about.map { String($0.text.prefix(7_000)) }
        let reply: String
        do { reply = try await generate(Self.prompt(question: question, person: parsed.person, documents: docs)) } catch { return nil }
        guard let p = Self.parse(reply) else { return nil }
        return Self.verify(p, parsed: parsed, sources: Array(about), docs: docs)
    }

    static func verify(_ p: Proposal, parsed: ProceedingAnswerer.Parsed, sources: [ProceedingAnswerer.Source], docs: [String]) -> VerifiedAnswer? {
        guard let answer = p.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty,
              let quote = p.quote?.trimmingCharacters(in: .whitespacesAndNewlines), quote.count >= 20,
              let n = p.doc, n >= 1, n <= docs.count else { return nil }
        let doc = docs[n - 1]
        let q = normalized(quote)
        // 1. Verbatim in the cited document.
        guard normalized(doc).contains(q) else { return nil }
        // 2. About the person: the quote names them by surname (a lead may name them a sentence later,
        //    so a quote without the surname is accepted only when the document's opening holds it).
        let surname = parsed.person.split(separator: " ").last.map { $0.lowercased() } ?? ""
        let namesPerson = q.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: surname) + #"\b"#, options: .regularExpression) != nil
        if !namesPerson, !normalized(String(doc.prefix(1_500))).contains(surname) { return nil }
        // A different given name before the surname is someone else ("Gary Lomax" for James Lomax).
        if let r = quote.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: String(parsed.person.split(separator: " ").last ?? "")) + #"\b"#, options: [.regularExpression, .caseInsensitive]),
           ProceedingEventExtractor.namesSomeoneElse(quote, at: NSRange(r, in: quote), asked: ProceedingEventExtractor.nameTokens(parsed.person)) {
            return nil
        }
        let printed = ProceedingEventExtractor.printedDate(in: doc)
        var text = answer
        switch parsed.ask {
        case .when:
            guard let value = p.value, let day = isoDay(value) else { return nil }
            let stated = ProceedingEventExtractor.fullDate(in: quote).map { $0.year == day.year && $0.month == day.month && $0.day == day.day } ?? false
            let monthDay = quoteHasMonthDay(quote, day: day)
            let relative: Bool = {
                guard let printed, let pd = Calendar(identifier: .gregorian).date(from: printed) else { return false }
                if quote.range(of: #"(?i)\btoday\b"#, options: .regularExpression) != nil { return same(printed, day) }
                if quote.range(of: #"(?i)\byesterday\b"#, options: .regularExpression) != nil,
                   let y = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: pd) {
                    return same(Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: y), day)
                }
                return false
            }()
            guard stated || monthDay || relative else { return nil }
            // The step TAKEN, in the past tense — "Sentencing is scheduled for October 4" is not a sentencing.
            if case .when(let step) = parsed.ask {
                let lower = quote.lowercased()
                guard lower.range(of: step.pattern, options: .regularExpression) != nil,
                      lower.range(of: ProceedingEventExtractor.notYet, options: .regularExpression) == nil else { return nil }
            }
            let verb = stepPhrase(parsed.ask) == "pleaded guilty" ? "pleaded guilty" : "was \(stepPhrase(parsed.ask))"
            text = "\(parsed.person) \(verb) on \(ProceedingAnswerer.render(day) ?? value)."
        case .sentenceImposed:
            guard let value = p.value, !value.isEmpty,
                  normalized(quote).contains(normalized(value).components(separatedBy: " ").prefix(2).joined(separator: " ")),
                  quote.range(of: #"(?i)\bsentenc"#, options: .regularExpression) != nil else { return nil }
            text = "\(parsed.person) was sentenced to \(value)."
        case .chargedWith:
            guard quote.range(of: #"(?i)\bcharg(?:ed|es|ing)\b[^.]{0,60}\bwith\b|\b(?:pleaded|pled|pleads) guilty\b[^.]{0,80}\bto\b|\b(?:convicted|found guilty)\b[^.]{0,80}\bof\b|\bindicted (?:for|on)\b|\bcounts? of\b"#, options: .regularExpression) != nil,
                  quote.range(of: #"(?i)\b(?:previously (?:been )?convicted|prior (?:felony )?convictions?|convicted felon|criminal history)\b"#, options: .regularExpression) == nil else { return nil }
            text = "The documents say:"
        case .whether(let step):
            let yes = answer.lowercased().hasPrefix("yes"), no = answer.lowercased().hasPrefix("no")
            guard yes || no else { return nil }
            if yes, quote.range(of: Self.stepWords(step), options: [.regularExpression, .caseInsensitive]) == nil { return nil }
            if no {
                guard step == .pleaded, quote.range(of: ProceedingAnswerer.trialVerdict, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
            }
            text = yes ? "Yes —" : "No — the documents say \(parsed.person) was found guilty at trial:"
        default:
            return nil
        }
        let body = "\(text) \(ProceedingAnswerer.quote(quote))"
        return VerifiedAnswer(body: body, answerText: body, intentKind: VerifiedAnswer.recordAnswerKind,
                              citations: [VerifiedAnswer.Citation(objectID: sources[n - 1].objectID, snippet: String(quote.prefix(300)))],
                              confidence: Confidence(0.85))
    }

    static func stepWords(_ step: ProceedingEventExtractor.Step) -> String {
        switch step {
        case .charged: return #"\b(?:charg|indict|complaint|information)"#
        case .arrested: return #"\barrest"#
        case .arraigned: return #"\barraign"#
        case .pleaded: return #"\b(?:pleaded|pled|pleads) guilty\b"#
        case .convicted: return #"\b(?:convicted|found guilty|verdict)\b"#
        case .acquitted: return #"\b(?:acquitted|not guilty)\b"#
        case .sentenced: return #"\bsentenc"#
        case .pardoned: return #"\bpardon"#
        case .released: return #"\breleased\b"#
        }
    }

    static func stepPhrase(_ ask: ProceedingAnswerer.Ask) -> String {
        if case .when(let step) = ask { return step.phrase }
        return ""
    }

    static func isoDay(_ s: String) -> DateComponents? {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    static func same(_ a: DateComponents, _ b: DateComponents) -> Bool { a.year == b.year && a.month == b.month && a.day == b.day }

    /// "on Feb. 15" / "June 10" with the day — the year may be the document's own.
    static func quoteHasMonthDay(_ quote: String, day: DateComponents) -> Bool {
        guard let month = day.month, let d = day.day else { return false }
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let pattern = #"(?i)\b"# + names[month - 1] + #"[a-z]*\.?\s+"# + String(d) + #"\b"#
        return quote.range(of: pattern, options: .regularExpression) != nil
    }
}
