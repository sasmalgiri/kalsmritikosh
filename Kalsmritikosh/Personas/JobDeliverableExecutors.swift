//
//  JobDeliverableExecutors.swift
//  Kalsmritikosh
//
//  Release-block directive 2026-10-29, item 1 — the sixteen jobs B3 had reopened as "preparation"
//  each get the deliverable its contract names, built deterministically over the case's own evidence
//  (read under the job's access context), every row citing the passage it comes from. Nothing here
//  states a conclusion that is the person's: a differing date is "differs", not "lying"; a shared
//  sentence is "one source family by text", not "copied"; a kinship sentence is "stated by", not
//  proven. Each executor blocks with its reason when the case gives it nothing to work from.
//

import Foundation

// MARK: - Shared text helpers

nonisolated enum JobDeliverableText {
    static let stop: Set<String> = ["that", "this", "with", "from", "were", "have", "been", "said", "says", "stated", "told", "wrote",
                                    "which", "their", "there", "would", "could", "should", "about", "into", "than", "then", "them",
                                    "they", "what", "when", "where", "while", "also", "very", "just", "over", "under", "after", "before",
                                    "because", "being", "does", "each", "other", "some", "such", "only", "more", "most", "made", "make"]

    /// The content words of a sentence (lowercased, four letters or more, no stop words, no numbers).
    static func contentWords(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
                .filter { $0.count >= 4 && !stop.contains($0) })
    }

    /// Two sentences are about the same point when they share at least two content words.
    static func sameTopic(_ a: String, _ b: String) -> Bool { contentWords(a).intersection(contentWords(b)).count >= 2 }

    /// The calendar days a sentence states (from the case's stated dates, whose title is the sentence).
    static func days(of sentence: String, _ f: StudioCaseFacts) -> [String] {
        Array(Set(f.statedDates.filter { $0.title == sentence || sentence.contains($0.title) || $0.title.contains(sentence) }
                      .map { JobText.day($0.date) })).sorted()
    }

    /// The amounts a sentence states, as written.
    static func amounts(in sentence: String, _ f: StudioCaseFacts) -> [String] {
        Array(Set(f.statedAmounts.filter { sentence.contains($0.value) }.map(\.value))).sorted()
    }

    /// A sentence normalised for "the same words": lowercased, one space between words, no punctuation.
    static func normalised(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// Money-like figures in free text ("₹1,000", "$2.75 million", "USD 500", "EUR 1.200,50").
    static let figurePattern = #"(?:[₹$€£]\s?\d[\d,]*(?:\.\d+)?|\b(?:USD|EUR|INR|GBP|CHF|JPY|AUD|CAD)\s?\d[\d,]*(?:\.\d+)?|\b\d[\d,]*(?:\.\d+)?\s?(?:million|billion|thousand|crore|lakh)\b)(?:\s?(?:million|billion|thousand|crore|lakh)\b)?"#
    static func figures(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: figurePattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
    }

    /// Attributed statements: each sentence with an attribution, and its speaker when the sentence
    /// ties one to a REPORTING VERB (investigator workflow review 2026-10-30, I6). "Asha Rao was
    /// present when Vikram Rao said the meeting ended" is Vikram's statement, not Asha's; a sentence
    /// whose speaker cannot be tied to a verb is kept UNASSIGNED for the person to attribute.
    static func attributedStatements(_ e: JobEvidence) -> [AttributedStatement] {
        var out: [AttributedStatement] = []
        for doc in e.facts.documents {
            let text = e.texts[doc.objectID] ?? ""
            let author = SpeakerAttribution.fromHeader(text, e.facts.named)
            for s in JobText.sentences(text) where JobText.matches(s, StatementExecutor.attribution) {
                let named = JobText.names(in: s, e.facts.named, persons: true)
                let a = SpeakerAttribution.resolve(s, named: named, author: author)
                // A sentence that names no one and has no author is a quote with no one to attribute it to — skipped.
                guard a.speaker != nil || !named.isEmpty else { continue }
                out.append(AttributedStatement(speaker: a.speaker, sentence: s, doc: doc, basis: a.basis, reported: a.reported, isDenial: a.isDenial))
            }
        }
        return out
    }

    /// Money figures normalised for comparison: currency code + plain number, so "₹10,000",
    /// "INR 10,000", "Rs. 10,000" and "10000 rupees" are the SAME amount while each keeps its wording.
    static func normalisedAmount(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        var currency = ""
        if lower.contains("₹") || lower.contains("inr") || lower.contains("rs.") || lower.hasPrefix("rs ") || lower.contains("rupee") { currency = "INR" }
        else if lower.contains("$") || lower.contains("usd") || lower.contains("dollar") { currency = "USD" }
        else if lower.contains("€") || lower.contains("eur") || lower.contains("euro") { currency = "EUR" }
        else if lower.contains("£") || lower.contains("gbp") || lower.contains("pound") { currency = "GBP" }
        else { for code in ["chf", "jpy", "aud", "cad"] where lower.contains(code) { currency = code.uppercased() } }
        guard let numberRange = t.range(of: #"\d[\d,]*(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        let digits = t[numberRange].replacingOccurrences(of: ",", with: "")
        guard var value = Double(digits) else { return nil }
        if lower.contains("crore") { value *= 10_000_000 }
        else if lower.contains("lakh") { value *= 100_000 }
        else if lower.contains("billion") { value *= 1_000_000_000 }
        else if lower.contains("million") { value *= 1_000_000 }
        else if lower.contains("thousand") { value *= 1_000 }
        let formatted = value == value.rounded() ? String(Int64(value)) : String(value)
        return currency.isEmpty ? formatted : "\(currency) \(formatted)"
    }

    /// The amounts a sentence states, grouped by normalised value → the wordings used.
    static func amountGroups(in sentence: String, _ f: StudioCaseFacts) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        let wordings = Set(amounts(in: sentence, f) + figures(in: sentence))
        for w in wordings { out[normalisedAmount(w) ?? w, default: []].insert(w) }
        return out
    }
}

/// One attributed sentence: who said it (nil = not assigned — for the person to attribute), on what
/// basis, whose words it reports in turn (nested attribution), and whether it is a denial.
public nonisolated struct AttributedStatement: Sendable, Equatable {
    public var speaker: String?
    public var sentence: String
    public var doc: StudioCaseDocument
    public var basis: String
    public var reported: [String]
    public var isDenial: Bool
}

