//
//  CaseContradictionFinder.swift
//  Kalsmritikosh
//
//  P3 (real-case evaluation 2026-11-03: the case workflow found 0 of 4 real contradictions in every run
//  and said "No conflicting accounts found in scope."). One case's documents are compared with each
//  other, never with anything outside the case:
//    1. Rules (always, on the Mac): each sentence's statements are read per SUBJECT — a person or
//       organisation named in full (a bare surname counts only when one full name in the case carries
//       it) — and ATTRIBUTE: the amount paid to someone, a loss / restitution / forfeiture, someone's
//       age, a count of victims or of an indictment, the date of a proceeding step, who did an act
//       (spread the fuel, set the fire) and what recorded it (which camera). Two documents giving the
//       same subject different values are a pair. Explained differences are not: a sentence stating a
//       correction, a value given with "each / per / in total", two values for one subject in the same
//       document (two payments), ages that time between the documents explains, actors that overlap.
//    2. The person's AI reader (Online, document reading on), when the caller supplies one: the case's
//       passages per subject, cleared for the cloud by CloudSourceGate, are read for pairs of statements
//       that cannot both be true. Every pair is VERIFIED here: both quotes verbatim in the passages sent,
//       two different documents (or two different statements), the subject named in both passages, the
//       differing values present in their quotes and actually different, no stated correction, no
//       instruction to a model. Anything else is dropped. Descriptions are built from verified values
//       only — no unverified model wording is shown.
//  The result is a Contradiction with both sides verbatim (never averaged, never resolved). Pure: no
//  database, no network, no model names — the reader is a closure the caller injects.
//

import Foundation
import CryptoKit

