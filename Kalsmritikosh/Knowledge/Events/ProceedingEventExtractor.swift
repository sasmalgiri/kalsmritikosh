//
//  ProceedingEventExtractor.swift
//  Kalsmritikosh
//
//  The steps of a proceeding against a person, as the documents report them: charged, arrested,
//  pleaded guilty, convicted, acquitted, sentenced, pardoned, released.
//
//  FOUND BY THE CLOSED-CASE SIMULATION, 2026-10-26. 200 finished federal prosecutions, each followed
//  across the Justice Department's own releases (charged → pleaded → sentenced): "When was Christi
//  Machala sentenced?", "Did she plead guilty?", "Give me the timeline of the case against her"
//  were answered 0–2% of the time — the release came back as a passage, because nothing in the
//  ledger held "this person, this step, this day". The incident and milestone extractors know
//  accidents and patent filings, not the steps of a case.
//
//  A sentence names the person (full name or surname) and a step in the past tense ("was
//  sentenced", "pleaded guilty", "was convicted by a jury"); future and conditional wording
//  ("is scheduled to be sentenced", "faces up to 20 years", "agreed to plead") is not a step.
//  The day is the one the sentence states ("on March 3, 2015"), or — for "today" / "yesterday" —
//  the day the document itself prints at its head (a release's "FOR IMMEDIATE RELEASE Thursday,
//  September 24, 2015"). With neither, the step is kept undated: the document's file date is never
//  substituted.
//
//  Deterministic, offline, pure.
//

import Foundation