/// Speaker resolution by reporting verb. Rules, in order, for each reporting verb in the sentence:
/// "according to NAME" → NAME; passive "was … VERB by NAME" → NAME; inverted "VERB NAME" after a
/// quote → NAME; otherwise the nearest person named BEFORE the verb, provided only a short
/// appositive (≤ 4 words, no clause boundary, no other name) separates them. The first verb's
/// speaker is the sentence's speaker; later verbs' speakers are people whose words it reports.
/// Anything else is left unassigned with the reason.
public nonisolated enum SpeakerAttribution {
    public static let verbs = #"(?:said|says|stated|states|told|tells|testified|testifies|wrote|writes|explained|explains|admitted|admits|denied|denies|disputed|disputes|alleged|alleges|claimed|claims|confirmed|confirms|recalled|recalls|reported|reports|insisted|insists|maintained|maintains|added|replied|responded|asserted|asserts|according to)"#
    static let denialVerbs: Set<String> = ["denied", "denies", "disputed", "disputes"]
    static let clauseBoundary = #"\b(?:when|while|after|before|because|although|though|that|who|which|whom|where|if|unless|until|and|but|or)\b"#

    public struct Resolution: Sendable, Equatable {
        public var speaker: String?
        public var basis: String
        public var reported: [String]
        public var isDenial: Bool
    }

    /// A document's author from a mail-style header ("From: Asha Rao <…>"), when the case names them.
    static func fromHeader(_ text: String, _ named: [StudioCaseValue]) -> String? {
        let head = String(text.prefix(600))
        guard let line = head.range(of: #"(?m)^\s*From:[^\n]*"#, options: .regularExpression).map({ String(head[$0]) }) else { return nil }
        return named.first { $0.label == "person" && line.range(of: $0.value, options: .caseInsensitive) != nil }?.value
    }

    public static func resolve(_ s: String, named: [String], author: String? = nil) -> Resolution {
        let ns = s as NSString
        guard let verbRe = try? NSRegularExpression(pattern: #"\b"# + verbs + #"\b"#, options: [.caseInsensitive]) else {
            return Resolution(speaker: nil, basis: "attribution not read", reported: [], isDenial: false)
        }
        // Every occurrence of every name, as ranges.
        var nameRanges: [(name: String, range: NSRange)] = []
        for n in named {
            guard let re = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: n) + #"\b"#, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) { nameRanges.append((n, m.range)) }
        }
        nameRanges.sort { $0.range.location < $1.range.location }
        let verbMatches = verbRe.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var isDenial = false
        var speakers: [(String, String)] = []     // (speaker, basis) per resolved verb
        var unresolvedReasons: [String] = []
        for m in verbMatches {
            let verb = ns.substring(with: m.range).lowercased()
            if denialVerbs.contains(verb) { isDenial = true }
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: m.range.location + m.range.length)
            func firstName(in text: String, offset: Int, within limit: Int) -> String? {
                nameRanges.first { $0.range.location >= offset && $0.range.location - offset <= limit }?.name
            }
            if verb == "according to" {
                if let n = firstName(in: after, offset: m.range.location + m.range.length, within: 3) { speakers.append((n, "“according to \(n)”")); continue }
                unresolvedReasons.append("“according to” names no one the case knows"); continue
            }
            // Passive with an agent: "was confirmed by NAME" / "were told by NAME".
            if before.range(of: #"\b(?:was|were|is|are|been|being)\s+(?:\w+ly\s+)?$"#, options: .regularExpression) != nil {
                if after.range(of: #"^\s+by\s+"#, options: .regularExpression) != nil,
                   let byEnd = after.range(of: #"^\s+by\s+"#, options: .regularExpression) {
                    let agentOffset = m.range.location + m.range.length + after.distance(from: after.startIndex, to: byEnd.upperBound)
                    if let n = firstName(in: after, offset: agentOffset, within: 2) { speakers.append((n, "“\(verb) by \(n)”")); continue }
                }
                unresolvedReasons.append("passive “\(verb)” without a named agent"); continue
            }
            // Inverted after a quote: "…,” said NAME".
            if before.range(of: #"[”"’,]\s*$"#, options: .regularExpression) != nil,
               let n = firstName(in: after, offset: m.range.location + m.range.length, within: 2) {
                speakers.append((n, "“\(verb) \(n)” after the quote")); continue
            }
            // First person with a known author: "I told the auditor …" in a mail From: the author.
            if before.range(of: #"\bI\s+(?:\w+ly\s+)?$"#, options: .regularExpression) != nil, let author {
                speakers.append((author, "“I \(verb)” in a document from \(author)")); continue
            }
            // Standard: the nearest name before the verb that is the verb's subject — separated from it
            // only by a short appositive or a bracketed relative clause ("Asha Rao, who hired Dev Sharma,
            // said" is Asha's: Dev is inside the clause, not the subject).
            let preceding = nameRanges.filter { $0.range.location + $0.range.length <= m.range.location }
            var tied: String?
            var nearestSkipped: String?
            for (idx, candidate) in preceding.enumerated().reversed() {
                let end = candidate.range.location + candidate.range.length
                let gap = ns.substring(with: NSRange(location: end, length: m.range.location - end))
                // The text between the previous name (or the start) and this candidate: a relative
                // clause opened there means the candidate sits inside it.
                let leadStart = idx > 0 ? preceding[idx - 1].range.location + preceding[idx - 1].range.length : 0
                let lead = ns.substring(with: NSRange(location: leadStart, length: candidate.range.location - leadStart))
                let insideClause = lead.range(of: #",\s*(?:who|whom|which|that)\b[^,]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
                    && gap.range(of: #"^\s*,"#, options: .regularExpression) != nil
                if insideClause { nearestSkipped = nearestSkipped ?? candidate.name; continue }
                // Drop bracketed clauses and appositives, then the remainder must be short and clause-free.
                let cleaned = gap.replacingOccurrences(of: #",\s*(?:who|whom|which|that)\b[^,]*,"#, with: " ", options: [.regularExpression, .caseInsensitive])
                    .replacingOccurrences(of: #",\s*[^,]{0,60},"#, with: " ", options: .regularExpression)
                let words = cleaned.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
                let boundary = cleaned.range(of: clauseBoundary, options: [.regularExpression, .caseInsensitive]) != nil
                if words.count <= 4, !boundary, !cleaned.contains(".") { tied = candidate.name }
                break
            }
            if let tied { speakers.append((tied, "\(tied) named before “\(verb)”")); continue }
            if let nearest = preceding.last?.name {
                unresolvedReasons.append("“\(verb)” is not tied to \(nearestSkipped ?? nearest) — a clause separates them"); continue
            }
            unresolvedReasons.append("no one is named before “\(verb)”")
        }
        if let first = speakers.first {
            let reported = Array(NSOrderedSet(array: speakers.dropFirst().map(\.0).filter { $0 != first.0 })) as? [String] ?? []
            return Resolution(speaker: first.0, basis: first.1, reported: reported, isDenial: isDenial)
        }
        // A transcript turn: "NAME: …".
        if let turn = named.first(where: { s.range(of: "^\\s*" + NSRegularExpression.escapedPattern(for: $0) + "\\s*:", options: [.regularExpression, .caseInsensitive]) != nil }) {
            return Resolution(speaker: turn, basis: "transcript turn “\(turn):”", reported: [], isDenial: isDenial)
        }
        var basis = "unassigned"
        if !named.isEmpty { basis += " — names \(named.joined(separator: ", ")) but ties no one to the reporting verb" }
        if !unresolvedReasons.isEmpty { basis += " (" + unresolvedReasons.joined(separator: "; ") + ")" }
        return Resolution(speaker: nil, basis: basis, reported: [], isDenial: isDenial)
    }
}

extension JobDeliverableText {

    /// Greedy topic clustering: a statement joins the first topic whose seed shares two content words.
    static func topics(_ sentences: [String]) -> [[Int]] {
        var topics: [[Int]] = []
        for (i, s) in sentences.enumerated() {
            if let t = topics.firstIndex(where: { sameTopic(sentences[$0[0]], s) }) { topics[t].append(i) } else { topics.append([i]) }
        }
        return topics
    }

    static func topicLabel(_ sentences: [String]) -> String {
        guard let first = sentences.first else { return "point" }
        var common = contentWords(first)
        for s in sentences.dropFirst() { common.formIntersection(contentWords(s)) }
        let words = (common.count >= 2 ? common : contentWords(first)).sorted().prefix(3)
        return words.isEmpty ? String(first.prefix(50)) : words.joined(separator: " · ")
    }
}

// MARK: - Human identity merges

extension MergedIdentity {
    /// The pairs whose LAST decision is a confirmation (a later reversal or rejection undoes it).
    public static func confirmedPairs(_ decisions: [IdentityResolutionDecision]) -> [(winner: UUID, loser: UUID, actor: String, at: Date)] {
        var last: [String: IdentityResolutionDecision] = [:]
        for d in decisions.sorted(by: { $0.sequence < $1.sequence }) { last["\(d.winnerEntityID)|\(d.loserEntityID)"] = d }
        return last.values.filter { $0.kind == .mergeConfirmed }.sorted { $0.sequence < $1.sequence }
            .map { ($0.winnerEntityID, $0.loserEntityID, $0.actor, $0.occurredAt) }
    }

    /// One entry per surviving name, with every name form merged into it.
    public static func grouped(_ merges: [MergedIdentity]) -> [MergedIdentity] {
        var out: [String: MergedIdentity] = [:]
        var order: [String] = []
        for m in merges {
            if let existing = out[m.canonical] {
                out[m.canonical] = MergedIdentity(canonical: m.canonical, aliases: existing.aliases + m.aliases.filter { !existing.aliases.contains($0) },
                                                  decidedBy: existing.decidedBy, decidedAt: max(existing.decidedAt, m.decidedAt))
            } else { out[m.canonical] = m; order.append(m.canonical) }
        }
        return order.compactMap { out[$0] }
    }
}

// MARK: - law.parties-issues

public nonisolated enum PartiesIssuesExecutor {
    static let lookalike = "possible same party — not merged (merge only through identity resolution)"

    /// Parties: every person and organisation the documents name, one row per NAME FORM — two forms
    /// become one party only through a confirmed human merge, which the row then records. Issues:
    /// every field the documents state, with the values given and whether the documents disagree.
    public static func run(_ e: JobEvidence) -> JobRun {
        let f = e.facts
        guard !f.named.isEmpty || !f.allFacts.isEmpty else {
            return JobText.blocked("The case's documents name no party and state no fact, so there is no list to build.",
                                   "Add the pleadings or correspondence that name the parties, or record the parties and issues by hand.")
        }
        // Name forms folded into their merged survivor.
        var canonicalOf: [String: MergedIdentity] = [:]
        for m in e.mergedIdentities { for a in m.aliases { canonicalOf[a.lowercased()] = m }; canonicalOf[m.canonical.lowercased()] = m }
        var parties: [(name: String, forms: [String], refs: [StudioEvidenceRef], label: String, merge: MergedIdentity?)] = []
        for n in f.named {
            if let m = canonicalOf[n.value.lowercased()] {
                if let i = parties.firstIndex(where: { $0.name == m.canonical }) {
                    if !parties[i].forms.contains(n.value) { parties[i].forms.append(n.value) }
                    parties[i].refs += n.refs
                } else { parties.append((m.canonical, [n.value], n.refs, n.label, m)) }
            } else { parties.append((n.value, [n.value], n.refs, n.label, nil)) }
        }
        let roles = f.parties   // role fields: plaintiff, defendant, witness …
        var rows: [JobResultRow] = []
        for (i, p) in parties.enumerated() {
            var flags: [String] = []
            var detail: [String] = []
            if let m = p.merge {
                flags.append("merged by a person")
                detail.append("Name forms: " + (p.forms + m.aliases.filter { !p.forms.contains($0) }).joined(separator: "; ")
                              + " — merged by \(m.decidedBy) on \(JobText.day(m.decidedAt)) (reversible)")
            }
            for (j, q) in parties.enumerated() where j != i && p.label == q.label && looksAlike(p.name, q.name) {
                flags.append("\(lookalike): \(q.name)")
            }
            let role = roles.filter { r in p.forms.contains { r.value.range(of: $0, options: .caseInsensitive) != nil } }.map(\.label)
            if !role.isEmpty { detail.append("Role stated: " + Array(Set(role)).sorted().joined(separator: ", ")) }
            rows.append(JobResultRow(title: p.name, detail: detail.isEmpty ? nil : detail.joined(separator: ". "), flags: flags,
                                     refs: Array(p.refs.prefix(4)),
                                     fields: ["kind": "party", "entity": p.name, "claim": role.first.map { "named as \($0)" } ?? ""]))
        }
        // Issues: each stated field, the values given, disagreement kept.
        let conflicts = IssueMatrixExecutor.conflictingLabels(f)
        var byLabel: [String: [StudioCaseValue]] = [:]
        var order: [String] = []
        for v in f.allFacts where !StudioCaseFactsReader.partyFields.contains(v.label) {
            if byLabel[v.label] == nil { order.append(v.label) }
            byLabel[v.label, default: []].append(v)
        }
        for label in order {
            let values = byLabel[label] ?? []
            var seen = Set<String>()
            let distinct = values.filter { seen.insert(IssueMatrixExecutor.key($0.value)).inserted }
            var flags: [String] = []
            if conflicts[label] != nil { flags.append("disputed between documents: " + distinct.map(\.value).joined(separator: " / ")) }
            rows.append(JobResultRow(title: "Issue: \(label)", detail: "Stated as: " + distinct.map(\.value).prefix(6).joined(separator: "; "),
                                     flags: flags, refs: Array(values.flatMap(\.refs).prefix(4)),
                                     fields: ["kind": "issue", "claim": label]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("Two name forms are listed as two parties until you merge them in identity resolution; a merge is recorded here with who made it and is reversible.")
        var next = ["Frame each issue; link each party row to its canonical entity and claim."]
        if rows.contains(where: { $0.flags.contains { $0.hasPrefix(lookalike) } }) { next.insert("Decide each look-alike pair in identity resolution (merge or keep separate).", at: 0) }
        return (.draft, JobResultContent(rows: rows, limitations: limitations, nextActions: next))
    }

    static func looksAlike(_ a: String, _ b: String) -> Bool {
        let ta = Set(a.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) })
        let tb = Set(b.lowercased().split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) })
        if ta.isSubset(of: tb) || tb.isSubset(of: ta) { return true }
        if let sa = ta.sorted().last, let sb = tb.sorted().last, a.split(separator: " ").last?.lowercased() == b.split(separator: " ").last?.lowercased(),
           sa.count >= 3, sb.count >= 3 { return true }
        return false
    }
}

// MARK: - res.chronology (periodisation; uncertain dates keep their range)

public nonisolated enum PeriodChronologyExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let base = ChronologyExecutor.run(e.facts)
        guard base.state == .draft else { return base }
        var rows = base.content.rows
        for ev in e.facts.events where ev.isUncertain {
            let start = JobText.day(ev.date)
            guard let i = rows.firstIndex(where: { $0.title == ev.title && $0.date == start }) else { continue }
            let range: String
            if let end = ev.endDate { range = "\(start) – \(JobText.day(end))" }
            else { range = ev.precision.renderPhrase(date: ev.date) }
            rows[i].flags.append("uncertain date — range kept: \(range)")
            var fields = rows[i].fields ?? [:]
            fields["period"] = range
            fields["dated"] = ev.endDate != nil ? "range \(range)" : "\(ev.precision.displayName) precision — \(range)"
            rows[i].fields = fields
            rows[i].detail = ([rows[i].detail] + ["Dated \(range) (\(ev.precision.displayName) precision)"]).compactMap { $0 }.joined(separator: ". ")
        }
        var limitations = base.content.limitations
        limitations.append("An event the document dates to a year, a decade or a span is placed at the start of that range and keeps the range; it is never narrowed to one day.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Name the periods; an event with an uncertain date belongs to every period its range touches."] + base.content.nextActions))
    }
}