public nonisolated enum CaseContradictionFinder {

    // MARK: - Inputs and outputs

    /// One in-scope document of the case.
    public struct Document: Sendable, Hashable {
        public let objectID: UUID
        public let sourceVersionID: UUID?
        public let text: String
        public let fileName: String?
        /// When the document was written, if known (ages are compared against the time between documents).
        public let date: Date?
        public init(objectID: UUID, sourceVersionID: UUID? = nil, text: String, fileName: String? = nil, date: Date? = nil) {
            self.objectID = objectID; self.sourceVersionID = sourceVersionID; self.text = text
            self.fileName = fileName; self.date = date
        }
    }

    public enum Kind: String, Sendable, CaseIterable, Codable {
        case amount, date, role, count, age, account
        /// A sentence's length (real-case v2, 2026-11-04: "13 months" and "a year and a day" for one
        /// sentence were never paired).
        case term

        public var label: String {
            switch self {
            case .amount: return "Amount"
            case .date: return "Date"
            case .role: return "Role"
            case .count: return "Count"
            case .age: return "Age"
            case .account: return "Account"
            case .term: return "Sentence"
            }
        }

        /// The ledger's kind vocabulary (the finder's word is kept in the description).
        public var stored: Contradiction.Kind {
            switch self {
            case .amount: return .amount
            case .date: return .date
            case .role, .account: return .testimony
            case .count, .term: return .other
            case .age: return .identity
            }
        }

        init?(loose: String?) {
            guard let s = loose?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
            if let k = Kind(rawValue: s) { self = k; return }
            switch s {
            case "payment", "money", "loss": self = .amount
            case "number", "quantity": self = .count
            case "actor", "who", "identity": self = .role
            case "location", "place", "testimony", "description", "event": self = .account
            case "sentence", "duration", "prison term", "length": self = .term
            default: return nil
            }
        }
    }

    public enum Provenance: String, Sendable, Codable {
        case rules, aiRead

        /// Kept at the end of the stored description: the case check's own rows (the archive-wide rescan
        /// keeps them) and how each was found.
        public var marker: String {
            switch self {
            case .rules: return "(case check · rules)"
            case .aiRead: return "(case check · AI reading, both quotes checked)"
            }
        }
    }

    /// Every stored description of the case check contains this.
    public static let markerStem = "(case check · "

    public struct Finding: Sendable, Equatable, Codable {
        public let kind: Kind
        public let subject: String
        public let attribute: String
        public let quoteA: String
        public let quoteB: String
        public let objectA: UUID
        public let objectB: UUID
        public let versionA: UUID?
        public let versionB: UUID?
        public let valueA: String
        public let valueB: String
        public let provenance: Provenance
        public var note: String? = nil

        public var description: String {
            var s = "\(kind.label) — \(subject)"
            if !attribute.isEmpty { s += ", \(attribute)" }
            s += ": \(valueA) vs \(valueB)."
            if let note { s += " \(note)" }
            return s + " " + provenance.marker
        }

        public var severity: Contradiction.Severity {
            switch kind {
            case .amount:
                let a = CaseContradictionFinder.number(valueA), b = CaseContradictionFinder.number(valueB)
                if let a, let b, max(a, b) > 0, abs(a - b) / max(a, b) > 0.25 { return .high }
                return .medium
            case .role, .account, .date, .count, .age, .term: return .medium
            }
        }

        /// The stored record: both sides verbatim, each with its document. The id is stable for the same
        /// pair, so running the check again adds nothing twice and keeps the case's decisions.
        public func contradiction(at date: Date = Date()) -> Contradiction {
            Contradiction(id: CaseContradictionFinder.stableID(kind: kind, a: (objectA, quoteA), b: (objectB, quoteB)),
                          kind: kind.stored, description: description, claimA: quoteA, claimB: quoteB,
                          evidenceA: objectA, evidenceB: objectB, severity: severity, detectedAt: date)
        }
    }

    /// The case check's provenance of a stored contradiction (nil: another detector found it).
    public static func provenance(of c: Contradiction) -> Provenance? {
        if c.description.contains(Provenance.aiRead.marker) { return .aiRead }
        if c.description.contains(Provenance.rules.marker) { return .rules }
        return nil
    }

    /// The case check's kind word of a stored contradiction ("Amount", "Role" …), or nil.
    public static func kindLabel(of c: Contradiction) -> String? {
        guard provenance(of: c) != nil else { return nil }
        return Kind.allCases.first { c.description.hasPrefix($0.label + " — ") }?.label
    }

    static func stableID(kind: Kind, a: (UUID, String), b: (UUID, String)) -> UUID {
        let sides = [a, b].map { "\($0.0.uuidString)|\(normalized($0.1))" }.sorted()
        let digest = SHA256.hash(data: Data("casecheck|\(kind.rawValue)|\(sides[0])|\(sides[1])".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func normalized(_ s: String) -> String { VerifiedAnswerComposer.normalized(s) }

    /// A document's date from the first of `candidates` that states a full date (its header date, then
    /// the opening of its text — a release's dateline). Nil when none does.
    public static func documentDate(_ candidates: [String]) -> Date? {
        for c in candidates {
            guard let d = VerifiedAnswerComposer.values(in: String(c.prefix(400))).dates.first(where: { $0.year != nil && $0.day != nil }),
                  let y = d.year, let day = d.day else { continue }
            var comps = DateComponents(); comps.year = y; comps.month = d.month; comps.day = day; comps.hour = 12
            if let date = Calendar(identifier: .gregorian).date(from: comps) { return date }
        }
        return nil
    }

    // MARK: - Names (subjects)

    /// The case's full names, unified: "Jamey Thompson" and "William Jamey Thompson" are one subject;
    /// "Brock Taylor" and "Jonathan Taylor" are two, and a bare "Taylor" then names neither.
    struct Names {
        var canonicals: [String] = []
        var tokens: [[String]] = []
        private var byFull: [String: Int] = [:]
        /// The documents each subject is named in full in.
        var fullInDoc: [Int: Set<Int>] = [:]

        static let generic: Set<String> = ["company", "corporation", "inc", "llc", "ltd", "co", "county", "court", "department",
                                           "office", "states", "state", "attorney", "bank", "group", "services", "agency", "bureau",
                                           "district", "city", "university", "the", "this", "that", "these", "those", "united",
                                           "federal", "national", "according", "police", "judge", "special", "agent", "assistant"]

        init(documents: [Document]) {
            var perDoc: [[String]] = []
            var all: [String] = []
            // Real-case v2 (2026-11-04): "Attorneys Jason S. Gould", "Charge James E. Dennehy" (from "Special
            // Agent in Charge James E. Dennehy") — a title read into the name; the person is the name after it.
            var raw: [String: String] = [:]   // as written → without its leading title
            for d in documents {
                let names = ProceedingEventExtractor.rawSentences(of: d.text).flatMap { Self.fullNames(in: $0).map(\.name) }
                perDoc.append(names)
                for n in names where raw[n.lowercased()] == nil {
                    let bare = Self.strippingTitles(n)
                    raw[n.lowercased()] = bare
                    all.append(bare)
                }
            }
            var unique: [String] = []
            var seen = Set<String>()
            for n in all where seen.insert(n.lowercased()).inserted { unique.append(n) }
            unique.sort { ProceedingEventExtractor.nameTokens($0).count > ProceedingEventExtractor.nameTokens($1).count }
            for n in unique {
                let t = ProceedingEventExtractor.nameTokens(n)
                guard t.count >= 2 else { continue }
                // "Michael D. Williams" and "Michael Williams", "Guy R. Miller, Jr." and "Guy Miller": one subject.
                let supersets = tokens.indices.filter { tokens[$0].last == t.last && Set(t).isSubset(of: Set(tokens[$0])) }
                if supersets.count == 1 { byFull[n.lowercased()] = supersets[0]; continue }
                if supersets.count > 1 { continue }   // ambiguous: names two subjects
                canonicals.append(n); tokens.append(t); byFull[n.lowercased()] = canonicals.count - 1
            }
            for (written, bare) in raw where byFull[written] == nil {
                if let c = byFull[bare.lowercased()] { byFull[written] = c }
            }
            for (i, names) in perDoc.enumerated() {
                for n in names { if let c = byFull[n.lowercased()] { fullInDoc[c, default: []].insert(i) } }
            }
        }

        /// Leading title words a capitalised run carries before the person's own name.
        static let leadingTitles: Set<String> = [
            "attorney", "attorneys", "charge", "judge", "judges", "justice", "magistrate", "agent", "agents", "special", "director",
            "inspector", "inspectors", "general", "chief", "sheriff", "deputy", "officer", "detective", "sergeant", "lieutenant",
            "captain", "commissioner", "prosecutor", "prosecutors", "counsel", "senator", "governor", "mayor", "president",
            "secretary", "trooper", "investigator", "acting", "assistant", "senior", "trial", "litigation", "district", "court",
            "defendant", "defendants", "co-defendant", "codefendant", "victim", "witness", "former", "principal", "associate",
            "superintendent", "postal", "chairman", "chairwoman", "ceo", "dr", "mr", "mrs", "ms",
        ]

        /// The name without the title words before it ("Attorneys Jason S. Gould" → "Jason S. Gould"); the
        /// name itself when fewer than two words would remain.
        static func strippingTitles(_ name: String) -> String {
            var words = name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            var dropped = false
            while words.count > 2, let f = words.first,
                  leadingTitles.contains(f.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))) {
                words.removeFirst(); dropped = true
            }
            return dropped ? words.joined(separator: " ") : name
        }

        func canonical(full name: String) -> Int? { byFull[name.lowercased()] }

        /// A bare surname: the one subject of this document with it, else the one subject of the case.
        func canonical(surname word: String, doc: Int?) -> Int? {
            let w = word.lowercased()
            guard !Self.generic.contains(w) else { return nil }
            let all = tokens.indices.filter { tokens[$0].last == w }
            if let doc {
                let here = all.filter { fullInDoc[$0]?.contains(doc) == true }
                if here.count == 1 { return here[0] }
                if here.count > 1 { return nil }
            }
            return all.count == 1 ? all[0] : nil
        }

        static let fullPattern = #"(?:(?:Mc|Mac|De|O')?[A-Z][a-z'’\-]+|[A-Z]\.)(?:\s+(?:(?:Mc|Mac|De|O')?[A-Z][a-z'’\-]+|[A-Z]\.)){1,5}"#
        static let fullRegex = try? NSRegularExpression(pattern: fullPattern)
        static let singleRegex = try? NSRegularExpression(pattern: #"(?<![\p{L}.])((?:Mc|Mac|De|O')?[A-Z][a-z\-]{2,})(?:['’]s)?(?![\p{L}])"#)

        /// Full names in a sentence with where they stand.
        static func fullNames(in sentence: String) -> [(name: String, range: NSRange)] {
            guard let re = fullRegex else { return [] }
            let ns = sentence as NSString
            return re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).compactMap { m in
                var range = m.range
                // Ease fixes A — "paid Ravi Kumar Rs 2.5 lakh": the rupee sign "Rs" after a name is not part of it.
                if ns.substring(with: range).hasSuffix(" Rs") { range.length -= 3 }
                let found = VerifiedAnswerComposer.names(in: ns.substring(with: range))
                return found.count == 1 ? (found[0], range) : nil
            }
        }

        struct Mention { let range: NSRange; let canonical: Int?; let surname: String }

        /// Every subject a sentence names: in full, or by a surname the case resolves. An unresolved
        /// capitalised word is kept with no subject (an actor's surname still counts for "who").
        func mentions(in sentence: String, doc: Int?) -> [Mention] {
            let ns = sentence as NSString
            var out: [Mention] = []
            for f in Self.fullNames(in: sentence) {
                let c = canonical(full: f.name)
                out.append(Mention(range: f.range, canonical: c, surname: ProceedingEventExtractor.nameTokens(f.name).last ?? ""))
            }
            if let re = Self.singleRegex {
                for m in re.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
                    let r = m.range(at: 1)
                    guard !out.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { continue }
                    let word = ns.substring(with: r)
                    if let c = canonical(surname: word, doc: doc) {
                        out.append(Mention(range: r, canonical: c, surname: word.lowercased()))
                    } else if !Self.generic.contains(word.lowercased()), !Self.commonCapitalised.contains(word.lowercased()),
                              r.location > 0 || ns.substring(from: r.location + r.length).range(of: #"^(?:['’]s)?(?:,|\s+and\b)"#, options: .regularExpression) != nil {
                        // A sentence's first word is a name only when a list follows ("Miller, Simon, and …").
                        out.append(Mention(range: r, canonical: nil, surname: word.lowercased()))
                    }
                }
            }
            return out.sorted { $0.range.location < $1.range.location }
        }

        static let commonCapitalised: Set<String> = ["the", "a", "an", "he", "she", "they", "it", "his", "her", "their", "on", "in", "at",
                                                     "january", "february", "march", "april", "may", "june", "july", "august", "september",
                                                     "october", "november", "december", "monday", "tuesday", "wednesday", "thursday",
                                                     "friday", "saturday", "sunday", "mr", "mrs", "ms", "dr", "according", "after", "before",
                                                     "during", "when", "while", "both", "each", "all", "and", "but", "or", "if", "as"]
    }

    // MARK: - Statements

    struct Statement {
        let doc: Int
        let sentence: String
        let kind: Kind
        let attribute: String
        let subjectKey: String
        let subject: String
        let value: String
        var number: Double? = nil
        /// How the figure is stated: exactly, approximately, as a lower bound ("more than") or an upper one.
        var bound: Bound = .exact
        var actors: Set<String> = []
        var day: VerifiedAnswerComposer.Day? = nil
        var tokens: Set<String> = []
        /// What the statement is about beyond its subject (the thing a camera caught).
        var about: Set<String> = []
        /// A sentence length, in months and days.
        var term: Duration? = nil
        /// Ease fixes A — the currency of an amount (ISO code, or "$" for a dollar whose country is not stated). Amounts are
        /// compared only with amounts of the same currency.
        var currency: String = ""
    }

    static let correctionPattern = #"(?i)\b(?:correct(?:ed|ion|ing|s)?|previously (?:reported|stated|announced|said|described)|earlier (?:release|report|announcement|statement|reported|stated|account)|contrary to|in fact|actually|clarif(?:y|ies|ied|ication)|was incorrect|were incorrect|erroneous(?:ly)?|mistaken(?:ly)?|misstated|amended)\b"#

    /// A sentence that states it corrects or clarifies an earlier account: an explained difference.
    static func statesCorrection(_ s: String) -> Bool { s.range(of: correctionPattern, options: .regularExpression) != nil }

    static func matches(_ pattern: String, in s: String) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    static let moneyPattern = #"\$\s?(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)(?:\s*(?:million|billion|thousand|mn|bn|m|k)\b)?"#
    static let approxPattern = #"(?i)(?:approximately|about|nearly|roughly|around|more than|over|at least|almost|in excess of|some|close to|less than|under)\s*$"#

    static func money(_ s: String) -> Double? { VerifiedAnswerComposer.values(in: s).money.min() }

    static func number(_ s: String) -> Double? {
        let v = VerifiedAnswerComposer.values(in: s)
        return v.money.min() ?? v.numbers.min()
    }

    static func display(_ amount: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 2
        return "$" + (f.string(from: NSNumber(value: amount)) ?? String(amount))
    }

    /// An amount with its currency: "$1,000" (a dollar whose country is not stated) or "INR 50,000.00" (the currency's
    /// own precision, exact digits — FAMoney).
    static func display(_ amount: Decimal, currency: String) -> String {
        if currency == FAMoney.ambiguousDollar { return display(NSDecimalNumber(decimal: amount).doubleValue) }
        return "\(currency) \(FAMoney.format(amount, currency: currency))"
    }

    // MARK: - Amounts in any currency (ease fixes A)

    /// One amount read from a sentence, with where it stands.
    struct Amount {
        let range: NSRange
        let value: Decimal
        /// ISO code, or "$" for a dollar whose country is not stated.
        let currency: String
        var number: Double { NSDecimalNumber(decimal: value).doubleValue }
    }

    static let currencyCodes = FAMoney.isoCodes
    static let prefixCurrency = #"(?:US\$|CA\$|C\$|A\$|AU\$|NZ\$|HK\$|S\$|SG\$|R\$|MX\$|\$|₹|€|£|\bRs\.?|\b(?:"# + currencyCodes + #")\b)"#
    static let amountNumber = #"(\d{1,3}(?:[,.]\d{2,3})+(?:[.,]\d{1,3})?|\d+(?:[.,]\d+)?)"#
    static let amountScale = #"(?:\s*(thousand|lakhs?|lacs?|crores?|million|billion|mn|bn|m|k)\b)?"#
    static let suffixCurrency = #"(rupees?|euros?|pounds sterling|us dollars?|(?:"# + currencyCodes + #")\b)"#
    static let prefixedAmount = try? NSRegularExpression(pattern: prefixCurrency + #"\s?"# + amountNumber + amountScale, options: [.caseInsensitive])
    static let suffixedAmount = try? NSRegularExpression(pattern: #"(?<![\d.,])"# + amountNumber + amountScale + #"\s*"# + suffixCurrency, options: [.caseInsensitive])
    static let bareAmount = try? NSRegularExpression(pattern: #"(?<![\d.,\w])"# + amountNumber + amountScale + #"(?![\d\w])"#, options: [.caseInsensitive])

    /// The currency a word after a figure names ("rupees" → INR, "euros" → EUR, an ISO code itself).
    static func currencyWord(_ word: String) -> String {
        let w = word.lowercased()
        if w.hasPrefix("rupee") { return "INR" }
        if w.hasPrefix("euro") { return "EUR" }
        if w.hasPrefix("pounds") { return "GBP" }
        if w.hasPrefix("us dollar") { return "USD" }
        return word.uppercased()
    }

    /// The written scale as FAMoney reads it ("mn" → million, "k" → thousand).
    static func scaleWord(_ s: String) -> String {
        switch s.lowercased() {
        case "m", "mn": return "million"
        case "bn": return "billion"
        case "k": return "thousand"
        default: return s.lowercased()
        }
    }

    /// Every amount a sentence states, read by the shared money reader (FAMoney): a figure with a currency before it
    /// ("₹2.5 lakh", "INR 50,000", "€1,200", "$3 million"), a figure with a currency word after it ("50,000 rupees"), and —
    /// when the sentence names exactly one currency, other than a bare "$" — a grouped or scaled figure with no mark of
    /// its own. A figure FAMoney cannot read without guessing ("1,085" with no currency to decide it) is not an amount, and
    /// a "¥" (yen or yuan) is never read.
    static func amounts(in s: String) -> [Amount] {
        let ns = s as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var out: [Amount] = []
        func taken(_ r: NSRange) -> Bool { out.contains { NSIntersectionRange($0.range, r).length > 0 } }
        func reading(cur: String, number: String, scale: String, stated: String?) -> FAMoney.Reading? {
            let scaled = scale.isEmpty ? "" : " " + scaleWord(scale)
            return FAMoney.read(cur + number + scaled, currency: stated)
        }
        for m in prefixedAmount?.matches(in: s, range: whole) ?? [] {
            let token = ns.substring(with: m.range)
            let number = ns.substring(with: m.range(at: 1))
            let scale = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            let cur = String(token[..<(token.range(of: number)?.lowerBound ?? token.endIndex)])
            guard let r = reading(cur: cur, number: number, scale: scale, stated: nil) else { continue }
            var currency = r.currency
            if currency.isEmpty, cur.contains("$") { currency = FAMoney.ambiguousDollar }
            guard !currency.isEmpty else { continue }
            out.append(Amount(range: m.range, value: r.value, currency: currency))
        }
        for m in suffixedAmount?.matches(in: s, range: whole) ?? [] where !taken(m.range) {
            let number = ns.substring(with: m.range(at: 1))
            let scale = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            let currency = currencyWord(ns.substring(with: m.range(at: 3)))
            guard let r = reading(cur: "", number: number, scale: scale, stated: currency) else { continue }
            out.append(Amount(range: m.range, value: r.value, currency: currency))
        }
        // A bare figure takes the sentence's one named currency ("amounts in INR: … 1,00,000 …").
        var named = Set(out.map(\.currency))
        let words = FAMoney.currencyInWords(s)
        if !words.isEmpty { named.insert(words) }
        if named.count == 1, let only = named.first, only != FAMoney.ambiguousDollar {
            for m in bareAmount?.matches(in: s, range: whole) ?? [] where !taken(m.range) {
                let number = ns.substring(with: m.range(at: 1))
                let scale = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
                // Only a grouped figure or a stated scale: a year, a day or a count is not money.
                guard number.contains(",") || !scale.isEmpty else { continue }
                guard let r = reading(cur: "", number: number, scale: scale, stated: only) else { continue }
                out.append(Amount(range: m.range, value: r.value, currency: only))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    static func statements(_ documents: [Document], names: Names) -> [Statement] {
        var out: [Statement] = []
        for (i, d) in documents.enumerated() {
            for sentence in ProceedingEventExtractor.rawSentences(of: d.text) where !statesCorrection(sentence) {
                let mentions = names.mentions(in: sentence, doc: i)
                out += payments(sentence, doc: i, mentions: mentions, names: names)
                out += ages(sentence, doc: i, mentions: mentions, names: names)
                out += losses(sentence, doc: i, mentions: mentions, names: names)
                out += counts(sentence, doc: i, mentions: mentions, names: names)
                out += stepDates(sentence, doc: i, mentions: mentions, names: names)
                out += roles(sentence, doc: i, mentions: mentions)
                out += recordings(sentence, doc: i)
                out += terms(sentence, doc: i, mentions: mentions, names: names, text: d.text)
            }
        }
        return out
    }

    static let separatePayment = #"(?i)\b(?:each|per|monthly|a month|weekly|a week|installments?|additional|another|totall?ing|in total|combined|altogether|in all|portion|part of)\b"#

    static func payments(_ s: String, doc: Int, mentions: [Names.Mention], names: Names) -> [Statement] {
        let monies = amounts(in: s)
        guard !monies.isEmpty, s.range(of: separatePayment, options: .regularExpression) == nil else { return [] }
        let ns = s as NSString
        var out: [Statement] = []
        for v in matches(#"(?i)\b(was paid|were paid|been paid|paid|pays|paying|gave|wired|transferred|received|receives|receiving|accepted|collected)\b"#, in: s) {
            let verb = ns.substring(with: v.range).lowercased()
            let verbEnd = v.range.location + v.range.length
            guard let m = monies.first(where: { $0.range.location >= verbEnd && $0.range.location - verbEnd <= 160 }) else { continue }
            let after = ns.substring(from: m.range.location + m.range.length)
            if after.range(of: #"(?i)^\s*(?:in\s+)?(?:restitution|fines?|forfeiture|penalt(?:y|ies)|bail|bond|losses)"#, options: .regularExpression) != nil { continue }
            let receiving = verb.hasPrefix("was") || verb.hasPrefix("were") || verb.hasPrefix("been")
                || ["received", "receives", "receiving", "accepted", "collected"].contains(verb)
            var payee: Names.Mention?
            if receiving {
                payee = mentions.last { $0.range.location < v.range.location }
            } else {
                payee = mentions.first { $0.range.location >= verbEnd && $0.range.location < m.range.location }
                if payee == nil, after.range(of: #"^\s*to\s+"#, options: .regularExpression) != nil {
                    let start = m.range.location + m.range.length
                    payee = mentions.first { $0.range.location >= start && $0.range.location - start <= 30 }
                }
            }
            guard let p = payee, let c = p.canonical else { continue }
            let before = ns.substring(to: m.range.location)
            out.append(Statement(doc: doc, sentence: s, kind: .amount, attribute: "amount paid to them", subjectKey: "p\(c)",
                                 subject: names.canonicals[c], value: display(m.value, currency: m.currency), number: m.number,
                                 bound: bound(before: before), currency: m.currency))
        }
        return out
    }

    static func ages(_ s: String, doc: Int, mentions: [Names.Mention], names: Names) -> [Statement] {
        let ns = s as NSString
        var out: [Statement] = []
        for m in mentions {
            guard let c = m.canonical else { continue }
            let end = m.range.location + m.range.length
            let after = ns.substring(from: end)
            var age: Int?
            if let r = after.range(of: #"^,\s*(?:age\s+|aged\s+)?(\d{1,2})\s*(?:,|\)|$|\s+(?:of|from)\b)"#, options: .regularExpression) {
                age = Int(after[r].filter(\.isNumber))
            } else if let r = after.range(of: #"^\s*\((?:age\s+)?(\d{1,2})\)"#, options: .regularExpression) {
                age = Int(after[r].filter(\.isNumber))
            } else {
                let before = ns.substring(to: m.range.location)
                if let r = before.range(of: #"(\d{1,2})-year-old\s+(?:[a-z]+\s+){0,2}$"#, options: .regularExpression) {
                    age = Int(before[r].prefix { $0.isNumber })
                }
            }
            guard let age, (14...99).contains(age) else { continue }
            out.append(Statement(doc: doc, sentence: s, kind: .age, attribute: "age", subjectKey: "p\(c)",
                                 subject: names.canonicals[c], value: String(age), number: Double(age)))
        }
        return out
    }

    static func losses(_ s: String, doc: Int, mentions: [Names.Mention], names: Names) -> [Statement] {
        let monies = amounts(in: s)
        guard !monies.isEmpty, s.range(of: #"(?i)\b(?:faces|facing|up to|maximum|could|may|would|statutory)\b"#, options: .regularExpression) == nil,
              s.range(of: separatePayment, options: .regularExpression) == nil,
              let subject = mentions.first(where: { $0.canonical != nil }), let c = subject.canonical else { return [] }
        let ns = s as NSString
        var out: [Statement] = []
        var seen = Set<String>()
        for w in matches(#"(?i)\b(loss(?:es)?|restitution|forfeit(?:ure)?|defrauded|stole|embezzled)\b"#, in: s) {
            let word = ns.substring(with: w.range).lowercased()
            let attribute = word.hasPrefix("restitution") ? "restitution" : word.hasPrefix("forfeit") ? "forfeiture" : "loss"
            guard seen.insert(attribute).inserted else { continue }
            let wEnd = w.range.location + w.range.length
            let near = monies.filter { abs($0.range.location - wEnd) <= 80 || abs(w.range.location - ($0.range.location + $0.range.length)) <= 30 }
            guard near.count == 1, let m = near.first else { continue }
            out.append(Statement(doc: doc, sentence: s, kind: .amount, attribute: attribute, subjectKey: "p\(c)",
                                 subject: names.canonicals[c], value: display(m.value, currency: m.currency), number: m.number,
                                 bound: bound(before: ns.substring(to: m.range.location)), currency: m.currency))
        }
        return out
    }

    static let numberWordPattern = #"\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty"#

    static func counts(_ s: String, doc: Int, mentions: [Names.Mention], names: Names) -> [Statement] {
        guard let subject = mentions.first(where: { $0.canonical != nil }), let c = subject.canonical,
              s.range(of: #"(?i)\b(?:superseding|additional|another|more than|at least|over|including|among)\b"#, options: .regularExpression) == nil else { return [] }
        let ns = s as NSString
        var out: [Statement] = []
        for m in matches(#"(?i)\b("# + numberWordPattern + #")(?:-|\s+)(?:individual\s+|separate\s+|known\s+)?(victims|counts?)\b"#, in: s) {
            let noun = ns.substring(with: m.range(at: 2)).lowercased()
            let raw = ns.substring(with: m.range(at: 1))
            guard let n = Int(raw) ?? VerifiedAnswerComposer.numberWords[raw.lowercased()].map(Int.init) else { continue }
            let attribute: String
            if noun.hasPrefix("count") {
                // The counts of the charge, not of a plea or a verdict.
                guard s.range(of: #"(?i)\b(?:indict|charg)"#, options: .regularExpression) != nil,
                      s.range(of: #"(?i)\b(?:pleaded|pled|plea|guilty|convicted|dismiss|acquitted)"#, options: .regularExpression) == nil else { continue }
                attribute = "counts charged"
            } else {
                attribute = "victims"
            }
            out.append(Statement(doc: doc, sentence: s, kind: .count, attribute: attribute, subjectKey: "p\(c)",
                                 subject: names.canonicals[c], value: String(n), number: Double(n)))
        }
        return out
    }

    /// Between a step verb and its "on <date>": another step's verb, or a schedule ("will", "scheduled",
    /// "set for", "hearing") — the date is not this step's.
    static let stepDateHandOff = #"(?i)\b(?:pleaded|pled|pleading|pleads|indicted|charged|convicted|found guilty|arraigned|arrested|sentenced|sentencing|hearing|trial|will|shall|scheduled|set|expected|due|is to|are to|awaiting|pending)\b"#

    static func stepDates(_ s: String, doc: Int, mentions: [Names.Mention], names: Names) -> [Statement] {
        guard s.range(of: #"(?i)\bsuperseding\b"#, options: .regularExpression) == nil else { return [] }
        let ns = s as NSString
        var out: [Statement] = []
        for v in matches(#"(?i)\b(sentenced|indicted|arrested|convicted|charged|pleaded guilty|pled guilty|found guilty)\b"#, in: s) {
            let step = ns.substring(with: v.range).lowercased().replacingOccurrences(of: "pled", with: "pleaded")
            let end = v.range.location + v.range.length
            let tail = ns.substring(with: NSRange(location: end, length: min(90, ns.length - end)))
            guard let on = tail.range(of: #"(?i)^[^.;]{0,50}?\bon\s+"#, options: .regularExpression) else { continue }
            // A date belongs to the verb that governs it: "have pleaded guilty and will be sentenced on Feb. 25,
            // 2014" dates the (scheduled) sentencing, not the plea (smoke 2026-11-03) — another step verb or a
            // scheduling word between this verb and "on" hands the date to that clause.
            if String(tail[..<on.upperBound]).range(of: stepDateHandOff, options: .regularExpression) != nil { continue }
            // A scheduled or conditional step ("will be sentenced on", "is scheduled to be sentenced on",
            // "is set to be sentenced on") has no date of its own yet: the date is the schedule's.
            let lead = ns.substring(with: NSRange(location: max(0, v.range.location - 40), length: v.range.location - max(0, v.range.location - 40)))
            if (lead + ns.substring(with: v.range)).range(of: ProceedingEventExtractor.notYet, options: .regularExpression) != nil { continue }
            let days = VerifiedAnswerComposer.values(in: String(tail[on.upperBound...]).components(separatedBy: CharacterSet(charactersIn: ";")).first ?? "").dates
            guard let day = days.first, day.year != nil, day.day != nil,
                  VerifiedAnswerComposer.values(in: s).dates.filter({ $0.year != nil && $0.day != nil }).count == 1,
                  let subject = mentions.last(where: { $0.range.location < v.range.location }), let c = subject.canonical else { continue }
            out.append(Statement(doc: doc, sentence: s, kind: .date, attribute: "date \(step)", subjectKey: "p\(c)",
                                 subject: names.canonicals[c], value: render(day), day: day))
        }
        return out
    }

    static func render(_ d: VerifiedAnswerComposer.Day) -> String {
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        var s = months[max(0, min(11, d.month - 1))]
        if let day = d.day { s += " \(day)" }
        if let y = d.year { s += ", \(y)" }
        return s
    }

    /// Acts whose doer an account names: key, readable "who …", pattern.
    static let acts: [(key: String, who: String, pattern: String)] = [
        ("spread-fuel", "who spread the fuel", #"(?i)\bspread(?:ing|s)?\b(?:\s+[\w’'-]+){0,4}?\s+(?:gasoline|gas|fuel|accelerants?|diesel|kerosene|lighter fluid)\b"#),
        ("set-fire", "who set the fire", #"(?i)\b(?:set|sets|setting|ignit(?:e|ed|es|ing)|lit|light|started|start)\s+(?:the\s+|a\s+)?fire\b"#),
    ]
    static let recruitVerbs = #"(?i)\b(?:recruited|hired|paid|asked|directed|instructed|enlisted|convinced|persuaded|had|got|told|ordered|arranged for)\s*$"#

    static func roles(_ s: String, doc: Int, mentions: [Names.Mention]) -> [Statement] {
        let ns = s as NSString
        var out: [Statement] = []
        for act in acts {
            guard let a = matches(act.pattern, in: s).first else { continue }
            // "X recruited Y to spread …": Y did it.
            var actors: [Names.Mention] = []
            for m in mentions where m.range.location < a.range.location {
                let before = ns.substring(to: m.range.location)
                let between = ns.substring(with: NSRange(location: m.range.location + m.range.length, length: a.range.location - m.range.location - m.range.length))
                if before.range(of: recruitVerbs, options: .regularExpression) != nil, between.range(of: #"\bto\b"#, options: .regularExpression) != nil {
                    actors = [m]; break
                }
            }
            if actors.isEmpty {
                actors = mentions.filter { m in
                    guard m.range.location < a.range.location else { return false }
                    // "Shawn C. Simon, 41, of Charleston" — a town, not an actor.
                    if ns.substring(to: m.range.location).range(of: #"(?i)\b(?:of|in|from|near)\s+$"#, options: .regularExpression) != nil { return false }
                    let after = ns.substring(from: m.range.location + m.range.length)
                    return after.range(of: #"^\s*(?:,\s*)?(?:recruited|hired|paid|asked|directed|instructed|enlisted|convinced|persuaded|had|got|told|ordered)\b"#, options: [.regularExpression, .caseInsensitive]) == nil
                }
            }
            let surnames = Set(actors.map(\.surname).filter { !$0.isEmpty })
            guard !surnames.isEmpty else { continue }
            let shown = actors.map { ns.substring(with: $0.range) }
            var seen = Set<String>()
            let display = shown.filter { seen.insert($0).inserted }.joined(separator: ", ")
            out.append(Statement(doc: doc, sentence: s, kind: .role, attribute: "", subjectKey: "act:\(act.key)", subject: act.who,
                                 value: display, actors: surnames,
                                 tokens: ContradictionDetector.contentWords(s).subtracting(surnames)))
        }
        return out
    }

    static let recordingGeneric: Set<String> = ["the", "a", "an", "its", "his", "her", "their", "security", "camera", "cameras", "video",
                                                "videos", "surveillance", "system", "systems", "recorder", "recorders", "digital",
                                                "footage", "tape", "cctv", "own", "store", "s", "of"]

    static func recordings(_ s: String, doc: Int) -> [Statement] {
        let ns = s as NSString
        guard let m = matches(#"(?i)\b(?:caught|captured|recorded|filmed|seen)\s+(?:on|by)\s+([^.;:!?,]{3,90}?)(?=[.;:!?,]|\s+(?:and|in order|which|that|while|when|as|but)\b|$)"#, in: s).first else { return [] }
        let phrase = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard phrase.range(of: #"(?i)\b(?:camera|video|surveillance|cctv|recorder|footage)"#, options: .regularExpression) != nil else { return [] }
        let tokens = Set(phrase.lowercased().replacingOccurrences(of: "’s", with: "").replacingOccurrences(of: "'s", with: "")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(recordingGeneric)
        guard !tokens.isEmpty else { return [] }
        // What was caught: "The three culprits were caught on 317's camera" and "The explosion was caught on
        // the courthouse video" record two things, both true (real-case v2, 2026-11-04).
        let clause = ns.substring(to: m.range.location).components(separatedBy: CharacterSet(charactersIn: ",;")).last ?? ""
        let about = ContradictionDetector.contentWords(clause).subtracting(recordingGeneric).subtracting(["was", "were", "been", "being", "is", "are"])
        return [Statement(doc: doc, sentence: s, kind: .account, attribute: "", subjectKey: "recorded", subject: "what recorded it",
                          value: phrase, tokens: tokens, about: about)]
    }

    // MARK: - Sentence lengths

    /// A sentence's length: months and days ("a year and a day" = 12 months 1 day; "13 months" = 13 months).
    struct Duration: Hashable, CustomStringConvertible {
        let months: Int
        let days: Int
        var description: String {
            var parts: [String] = []
            if months > 0 { parts.append(months == 1 ? "1 month" : "\(months) months") }
            if days > 0 { parts.append(days == 1 ? "1 day" : "\(days) days") }
            return parts.isEmpty ? "0 days" : parts.joined(separator: " and ")
        }
    }

    static let durationUnit = #"(?:\d{1,3}|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty(?:-(?:one|two|three|four|five|six|seven|eight|nine))?|thirty|forty|fifty|sixty)[\s-]+(?:years?|months?|weeks?|days?)\b"#

    /// The length a phrase states at its start ("13 months in prison", "a year and a day", "seven years and
    /// three months", "46-month"), or nil.
    static func duration(_ phrase: String) -> Duration? {
        let p = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = "^(?:to\\s+)?(?:serve\\s+|spend\\s+)?(?:an?\\s+(?:total|term|period)\\s+of\\s+)?(" + durationUnit + "(?:(?:,\\s*|\\s+)(?:and\\s+)?" + durationUnit + "){0,2})"
        guard let r = p.range(of: pattern, options: .regularExpression) else { return nil }
        var months = 0, days = 0
        for m in matches(durationUnit, in: String(p[r])) {
            let part = (String(p[r]) as NSString).substring(with: m.range)
            let words = part.split { $0 == " " || $0 == "-" }.map(String.init)
            guard let head = words.first, let unit = words.last else { continue }
            let article: [String: Int] = ["a": 1, "an": 1, "one": 1]
            let compound: Int? = VerifiedAnswerComposer.numberWords[words.dropLast().joined(separator: "-")].map(Int.init)
            let single: Int? = VerifiedAnswerComposer.numberWords[head].map(Int.init)
            let n: Int = Int(head) ?? article[head] ?? compound ?? single ?? 0
            if unit.hasPrefix("year") { months += 12 * n }
            else if unit.hasPrefix("month") { months += n }
            else if unit.hasPrefix("week") { days += 7 * n }
            else { days += n }
        }
        return months + days > 0 ? Duration(months: months, days: days) : nil
    }

    /// Words that make a sentence's term not this case's prison term: a maximum the law allows, a
    /// resentencing, supervised release or probation alone.
    static let notATerm = #"(?i)\b(?:faces?|facing|up to|maximum|minimum|could|would|may(?!\s+\d)|resentenc\w*|reduced|commut\w*|vacat\w*|appeal\w*|if convicted|will be|scheduled|set to)\b"#

    /// "Vernell Burris, Jr., … was sentenced today to serve 13 months in prison": the person the clause's
    /// own sentencing is about, with its term — the term never moves to another person of the sentence
    /// ("Simon … was sentenced to 22 months" is not Miller's or Williams's term).
    static func terms(_ s: String, doc: Int, mentions: [Names.Mention], names: Names, text: String) -> [Statement] {
        guard s.range(of: #"(?i)\bsentenced\b"#, options: .regularExpression) != nil else { return [] }
        var out: [Statement] = []
        var offset = 0
        let ns = s as NSString
        for clause in ProceedingAnswerer.clauses(of: s) {
            let start = ns.range(of: clause, options: [], range: NSRange(location: offset, length: ns.length - offset)).location
            guard start != NSNotFound else { continue }
            offset = start + (clause as NSString).length
            let cs = clause as NSString
            guard let verb = matches(#"(?i)\bsentenced\b"#, in: clause).first,
                  clause.range(of: notATerm, options: .regularExpression) == nil,
                  let detail = ProceedingEventExtractor.sentenceDetail(clause),
                  detail.range(of: #"(?i)^[^,;]{0,40}\b(?:probation|supervised release|home (?:detention|confinement))\b"#, options: .regularExpression) == nil
                    || detail.range(of: #"(?i)\b(?:prison|imprisonment|incarceration|jail|custody)\b"#, options: .regularExpression) != nil,
                  let term = duration(detail) else { continue }
            // The clause's subject: its introduced person, else the people before the verb ("A and B were
            // sentenced to …" both), else the person right after it ("Judge X sentenced Y to …").
            let local = mentions.filter { $0.canonical != nil && $0.range.location >= start && $0.range.location < start + cs.length }
                .map { (m: $0, at: $0.range.location - start) }
            var subjects: [Int] = []
            if let intro = ProceedingAnswerer.introducedSubject(clause), let c = names.canonical(full: intro) ?? names.canonical(full: CaseContradictionFinder.Names.strippingTitles(intro)) {
                subjects = [c]
            } else {
                let before = local.filter { $0.at < verb.range.location }
                let plural = cs.substring(to: verb.range.location).range(of: #"(?i)\bwere\s+(?:\w+\s+){0,2}$"#, options: .regularExpression) != nil
                if plural { subjects = before.compactMap(\.m.canonical) }
                else if let first = before.first?.m.canonical { subjects = [first] }
                else if let after = local.first(where: { $0.at > verb.range.location && $0.at - verb.range.location - verb.range.length <= 3 }), let c = after.m.canonical {
                    subjects = [c]
                }
            }
            for c in Array(Set(subjects)).sorted() {
                let person = names.canonicals[c]
                if let role = ProceedingRoleClassifier.role(of: person, in: text), role.takesNoSteps { continue }
                out.append(Statement(doc: doc, sentence: s, kind: .term, attribute: "prison term", subjectKey: "p\(c)",
                                     subject: person, value: detail.count <= 60 ? detail : term.description, term: term))
            }
        }
        return out
    }

    // MARK: - Explained differences (real-case v2, 2026-11-04)
    //
    // Pairs the real cases showed are not contradictions: the case growing between an early and a later
    // release ("over $500K" then "more than $2 million"; "two victims" then "four victims"), an agreed fee
    // against what was paid or lost, figures of different records (two recall events' product counts), the
    // send dates of two messages, an office's holder or a person's title changing. Both passes use these.

    enum Bound { case exact, approximate, lower, upper }

    static let lowerBoundWords = #"(?i)\b(?:more than|over|at least|in excess of|exceeding|upwards of|greater than|no less than|not less than)\s*$"#
    static let upperBoundWords = #"(?i)\b(?:less than|under|up to|no more than|fewer than|below|at most)\s*$"#
    static let approximateWords = #"(?i)\b(?:approximately|about|nearly|roughly|around|almost|some|close to|an estimated|estimated|an approximate)\s*$"#

    /// How the words just before a figure state it.
    static func bound(before: String) -> Bound {
        let tail = String(before.suffix(40))
        if tail.range(of: lowerBoundWords, options: .regularExpression) != nil { return .lower }
        if tail.range(of: upperBoundWords, options: .regularExpression) != nil { return .upper }
        if tail.range(of: approximateWords, options: .regularExpression) != nil { return .approximate }
        return .exact
    }

    /// Both statements can be true of one figure: "more than $750,000" and "more than $1 million" can.
    static func compatible(_ x: Double, _ bx: Bound, _ y: Double, _ by: Bound) -> Bool {
        func span(_ v: Double, _ b: Bound) -> ClosedRange<Double> {
            switch b {
            case .exact: return (v * 0.995)...(v * 1.005)
            case .approximate: return (v * 0.85)...(v * 1.15)
            case .lower: return v...Double.greatestFiniteMagnitude
            case .upper: return 0...v
            }
        }
        return span(x, bx).overlaps(span(y, by))
    }

    /// The case grew between the documents: the later one gives the higher figure. Nil when either
    /// document's date is unknown or both are the same day.
    static func grew(_ x: Double, dateX: Date?, _ y: Double, dateY: Date?) -> Bool {
        guard let dx = dateX, let dy = dateY, abs(dx.timeIntervalSince(dy)) >= 86_400 else { return false }
        return dx < dy ? y > x : x > y
    }

    /// Record identifiers a document states of itself: "Event ID: 70738", "recall event 70738", "Case
    /// Number: 13-336". Kind → value.
    static func recordIDs(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let head = String(text.prefix(3_000))
        let pattern = #"(?im)^\s*(?:[A-Za-z .]{0,30}?\s)?(event id|recall event|recall number|event number|case (?:no\.?|number)|docket (?:no\.?|number)|file (?:no\.?|number)|report (?:no\.?|number))\s*[:#]?\s*([A-Za-z0-9][A-Za-z0-9\-:./]{1,40})"#
        for m in matches(pattern, in: head) {
            let ns = head as NSString
            let label = ns.substring(with: m.range(at: 1)).lowercased()
            let value = ns.substring(with: m.range(at: 2)).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".:,"))
            let kind = label.contains("event") ? "event" : label.hasPrefix("recall") ? "recall"
                : (label.hasPrefix("case") || label.hasPrefix("docket")) ? "case" : label.components(separatedBy: " ").first ?? label
            if out[kind] == nil { out[kind] = value }
        }
        return out
    }

    /// The two documents identify themselves as different records of one kind (two recall events, two
    /// court cases): their figures are not two accounts of one fact.
    static func differentRecords(_ a: String, _ b: String) -> String? {
        let x = recordIDs(a), y = recordIDs(b)
        for (kind, v) in x { if let w = y[kind], w != v { return "\(kind) \(v) vs \(w)" } }
        return nil
    }

    /// A message header line ("Date: Fri, 9 Nov 2001 …", "X-From: …"): the date it carries is a send date.
    static let headerLine = #"(?im)^\s*(?:date|sent|from|to|cc|subject|x-from|x-to|x-cc|received)\s*:|\bx-from\s*:|-0[0-9]00 \((?:pst|pdt|est|edt|cst|cdt|mst|mdt)\)"#

    /// A date the sentence gives as planned, not as what happened ("is set to be sentenced on May 28").
    static let scheduled = #"(?i)\b(?:will be|is set to|are set to|set for|scheduled|is to be|are to be|faces?|facing|when (?:he|she|they) (?:is|are) sentenced|expected to|awaiting|pending)\b"#

    /// The events a sentence dates, by their word.
    static func eventWords(_ s: String) -> Set<String> {
        let l = s.lowercased()
        let table: [(String, String)] = [
            (#"\bsentenc\w*"#, "sentenced"), (#"\bplead\w*|\bpled\b|\bplea\b"#, "plea"), (#"\bconvict\w*|\bfound guilty\b|\bverdict"#, "convicted"),
            (#"\bindict\w*|\bcharg\w*|\bcomplaint\b"#, "charged"), (#"\barrest\w*"#, "arrested"), (#"\brecall\w*"#, "recall"),
            (#"\bterminat\w*"#, "terminated"), (#"\bclassif\w*"#, "classified"), (#"\bcollid\w*|\bcollision\b|\bcrash\w*"#, "collision"),
            (#"\bfire\b|\bblaze\b|\bburn\w*|\bexplo\w*"#, "fire"), (#"\bresign\w*"#, "resigned"), (#"\bmeet\w*|\bmet\b"#, "met"),
            (#"\bsigned\b|\bsigning\b"#, "signed"), (#"\bfiled\b|\bfiling\b"#, "filed"), (#"\bhired\b|\bhiring\b"#, "hired"),
            (#"\bpaid\b|\bpayment\b|\bwired\b|\btransferr\w*"#, "paid"), (#"\bborn\b|\bbirth"#, "born"), (#"\bdied\b|\bdeath\b|\bkilled\b"#, "died"),
        ]
        return Set(table.compactMap { l.range(of: $0.0, options: .regularExpression) != nil ? $0.1 : nil })
    }

    /// What an amount is in its sentence: agreed, paid, a loss, restitution, forfeiture, a fine, a fee,
    /// loans, sales — by the label right after it ("$750,000 in EIDLs") or the nearest word before it.
    static func amountRole(_ value: String, in quote: String) -> String? {
        let q = quote as NSString
        var at = q.range(of: value, options: .caseInsensitive)
        if at.location == NSNotFound, let target = VerifiedAnswerComposer.values(in: value).money.min() {
            at = matches(moneyPattern, in: quote).first { money(q.substring(with: $0.range)) == target }?.range ?? at
        }
        guard at.location != NSNotFound else { return nil }
        let before = String(q.substring(to: at.location).suffix(160)).lowercased()
        let after = String(q.substring(from: at.location + at.length).prefix(40)).lowercased()
        let agreed = #"\b(?:agreed to pay|agreed to|promised(?: to pay)?|owed|to pay|would pay|demanded|charged (?:a|an|the))\b"#
        if before.range(of: agreed + #"[^$]{0,60}$"#, options: .regularExpression) != nil { return "agreed" }
        let labels: [(String, String)] = [
            // "$1 Million Advance Fee Scheme" names the scheme's size; "received $120,000 from the scheme" does not.
            (#"^\s*(?:(?!(?:from|by|through|via|in|of|for|with|to|the|a|an)\b)[\w\-“”"'’]+\s+){0,3}?(?:schemes?|scams?|ponzi|frauds?|conspiracy)\b"#, "scheme"),
            (#"^\s*(?:in\s+)?(?:court-ordered\s+)?restitution"#, "restitution"), (#"^\s*(?:in\s+)?forfeit"#, "forfeiture"),
            (#"^\s*(?:in\s+)?(?:criminal\s+)?fines?\b"#, "fine"), (#"^\s*(?:in|of)?\s*(?:[\w-]+\s+){0,2}?(?:fees?)\b|^\s*for\s+(?:the\s+|a\s+|an\s+)?(?:[\w-]+\s+){0,2}?fees?\b"#, "fee"),
            (#"^\s*(?:in\s+)?(?:[\w-]+\s+){0,3}?(?:loans?|eidls?|grants?|benefits|relief funds?|unemployment)\b"#, "loan"),
            (#"^\s*(?:in\s+)?(?:annual\s+)?(?:sales|revenue)"#, "sales"), (#"^\s*(?:in\s+)?loss(?:es)?\b"#, "loss"),
        ]
        if let l = labels.first(where: { after.range(of: $0.0, options: .regularExpression) != nil }) { return l.1 }
        let words: [(String, String)] = [
            (#"\brestitution\b"#, "restitution"), (#"\bforfeit\w*|\bseized\b"#, "forfeiture"), (#"\bfine[sd]?\b|\bpenalt\w*"#, "fine"),
            (#"\bfees?\b"#, "fee"), (#"\bloans?\b|\beidls?\b|\bgrants?\b"#, "loan"), (#"\bsales\b|\brevenue\b"#, "sales"),
            (#"\b(?:paid|pays|paying|wired|sent|transferred|received|receiving|accepted|deposited|gave|disbursed|provided)\b"#, "paid"),
            (#"\bdefraud\w*|\bout of\b|\bloss(?:es)?\b|\blost\b|\bstole\b|\bstolen\b|\bswindl\w*|\bembezzl\w*|\bobtain\w*|\bmisappropriat\w*"#, "loss"),
        ]
        var best: (end: Int, role: String)?
        for (pattern, role) in words {
            if let last = matches(pattern, in: before).last {
                let end = last.range.location + last.range.length
                if best == nil || end > best!.end { best = (end, role) }
            }
        }
        return best?.role
    }

    /// What a count counts: its noun ("victims", "defendants", "product records") and the step it is of
    /// ("charged", "convicted") — "22 individuals charged" and "24 defendants convicted" count different things.
    static func countRole(_ value: String, in quote: String) -> (noun: String?, step: String?) {
        let q = quote.lowercased()
        // The count's own figure (digits or a number word) in the quote, and the noun after it.
        let figure = value.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            .first { Double($0.replacingOccurrences(of: ",", with: "")) != nil || VerifiedAnswerComposer.numberWords[$0] != nil }
        var noun: String?
        if let figure, let r = q.range(of: #"(?<![\p{L}\d,.])"# + NSRegularExpression.escapedPattern(for: figure) + #"(?![\p{L}\d,])"#, options: .regularExpression) {
            let people: Set<String> = ["individuals", "individual", "defendants", "defendant", "people", "persons", "men", "women", "others",
                                       "co-defendants", "codefendants", "co-conspirators", "conspirators"]
            for w in q[r.upperBound...].prefix(80).split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init).prefix(5) {
                if ["of", "the", "individual", "separate", "known", "other", "additional", "more", "new", "total"].contains(w) { continue }
                noun = people.contains(w) ? "people" : (w.hasSuffix("s") ? String(w.dropLast()) : w)
                break
            }
        }
        let steps: [(String, String)] = [(#"\b(?:charg\w*|indict\w*|accused)\b"#, "charged"), (#"\b(?:convicted|found guilty|pleaded|pled)\b"#, "convicted"),
                                         (#"\bsentenced\b"#, "sentenced"), (#"\barrested\b"#, "arrested")]
        let found = steps.filter { q.range(of: $0.0, options: .regularExpression) != nil }.map(\.1)
        // The step a sentence reports is the count's own only for a count of people ("24 defendants who have
        // been convicted"); "defrauded four victims" in an indictment release is not a count of charges.
        return (noun, (noun == nil || noun == "people") && found.count == 1 ? found[0] : nil)
    }

    /// Two role-or-account values that are an office or a title ("Special Agent in Charge … Dennehy" vs
    /// "… Crouch", "Senior Litigation Counsel" vs "Trial Attorney"): who holds an office and what a person's
    /// title is change between documents written years apart.
    static let officeWords = #"(?i)\b(?:attorneys?|counsel|director|agents?|special agent|in charge|judge|justice|inspector|chief|commissioner|sheriff|prosecutors?|secretary|head of|deputy|officer|chairman|president|superintendent|administrator|trustee)\b"#

    /// Kinds whose figure is an aggregate of the case (it can grow as the case does).
    static func aggregate(_ attribute: String, role: String?) -> Bool {
        if attribute == "amount paid to them" { return false }
        return !["agreed", "paid", "restitution", "forfeiture", "fine", "fee"].contains(role ?? "")
    }

    // MARK: - Rules: compare

    /// The rule pass over the case's documents.
    public static func ruleFindings(_ documents: [Document], limit: Int = 80) -> [Finding] {
        let names = Names(documents: documents)
        return compare(statements(documents, names: names), documents: documents, limit: limit)
    }

    static func valueKey(_ s: Statement) -> String {
        switch s.kind {
        case .role: return s.actors.sorted().joined(separator: "+")
        case .account: return s.tokens.sorted().joined(separator: "+")
        case .date: return s.value
        case .term: return s.term?.description ?? s.value
        default: return s.number.map { String(format: "%.2f", $0) } ?? s.value
        }
    }

    static func compare(_ statements: [Statement], documents: [Document], limit: Int) -> [Finding] {
        var groups: [String: [Statement]] = [:]
        var order: [String] = []
        for s in statements {
            // Ease fixes A — the currency is part of the key: €, ₹ and $ amounts are never compared with each other.
            let key = "\(s.kind.rawValue)|\(s.attribute)|\(s.subjectKey)|\(s.currency)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(s)
        }
        var out: [Finding] = []
        var seenPairs = Set<String>()
        for key in order {
            guard let group = groups[key] else { continue }
            // One value per document: two values for one subject in one document are two things (two
            // payments, two events), not a disagreement — that document sits this subject out.
            var perDoc: [Int: Statement] = [:]
            var ambiguous = Set<Int>()
            for s in group {
                if let prior = perDoc[s.doc] {
                    if !sameValue(prior, s) { ambiguous.insert(s.doc) }
                } else { perDoc[s.doc] = s }
            }
            let docs = perDoc.keys.filter { !ambiguous.contains($0) }.sorted()
            guard docs.count >= 2 else { continue }
            for (x, i) in docs.enumerated() {
                for j in docs[(x + 1)...] {
                    guard let a = perDoc[i], let b = perDoc[j], documents[i].objectID != documents[j].objectID else { continue }
                    // Two documents that identify themselves as different records (two recall events, two court
                    // cases) give figures of different things.
                    guard differentRecords(documents[i].text, documents[j].text) == nil else { continue }
                    guard let note = conflict(a, b, documents: documents) else { continue }
                    let pairKey = [valueKey(a), valueKey(b)].sorted().joined(separator: "|") + "|" + key
                    let sentencePair = [normalized(a.sentence), normalized(b.sentence)].sorted().joined(separator: "|")
                    guard seenPairs.insert(pairKey).inserted, seenPairs.insert(sentencePair).inserted else { continue }
                    out.append(Finding(kind: a.kind, subject: a.subject, attribute: a.attribute, quoteA: a.sentence, quoteB: b.sentence,
                                       objectA: documents[i].objectID, objectB: documents[j].objectID,
                                       versionA: documents[i].sourceVersionID, versionB: documents[j].sourceVersionID,
                                       valueA: a.value, valueB: b.value, provenance: .rules, note: note.isEmpty ? nil : note))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    static func sameValue(_ a: Statement, _ b: Statement) -> Bool { valueKey(a) == valueKey(b) }

    /// Nil when the two do not conflict; otherwise a note ("" for none).
    static func conflict(_ a: Statement, _ b: Statement, documents: [Document]) -> String? {
        switch a.kind {
        case .amount, .count:
            guard let x = a.number, let y = b.number, max(x, y) > 0 else { return nil }
            // Both can be true ("more than $750,000" / "more than $1 million"; "about $50,000" / "$52,000").
            if compatible(x, a.bound, y, b.bound) { return nil }
            // The case grew: a later release gives the higher victims, counts or loss (a payment to someone
            // does not grow).
            if aggregate(a.attribute, role: nil), grew(x, dateX: documents[a.doc].date, y, dateY: documents[b.doc].date) { return nil }
            return ""
        case .term:
            guard let x = a.term, let y = b.term else { return nil }
            return x != y ? "" : nil
        case .date:
            guard let x = a.day, let y = b.day else { return nil }
            return x != y ? "" : nil
        case .age:
            guard let x = a.number, let y = b.number, x != y else { return nil }
            if let da = documents[a.doc].date, let db = documents[b.doc].date {
                // Time between the documents explains up to a year either side of it.
                let (older, newer, ageOlder, ageNewer) = da <= db ? (da, db, x, y) : (db, da, y, x)
                let years = newer.timeIntervalSince(older) / (365.25 * 86_400)
                let grew = ageNewer - ageOlder
                return (grew >= years.rounded(.down) && grew <= years.rounded(.down) + 1) ? nil : ""
            }
            return "The documents' dates are not known; check whether the time between them explains it."
        case .role:
            guard !a.actors.isEmpty, !b.actors.isEmpty, a.actors.isDisjoint(with: b.actors),
                  !a.tokens.intersection(b.tokens).subtracting(["spread", "spreading", "gasoline", "fuel", "set", "fire"]).isEmpty else { return nil }
            return ""
        case .account:
            // Two recordings of one thing (both say what was caught, and it is the same).
            guard !a.about.isEmpty, !b.about.isEmpty, !a.about.isDisjoint(with: b.about) else { return nil }
            return a.tokens.isDisjoint(with: b.tokens) ? "" : nil
        }
    }

    // MARK: - What a document says about payments vs the case's money records (ease fixes A)
    //
    // A witness or a document states how many payments were made to someone, or the total paid ("I approved one payment of
    // INR 50,000 to Kestrel"); the case's structured money records (statement rows, recorded payments — each real payment
    // once, copies counted once) show something else (two payments of INR 50,000 to Kestrel). Both sides are kept: the
    // sentence in its document, and the money records' own lines in the document they were recorded from. Only the same
    // currency is compared, only exact readings, and nothing is decided.

    /// One real payment in the case's money records (several records of one payment are ONE movement).
    public struct MoneyMovement: Sendable, Hashable {
        /// Where one record of the payment comes from.
        public struct Source: Sendable, Hashable {
            public let sourceVersionID: UUID?
            /// The day, amount and reference as written in the record (used to find the record's line in its document).
            public let dateText: String?
            public let amountText: String
            public let reference: String?
            /// The record's own quote, when the line cannot be found in the document.
            public let quote: String?
            public init(sourceVersionID: UUID?, dateText: String?, amountText: String, reference: String?, quote: String?) {
                self.sourceVersionID = sourceVersionID; self.dateText = dateText; self.amountText = amountText; self.reference = reference; self.quote = quote
            }
        }
        /// "payment", "receipt", "transfer", "refund", "reversal" or "fee".
        public let kind: String
        public let amount: Decimal
        public let currency: String
        /// yyyy-MM-dd, when known.
        public let day: String?
        /// The payee as recorded: names, an account's identifier and its recorded holders.
        public let payee: [String]
        public let sources: [Source]
        /// The money records could not tell whether it is one payment or several (a day or reference missing).
        public let uncertain: Bool
        public init(kind: String, amount: Decimal, currency: String, day: String?, payee: [String], sources: [Source], uncertain: Bool = false) {
            self.kind = kind; self.amount = amount; self.currency = currency; self.day = day; self.payee = payee; self.sources = sources
            self.uncertain = uncertain
        }
    }

    /// What the case check compares, in plain words (shown on the case-check screen).
    public static let ruleCoverage = """
        What the rules compare (no AI): amounts paid to a named person, losses, restitution and forfeiture, in any currency the \
        documents write with a sign, a code or a word (₹, Rs, INR, lakh and crore, €, £, $ and others) — only the same currency, \
        and never an amount that cannot be read without guessing; how many payments, or what total, a document says were made \
        to someone against the case's money records; the dates of proceeding steps (charged, convicted, sentenced); ages; \
        counts of victims and of charges; who did an act; what recorded it; and prison terms. Not compared: meaning in other \
        words, places, descriptions of events, amounts in different currencies (no conversion), money records with no source \
        document in the case, and anything outside the case. Finding nothing does not show that the documents agree.
        """

    static let countWords: [String: Int] = ["one": 1, "a single": 1, "single": 1, "only one": 1, "just one": 1, "two": 2, "three": 3, "four": 4,
                                            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
    static let paymentCount = #"(?i)\b(only one|just one|a single|single|one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2})\s+(?:separate\s+)?(payments?|transfers?|debits?|instalments?|installments?)\b"#
    static let paymentTotal = #"(?i)\b(?:paid|transferred|sent|wired|remitted|payments?)\b[^.;]{0,60}?\b(?:a total of|in total|totall?ing|altogether|in all|total of)\b|\b(?:a total of|total of)\b[^.;]{0,40}?\b(?:paid|transferred|sent|wired|remitted)\b"#
    static let negation = #"(?i)\b(?:not|never|no|n't|cannot|can't|don't|didn't|doesn't|deny|denies|denied)\b"#
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
    static let partyGeneric: Set<String> = ["ltd", "pvt", "private", "limited", "inc", "llc", "llp", "co", "company", "corp", "corporation", "plc", "gmbh",
                                            "the", "and", "of", "bank", "account", "accounts", "supplies", "services", "group", "holdings", "trading",
                                            "industries", "enterprises", "international", "solutions", "a/c"]

    /// The words of a payee that name it ("Kestrel" of "Kestrel Supplies Pvt Ltd"; an account number as a whole token).
    static func partyTokens(_ names: [String]) -> Set<String> {
        var out = Set<String>()
        for n in names {
            for w in n.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
                let digits = w.allSatisfy(\.isNumber)
                if digits ? w.count >= 3 : (w.count >= 3 && !partyGeneric.contains(w)) { out.insert(w) }
            }
        }
        return out
    }

    /// Whether `phrase` (the words after "to") names the payee: one of its naming words as a whole word.
    static func phraseNames(_ phrase: String, payee: Set<String>) -> Bool {
        let words = Set(phrase.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return !words.isDisjoint(with: payee)
    }

    /// The month (1–12) and year a sentence limits its payments to ("in the first week of March", "in March 2026"), if any.
    static func period(_ s: String, documentDate: Date?) -> (month: Int, year: Int?)? {
        let l = s.lowercased()
        let found = months.enumerated().filter { l.range(of: #"\b"# + $0.element + #"\b"#, options: .regularExpression) != nil }
        guard found.count == 1, let month = found.first.map({ $0.offset + 1 }) else { return nil }
        if let r = s.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression), let y = Int(s[r]) { return (month, y) }
        let year = documentDate.map { Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .current, from: $0).year }
        return (month, year ?? nil)
    }

    /// The line of `text` that holds one money record (its reference, else its day and amount), verbatim; nil when none does.
    static func recordLine(_ source: MoneyMovement.Source, in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
        func has(_ line: String, _ part: String?) -> Bool {
            guard let p = part?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return true }
            return line.localizedCaseInsensitiveContains(p)
        }
        if let ref = source.reference, !ref.trimmingCharacters(in: .whitespaces).isEmpty,
           let line = lines.first(where: { has($0, ref) && has($0, source.amountText) }) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        return lines.first { has($0, source.dateText) && has($0, source.amountText) && source.dateText != nil }?.trimmingCharacters(in: .whitespaces)
    }

    /// The payments a document's sentence counts or totals, against the case's money records. A pair is raised only when
    /// the sentence names the payee, the money records hold at least one payment to that payee in the sentence's month (when
    /// it names one) and in the sentence's currency, and the records came from a document of the case other than the
    /// sentence's own.
    public static func moneyRecordFindings(_ documents: [Document], movements: [MoneyMovement], limit: Int = 40) -> [Finding] {
        let payments = movements.filter { $0.kind == "payment" }
        guard !payments.isEmpty else { return [] }
        let byVersion = Dictionary(documents.enumerated().compactMap { i, d in d.sourceVersionID.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        var out: [Finding] = []
        var seen = Set<UUID>()
        for d in documents {
            for sentence in ProceedingEventExtractor.rawSentences(of: d.text) where !statesCorrection(sentence) {
                guard let claim = paymentClaim(sentence, payments: payments, documentDate: d.date) else { continue }
                // The money records' side: a document of the case they were recorded from, not this one.
                let sourceDocs = claim.matched.flatMap(\.sources).compactMap { $0.sourceVersionID.flatMap { byVersion[$0] } }
                guard let j = sourceDocs.first(where: { documents[$0].objectID != d.objectID }) else { continue }
                let other = documents[j]
                var lines: [String] = []
                for m in claim.matched {
                    for src in m.sources where src.sourceVersionID == other.sourceVersionID {
                        if let line = recordLine(src, in: other.text) ?? src.quote, !lines.contains(line) { lines.append(line) }
                    }
                }
                guard !lines.isEmpty else { continue }
                let days = claim.matched.map { $0.day ?? "day not recorded" }.joined(separator: ", ")
                var note = "From the case's money records (each payment counted once; copies of a record are one payment): \(days)."
                if let p = claim.period { note += " The statement names \(months[p.month - 1].capitalized); payments in that month are counted." }
                if claim.matched.contains(where: \.uncertain) { note += " Some records may be one payment or several; confirm or split them in Money." }
                let f = Finding(kind: claim.isTotal ? .amount : .count, subject: claim.payee, attribute: claim.attribute,
                                quoteA: sentence, quoteB: lines.joined(separator: "\n"), objectA: d.objectID, objectB: other.objectID,
                                versionA: d.sourceVersionID, versionB: other.sourceVersionID, valueA: claim.stated, valueB: claim.recorded,
                                provenance: .rules, note: note)
                guard seen.insert(f.contradiction().id).inserted else { continue }
                out.append(f)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    struct PaymentClaim {
        let payee: String
        let attribute: String
        let stated: String
        let recorded: String
        let matched: [MoneyMovement]
        let isTotal: Bool
        let period: (month: Int, year: Int?)?
    }

    /// One sentence's count or total of payments to a recorded payee, when the money records disagree with it.
    static func paymentClaim(_ s: String, payments: [MoneyMovement], documentDate: Date?) -> PaymentClaim? {
        let ns = s as NSString
        let monies = amounts(in: s)
        let total = s.range(of: paymentTotal, options: .regularExpression) != nil
        let count = matches(paymentCount, in: s).first
        guard total || count != nil else { return nil }
        if !total, s.range(of: separatePayment, options: .regularExpression) != nil { return nil }
        // The figure the sentence states: the count word, and the amount after it (a total needs its amount).
        var n: Int?
        var amount: Amount?
        var from = 0
        if let c = count, !total {
            let word = ns.substring(with: c.range(at: 1)).lowercased()
            n = countWords[word] ?? Int(word)
            // "I did not approve one payment …": a negated count is not a statement of how many.
            if ns.substring(to: c.range.location).range(of: negation, options: .regularExpression) != nil { return nil }
            from = c.range.location + c.range.length
            amount = monies.first { $0.range.location >= from && $0.range.location - from <= 12 }
        } else {
            amount = monies.first
            from = amount.map { $0.range.location + $0.range.length } ?? 0
        }
        guard total ? amount != nil : n != nil else { return nil }
        if amount.map({ $0.currency.isEmpty || $0.currency == FAMoney.ambiguousDollar }) ?? false { return nil }
        // The payee: the words after "to" following the figure.
        let rest = ns.substring(from: min(from, ns.length))
        guard let to = rest.range(of: #"(?i)\bto\s+"#, options: .regularExpression) else { return nil }
        let phrase = String(rest[to.upperBound...].prefix(60))
        let window = period(s, documentDate: documentDate)
        var toPayee: [MoneyMovement] = []
        var payeeName = ""
        for p in payments where phraseNames(phrase, payee: partyTokens(p.payee)) {
            toPayee.append(p)
            if payeeName.isEmpty { payeeName = p.payee.first ?? "" }
        }
        guard !toPayee.isEmpty else { return nil }
        if let window {
            // An undated payment cannot be placed in the month: the comparison would be a guess.
            if toPayee.contains(where: { $0.day == nil }) { return nil }
            toPayee = toPayee.filter { p in
                guard let d = p.day, d.count >= 7, let m = Int(d.dropFirst(5).prefix(2)), let y = Int(d.prefix(4)) else { return false }
                return m == window.month && (window.year.map { $0 == y } ?? true)
            }
        }
        if let a = amount {
            let same = toPayee.filter { $0.currency == a.currency }
            if total {
                guard !same.isEmpty else { return nil }
                let sum = same.reduce(Decimal(0)) { $0 + $1.amount }
                let b = bound(before: ns.substring(to: a.range.location))
                guard sum != a.value, !compatible(a.number, b, NSDecimalNumber(decimal: sum).doubleValue, .exact) else { return nil }
                return PaymentClaim(payee: payeeName, attribute: "total paid to them (a document vs the case's money records)",
                                    stated: display(a.value, currency: a.currency), recorded: "\(display(sum, currency: a.currency)) in \(same.count) payment(s)",
                                    matched: same, isTotal: true, period: window)
            }
            let exact = same.filter { $0.amount == a.value }
            guard let n, !exact.isEmpty, exact.count != n else { return nil }
            let shown = display(a.value, currency: a.currency)
            return PaymentClaim(payee: payeeName, attribute: "payments of \(shown) to them (a document vs the case's money records)",
                                stated: n == 1 ? "1 payment" : "\(n) payments", recorded: exact.count == 1 ? "1 payment" : "\(exact.count) payments",
                                matched: exact, isTotal: false, period: window)
        }
        guard let n, toPayee.count != n else { return nil }
        return PaymentClaim(payee: payeeName, attribute: "payments to them (a document vs the case's money records)",
                            stated: n == 1 ? "1 payment" : "\(n) payments", recorded: toPayee.count == 1 ? "1 payment" : "\(toPayee.count) payments",
                            matched: toPayee, isTotal: false, period: window)
    }

    // MARK: - Shared with the AI look: passages, the whole-case batch, verbatim and value checks

    public struct Passage: Sendable, Hashable {
        public let objectID: UUID
        public let sourceVersionID: UUID?
        public let text: String
        public init(objectID: UUID, sourceVersionID: UUID? = nil, text: String) {
            self.objectID = objectID; self.sourceVersionID = sourceVersionID; self.text = text
        }
    }

    public struct Batch: Sendable {
        /// The person or organisation the passages are about (nil: the case's events).
        public let subject: String?
        public let passages: [Passage]
    }

    static let passageCharacters = 1_500
    static let officialWords = #"(?i)\b(?:attorney|judge|justice|agent|court|office|department|united states|bureau|special|inspector|prosecutor)\b"#
    static let eventWords = #"(?i)\b(?:fire|gasoline|fuel|camera|video|recorded|explosion|loss(?:es)?|victims?|restitution|counts?|paid|received|ages?|sentenced|indicted)\b"#

    /// The passages the reader gets: per subject named in at least two documents, each document's
    /// sentences naming that subject (from its first full mention); then one batch of the case's event
    /// sentences. Only the given documents (the cleared ones) are used.
    public static func batches(_ documents: [Document], allDocuments: [Document]? = nil, maxSubjects: Int = 6, maxPassages: Int = 8) -> [Batch] {
        batchPlan(documents, allDocuments: allDocuments, maxSubjects: maxSubjects, maxPassages: maxPassages).batches
    }

    /// The batches and what the limits left out (case plan 2026-11-16, SEARCH-14): subjects named in two or more documents
    /// beyond `maxSubjects`, and passages beyond `maxPassages` per subject (and for the case's events), so a look over
    /// passages says what it did not send instead of dropping it silently.
    public struct BatchPlan: Sendable {
        public var batches: [Batch] = []
        /// Subjects named in two or more documents, and how many of them got a batch.
        public var subjects = 0
        public var subjectsSent = 0
        /// The subjects left out by the limit, by name.
        public var subjectsLeftOut: [String] = []
        /// Passages left out by the per-subject / events limit.
        public var passagesLeftOut = 0
        public var complete: Bool { subjectsLeftOut.isEmpty && passagesLeftOut == 0 }
    }

    public static func batchPlan(_ documents: [Document], allDocuments: [Document]? = nil, maxSubjects: Int = 6, maxPassages: Int = 8) -> BatchPlan {
        var plan = BatchPlan()
        let names = Names(documents: allDocuments ?? documents)
        let docIndex: [UUID: Int] = Dictionary((allDocuments ?? documents).enumerated().map { ($0.element.objectID, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var sentencesBySubject: [Int: [Int: [String]]] = [:]   // subject → doc (local) → sentences
        var eventSentences: [Int: [String]] = [:]
        for (i, d) in documents.enumerated() {
            let indexInAll = docIndex[d.objectID]
            for s in ProceedingEventExtractor.rawSentences(of: d.text) {
                let named = Set(names.mentions(in: s, doc: indexInAll).compactMap(\.canonical))
                for c in named { sentencesBySubject[c, default: [:]][i, default: []].append(s) }
                if s.range(of: eventWords, options: .regularExpression) != nil { eventSentences[i, default: []].append(s) }
            }
        }
        let ranked = sentencesBySubject.filter { $0.value.count >= 2 && names.canonicals[$0.key].range(of: officialWords, options: .regularExpression) == nil }
            .sorted { a, b in
                a.value.count != b.value.count ? a.value.count > b.value.count
                    : a.value.values.reduce(0) { $0 + $1.count } > b.value.values.reduce(0) { $0 + $1.count }
            }
        func passage(_ doc: Int, _ sentences: [String]) -> Passage {
            var text = ""
            for s in sentences where text.count + s.count + 1 <= passageCharacters { text += (text.isEmpty ? "" : " ") + s }
            return Passage(objectID: documents[doc].objectID, sourceVersionID: documents[doc].sourceVersionID, text: text)
        }
        var out: [Batch] = []
        plan.subjects = ranked.count
        for (c, byDoc) in ranked.prefix(maxSubjects) {
            let passages = byDoc.keys.sorted().prefix(maxPassages).map { passage($0, byDoc[$0] ?? []) }.filter { !$0.text.isEmpty }
            plan.passagesLeftOut += max(0, byDoc.count - maxPassages)
            if passages.count >= 2 { out.append(Batch(subject: names.canonicals[c], passages: Array(passages))); plan.subjectsSent += 1 }
        }
        plan.subjectsLeftOut = ranked.dropFirst(maxSubjects).map { names.canonicals[$0.key] }
        let events = eventSentences.keys.sorted().prefix(maxPassages).map { passage($0, eventSentences[$0] ?? []) }.filter { !$0.text.isEmpty }
        plan.passagesLeftOut += max(0, eventSentences.count - maxPassages)
        if events.count >= 2 { out.append(Batch(subject: nil, passages: Array(events))) }
        plan.batches = out
        return plan
    }

    /// The whole case as one batch: passage N is [Document N] of the prefix.
    public static func wholeCaseBatch(_ documents: [CaseReader.Document]) -> Batch {
        Batch(subject: nil, passages: documents.map { Passage(objectID: $0.objectID, sourceVersionID: $0.sourceVersionID, text: $0.text) })
    }

    static let statutoryPattern = #"(?i)\b(?:maximum (?:possible )?(?:penalty|penalties|sentence|sentences|term|fine|prison term)|statutory maximum|faces? (?:up to|a maximum|a possible)|facing (?:up to|a maximum)|carr(?:y|ies) (?:a )?(?:maximum|up to|a possible)|punishable by)\b"#

    /// Why two verified sides are not a contradiction after all, or nil (the rules' own reasons, applied to
    /// a pair of sides of an AI finding — AIConflictContract.check).
    static func explained(kind: Kind, about: String, qa: String, qb: String, va: String, vb: String,
                          contextA: [String], contextB: [String], docA: Document?, docB: Document?) -> String? {
        let sa = ([qa] + contextA).joined(separator: " "), sb = ([qb] + contextB).joined(separator: " ")
        if let a = docA, let b = docB, let ids = differentRecords(a.text, b.text) {
            return "values of different records (\(ids))"
        }
        switch kind {
        case .date:
            if [qa, qb].contains(where: { $0.range(of: headerLine, options: .regularExpression) != nil }) {
                return "the send dates of two different messages"
            }
            if [sa, sb].contains(where: { $0.range(of: scheduled, options: .regularExpression) != nil }) {
                return "a scheduled date, which can move — not a date of what happened"
            }
            let ea = eventWords(qa).union(eventWords(contextA.joined(separator: " "))), eb = eventWords(qb).union(eventWords(contextB.joined(separator: " ")))
            if ea.isEmpty || eb.isEmpty || ea.isDisjoint(with: eb) { return "dates of different events" }
        case .amount:
            let ra = amountRole(va, in: qa) ?? amountRole(va, in: sa), rb = amountRole(vb, in: qb) ?? amountRole(vb, in: sb)
            if let ra, let rb, ra != rb { return "different amounts (\(ra) vs \(rb))" }
            let fa = VerifiedAnswerComposer.values(in: va), fb = VerifiedAnswerComposer.values(in: vb)
            // Sorted: the figures are a Set, so ".first" used to be arbitrary (a flaky verdict on ranges).
            let la = (fa.money.isEmpty ? fa.numbers : fa.money).sorted(), lb = (fb.money.isEmpty ? fb.numbers : fb.money).sorted()
            // A range ("$400 to $2,000") is compared whole: two ranges sharing an endpoint still differ.
            let rangesDiffer = (la.count > 1 || lb.count > 1) && la != lb
            if let x = la.first, let y = lb.first {
                if !rangesDiffer, compatible(x, bound(of: va, in: qa), y, bound(of: vb, in: qb)) { return "both can be true (a bound, not an exact figure)" }
                if aggregate("", role: ra ?? rb), grew(x, dateX: docA?.date, y, dateY: docB?.date) {
                    return "the case grew between the documents (the later one gives the higher figure)"
                }
            }
        case .count:
            let ra = countRole(va, in: qa), rb = countRole(vb, in: qb)
            if (ra.noun != nil && rb.noun != nil && ra.noun != rb.noun) || (ra.step != nil && rb.step != nil && ra.step != rb.step) {
                let a = [ra.noun, ra.step].compactMap { $0 }.joined(separator: " "), b = [rb.noun, rb.step].compactMap { $0 }.joined(separator: " ")
                return "different counts (\(a) vs \(b))"
            }
            let na = VerifiedAnswerComposer.values(in: va).numbers.sorted(), nb = VerifiedAnswerComposer.values(in: vb).numbers.sorted()
            let countRangesDiffer = (na.count > 1 || nb.count > 1) && na != nb
            if let x = na.first, let y = nb.first {
                if !countRangesDiffer, compatible(x, bound(of: va, in: qa), y, bound(of: vb, in: qb)) { return "both can be true (a bound, not an exact figure)" }
                if grew(x, dateX: docA?.date, y, dateY: docB?.date) { return "the case grew between the documents (the later one gives the higher count)" }
            }
        case .role, .account:
            if [about, va, vb].contains(where: { $0.range(of: officeWords, options: .regularExpression) != nil }) {
                return "an office's holder or a person's title can change between documents"
            }
        case .age, .term:
            break
        }
        return nil
    }

    /// How a value is stated in its quote (the words before it).
    static func bound(of value: String, in quote: String) -> Bound {
        // "more than $750,000" as the value itself, else the words before the figure in the quote.
        let lead = String(value.prefix { !$0.isNumber && $0 != "$" })
        if !lead.trimmingCharacters(in: .whitespaces).isEmpty, case let b = bound(before: lead), b != .exact { return b }
        let q = quote as NSString
        var r = q.range(of: value, options: .caseInsensitive)
        if r.location == NSNotFound, let figure = value.range(of: #"\$?\s?\d[\d,.]*"#, options: .regularExpression) {
            r = q.range(of: String(value[figure]))
        }
        return r.location == NSNotFound ? .exact : bound(before: q.substring(to: r.location))
    }

    static func fragments(_ quote: String) -> [String] {
        normalized(quote).components(separatedBy: "...").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func verbatim(_ quote: String, in passage: String) -> Bool {
        let parts = fragments(quote)
        guard parts.reduce(0, { $0 + $1.count }) >= 12 else { return false }
        let body = normalized(passage)
        var from = body.startIndex
        for f in parts {
            guard let r = body.range(of: f, range: from..<body.endIndex) else { return false }
            from = r.upperBound
        }
        return true
    }

    /// A value as written in the quote, or the same amount / number / date in another spelling.
    static func present(_ value: String, in quote: String) -> Bool {
        if normalized(quote).localizedCaseInsensitiveContains(normalized(value)) { return true }
        let v = VerifiedAnswerComposer.values(in: value), q = VerifiedAnswerComposer.values(in: quote)
        guard !v.isEmpty else { return false }
        let qn = q.money.union(q.numbers)
        return v.money.allSatisfy { qn.contains($0) } && v.numbers.allSatisfy { qn.contains($0) }
            && v.dates.allSatisfy { d in q.dates.contains { $0.month == d.month && ($0.day == d.day || d.day == nil) && (d.year == nil || $0.year == d.year) } }
    }
}

/// The person's AI passage reader for "Look for conflicts with AI…" when the case is too large to read whole (its
/// passages, under the case's stored permission), injected by the caller (the app's Online provider with its masking,
/// byte cap and consent; the bench's key). No model name here.
public nonisolated struct CaseContradictionReader: Sendable {
    private let generate: @Sendable (String, CloudSourceClearance?) async throws -> String
    public init(generate: @escaping @Sendable (String, CloudSourceClearance?) async throws -> String) { self.generate = generate }

    /// Throws `VerifiedAnswerComposer.NotSent` when nothing was sent.
    public func read(_ prompt: String, clearance: CloudSourceClearance) async throws -> String {
        try await generate(prompt, clearance)
    }
}