public nonisolated enum ProceedingEventExtractor {

    public enum Step: String, Sendable, CaseIterable {
        case charged, arrested, arraigned, pleaded, convicted, acquitted, sentenced, pardoned, released

        /// How the step reads in an answer.
        public var phrase: String {
            switch self {
            case .charged: return "charged"
            case .arrested: return "arrested"
            case .arraigned: return "arraigned"
            case .pleaded: return "pleaded guilty"
            case .convicted: return "convicted"
            case .acquitted: return "acquitted"
            case .sentenced: return "sentenced"
            case .pardoned: return "pardoned"
            case .released: return "released"
            }
        }

        /// Past-tense wording that reports the step. Matched case-insensitively.
        public var pattern: String {
            switch self {
            case .charged: return #"\b(?:was|were|has been|have been|been) (?:arrested and )?(?:indicted|charged)\b|\barrested and charged\b|\b(?:indicted|charged) (?:by|in) (?:a|an|the) (?:federal )?(?:grand jury|indictment|complaint|information)\b|\ba (?:federal )?grand jury (?:returned|handed up) an indictment\b|\b(?:indictment|complaint|information)\b[^.]{0,80}\bcharg(?:es|ed|ing)\b"#
            case .arrested: return #"\b(?:was|were|has been) arrested\b"#
            case .arraigned: return #"\b(?:was|were) arraigned\b"#
            case .pleaded: return #"\b(?:pleaded|pled|pleads) guilty\b"#
            case .convicted: return #"\b(?:was|were|has been) (?:convicted|found guilty)\b|\bjury (?:convicted|found)\b"#
            case .acquitted: return #"\b(?:was|were) acquitted\b|\bfound not guilty\b"#
            case .sentenced: return #"\b(?:was|were|has been|been) sentenced\b|\bsentenced\b.{0,200}?\bto\s+(?:serve\s+|spend\s+)?(?:an?\s+(?:total|term|period)\s+of\s+)?(?:\d|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|life|time served|probation)"#
            case .pardoned: return #"\b(?:was|were|has been) pardoned\b|\bgranted (?:a|him a|her a) pardon\b"#
            case .released: return #"\b(?:was|were) released from (?:prison|custody)\b"#
            }
        }
    }

    public struct Finding: Sendable, Equatable {
        public let step: Step
        /// The day the step happened, as the document states it (nil: the document gives none).
        public let day: DateComponents?
        /// True when the day was read from "today"/"yesterday" against the document's printed date.
        public let dayFromPrintedDate: Bool
        /// The sentence that reports the step, verbatim.
        public let sentence: String
        /// "to 48 months in federal prison …" — what a sentencing sentence imposes.
        public let detail: String?
        /// The date the document itself prints (the day it reports the step), when it prints one.
        public var reportedOn: DateComponents? = nil
    }

    /// Words that make a sentence about the future or a possibility, not a step taken.
    static let notYet = #"(?i)\b(?:scheduled to|will be|faces?|facing|could|would|may(?!\s+\d)|might|agreed to|expected to|is set to|set for|awaiting|faces up to|maximum|up to \d+ years)\b"#

    /// The steps the text reports for `person` (the name as asked), earliest first, one per step and day.
    public static func findings(in text: String, person: String) -> [Finding] {
        let tokens = nameTokens(person)
        guard let surname = tokens.last, tokens.count >= 2 else { return [] }
        let lower = text.lowercased()
        // The document must name the person in full (all of the asked tokens near each other).
        guard mentionsFully(lower, tokens: tokens) else { return [] }
        let printed = printedDate(in: text)
        // "Christi Romano, aka Christi Machala" — later sentences call the person by either name.
        var surnames: Set<String> = [surname]
        if let re = try? NSRegularExpression(pattern: #"\b([a-z]+(?: [a-z]\.?)? [a-z'\-]+),? (?:aka|a/k/a|also known as|formerly known as|née) ([a-z]+(?: [a-z]\.?)? [a-z'\-]+)\b"#) {
            let ns = lower as NSString
            for m in re.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2))
                let asked = tokens.joined(separator: " ")
                if a.hasSuffix(surname) || a == asked, let s = nameTokens(b).last { surnames.insert(s) }
                if b.hasSuffix(surname) || b == asked, let s = nameTokens(a).last { surnames.insert(s) }
            }
        }
        var out: [Finding] = []
        var seen = Set<String>()
        let all = sentences(of: text)
        // "A Florida man was sentenced today to one year …" — the lead names the person a sentence or
        // two later. In a document about one defendant (one "Name, 41," introduction at most), the
        // descriptive lead is about the person asked.
        let introductions = (try? NSRegularExpression(pattern: #"\b[A-Z][a-z]+(?: [A-Z]\.?| [A-Z][a-z]+){0,2} [A-Z][a-zA-Z'\-]+, (?:a\s)?\d{2},"#))?
            .numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? 0
        var descriptiveLead: Int?
        if introductions <= 1, let i = all.firstIndex(where: { $0.range(of: #"^(?:[A-Z][A-Za-z.,' ]{2,40}\s[–—-]\s*)?(?:An?|The)\s(?:[A-Za-z\-]+,?\s){0,6}(?:man|woman|resident|officer|official|doctor|physician|businessman|businesswoman|executive|attorney|lawyer|felon|defendant|employee|manager|teen|teenager|person|nurse|pharmacist|owner|operator|agent|leader|head|founder|president|chief|director|member|ringleader|pastor|teacher|contractor|banker|broker|accountant|preparer|trafficker|dealer|smuggler|hacker|citizen|national|immigrant|veteran|inmate|felon|deputy|pilot|sheriff|trooper|detective|sergeant|lieutenant|guard|soldier|marine|sailor|student|priest|coach|driver|worker|clerk|dentist|chiropractor|therapist|engineer|analyst|consultant|adviser|advisor|investor|developer|landlord|mayor|councilman|councilwoman|legislator|bookkeeper|administrator|cashier|teller|courier|mechanic|rancher|farmer|veterinarian|firefighter|paramedic|technician|salesman|saleswoman|realtor|fugitive|gang member|businessperson|couple)\b"#, options: .regularExpression) != nil }),
           i < 8, all[i..<min(all.count, i + 4)].contains(where: { mentionsFully($0.lowercased(), tokens: tokens) }) {
            descriptiveLead = i
        }
        // "Two Florida women pleaded guilty today …" followed by "Analay Rico, 37, … and Daylen Diaz,
        // 44, …": a plural lead is about each defendant the next sentences introduce.
        if descriptiveLead == nil,
           let i = all.prefix(8).firstIndex(where: { $0.range(of: #"^(?:[A-Z][A-Za-z.,' ]{2,40}\s[–—-]\s*)?(?:Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|\d{1,2})\s(?:[A-Za-z\-]+,?\s){0,6}(?:men|women|residents|people|individuals|defendants|officers|officials|executives|employees|doctors|physicians|nurses|members|brothers|sisters|siblings|nationals|citizens|leaders|owners|operators)\b"#, options: .regularExpression) != nil }),
           all[(i + 1)..<min(all.count, i + 4)].contains(where: { mentionsFully($0.lowercased(), tokens: tokens) }) {
            descriptiveLead = i
        }
        for (index, sentence) in all.enumerated() {
            let s = sentence.lowercased()
            guard index == descriptiveLead || surnames.contains(where: { s.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil }) else { continue }
            // Where the person is named in the sentence (by any of their surnames, or the descriptive lead).
            // A surname right after a DIFFERENT given name is someone else ("The brother, Charles Stanley,
            // … was sentenced" is not David Stanley's sentence — closed-case simulation 2026-10-26).
            let named = surnames.flatMap { surname -> [Range<String.Index>] in
                guard let re = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: surname) + #"\b"#) else { return [] }
                let ns = s as NSString
                return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m -> Range<String.Index>? in
                    guard let r = Range(m.range, in: s) else { return nil }
                    if sentence.count == s.count, Self.namesSomeoneElse(sentence, at: m.range, asked: tokens) { return nil }
                    return r
                }
            }
            if index != descriptiveLead, named.isEmpty { continue }
            for step in Step.allCases {
                guard let r = s.range(of: step.pattern, options: .regularExpression) else { continue }
                // "pleaded guilty … to an information charging him with …" reports the plea; the charge is
                // background, not a charging event on this sentence's day — unless the day is stated for it.
                if step == .charged,
                   [Step.pleaded, .convicted, .sentenced, .arraigned].contains(where: { s.range(of: $0.pattern, options: .regularExpression) != nil }),
                   s.range(of: #"\b(?:charged|indicted|indictment|complaint|information)\b[^.]{0,60}\bon\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d"#, options: .regularExpression) == nil {
                    continue
                }
                // The step is the person's when they are named before it ("Romano … was sentenced"), or
                // right after it ("sentenced Kalomi Kambui, 41, to 18 months") — not when the name only
                // follows it in an attribution ("… was sentenced today, announced U.S. Attorney Peter F. Neronha").
                if index != descriptiveLead {
                    // "Steed's co-defendant Upchurch was sentenced …" — the step is the other person's.
                    let before = named.contains { m in
                        guard m.lowerBound < r.lowerBound else { return false }
                        let between = s[m.upperBound..<r.lowerBound]
                        // "Steed and her co-defendant Upchurch were sentenced" is both of them.
                        if s[r].hasPrefix("were") { return true }
                        return between.range(of: #"\b(?:co-?defendants?|co-?conspirators?|associates?|accomplices?|partners?|wife|husband|brother|sister|son|daughter|father|mother)\b"#,
                                             options: .regularExpression) == nil
                    }
                    let rightAfter = named.contains { $0.lowerBound >= r.lowerBound && s.distance(from: r.lowerBound, to: $0.lowerBound) <= 60 }
                    guard before || rightAfter else { continue }
                }
                // A future or conditional clause right around the step is not the step.
                let window = String(s[s.index(r.lowerBound, offsetBy: -min(40, s.distance(from: s.startIndex, to: r.lowerBound)))..<r.upperBound])
                if window.range(of: notYet, options: .regularExpression) != nil { continue }
                if step == .pleaded, s.range(of: #"\bnot guilty\b"#, options: .regularExpression) != nil { continue }
                let (day, relative) = stepDay(sentence, printed: printed, stepEnd: s.distance(from: s.startIndex, to: r.upperBound))
                // One per step and day; undated mentions are kept apart (the one that states the offence may come second).
                let key = step.rawValue + "|" + (day.map { "\($0.year ?? 0)-\($0.month ?? 0)-\($0.day ?? 0)" } ?? "?" + String(sentence.prefix(60)))
                guard seen.insert(key).inserted else { continue }
                out.append(Finding(step: step, day: day, dayFromPrintedDate: relative, sentence: sentence.trimmingCharacters(in: .whitespacesAndNewlines),
                                   detail: step == .sentenced ? sentenceDetail(sentence) : nil, reportedOn: printed))
            }
        }
        // A release's headline states its step ("Man Arrested for Possession …") while its lead only
        // says what happened in court that day ("Kenneth James … made his initial appearance"): the
        // step is reported on the document's printed date, undated in itself.
        if let title = headline(of: text), mentionsFully(String(lower.prefix(1500)), tokens: tokens) {
            let t = title.lowercased()
            let headlineSteps: [(String, Step)] = [("sentenced", .sentenced), ("pleads guilty", .pleaded), ("pleaded guilty", .pleaded),
                                                   ("convicted", .convicted), ("found guilty", .convicted), ("indicted", .charged),
                                                   ("charged", .charged), ("arrested", .arrested), ("acquitted", .acquitted), ("pardoned", .pardoned)]
            if let step = headlineSteps.first(where: { t.range(of: #"\b"# + $0.0 + #"\b"#, options: .regularExpression) != nil })?.1 {
                // "Owner … Sentenced to 113 Months in Prison" — the headline's term, when no sentence
                // in the body states one for this person.
                let detail = step == .sentenced ? sentenceDetail(title) : nil
                let bodyHasStep = out.contains(where: { $0.step == step })
                let bodyHasTerm = out.contains(where: { $0.step == .sentenced && $0.detail != nil })
                if !bodyHasStep || (detail != nil && !bodyHasTerm) {
                    out.append(Finding(step: step, day: nil, dayFromPrintedDate: false, sentence: title, detail: detail, reportedOn: printed))
                }
            }
        }
        return out.sorted { order($0) < order($1) }
    }

    /// The document's headline: the first line of four or more words near its head that is not an
    /// organisation line, a release line or a date.
    static func headline(of text: String) -> String? {
        for raw in text.components(separatedBy: .newlines).prefix(14) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.split(separator: " ").count >= 4, line.count <= 200,
                  line.range(of: #"(?i)^(?:u\.s\. department|department of|united states attorney|for immediate release|office of|(?:(?:northern|southern|eastern|western|middle|central)\s+)?district of\b)|(?i)\b(?:division|office|bureau|department|section)$"#, options: .regularExpression) == nil,
                  fullDate(in: line) == nil || line.count > 40 else { continue }
            // A lead paragraph ("PROVIDENCE, R.I. – …") is not a headline.
            if line.range(of: #"^[A-Z][A-Z .,'\-]{2,40}(?:,|\s[–—-])"#, options: .regularExpression) != nil { return nil }
            // Nor is a body paragraph: a headline does not end with a full stop or hold sentence breaks.
            if line.hasSuffix(".") || line.range(of: #"[a-z0-9)][.!?]\s+[A-Z]"#, options: .regularExpression) != nil { return nil }
            return line
        }
        return nil
    }

    static func order(_ f: Finding) -> String {
        guard let d = f.day, let y = d.year, let m = d.month, let dd = d.day else { return "9999" + f.step.rawValue }
        return String(format: "%04d-%02d-%02d", y, m, dd)
    }

    static func nameTokens(_ person: String) -> [String] {
        person.lowercased().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { $0.count >= 2 && !["jr", "sr", "ii", "iii"].contains($0) }
    }

    /// All the asked name's tokens within a short stretch ("Christi Romano, aka Christi Machala").
    /// True when the surname at `range` (in the original-case sentence) follows a capitalised given
    /// name that is not one of the asked person's ("Charles Stanley" when asked about David Stanley).
    static func namesSomeoneElse(_ sentence: String, at range: NSRange, asked tokens: [String]) -> Bool {
        let ns = sentence as NSString
        guard range.location > 0 else { return false }
        let before = ns.substring(to: range.location)
        guard let m = before.range(of: #"([A-Z][a-z'’\-]+)\s+(?:[A-Z]\.\s+)?$"#, options: .regularExpression) else { return false }
        let word = String(before[m]).trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""
        let given = word.lowercased()
        let titles: Set<String> = ["mr", "mrs", "ms", "dr", "judge", "justice", "defendant", "officer", "agent", "detective", "sergeant",
                                   "deputy", "senator", "representative", "governor", "mayor", "pastor", "reverend", "the", "a", "an",
                                   "and", "said", "says", "when", "after", "before", "then", "while", "that", "according", "to", "both",
                                   "general", "attorney", "special", "former", "acting", "assistant", "chief", "commissioner",
                                   "yesterday", "today", "earlier", "later", "meanwhile", "however", "also", "here", "there"]
        if titles.contains(given) || tokens.dropLast().contains(given) { return false }
        // A given name the person goes by is a prefix of an asked token ("Dave" ~ "david") — kept as theirs.
        if tokens.dropLast().contains(where: { $0.hasPrefix(given) || given.hasPrefix($0) }) { return false }
        // At the start of a sentence the capital may only be the sentence's ("Yesterday Stanley …"):
        // common opening words are not given names; anything else is ("Gary Lomax was sentenced …" is not
        // James Lomax — held-out chronology 2026-10-27).
        let isSentenceStart = before[..<m.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"(?:^|[.!?]["”’)]?)$"#, options: .regularExpression) != nil
        if isSentenceStart { return !Self.sentenceOpeners.contains(given) }
        return true
    }

    /// Words that open a sentence before a bare surname without being a given name.
    static let sentenceOpeners: Set<String> = [
        "yesterday", "today", "tomorrow", "then", "now", "later", "earlier", "afterward", "afterwards", "subsequently",
        "previously", "eventually", "ultimately", "finally", "additionally", "also", "however", "meanwhile", "thereafter",
        "according", "in", "on", "at", "during", "following", "after", "before", "when", "while", "since", "as", "if",
        "because", "although", "though", "both", "each", "either", "neither", "this", "that", "these", "those", "there",
        "here", "his", "her", "their", "its", "our", "defendant", "defendants", "prosecutors", "investigators", "officials",
        "authorities", "agents", "police", "federal", "judge", "district", "chief", "senior", "attorney", "assistant",
        "acting", "former", "special", "co-defendant", "codefendant", "victim", "witnesses", "evidence", "court", "records",
        "documents", "sentencing", "trial", "jurors", "jury", "under", "with", "without", "by", "from", "for", "of", "to",
        "last", "next", "first", "second", "third", "once", "upon", "unlike", "like", "specifically", "separately",
    ]

    static func mentionsFully(_ lower: String, tokens: [String]) -> Bool {
        guard let first = tokens.first, let last = tokens.last else { return false }
        // A middle initial's period ("Nathaniel E. Robinson") is part of the name.
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: first) + #"\b(?:[^.]|(?<=\b[a-z])\.){0,40}?\b"# + NSRegularExpression.escapedPattern(for: last) + #"\b"#
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    /// The date a document prints at its head: a line that is only a date ("Thursday, September 24,
    /// 2015"), a "Date:" line, or a release line ("FOR IMMEDIATE RELEASE … September 24, 2015").
    public static func printedDate(in text: String) -> DateComponents? {
        let head = String(text.prefix(600))
        for raw in head.components(separatedBy: .newlines).prefix(12) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count <= 60 else { continue }
            let bare = line.replacingOccurrences(of: #"(?i)^(?:date|dated|released?|for immediate release)\s*:?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)^(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday),?\s+"#, with: "", options: .regularExpression)
            if let d = fullDate(in: bare), bare.count <= 22 { return d }
        }
        if let r = head.range(of: #"(?i)for immediate release[^A-Za-z0-9]{0,6}(?:(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday),?\s+)?"#, options: .regularExpression) {
            return fullDate(in: String(head[r.upperBound...].prefix(30)))
        }
        return nil
    }

    static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]
    static let monthPattern = #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#

    /// "September 24, 2015" / "Sept. 24, 2015" (with year).
    static func fullDate(in text: String) -> DateComponents? {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\b"# + monthPattern + #"\b"#),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.range(at: 3).location != NSNotFound else { return nil }
        let ns = text as NSString
        guard let month = months[String(ns.substring(with: m.range(at: 1)).lowercased().prefix(3))],
              let day = Int(ns.substring(with: m.range(at: 2))), let year = Int(ns.substring(with: m.range(at: 3))),
              (1...31).contains(day) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// The day a sentence gives its step: "on March 3, 2015" (a year-less "on March 3" takes the
    /// printed date's year), or "today"/"yesterday" against the printed date.
    static func stepDay(_ sentence: String, printed: DateComponents?, stepEnd: Int? = nil) -> (DateComponents?, Bool) {
        let ns = sentence as NSString
        // A date after the step belongs to it unless another step's verb comes between them ("was
        // sentenced to 27 months … Parks pled guilty … on May 27, 2015" is the plea's day).
        let stepEndUTF16 = stepEnd.map { NSRange(sentence.startIndex..<sentence.index(sentence.startIndex, offsetBy: min($0, sentence.count)), in: sentence).length }
        func belongs(_ m: NSTextCheckingResult) -> Bool {
            guard let end = stepEndUTF16, m.range.location > end else { return true }
            let between = ns.substring(with: NSRange(location: end, length: m.range.location - end))
            return between.range(of: #"(?i)\b(?:pleaded|pled|pleading|indicted|charged|convicted|found guilty|arraigned|arrested|sentenced)\b"#, options: .regularExpression) == nil
        }
        // "was sentenced today …, on December 15, 2023, Smith …" (two sentences a text conversion ran
        // together): "today"/"yesterday" attached to the step wins over a date further along.
        let attached = sentence.range(of: #"(?i)\b(?:sentenced|pleaded|pled|convicted|charged|indicted|arrested|arraigned|found guilty)\s+(?:\w+\s+){0,2}?(?:today|yesterday)\b"#, options: .regularExpression)
        if let re = try? NSRegularExpression(pattern: #"(?i)\bon\s+(?:(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday),?\s+)?"# + monthPattern + #"\b"#),
           let m = re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).first(where: belongs),
           attached.map({ NSRange($0, in: sentence).location > m.range.location }) ?? true,
           let month = months[String(ns.substring(with: m.range(at: 1)).lowercased().prefix(3))],
           let day = Int(ns.substring(with: m.range(at: 2))) {
            let year = m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : printed?.year
            if let year { return (DateComponents(year: year, month: month, day: day), false) }
        }
        guard let printed, let date = Calendar(identifier: .gregorian).date(from: printed) else { return (nil, false) }
        if sentence.range(of: #"(?i)\btoday\b"#, options: .regularExpression) != nil { return (printed, true) }
        if sentence.range(of: #"(?i)\byesterday\b"#, options: .regularExpression) != nil,
           let y = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: date) {
            return (Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: y), true)
        }
        return (nil, false)
    }

    /// "to 48 months in federal prison, followed by three years of supervised release".
    static func sentenceDetail(_ sentence: String) -> String? {
        let pattern = #"(?i)\bsentenced\b.{0,200}?\bto\s+(?:serve\s+|spend\s+)?(?:an?\s+(?:total|term|period)\s+of\s+)?(?:an?\s+)?((?:\d+|[a-z]+(?:-[a-z]+)?)\s+(?:months?|years?|days?)\b[^.;]{0,120}|\d+-(?:month|year|day)\b[^.;]{0,120}|life\b[^.;]{0,80}|time served\b[^.;]{0,80}|probation\b[^.;]{0,80})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)),
              m.range(at: 1).location != NSNotFound else { return nil }
        let term = (sentence as NSString).substring(with: m.range(at: 1))
        // "… from her employer, announced United States Attorney …" — the term ends before the attribution.
        let cut = term.replacingOccurrences(of: #"(?i),?\s+(?:announced|said|stated|according to|the (?:justice )?department)\b.*$"#, with: "", options: .regularExpression)
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// Sentence split that keeps initials and "U.S." inside the sentence.
    static func sentences(of text: String) -> [String] {
        // A short line without closing punctuation is a heading ("District of Rhode Island",
        // "FOR IMMEDIATE RELEASE") and ends a sentence; a long one is a wrapped line of a paragraph
        // (PDF text breaks "Reginald Bennett, 41, of\nCedar Grove, … was sentenced") and runs on.
        var paragraphs: [String] = [], current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if !current.isEmpty { paragraphs.append(current); current = "" }; continue }
            // A dateline ("COLUMBUS, Ohio – …", "BECKLEY, W.Va. – …") opens a paragraph: HTML text has
            // one element per line with no blank line, and a lower-case headline above it would
            // otherwise run on into the lead.
            if !current.isEmpty, line.range(of: #"^[A-Z][A-Z.'\- ]{2,30}(?:,\s*[A-Z][A-Za-z.]+(?:\s[A-Z][A-Za-z.]+)?)?\s*[–—-]\s"#, options: .regularExpression) != nil {
                paragraphs.append(current); current = ""
            }
            let open = line.last.map { !".!?:;,”\")".contains($0) } == true
            // A headline is Title Case ("Hedge Fund Manager Sentenced for Operating …"); a wrapped
            // paragraph line is mostly lower-case words.
            let words = line.split(separator: " ")
            // Headline style lower-cases the small words ("Sentenced to 18 Months for Assault on a …").
            let small: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "for", "on", "in", "at", "by", "with", "from", "as", "into", "over"]
            let content = words.filter { !small.contains($0.lowercased()) }
            let capitalised = content.filter { $0.first?.isUppercase == true || $0.first?.isNumber == true }.count
            let endsMidPhrase = ["of", "to", "the", "and", "a", "an", "in", "for", "with", "that", "by", "on", "at", "from"].contains(words.last.map { $0.lowercased() } ?? "")
            let prose = line.range(of: #", \d{1,3},|\b(?:announced|said|was|were|today)\b"#, options: .regularExpression) != nil
            let heading = open && (line.count < 60 || (line.count < 180 && words.count >= 4 && !endsMidPhrase && !prose
                                                       && Double(capitalised) / Double(max(1, content.count)) >= 0.8))
            if heading {
                if !current.isEmpty { paragraphs.append(current); current = "" }
                paragraphs.append(line)
            } else {
                current += current.isEmpty ? line : " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.flatMap(sentencesOfLine)
    }

    static func sentencesOfLine(_ flat: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"(?<=[a-z0-9\)”"'][.!?])\s+(?=[A-Z“"])"#) else { return [flat] }
        let ns = flat as NSString
        var out: [String] = [], start = 0
        for m in re.matches(in: flat, range: NSRange(location: 0, length: ns.length)) {
            // "Mr. Smith", "U.S. Attorney", "St. Louis" do not end a sentence.
            let before = ns.substring(with: NSRange(location: max(0, m.range.location - 4), length: min(4, m.range.location)))
            if before.range(of: #"(?:\b[A-Z][a-z]?|Mr|Ms|Mrs|Dr|St|Jr|Sr|No|U\.S|Inc|Co)\.$"#, options: .regularExpression) != nil { continue }
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        out.append(ns.substring(from: start))
        return out.filter { $0.count >= 20 }
    }

    /// Steps as ledger events: one per step and day, dated only when the document gives the day.
    public static func extract(text: String, sourceObjectID: UUID, people: [(name: String, entityID: UUID)]) -> [Event] {
        // Cheap gate: most documents report no proceeding at all.
        guard text.range(of: #"(?i)\b(?:sentenced|pleaded|pled|indicted|charged|convicted|arrested|acquitted|pardon|arraigned)\b"#,
                         options: .regularExpression) != nil else { return [] }
        var out: [Event] = []
        var asked = Set<String>()
        for person in people.prefix(40) where nameTokens(person.name).count >= 2 && asked.insert(person.name.lowercased()).inserted {
            for f in findings(in: text, person: person.name) {
                guard let day = f.day, let date = Calendar(identifier: .gregorian).date(from: day) else { continue }
                out.append(Event(kind: .other, date: date, title: "\(person.name) \(f.step.phrase)",
                                 summary: String(f.sentence.prefix(300)), entityIDs: [person.entityID],
                                 sourceObjectID: sourceObjectID, confidence: .medium,
                                 dateConfidence: f.dayFromPrintedDate ? 0.6 : 0.7,
                                 attributes: ["proceedingStep": AnyCodable(.string(f.step.rawValue))],
                                 datePrecision: .day, status: .asserted))
            }
        }
        return Array(out.prefix(24))
    }
}