// MARK: - ind.career-education (gaps shown as gaps)

public nonisolated enum CareerExecutor {
    static let words = #"\b(joined|appointed|employed|employer|employment|worked|works|working|hired|promoted|resigned|retired|dismissed|left|position|role|graduated|graduate|degree|diploma|studied|enrolled|enrolment|admitted|university|college|school|institute|apprentice|internship|training|certified|qualified)\b"#
    /// A gap longer than this between the END of one entry (left, resigned, graduated …) and the next
    /// dated entry is shown as a gap. The span between a start ("joined") and its end is a tenure,
    /// not a gap.
    public static let gapDays = 180
    static let ends = #"\b(left|resigned|retired|dismissed|graduated|completed|ended|terminated|expired|concluded)\b"#

    public static func run(_ e: JobEvidence) -> JobRun {
        let f = e.facts
        // A career or education entry is about a person: the sentence names one, or speaks as or of
        // one ("I joined …", "She graduated …"). "We expect the certified material on …" is not an
        // entry (UI journey 2026-10-30, sample archive).
        func aboutAPerson(_ s: String) -> Bool {
            !JobText.names(in: s, f.named, persons: true).isEmpty || JobText.matches(s, #"\b(?:I|he|she|my|his|her)\b"#)
        }
        var entries: [(date: Date, title: String, refs: [StudioEvidenceRef])] = []
        for ev in f.events where JobText.matches(ev.title, words) && aboutAPerson(ev.title) { entries.append((ev.date, ev.title, ev.refs)) }
        for d in f.statedDates where JobText.matches(d.title, words) && aboutAPerson(d.title) && !entries.contains(where: { $0.title == d.title && $0.date == d.date }) {
            entries.append((d.date, d.title, d.refs))
        }
        guard !entries.isEmpty else {
            return JobText.blocked("The case's documents date no career or education entry (no sentence about a post, employer, course or qualification carries a date).",
                                   "Add the CV, contracts, certificates or letters that date the entries, or record them by hand.")
        }
        entries.sort { $0.date == $1.date ? $0.title < $1.title : $0.date < $1.date }
        var rows: [JobResultRow] = []
        var gaps = 0
        for (i, en) in entries.enumerated() {
            if i > 0 {
                let prev = entries[i - 1]
                let days = Calendar(identifier: .gregorian).dateComponents([.day], from: prev.date, to: en.date).day ?? 0
                if days > gapDays, JobText.matches(prev.title, ends) {
                    gaps += 1
                    rows.append(JobResultRow(title: "Gap: \(JobText.day(prev.date)) to \(JobText.day(en.date)) (\(days) days) — no dated record",
                                             detail: "Between “\(prev.title.prefix(80))” and “\(en.title.prefix(80))”.",
                                             date: JobText.day(prev.date), flags: ["gap — no document covers this period"],
                                             refs: Array((prev.refs + en.refs).prefix(4))))
                }
            }
            let names = JobText.names(in: en.title, f.named, persons: true)
            rows.append(JobResultRow(title: en.title, detail: names.isEmpty ? nil : "Names: " + names.joined(separator: ", "),
                                     date: JobText.day(en.date), flags: en.refs.isEmpty ? ["no source"] : [], refs: en.refs))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        let other = f.events.count + f.statedDates.count - entries.count
        if other > 0 { limitations.append("\(other) dated item(s) in the case are not career or education entries and are left out of this chronology.") }
        limitations.append("A gap is more than \(gapDays) days between an entry that ends something (left, resigned, graduated …) and the next dated entry; a start without a dated end is not a gap. It is the absence of a dated record, not a finding about what the person did.")
        var next = ["Confirm each entry against its document."]
        if gaps > 0 { next.insert("Account for \(gaps) gap(s): obtain the records for the period, or record that none exists.", at: 0) }
        return (.draft, JobResultContent(rows: rows, limitations: limitations, nextActions: next))
    }
}

// MARK: - law.document-coding (coding controls production)

public nonisolated enum DocumentCodingExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let f = e.facts
        guard !f.documents.isEmpty else {
            return JobText.blocked("The case has no documents in scope, so there is nothing to code.", "Include the matter's documents in the case's scope.")
        }
        var rows: [JobResultRow] = []
        for doc in f.documents {
            let text = e.texts[doc.objectID] ?? ""
            let labels = Array(Set(f.allFacts.filter { v in v.refs.contains { JobText.document(of: $0, in: f.documents)?.objectID == doc.objectID } }.map(\.label))).sorted()
            let names = f.named.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map(\.value)
            var flags = ["not coded — relevance and privilege are the reviewer's"]
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flags.append("unreadable — code from the native file") }
            var detail: [String] = []
            if !labels.isEmpty { detail.append("Candidate issue codes (fields the document states): " + labels.joined(separator: ", ")) }
            if !names.isEmpty { detail.append("Names: " + names.prefix(6).joined(separator: ", ")) }
            rows.append(JobResultRow(title: doc.name, detail: detail.isEmpty ? nil : detail.joined(separator: ". "), flags: flags,
                                     refs: [JobText.ref(doc, JobText.sentences(text).first ?? doc.name)]))
        }
        var limitations = JobText.withheldLimitation(e.withheld).map { $0 + " They are already outside any production." }
        limitations.append("A document coded privileged or partly privileged here is withheld from every production built in this ledger: it gets a slip sheet and a privilege-log line, never its text or native. A partly privileged document needs a redacted copy produced separately.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Code each document (issue codes, relevance, privilege); the coding takes effect on the next production run."]))
    }
}

