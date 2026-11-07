//
//  IssuingOfficeGate.swift
//  Kalsmritikosh
//
//  Q-3 (docs/INVESTIGATIONS_MADE_EASY_TODO.md) — "Which office announced / issued …?" is answered
//  with the office, as the release names it, or with an honest "the release doesn't name the office".
//  Case bench round 4: answers pasted the release's closing paragraph, named a partner agency, or
//  said "a U.S. Attorney office" while the passage named the district. A government release names
//  its office in a few fixed forms; this reads those forms from the answer and its cited passages.
//  An answer that already names a specific office is never touched.
//

import Foundation

public nonisolated enum IssuingOfficeGate {

    public static func asksIssuingOffice(_ question: String) -> Bool {
        // A wording the rules miss, placed by the question interpreter.
        if QuestionUnderstanding.gateIntent(for: question) == .announcingOffice { return true }
        let q = question.lowercased()
        return q.range(of: #"\b(?:which|what)\b[^?]{0,40}\b(?:office|agency|component|department|division|unit)\b[^?]{0,40}\b(?:announc|issu|publish|releas|put out|sent out)"#,
                       options: .regularExpression) != nil
            // "Who released "Fairfield Man Indicted …"?" — a quoted release title names the release
            // itself (held-out wording set 4, 2026-10-25). "Who issued FDA recall X" has no title.
            || q.range(of: #"^\s*who\s+(?:released|issued|published|put out|sent out)\s+(?:the\s+(?:release|statement|announcement)\s+)?["“]"#,
                       options: .regularExpression) != nil
            // "Which office prosecuted Christi Machala?" — a federal release is issued by the office
            // that prosecutes the case (closed-case simulation, 2026-10-26).
            || q.range(of: #"^\s*(?:which|what)\s+(?:u\.s\. attorney'?s\s+)?(?:office|agency|prosecutors?)\s+(?:prosecuted|handled|brought|charged|is prosecuting)\b"#,
                       options: .regularExpression) != nil
            // "Which office is the source of "…"?" (held-out wording set 5, 2026-10-25).
            || q.range(of: #"^\s*(?:which|what)\s+(?:office|agency|department)\s+is\s+(?:the\s+)?(?:source|author|origin)\s+of\b"#,
                       options: .regularExpression) != nil
            // "Who announced the case …?" (wide case bench 2026-10-25).
            // "Who issued FDA recall X?" asks for the recalling firm, not an office: issued /
            // released / published count only of a release or announcement.
            || q.range(of: #"^\s*who\s+announced\b"#, options: .regularExpression) != nil
            // "Who is credited with announcing …?" (untouched wording set 2026-10-25).
            || q.range(of: #"^\s*(?:who|which)\b[^?]{0,40}\bannouncing\b"#, options: .regularExpression) != nil
            || q.range(of: #"^\s*who\s+(?:issued|released|published)\s+the\s+(?:release|press release|announcement|statement)\b"#, options: .regularExpression) != nil
            || q.range(of: #"^\s*who\s+(?:made|issued|put out|sent out)\s+the\s+(?:announcement|release|press release)\b"#, options: .regularExpression) != nil
    }

    /// "the Middle District of Pennsylvania", "the Southern District of New York", "the District of Columbia".
    /// A two-word state only when its first word starts one ("New York", "North Carolina"): "the
    /// Southern District of California Laura E. Duffy" must not take the attorney's first name.
    static let district = #"(?:Northern|Southern|Eastern|Western|Middle|Central)?\s?District of (?:(?:New|North|South|West|Rhode|Puerto|Virgin)\s[A-Z][a-z]+|Northern Mariana Islands|the Virgin Islands|[A-Z][a-z]+)"#

    static let forms: [(String, (String) -> String)] = [
        (#"(?:United States|U\.S\.)\s+Attorney[’']s\s+Office\s+(?:for|in)\s+the\s+("# + district + ")", { "the U.S. Attorney's Office for the \($0)" }),
        (#"Office\s+of\s+the\s+(?:United States|U\.S\.)\s+Attorney\s+(?:for|in)\s+the\s+("# + district + ")", { "the U.S. Attorney's Office for the \($0)" }),
        // "United States Attorney Gregory J. Haanstad of the Eastern District of Wisconsin announced".
        (#"(?:United States|U\.S\.)\s+Attorney\s+(?:[A-Z][A-Za-z.'’\-]*\s+){0,4}(?:for|of)\s+the\s+("# + district + ")", { "the U.S. Attorney's Office for the \($0)" }),
        // A Justice Department division — not another agency's ("the FBI Washington Field Office
        // Criminal Division" is the FBI's; held-out chronology 2026-10-26 answered it as the DOJ's).
        (#"(?<!Office )(?<!FBI )(?<!Bureau )(?<!Police )\b(Criminal|Civil|Tax|Antitrust|Civil Rights|National Security|Environment and Natural Resources)\s+Division\b"#, { "the Justice Department's \($0) Division" }),
    ]

    /// The office as a release names it, normalised to one form. The sentence that says who
    /// announced comes first (case bench 2026-10-24: a release naming the Tax Division as the
    /// announcer and a district office as a partner answered with the district); within a
    /// stretch of text the earliest-named office wins, whichever form names it.
    public static func office(in text: String) -> String? { located(in: text)?.office }

    /// The office and whether a sentence says it announced (false: the release only names it).
    static func located(in text: String) -> (office: String, announced: Bool)? {
        let announcing = announcingSentences(in: text)
        // A joint release names every announcing office in that sentence ("U.S. Attorney Scott for
        // the Eastern District of California and … the Justice Department's Criminal Division
        // announced") — all of them, in the order named.
        for stretch in announcing {
            let all = allOffices(in: stretch)
            if !all.isEmpty { return (all.joined(separator: " and "), true) }
        }
        // "… the Justice Department announced." with no office in that sentence: the department
        // announced, and the division the release names is its part in it — not a U.S. Attorney's
        // office mentioned further down (held-out wording set 5, 2026-10-25).
        if announcing.contains(where: { $0.range(of: #"(?i)\b(?:Justice Department|Department of Justice)\b"#, options: .regularExpression) != nil }),
           let division = earliestOffice(in: text, forms: [forms[3]]) {
            return ("the Justice Department (the release names \(division.replacingOccurrences(of: "the Justice Department's ", with: "its ")))", true)
        }
        // No sentence says who announced: a U.S. Attorney's office named anywhere is the
        // announcer before a division the release mentions as a helper ("with assistance from
        // the Criminal Division's Computer Crime Section" — case bench 2026-10-24).
        if let named = earliestOffice(in: text, forms: Array(forms.prefix(3))) ?? earliestOffice(in: text) {
            return (named, false)
        }
        // Only a district, with no office around it ("… found in the Eastern District of Louisiana")
        // — reported as what the release mentions, never as the announcer.
        if let r = text.range(of: #"\b(?:the\s+)?("# + district + ")", options: .regularExpression) {
            let d = String(text[r]).replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
            return ("the \(d.trimmingCharacters(in: .whitespacesAndNewlines))", false)
        }
        return nil
    }

    /// The sentences that say "announced". Initials ("McGregor W. Scott", "Brian C. Rabbitt") are
    /// not sentence ends: a sentence starts after a word of two or more lowercase letters (or a
    /// line break) and its period, so the officials' names stay in the sentence they announce.
    static func announcingSentences(in text: String) -> [String] {
        let ns = text as NSString
        guard let ann = try? NSRegularExpression(pattern: #"(?i)announc"#),
              let end = try? NSRegularExpression(pattern: #"(?:[a-z]{2,}[.!?]["”’)]?\s+(?=[A-Z“"])|\n)"#) else { return [] }
        let ends = end.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.location + $0.range.length }
        var out: [String] = []
        for m in ann.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let start = ends.last { $0 <= m.range.location } ?? 0
            let stop = ends.first { $0 > m.range.location } ?? ns.length
            out.append(ns.substring(with: NSRange(location: start, length: stop - start)))
        }
        return out
    }

    /// Every distinct office the text names, in order of appearance.
    static func allOffices(in text: String) -> [String] {
        let ns = text as NSString
        var found: [(location: Int, value: String)] = []
        for (pattern, render) in forms {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.append((m.range.location, render(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.location < $1.location }.map(\.value).filter { seen.insert($0).inserted }
    }

    static func earliestOffice(in text: String, forms: [(String, (String) -> String)] = IssuingOfficeGate.forms) -> String? {
        let ns = text as NSString
        var best: (location: Int, value: String)?
        for (pattern, render) in forms {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            if best == nil || m.range.location < best!.location {
                best = (m.range.location, render(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)))
            }
        }
        return best?.value
    }

    /// True when the answer already names a specific office (a district office or a division).
    static func namesOffice(_ text: String) -> Bool { earliestOffice(in: text) != nil }

    /// `sourceTexts` — the full text of the cited documents (the office line is often outside the
    /// cited snippet). Without it, a "not named" refusal is only given when the snippets are all there is.
    public static func apply(question: String, _ answer: VerifiedAnswer, sourceTexts: [String] = []) -> VerifiedAnswer {
        let said = answer.answerText ?? answer.body
        // An answer that STATES an office is kept; a pasted passage that merely contains one is not
        // a statement of who announced (wide case bench 2026-10-25: "Who announced the case …?"
        // came back as the cover email and release text).
        guard asksIssuingOffice(question), !answer.refused, !(said.count <= 250 && namesOffice(said)) else { return answer }
        // Only texts about THIS matter: a release that shares most of the question's words. Wide case
        // bench 2026-10-25: "Who announced the case Oxnard Man Indicted …?" (title unquoted, so not
        // anchored) took the office of another release the search surfaced.
        let asked = Set(question.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !["which", "office", "announced", "announce", "justice", "department", "case",
                                         "release", "issued", "about", "what", "that"].contains($0) })
        func aboutThisMatter(_ t: String) -> Bool {
            guard asked.count >= 3 else { return true }
            let words = Set(t.lowercased().components(separatedBy: CharacterSet.letters.inverted))
            return Double(asked.intersection(words).count) / Double(asked.count) >= 0.6
        }
        let all = [answer.body] + answer.citations.map(\.snippet) + sourceTexts
        // When some texts are about this matter, the others (another release) are set aside; when
        // none is recognisably about it, all of them are read as before.
        let matching = all.filter(aboutThisMatter)
        let pool = (matching.isEmpty ? all : matching).joined(separator: "\n")
        let text: String
        let refused: Bool
        if let found = located(in: pool) {
            // Only a sentence that says who announced is stated as the announcer; otherwise the
            // reader is told the release names the office without saying it announced.
            text = found.announced
                ? "\(found.office.prefix(1).uppercased() + found.office.dropFirst()) announced it."
                : "The release doesn't say which office announced it; it mentions \(found.office)."
            refused = false
        } else {
            text = "The release doesn't name the office that announced it."
            refused = true
        }
        return VerifiedAnswer(body: text, answerText: text, intentKind: answer.intentKind, citations: answer.citations,
                              confidence: answer.confidence, contradictions: answer.contradictions, refused: refused,
                              refusalReason: refused ? "The evidence names no issuing office." : nil, report: answer.report,
                              walkSteps: answer.walkSteps, source: answer.source, reasoningTrace: answer.reasoningTrace,
                              answerState: answer.answerState, ledgerAnswerID: answer.ledgerAnswerID)
    }
}