/// What a coding result withholds from production.
public nonisolated enum DocumentCodingProduction {
    public static let withholdingCodes: Set<String> = ["privileged", "partly privileged"]

    /// The documents (knowledge-object ids) coded privileged or partly privileged. A rejected row
    /// codes nothing; an undecided or accepted row with the code withholds (fail closed).
    public static func withheld(in rows: [JobResultRow]) -> Set<UUID> {
        var out = Set<UUID>()
        for r in rows where r.decision != .rejected && withholdingCodes.contains(r.fields?["privilege"] ?? "") {
            out.formUnion(r.refs.compactMap(\.objectID))
        }
        return out
    }
}

// MARK: - hr.statements (points × witnesses)

public nonisolated enum StatementComparisonExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let statements = JobDeliverableText.attributedStatements(e)
        guard !statements.isEmpty else {
            return JobText.blocked("The case's documents contain no statement attributed to a named person, so there are no accounts to compare.",
                                   "Add the statements, interview notes or emails in which each witness gives their account.")
        }
        let witnesses = Array(NSOrderedSet(array: statements.compactMap(\.speaker))) as? [String] ?? []
        let topics = JobDeliverableText.topics(statements.map(\.sentence))
        var rows: [JobResultRow] = []
        var unassigned = 0
        for (t, members) in topics.enumerated() {
            let label = "Point \(t + 1): " + JobDeliverableText.topicLabel(members.map { statements[$0].sentence })
            // What each witness states on this point: days and amounts (normalised value → wordings).
            var byWitness: [String: (days: Set<String>, amounts: [String: Set<String>], items: [Int], denial: Bool)] = [:]
            for i in members {
                let s = statements[i]
                guard let speaker = s.speaker else {
                    // Unassigned: kept for the person to attribute — never given to the nearest name.
                    unassigned += 1
                    rows.append(JobResultRow(title: "\(label) — speaker unassigned", detail: "“\(s.sentence)”",
                                             flags: ["verbatim", "attribution \(s.basis)", "assign the speaker before comparing"],
                                             refs: [JobText.ref(s.doc, s.sentence)],
                                             fields: ["point": label, "witness": "", "comparison": "", "event": ""]))
                    continue
                }
                var w = byWitness[speaker] ?? ([], [:], [], false)
                w.days.formUnion(JobDeliverableText.days(of: s.sentence, e.facts))
                for (norm, words) in JobDeliverableText.amountGroups(in: s.sentence, e.facts) { w.amounts[norm, default: []].formUnion(words) }
                w.items.append(i)
                w.denial = w.denial || s.isDenial
                byWitness[speaker] = w
            }
            for name in witnesses {
                guard let w = byWitness[name] else {
                    let p = e.facts.named.first { $0.value == name }
                    rows.append(JobResultRow(title: "\(label) — \(name)", detail: "No statement by \(name) on this point.", flags: ["silent"],
                                             refs: Array((p?.refs ?? []).prefix(1)),
                                             fields: ["point": label, "witness": name, "comparison": "silent", "event": label]))
                    continue
                }
                var flags: [String] = []
                var differs = false, same = false
                func wording(_ g: [String: Set<String>]) -> String { g.keys.sorted().map { g[$0]!.sorted().joined(separator: " = ") }.joined(separator: ", ") }
                for (other, o) in byWitness where other != name {
                    if !w.days.isEmpty, !o.days.isEmpty {
                        if w.days == o.days { same = true; flags.append("states the same date as \(other) (\(w.days.sorted().joined(separator: ", "))) — the same date, not necessarily the same event") }
                        else { differs = true; flags.append("differs from \(other) on date: \(w.days.sorted().joined(separator: ", ")) vs \(o.days.sorted().joined(separator: ", "))") }
                    }
                    if !w.amounts.isEmpty, !o.amounts.isEmpty {
                        if Set(w.amounts.keys) == Set(o.amounts.keys) {
                            same = true
                            flags.append("states the same amount as \(other) (\(wording(w.amounts))\(wording(w.amounts) == wording(o.amounts) ? "" : "; \(other) writes \(wording(o.amounts))")) — the same figure, not agreement on what happened")
                        } else { differs = true; flags.append("differs from \(other) on amount: \(wording(w.amounts)) vs \(wording(o.amounts))") }
                    }
                    if w.denial != o.denial, same {
                        differs = true
                        flags.append(w.denial ? "denies what \(other) asserts — the shared figures do not make this agreement"
                                              : "asserts what \(other) denies — the shared figures do not make this agreement")
                    }
                }
                if w.denial { flags.append("denial") }
                let comparison = differs ? "differs" : (same ? "agrees" : "")
                let quotes = w.items.map { statements[$0].sentence }
                let bases = Set(w.items.map { statements[$0].basis })
                let reported = Set(w.items.flatMap { statements[$0].reported })
                if !reported.isEmpty { flags.append("reports words of \(reported.sorted().joined(separator: ", ")) — nested attribution") }
                rows.append(JobResultRow(title: "\(label) — \(name)", detail: quotes.map { "“\($0)”" }.joined(separator: " "),
                                         flags: ["verbatim", "speaker: " + bases.sorted().joined(separator: "; ")] + flags,
                                         refs: w.items.map { JobText.ref(statements[$0].doc, statements[$0].sentence) },
                                         fields: ["point": label, "witness": name, "comparison": comparison, "event": label]))
            }
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if witnesses.count == 1 { limitations.append("Only one witness gives an attributed account; there is no second account to compare it with.") }
        if unassigned > 0 { limitations.append("\(unassigned) statement(s) name people but tie none of them to the reporting verb; they are left unassigned for you to attribute, not given to the nearest name.") }
        limitations.append("A speaker is read from the reporting verb (“X said”, “according to X”, “confirmed by X”, “said X” after a quote); a point groups statements by shared words, which can put two different events together — correct the point or the event field. “Same date/amount” means the same figure in both statements, not that they describe the same event or agree in meaning; a denial and an assertion that share a figure are shown as differing. Wording and meaning are yours to assess. A statement is what someone said, not what happened.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Assign any unassigned speaker; correct the point or event where two statements are about different things; then assess each point (agrees, differs, silent) against the quotes — corrections are added as new entries, never over the original."]))
    }
}

// MARK: - law.witness-profiles (inconsistent statements both quoted)

public nonisolated enum WitnessProfileExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let persons = e.facts.named.filter { $0.label == "person" }
        guard !persons.isEmpty else {
            return JobText.blocked("The case's documents name no person, so there is no witness to profile.", "Add the statements and correspondence that name the witnesses.")
        }
        let statements = JobDeliverableText.attributedStatements(e)
        var rows: [JobResultRow] = []
        for p in persons {
            let mine = statements.enumerated().filter { $0.element.speaker == p.value }
            let ambiguous = statements.filter { $0.speaker == nil && $0.sentence.range(of: p.value, options: .caseInsensitive) != nil }.count
            // Documents: authored (From line or "X wrote/said" opening), received (To line), or merely naming.
            var authored: [String] = [], received: [String] = [], naming: [String] = []
            for doc in e.facts.documents {
                let text = e.texts[doc.objectID] ?? ""
                guard text.range(of: p.value, options: .caseInsensitive) != nil else { continue }
                let head = String(text.prefix(600))
                let name = NSRegularExpression.escapedPattern(for: p.value)
                if JobText.matches(head, #"(?m)^\s*From:.*"# + name) || JobText.matches(JobText.sentences(text).first ?? "", "^" + name + #"\b.{0,20}\b(wrote|said|states|stated)\b"#) { authored.append(doc.name) }
                else if JobText.matches(head, #"(?m)^\s*(To|Cc):.*"# + name) { received.append(doc.name) }
                else { naming.append(doc.name) }
            }
            let docs = [authored.isEmpty ? nil : "authored: " + authored.joined(separator: ", "), received.isEmpty ? nil : "received: " + received.joined(separator: ", "),
                        naming.isEmpty ? nil : "names \(p.value): " + naming.joined(separator: ", ")].compactMap { $0 }.joined(separator: "; ")
            // Inconsistencies: two statements by the same witness on the same point with different dates or amounts.
            var inconsistencies: [JobResultRow] = []
            for (x, a) in mine { for (y, b) in mine where y > x && JobDeliverableText.sameTopic(a.sentence, b.sentence) {
                let da = JobDeliverableText.days(of: a.sentence, e.facts), db = JobDeliverableText.days(of: b.sentence, e.facts)
                let aa = JobDeliverableText.amounts(in: a.sentence, e.facts), ab = JobDeliverableText.amounts(in: b.sentence, e.facts)
                var what: [String] = []
                if !da.isEmpty, !db.isEmpty, da != db { what.append("date \(da.joined(separator: ", ")) vs \(db.joined(separator: ", "))") }
                if !aa.isEmpty, !ab.isEmpty, aa != ab { what.append("amount \(aa.joined(separator: ", ")) vs \(ab.joined(separator: ", "))") }
                guard !what.isEmpty else { continue }
                let text = "“\(a.sentence)” (\(a.doc.name)) vs “\(b.sentence)” (\(b.doc.name))"
                inconsistencies.append(JobResultRow(title: "Inconsistency — \(p.value): \(what.joined(separator: "; "))", detail: text,
                                                    flags: ["both statements quoted", "inconsistent on \(what.map { String($0.split(separator: " ")[0]) }.joined(separator: ", "))"],
                                                    refs: [JobText.ref(a.doc, a.sentence), JobText.ref(b.doc, b.sentence)],
                                                    fields: ["statements": text, "documents": docs.isEmpty ? "none" : docs, "inconsistencies": what.joined(separator: "; ")]))
            } }
            let quotes = mine.map { "“\($0.element.sentence)”" }
            var flags: [String] = mine.isEmpty ? ["no attributed statement in the documents"] : ["\(mine.count) statement(s) quoted verbatim"]
            if ambiguous > 0 { flags.append("\(ambiguous) statement(s) name \(p.value) without tying them to the reporting verb — unassigned, attribute by hand") }
            if inconsistencies.isEmpty { flags.append("no date or amount inconsistency found between the statements") }
            rows.append(JobResultRow(title: p.value, detail: quotes.isEmpty ? "Named in: \(([authored, received, naming].flatMap { $0 }).joined(separator: ", "))" : quotes.joined(separator: " "),
                                     flags: flags, refs: mine.isEmpty ? Array(p.refs.prefix(2)) : mine.map { JobText.ref($0.element.doc, $0.element.sentence) },
                                     fields: ["statements": quotes.isEmpty ? "none attributed" : quotes.joined(separator: " | "),
                                              "documents": docs.isEmpty ? "none" : docs,
                                              "inconsistencies": inconsistencies.isEmpty ? "none found by date/amount comparison" : inconsistencies.map(\.title).joined(separator: "; ")]))
            rows += inconsistencies
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("Authorship is read from From/To lines and an opening “X wrote/said”; a document that only names the witness is listed as naming them. A statement's speaker is read from its reporting verb; a sentence that names the witness without tying them to the verb is not counted as theirs. Inconsistencies are found on dates and amounts only; wording is yours to compare.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Assess each witness from the quotes; an inconsistency is a difference to put to them, not a finding of untruth."]))
    }
}

// MARK: - law.deposition, siu.euo-prep (every question tied to its passage)

public nonisolated enum SourcedQuestionsExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let persons = e.facts.named.filter { $0.label == "person" }
        let conflicts = IssueMatrixExecutor.conflictingLabels(e.facts)
        guard !persons.isEmpty || !conflicts.isEmpty else {
            return JobText.blocked("The case's documents name no person and state no disputed fact, so no question can be tied to a passage.",
                                   "Add the documents the examination will cover; questions are written against their passages.")
        }
        var rows: [JobResultRow] = []
        for p in persons {
            for doc in e.facts.documents {
                for s in JobText.sentences(e.texts[doc.objectID] ?? "") where s.range(of: p.value, options: .caseInsensitive) != nil {
                    let q = "Put to \(p.value): “\(s.prefix(160))\(s.count > 160 ? "…" : "")” — confirm, deny or explain."
                    rows.append(JobResultRow(title: q, detail: "\(doc.name) · \(p.value)", flags: ["question tied to its passage"],
                                             refs: [JobText.ref(doc, s)],
                                             fields: ["topic": "\(p.value) — \(doc.name)", "topics": "\(p.value) — \(doc.name)", "questions": q,
                                                      "exhibits": doc.name, "documents": doc.name]))
                }
            }
        }
        // Disputed points: both sources shown.
        var byLabel: [String: [String: [StudioEvidenceRef]]] = [:]
        for v in e.facts.allFacts + e.facts.statedAmounts.map({ StudioCaseValue(value: $0.value, label: "amount", refs: $0.refs) }) where conflicts[v.label] != nil {
            byLabel[v.label, default: [:]][v.value, default: []] += v.refs
        }
        for (label, values) in byLabel.sorted(by: { $0.key < $1.key }) where values.count > 1 {
            let parts = values.sorted { $0.key < $1.key }.map { value, refs -> String in
                let docs = Set(refs.compactMap { JobText.document(of: $0, in: e.facts.documents)?.name }).sorted().joined(separator: ", ")
                return "\(value) (\(docs.isEmpty ? "source not named" : docs))"
            }
            let refs = values.sorted { $0.key < $1.key }.compactMap { $0.value.first }
            rows.append(JobResultRow(title: "Disputed point: \(label) — " + values.keys.sorted().joined(separator: " vs "),
                                     detail: "Both sources: " + parts.joined(separator: "; "), flags: ["disputed — both sources shown"], refs: refs,
                                     fields: ["topic": "Disputed: \(label)", "topics": "Disputed: \(label)", "disputed": parts.joined(separator: "; "),
                                              "questions": "Which is right: " + parts.joined(separator: " or ") + "?"]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("Every question here is written against one passage and cites it; a question you add without a passage cannot be accepted until a source is linked.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Order the outline; put each disputed point with both sources.",
                                                       "An unanswered question is recorded as unanswered, never as an admission."]))
    }
}

// MARK: - fa.workpapers (every report figure traces to a workpaper)

public nonisolated enum WorkpaperExecutor {
    public static let untraced = "untraced — no workpaper states this figure"

    public static func run(_ e: JobEvidence) -> JobRun {
        let amounts = e.facts.statedAmounts
        guard !amounts.isEmpty || !e.exports.isEmpty else {
            return JobText.blocked("The case's documents state no amount and no report has been exported, so there is no figure to trace.",
                                   "Add the records that carry the amounts; export the report whose figures must trace.")
        }
        var rows: [JobResultRow] = []
        var papers: [(key: String, id: String, refs: [StudioEvidenceRef])] = []
        for (i, a) in amounts.enumerated() {
            let id = String(format: "WP-%03d", i + 1)
            let doc = a.refs.compactMap { JobText.document(of: $0, in: e.facts.documents)?.name }.first ?? "document"
            papers.append((IssueMatrixExecutor.key(a.value), id, a.refs))
            rows.append(JobResultRow(title: "\(id): \(a.value)", detail: a.refs.first?.quote, flags: ["workpaper — stated amount"], refs: a.refs,
                                     fields: ["calculation": "Stated amount as written in \(doc) (no computation)", "inputs": a.value]))
        }
        var traced = 0, untracedCount = 0
        for export in e.exports {
            for fig in Array(NSOrderedSet(array: JobDeliverableText.figures(in: export.text))) as? [String] ?? [] {
                let k = IssueMatrixExecutor.key(fig)
                if let wp = papers.first(where: { $0.key == k }) {
                    traced += 1
                    rows.append(JobResultRow(title: "Report figure \(fig) — \(export.title)", detail: "Traces to \(wp.id).", flags: ["traces to \(wp.id)"], refs: wp.refs,
                                             fields: ["calculation": "Report figure, traced to \(wp.id)", "inputs": fig]))
                } else {
                    untracedCount += 1
                    rows.append(JobResultRow(title: "Report figure \(fig) — \(export.title)", detail: "No workpaper states this figure.", flags: [untraced],
                                             fields: ["calculation": "Report figure — untraced", "inputs": fig]))
                }
            }
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if e.exports.isEmpty { limitations.append("No report has been exported for this case yet; its figures will be listed for tracing once one is.") }
        limitations.append("A figure traces when a workpaper states the same amount; a computed figure (a sum, a difference) needs a workpaper you add with its calculation and inputs.")
        var next = ["Sign off each workpaper after checking its inputs against the source."]
        if untracedCount > 0 { next.insert("Add a workpaper for each of the \(untracedCount) untraced figure(s), or correct the report.", at: 0) }
        if traced > 0 { next.append("\(traced) report figure(s) trace to a workpaper.") }
        return (.draft, JobResultContent(rows: rows, limitations: limitations, nextActions: next))
    }
}

// MARK: - jrn.source-map (source families by shared text)

public nonisolated enum SourceFamilyExecutor {
    static let minimumSharedLength = 60
    /// Content-word overlap at or above which two long sentences are "similar wording" (a rewrite).
    static let similarityThreshold = 0.6
    /// Routine notices that documents share without any relationship between them.
    static let boilerplatePattern = #"(?i)\b(?:confidential|intended (?:solely )?for|intended recipient|unsubscribe|all rights reserved|copyright|privacy policy|terms of (?:use|service)|disclaimer|do not reply|legal notice|received (?:this )?in error|notify the sender|this (?:e-?mail|message|communication))\b|©"#

    public static let unassessedFamily = "No shared text detected; independence unassessed"
    public static let noSharedText = "no shared text detected; independence unassessed"
    public static let sharedText = "shared text detected; possible relationship"

    /// Text-similarity CANDIDATES only (investigator workflow review 2026-10-30, I7): documents sharing
    /// a long identical sentence, or near-identical wording, are grouped as a possible relationship;
    /// documents sharing nothing are "independence unassessed", never "independent". Routine
    /// boilerplate — a notice most documents carry, or a standard legal/e-mail footer — is excluded
    /// before grouping. The person's confirmed lineage is a separate field with its rationale.
    public static func run(_ e: JobEvidence) -> JobRun {
        let docs = e.facts.documents
        guard !docs.isEmpty else {
            return JobText.blocked("The case has no documents in scope, so there is no source to map.", "Include the sources in the case's scope.")
        }
        // Long sentences per document, normalised; count in how many documents each appears.
        var perDoc: [UUID: [String]] = [:]
        var docCount: [String: Int] = [:]
        for d in docs {
            let longOnes = Array(Set(JobText.sentences(e.texts[d.objectID] ?? "").filter { $0.count >= minimumSharedLength }.map(JobDeliverableText.normalised)))
            perDoc[d.objectID] = longOnes
            for s in longOnes { docCount[s, default: 0] += 1 }
        }
        // Boilerplate: a standard notice by its words, or a sentence carried by most documents (3+).
        func isBoilerplate(_ s: String) -> Bool {
            if s.range(of: boilerplatePattern, options: .regularExpression) != nil { return true }
            let n = docCount[s] ?? 0
            return n >= 3 && Double(n) > Double(docs.count) / 2
        }
        var boilerplateCount: [UUID: Int] = [:]
        let candidates: [UUID: [String]] = Dictionary(uniqueKeysWithValues: docs.map { d in
            let all = perDoc[d.objectID] ?? []
            let kept = all.filter { !isBoilerplate($0) }
            boilerplateCount[d.objectID] = all.count - kept.count
            return (d.objectID, kept)
        })
        let words: [String: Set<String>] = Dictionary(uniqueKeysWithValues: Set(candidates.values.flatMap { $0 }).map { ($0, JobDeliverableText.contentWords($0)) })
        // Union-find over documents sharing an identical long sentence or similar wording.
        var parent: [UUID: UUID] = Dictionary(uniqueKeysWithValues: docs.map { ($0.objectID, $0.objectID) })
        func find(_ x: UUID) -> UUID { var x = x; while parent[x] != x { x = parent[x]! }; return x }
        var identical: [UUID: [(UUID, Int)]] = [:]
        var similar: [UUID: [(UUID, Int)]] = [:]
        for i in docs.indices { for j in docs.indices where j > i {
            let a = docs[i].objectID, b = docs[j].objectID
            let sa = candidates[a] ?? [], sb = candidates[b] ?? []
            let same = Set(sa).intersection(sb)
            var near = 0
            for x in sa where !same.contains(x) { for y in sb where !same.contains(y) {
                let wx = words[x] ?? [], wy = words[y] ?? []
                guard !wx.isEmpty, !wy.isEmpty else { continue }
                let overlap = Double(wx.intersection(wy).count) / Double(wx.union(wy).count)
                if overlap >= similarityThreshold { near += 1 }
            } }
            guard !same.isEmpty || near > 0 else { continue }
            if !same.isEmpty { identical[a, default: []].append((b, same.count)); identical[b, default: []].append((a, same.count)) }
            if near > 0 { similar[a, default: []].append((b, near)); similar[b, default: []].append((a, near)) }
            parent[find(a)] = find(b)
        } }
        var familyNumber: [UUID: Int] = [:]
        var next = 1
        var rows: [JobResultRow] = []
        func name(_ id: UUID) -> String { docs.first { $0.objectID == id }?.name ?? id.uuidString }
        for doc in docs {
            let root = find(doc.objectID)
            let exact = identical[doc.objectID] ?? [], near = similar[doc.objectID] ?? []
            let related = !exact.isEmpty || !near.isEmpty
            var flags: [String] = ["not assessed"]
            if !exact.isEmpty { flags.append("repeats text of \(exact.map { name($0.0) }.joined(separator: ", ")) — \(sharedText), not proof of common origin") }
            if !near.isEmpty { flags.append("similar wording to \(near.map { name($0.0) }.joined(separator: ", ")) — possible rewrite; review as potentially dependent") }
            if let b = boilerplateCount[doc.objectID], b > 0 { flags.append("\(b) boilerplate sentence(s) excluded from grouping") }
            let family: String
            if related {
                if familyNumber[root] == nil { familyNumber[root] = next; next += 1 }
                family = "Family \(familyNumber[root]!) — \(sharedText)"
            } else {
                family = unassessedFamily
            }
            let quote = JobText.sentences(e.texts[doc.objectID] ?? "").first ?? doc.name
            var detailParts: [String] = []
            if !exact.isEmpty { detailParts.append("Identical text with: " + exact.map { "\(name($0.0)) (\($0.1) sentence(s))" }.joined(separator: "; ")) }
            if !near.isEmpty { detailParts.append("Similar wording to: " + near.map { "\(name($0.0)) (\($0.1) near-identical sentence(s))" }.joined(separator: "; ")) }
            if !related { detailParts.append("No sentence of \(minimumSharedLength)+ characters is shared with or similar to another case document (boilerplate excluded). That does not establish independence.") }
            rows.append(JobResultRow(title: doc.name, detail: detailParts.joined(separator: " "), flags: flags, refs: [JobText.ref(doc, quote)],
                                     fields: ["family": family]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("“Shared text detected” means the same long sentences, or near-identical wording, appear in both sources — a candidate relationship (a wire story repeated, a rewrite), not proof of a common origin. “No shared text detected” means only that; it does not establish independence. Standard notices and footers most documents carry are excluded before grouping. Your confirmed lineage, with its rationale, is recorded separately in the Lineage field and the note.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Decide each source's lineage (independent, same origin, derivative, unknown) with the rationale in the note; record its relationship to the story and its protection; count one origin once when weighing corroboration."]))
    }
}

// MARK: - jrn.source-vault (protected identities never in exports or AI payloads)

public nonisolated enum SourceVaultExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let docs = e.facts.documents
        guard !docs.isEmpty else {
            return JobText.blocked("The case has no documents in scope, so there is no original to vault.", "Include the originals in the case's scope.")
        }
        var rows: [JobResultRow] = []
        for doc in docs {
            let names = e.facts.named.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map(\.value)
            let hash = doc.sourceVersionID.flatMap { e.versionHashes[$0] }
            var flags = [hash == nil ? "no exact version — hash unavailable" : "original hashed (SHA-256)"]
            flags.append("protection not recorded")
            let quote = JobText.sentences(e.texts[doc.objectID] ?? "").first ?? doc.name
            rows.append(JobResultRow(title: doc.name, detail: names.isEmpty ? nil : "Names: " + names.prefix(6).joined(separator: ", "),
                                     flags: flags, refs: [JobText.ref(doc, quote)]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("A source you mark protected needs its identity recorded here; that name is then kept out of every job-result and studio export of this ledger and masked in every cloud AI request (a request in which it would survive masking is not sent).")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Mark each protected source and record its identity; note each access to an original."]))
    }
}

/// The identities a source vault protects, read from its rows.
public nonisolated enum ProtectedIdentities {
    /// Names recorded as protected (a rejected row protects nothing; an undecided one does — fail closed).
    public static func names(in rows: [JobResultRow]) -> [String] {
        var out: [String] = []
        for r in rows where r.decision != .rejected && r.fields?["protected"] == "yes" {
            for part in (r.fields?["identity"] ?? "").split(separator: ";") {
                let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count >= 2, !out.contains(name) { out.append(name) }
            }
        }
        return out
    }

    /// Replace every protected name in `text`; returns nil when a name is still recoverable afterwards.
    public static func scrub(_ text: String, names: [String], token: String = "[PROTECTED SOURCE]") -> (text: String, leaks: [RedactionVerifier.Leak]) {
        guard !names.isEmpty else { return (text, []) }
        let redacted = PIIRedactor().redact(text, policy: RedactionPolicy(redactEmails: false, redactPhones: false, customTerms: names, token: token)).redactedText
        return (redacted, RedactionVerifier().leaks(in: redacted, protectedTerms: names, artifact: "export"))
    }
}

// MARK: - res.transcription (translation linked to original and transcription)

public nonisolated enum TranscriptionExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        var rows: [JobResultRow] = []
        var attributed = 0
        for doc in e.facts.documents {
            let sentences = JobText.sentences(e.texts[doc.objectID] ?? "")
            let quoted = sentences.filter { JobText.matches($0, StatementExecutor.attribution) }
            attributed += quoted.count
            let chosen = quoted.isEmpty ? Array(sentences.prefix(60)) : quoted
            for s in chosen {
                let lineage = ["original: \(doc.name)", doc.sourceVersionID.map { "version \($0.uuidString)" },
                               doc.sourceVersionID.flatMap { e.versionHashes[$0] }.map { "sha256 \($0.prefix(16))…" }].compactMap { $0 }.joined(separator: " · ")
                rows.append(JobResultRow(title: s, detail: doc.name, flags: [quoted.isEmpty ? "passage" : "verbatim statement"], refs: [JobText.ref(doc, s)],
                                         fields: ["original": s, "lineage": lineage]))
            }
        }
        guard !rows.isEmpty else {
            return JobText.blocked("The case's documents have no readable passage to transcribe or code.", "Add the recordings' transcripts, letters or notes as documents.")
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if attributed == 0 { limitations.append("No sentence is attributed to a speaker; every readable passage is listed instead.") }
        limitations.append("Each row is one passage: its original (cited), your transcription, and a translation only together with the transcription it was made from — the lineage original → transcription → translation stays on the row and in every export.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Transcribe and code each passage; a translation is entered beside its transcription, never instead of it."]))
    }
}

// MARK: - res.alternative (opposing accounts, each cited)

public nonisolated enum AlternativeAccountsExecutor {
    public static func run(_ e: JobEvidence) -> JobRun {
        let f = e.facts
        let conflicts = IssueMatrixExecutor.conflictingLabels(f)
        var rows: [JobResultRow] = []
        var byLabel: [String: [String: [StudioEvidenceRef]]] = [:]
        var order: [String] = []
        for v in f.allFacts + f.statedAmounts.map({ StudioCaseValue(value: $0.value, label: "amount", refs: $0.refs) }) where conflicts[v.label] != nil {
            if byLabel[v.label] == nil { order.append(v.label) }
            byLabel[v.label, default: [:]][v.value, default: []] += v.refs
        }
        for label in order {
            let values = (byLabel[label] ?? [:]).sorted { $0.key < $1.key }
            guard values.count > 1 else { continue }
            for (value, refs) in values {
                let docs = Set(refs.compactMap { JobText.document(of: $0, in: f.documents)?.name }).sorted()
                let others = values.filter { $0.key != value }
                let contrary = others.map { o -> String in
                    let d = Set(o.value.compactMap { JobText.document(of: $0, in: f.documents)?.name }).sorted().joined(separator: ", ")
                    return "\(o.key) (\(d.isEmpty ? "source not named" : d))"
                }
                rows.append(JobResultRow(title: "Account: \(label) = \(value)",
                                         detail: "Supported by: " + (docs.isEmpty ? "cited passage" : docs.joined(separator: ", ")) + ". Contrary: " + contrary.joined(separator: "; ") + ".",
                                         flags: others.map { "opposing account: \(label) = \($0.key)" } + ["competing interpretation — kept"],
                                         refs: Array(refs.prefix(4)),
                                         fields: ["account": "\(label) = \(value)", "for": refs.compactMap(\.quote).prefix(2).map { "“\($0)”" }.joined(separator: " ") + (docs.isEmpty ? "" : " [\(docs.joined(separator: ", "))]"),
                                                  "against": contrary.joined(separator: "; ")]))
            }
        }
        let causal = CausationExecutor.run(e, askForAlternatives: false)
        if causal.state == .draft {
            for r in causal.content.rows {
                rows.append(JobResultRow(title: "Account (stated cause): \(r.title)", detail: r.detail, flags: r.flags, refs: r.refs,
                                         fields: ["account": r.title]))
            }
        }
        guard !rows.isEmpty else {
            return JobText.blocked("The case's documents state no fact two ways and give no cause, so no alternative account can be built from them.",
                                   "State the competing accounts yourself and link the evidence for and against each.")
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("Each opposing account is built from the documents that state its value and lists the documents that state otherwise; neither is preferred here.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Weigh the accounts; keep every competing interpretation with its evidence for and against."]))
    }
}

// MARK: - res.edition (annotations linked to passages)

public nonisolated enum AnnotatedEditionExecutor {
    public static let perDocument = 150, total = 600

    public static func run(_ e: JobEvidence) -> JobRun {
        var rows: [JobResultRow] = []
        var truncated = 0
        for doc in e.facts.documents {
            let sentences = JobText.sentences(e.texts[doc.objectID] ?? "")
            if sentences.count > perDocument { truncated += sentences.count - perDocument }
            let lineage = [doc.sourceVersionID.map { "version \($0.uuidString)" }, doc.sourceVersionID.flatMap { e.versionHashes[$0] }.map { "sha256 \($0)" }].compactMap { $0 }.joined(separator: " · ")
            for (n, s) in sentences.prefix(perDocument).enumerated() {
                guard rows.count < total else { truncated += 1; continue }
                rows.append(JobResultRow(title: s, detail: "\(doc.name) §\(n + 1)", flags: ["source text — verbatim"], refs: [JobText.ref(doc, s)],
                                         fields: ["text": s, "lineage": lineage.isEmpty ? doc.name : "\(doc.name) · \(lineage)"]))
            }
        }
        guard !rows.isEmpty else {
            return JobText.blocked("The case's documents have no readable text to edit.", "Add the source texts (transcriptions or OCR) as documents.")
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if truncated > 0 { limitations.append("\(truncated) passage(s) beyond the first \(perDocument) per document (\(total) in all) are not listed in this run.") }
        limitations.append("Each passage is the source text verbatim with its exact version; an annotation is recorded on the passage it concerns and cannot be accepted on a row without one. State your editorial principles in the completion note.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Annotate passage by passage; record the apparatus (variants, emendations) where the sources differ."]))
    }
}

// MARK: - gen.family-lines (lineage chart; unsourced relationships drawn as unproven)

public nonisolated enum LineageExecutor {
    static let kin = #"(daughter|son|wife|husband|widow|widower|mother|father|brother|sister|child|grandson|granddaughter|grandfather|grandmother|nephew|niece|uncle|aunt|cousin|parent)"#
    static let vital = #"\b(born|birth|baptis|christen|married|marriage|wedding|died|death|buried|burial|funeral)\w*"#

    public static func run(_ e: JobEvidence) -> JobRun {
        let persons = e.facts.named.filter { $0.label == "person" }
        guard !persons.isEmpty else {
            return JobText.blocked("The case's documents name no person, so there is no family line to draw.", "Add the records (certificates, registers, letters) that name the people.")
        }
        var rows: [JobResultRow] = []
        var seen = Set<String>()
        for doc in e.facts.documents {
            for s in JobText.sentences(e.texts[doc.objectID] ?? "") {
                let here = persons.filter { s.range(of: $0.value, options: .caseInsensitive) != nil }.map(\.value)
                guard here.count >= 2 else { continue }
                for a in here { for b in here where a != b {
                    let ea = NSRegularExpression.escapedPattern(for: a), eb = NSRegularExpression.escapedPattern(for: b)
                    var relation: String?
                    if let re = try? NSRegularExpression(pattern: ea + #"\b[^.]{0,40}?\b"# + kin + #"\b\s+of\s+(?:the\s+)?(?:late\s+)?"# + eb, options: [.caseInsensitive]),
                       let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) {
                        relation = String(s[r]).lowercased() + " of"
                    } else if JobText.matches(s, ea + #"\b[^.]{0,30}?\bmarried\b[^.]{0,30}?"# + eb) { relation = "married" }
                    guard let relation, seen.insert("\(a)|\(relation)|\(b)".lowercased()).inserted else { continue }
                    rows.append(JobResultRow(title: "\(a) — \(relation) — \(b)", detail: "Stated in \(doc.name).", flags: ["stated by a source"],
                                             refs: [JobText.ref(doc, s)], fields: ["person": a, "relationship": relation, "relative": b]))
                } }
            }
        }
        // Vital events on the timeline.
        for d in e.facts.statedDates where JobText.matches(d.title, vital) {
            let who = JobText.names(in: d.title, e.facts.named, persons: true)
            // The event's subject: the person named first in the sentence ("Meera Rao, daughter of Asha Rao, was born").
            guard let person = who.min(by: { (d.title.range(of: $0, options: .caseInsensitive)?.lowerBound ?? d.title.endIndex) < (d.title.range(of: $1, options: .caseInsensitive)?.lowerBound ?? d.title.endIndex) }) else { continue }
            let kind = d.title.range(of: vital, options: [.regularExpression, .caseInsensitive]).map { String(d.title[$0]).lowercased() } ?? "event"
            rows.append(JobResultRow(title: d.title, detail: "Names: " + who.joined(separator: ", "), date: JobText.day(d.date), flags: ["vital event"], refs: d.refs,
                                     fields: ["person": person, "relationship": "event: \(kind)", "relative": ""]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if !rows.contains(where: { $0.fields?["relative"]?.isEmpty == false }) { limitations.append("No sentence states a kinship between two named people; relationships you add by hand are drawn as unproven until a source is linked.") }
        limitations.append("The chart draws a relationship with a source as a solid line and one without a source as a dashed, unproven line; a stated relationship is what the document says, not a proven fact.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Link a source to every relationship you add; an unproven line stays dashed until you do."]))
    }
}

/// The lineage chart of a family-lines result (Mermaid; dashed = no source).
public nonisolated enum LineageChart {
    public static let unprovenLabel = "unproven — no source"

    public static func mermaid(rows: [JobResultRow]) -> String? {
        var ids: [String: String] = [:]
        func id(_ name: String) -> String {
            if let i = ids[name] { return i }
            let i = "p\(ids.count + 1)"; ids[name] = i; return i
        }
        var lines: [String] = []
        for r in rows where r.decision != .rejected {
            guard let a = r.fields?["person"], let b = r.fields?["relative"], let rel = r.fields?["relationship"], !a.isEmpty, !b.isEmpty else { continue }
            let label = rel.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\"", with: "'")
            lines.append(r.refs.isEmpty ? "    \(id(a)) -.->|\"\(label) (\(unprovenLabel))\"| \(id(b))" : "    \(id(a)) -->|\"\(label)\"| \(id(b))")
        }
        guard !lines.isEmpty else { return nil }
        let nodes = ids.sorted { $0.value < $1.value }.map { "    \($0.value)[\"\($0.key.replacingOccurrences(of: "\"", with: "'"))\"]" }
        return (["graph TD"] + nodes + lines).joined(separator: "\n")
    }
}

// MARK: - inv.data-lab (the person's filter, grouping and total; every row cited)

public nonisolated struct DataAnalysisQuery: Sendable, Hashable {
    /// "label = value", "label contains text", "document = name", "document contains text" (nil: no filter).
    public var filter: String?
    /// "label" (default) or "document".
    public var groupBy: String
    /// The label whose amounts are totalled per currency (default "amount"; empty: no total).
    public var total: String

    public static let `default` = DataAnalysisQuery(filter: nil, groupBy: "label", total: "amount")

    public init(filter: String?, groupBy: String, total: String) {
        let f = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.filter = f.isEmpty ? nil : f
        let g = groupBy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.groupBy = g == "document" ? "document" : "label"
        self.total = total.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The query the person saved on the analysis row (nil: no row or no entry → default).
    public static func from(rows: [JobResultRow]) -> DataAnalysisQuery {
        guard let r = rows.first(where: { $0.title.hasPrefix(ConfigurableAnalysisExecutor.analysisTitle) }), let f = r.fields else { return .default }
        return DataAnalysisQuery(filter: f["filter"], groupBy: f["groupBy"] ?? "label", total: f["total"] ?? "amount")
    }

    public var description: String {
        "filter: \(filter ?? "none") · group by: \(groupBy) · total: \(total.isEmpty ? "none" : total)"
    }

    /// Does a table row ("label = value", detail = document name) pass the filter?
    func admits(label: String, value: String, document: String) -> Bool {
        guard let filter else { return true }
        let ci: (String, String) -> Bool = { $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if let r = filter.range(of: " contains ", options: .caseInsensitive) {
            let key = filter[..<r.lowerBound].trimmingCharacters(in: .whitespaces), needle = filter[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if ci(key, "document") { return document.localizedCaseInsensitiveContains(needle) }
            return ci(key, label) && value.localizedCaseInsensitiveContains(needle)
        }
        if let r = filter.range(of: "=") {
            let key = filter[..<r.lowerBound].trimmingCharacters(in: .whitespaces), wanted = filter[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if ci(key, "document") { return ci(document, wanted) }
            return ci(key, label) && IssueMatrixExecutor.key(value) == IssueMatrixExecutor.key(wanted)
        }
        // A bare word: label match.
        return ci(filter, label)
    }
}

public nonisolated enum ConfigurableAnalysisExecutor {
    public static let analysisTitle = "Analysis"

    public static func run(_ e: JobEvidence, query: DataAnalysisQuery = .default) -> JobRun {
        let table = DataTableExecutor.run(e)
        guard table.state != .blocked else { return table }
        struct Cell { let label: String; let value: String; let document: String; let row: JobResultRow }
        let cells: [Cell] = table.content.rows.map { r in
            let parts = r.title.components(separatedBy: " = ")
            return Cell(label: parts.first ?? r.title, value: parts.dropFirst().joined(separator: " = "), document: r.detail ?? "", row: r)
        }
        let admitted = cells.filter { query.admits(label: $0.label, value: $0.value, document: $0.document) }
        var rows: [JobResultRow] = []
        rows.append(JobResultRow(title: "\(analysisTitle): \(query.description)",
                                 detail: "\(admitted.count) of \(cells.count) value(s) admitted by the filter; sources: \(Set(admitted.map(\.document)).count) document(s).",
                                 flags: ["query — edit the fields and run the job again to recompute"],
                                 refs: Array(admitted.flatMap { $0.row.refs }.prefix(8)),
                                 fields: ["filter": query.filter ?? "", "groupBy": query.groupBy, "total": query.total]))
        var groups: [String: [Cell]] = [:]
        var order: [String] = []
        for c in admitted {
            let g = query.groupBy == "document" ? (c.document.isEmpty ? "(document not named)" : c.document) : c.label
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(c)
        }
        for g in order.sorted() {
            let members = groups[g] ?? []
            var detail = "\(members.count) value(s), \(Set(members.map { IssueMatrixExecutor.key($0.value) }).count) distinct"
            if !query.total.isEmpty {
                // The same statement filed in several documents (an invoice and its e-mail copies) is
                // one statement: the total counts distinct (value, sentence) pairs and says how many
                // mentions were folded. A total of stated amounts is never a payment figure.
                var totals: [String: Decimal] = [:]; var left = 0; var folded = 0
                var seen = Set<String>()
                for m in members where m.label.compare(query.total, options: .caseInsensitive) == .orderedSame {
                    let c = FAMoney.currency(of: m.value)
                    let key = JobDeliverableText.normalised(m.value) + "|" + JobDeliverableText.normalised(m.row.refs.first?.quote ?? "")
                    if !(m.row.refs.first?.quote ?? "").isEmpty, !seen.insert(key).inserted { folded += 1; continue }
                    if let d = FAMoney.value(of: m.value), !c.isEmpty { totals[c, default: 0] += d } else { left += 1 }
                }
                if !totals.isEmpty || left > 0 {
                    detail += "; total of \(query.total) (distinct statements): " + (totals.isEmpty ? "none with a stated currency" : totals.sorted { $0.key < $1.key }.map { "\($0.key) \(FAMoney.format($0.value))" }.joined(separator: ", "))
                    if folded > 0 { detail += "; \(folded) repeated statement(s) counted once" }
                    if left > 0 { detail += "; \(left) not totalled (no currency or not one figure)" }
                    detail += " — stated amounts, not payments"
                }
            }
            rows.append(JobResultRow(title: "\(query.groupBy == "document" ? "Document" : "Field") \(g): " + Array(NSOrderedSet(array: members.map(\.value))).prefix(5).map { "\($0)" }.joined(separator: ", ") + (members.count > 5 ? " …" : ""),
                                     detail: detail, flags: ["computed from the cited rows"], refs: Array(members.flatMap { $0.row.refs }.prefix(8))))
        }
        rows += admitted.map(\.row)
        return (.draft, JobResultContent(rows: rows,
                                         limitations: table.content.limitations + ["Query: \(query.description). The same query over the same sources gives the same result; a changed query is a new run, the earlier one stays in the history."],
                                         nextActions: ["Set the filter, grouping and total on the Analysis row and run the job again; interpret each computed row in its note."]))
    }
}
