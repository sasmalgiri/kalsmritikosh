//
//  JobFamilyExecutors.swift
//  Kalsmritikosh
//
//  Final completion instructions §3 — the shared executors behind the result families. Each one is
//  deterministic over the case's own evidence (read under the job's access context), quotes the
//  documents verbatim, never states a conclusion that is a person's to reach, and returns a typed
//  result: rows with exact source references and flags, the run's limitations and next actions.
//  A run with nothing to work from is `.blocked` with its reason — never an empty success.
//

import Foundation

/// The case's evidence a shared executor works from, read under the job's access context.
public nonisolated struct JobEvidence: Sendable {
    public let facts: StudioCaseFacts
    /// Each case document's text, by knowledge-object id (a document whose text could not be read is absent).
    public let texts: [UUID: String]
    /// Case sources the job's access context does not admit (they are never read).
    public let withheld: Int
    public let now: Date
    /// Each admitted source version's content hash (SHA-256), for vault, citation and custody fields.
    public let versionHashes: [UUID: String]
    /// The case's produced exports (the exact snapshot text written), for redaction validation.
    public let exports: [(title: String, text: String)]
    public let batesPrefix: String
    /// B3 — admitted source versions that a newer version of the same document replaces.
    public let replacedVersions: Set<UUID>
    /// The identity merges a person confirmed in this case (identity resolution; reversible). The
    /// only way two name forms become one party (law.parties-issues).
    public let mergedIdentities: [MergedIdentity]
    public init(facts: StudioCaseFacts, texts: [UUID: String] = [:], withheld: Int = 0, now: Date = Date(),
                versionHashes: [UUID: String] = [:], exports: [(title: String, text: String)] = [], batesPrefix: String = "PROD",
                replacedVersions: Set<UUID> = [], mergedIdentities: [MergedIdentity] = []) {
        self.facts = facts; self.texts = texts; self.withheld = withheld; self.now = now
        self.versionHashes = versionHashes; self.exports = exports; self.batesPrefix = batesPrefix
        self.replacedVersions = replacedVersions; self.mergedIdentities = mergedIdentities
    }
}

/// A confirmed, unreversed human merge: the surviving name and the name forms merged into it.
public nonisolated struct MergedIdentity: Sendable, Hashable {
    public let canonical: String
    public let aliases: [String]
    public let decidedBy: String
    public let decidedAt: Date
    public init(canonical: String, aliases: [String], decidedBy: String, decidedAt: Date) {
        self.canonical = canonical; self.aliases = aliases; self.decidedBy = decidedBy; self.decidedAt = decidedAt
    }
}

public typealias JobRun = (state: JobResultState, content: JobResultContent)

/// Text helpers shared by the executors (verbatim sentences, days, references, names).
nonisolated enum JobText {
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            // A closing quote after the full stop belongs to the sentence it closes.
            let closesQuote = i + 1 < chars.count && "”\"’)".contains(chars[i + 1])
            if (ch == "." || ch == "!" || ch == "?" || ch == "\n") && !closesQuote || ("”\"’)".contains(ch) && i > 0 && ".!?".contains(chars[i - 1])) {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.count >= 12 { out.append(String(s.prefix(400))) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.count >= 12 { out.append(String(rest.prefix(400))) }
        return out
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.string(from: d)
    }

    static func ref(_ doc: StudioCaseDocument, _ quote: String) -> StudioEvidenceRef {
        StudioEvidenceRef(sourceVersionID: doc.sourceVersionID, objectID: doc.objectID, quote: quote)
    }

    /// The people and organisations the case names that occur in `s`.
    static func names(in s: String, _ named: [StudioCaseValue], persons: Bool = false) -> [String] {
        named.filter { (!persons || $0.label == "person") && $0.value.count >= 3 && s.range(of: $0.value, options: .caseInsensitive) != nil }
            .map(\.value)
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func count(_ s: String, _ pattern: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return re.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    static func blocked(_ reason: String, _ next: String) -> JobRun {
        (.blocked, JobResultContent(rows: [], limitations: [reason], nextActions: [next]))
    }

    /// The case document a reference belongs to (by object, else by source version).
    static func document(of ref: StudioEvidenceRef, in docs: [StudioCaseDocument]) -> StudioCaseDocument? {
        if let o = ref.objectID, let d = docs.first(where: { $0.objectID == o }) { return d }
        if let v = ref.sourceVersionID { return docs.first { $0.sourceVersionID == v } }
        return nil
    }

    static func documents(of value: StudioCaseValue, in docs: [StudioCaseDocument]) -> [StudioCaseDocument] {
        var seen = Set<UUID>()
        return value.refs.compactMap { document(of: $0, in: docs) }.filter { seen.insert($0.objectID).inserted }
    }

    static func withheldLimitation(_ n: Int) -> [String] {
        n > 0 ? ["\(n) case source(s) are not admitted by this job's access (privileged or above its sensitivity) and were not read."] : []
    }
}

// MARK: - Source / exhibit / citation / records inventory

public nonisolated enum InventoryExecutor {
    public enum Style: Sendable { case catalogue, exhibit, citation, records }

    public static func run(_ e: JobEvidence, style: Style) -> JobRun {
        let f = e.facts
        guard !f.documents.isEmpty else {
            return JobText.blocked("The case has no documents in scope, so there is nothing to list.", "Include the case's documents in its scope.")
        }
        var rows: [JobResultRow] = []
        var unreadable = 0, undated = 0, incomplete = 0
        for (i, doc) in f.documents.enumerated() {
            let text = e.texts[doc.objectID] ?? ""
            let first = JobText.sentences(text).first ?? doc.name
            let dates = f.statedDates.filter { $0.refs.contains { $0.objectID == doc.objectID } }
            let names = f.named.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map(\.value)
            let amounts = f.statedAmounts.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map(\.value)
            var flags: [String] = []
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flags.append("unreadable — not reviewed"); unreadable += 1 }
            if dates.isEmpty { flags.append("no date stated"); undated += 1 }
            if doc.sourceVersionID == nil { flags.append("no exact source version") }
            var parts: [String] = []
            let days = Array(Set(dates.map { JobText.day($0.date) })).sorted()
            if !days.isEmpty { parts.append("Dates: " + days.prefix(6).joined(separator: ", ")) }
            if !names.isEmpty { parts.append("Names: " + names.prefix(6).joined(separator: ", ")) }
            if !amounts.isEmpty { parts.append("Amounts: " + amounts.prefix(6).joined(separator: ", ")) }
            let title: String
            switch style {
            case .exhibit:
                title = String(format: "EX-%03d  ", i + 1) + doc.name
                // B3 — an exhibit cites its exact version; one a newer version replaces is flagged.
                if let v = doc.sourceVersionID, e.replacedVersions.contains(v) { flags.append("replaced by a newer version") }
            case .citation:
                // A citation needs who and when; a missing element is flagged, never invented.
                if days.isEmpty || names.isEmpty { flags.append("citation metadata incomplete"); incomplete += 1 }
                title = [names.first, doc.name, days.first].compactMap { $0 }.joined(separator: ". ")
            case .catalogue, .records: title = doc.name
            }
            if style == .records {
                for d in dates where JobText.matches(d.title, #"expir|renew|valid until|due|deadline"#) {
                    flags.append((d.date < e.now ? "passed: " : "upcoming: ") + JobText.day(d.date))
                }
            }
            rows.append(JobResultRow(title: title, detail: parts.isEmpty ? nil : parts.joined(separator: "; "),
                                     date: days.first, flags: flags, refs: [JobText.ref(doc, first)]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if unreadable > 0 { limitations.append("\(unreadable) document(s) could not be read; they stay listed and count as not reviewed.") }
        var next: [String] = []
        switch style {
        case .exhibit: next.append("Select and order the exhibits; numbering follows the list until you change it.")
        case .citation: if incomplete > 0 { next.append("Complete the author and date of \(incomplete) citation(s) from the documents themselves.") }
        case .records: next.append("Check every passed or upcoming date against the original document.")
        case .catalogue: break
        }
        if undated > 0 { next.append("\(undated) document(s) state no date; record their dates if known.") }
        next.append("Review the list; it is a draft until you accept it.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations, nextActions: next))
    }

    /// Dates the documents state, as reminders: each with its sentence, passed or upcoming.
    public static func reminders(_ e: JobEvidence) -> JobRun {
        let dates = e.facts.statedDates.sorted { $0.date < $1.date }
        guard !dates.isEmpty else {
            return JobText.blocked("The case's documents state no calendar date, so there is nothing to remind you of.", "Add documents that carry the dates, or record them by hand.")
        }
        let rows = dates.map { d in
            JobResultRow(title: d.title, date: JobText.day(d.date), flags: [d.date < e.now ? "passed" : "upcoming"], refs: d.refs)
        }
        return (.draft, JobResultContent(rows: rows, limitations: JobText.withheldLimitation(e.withheld),
                                         nextActions: ["Confirm each upcoming date against the original document before relying on it."]))
    }
}

// MARK: - Reliability and corroboration

public nonisolated enum ReliabilityExecutor {
    /// Per source: how many of the names, amounts and dates it states also appear in another case
    /// document, and any field on which it gives a value other documents contradict. The grade itself
    /// is the person's: every source stays "not assessed" here.
    public static func run(_ e: JobEvidence) -> JobRun {
        let f = e.facts
        guard !f.documents.isEmpty else {
            return JobText.blocked("The case has no documents in scope, so no source can be assessed.", "Include the case's documents in its scope.")
        }
        let conflicts = IssueMatrixExecutor.conflictingLabels(f)
        var rows: [JobResultRow] = []
        for doc in f.documents {
            let others = f.documents.filter { $0.objectID != doc.objectID }
            let values = f.named.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map(\.value)
                + f.statedAmounts.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map(\.value)
            let days = Set(f.statedDates.filter { $0.refs.contains { $0.objectID == doc.objectID } }.map { JobText.day($0.date) })
            let otherDays = Set(f.statedDates.filter { d in d.refs.contains { r in others.contains { $0.objectID == r.objectID } } }.map { JobText.day($0.date) })
            let corroborated = values.filter { v in others.contains { (e.texts[$0.objectID] ?? "").range(of: v, options: .caseInsensitive) != nil } }.count
                + days.intersection(otherDays).count
            let total = values.count + days.count
            var flags = ["not assessed"]
            if f.documents.count == 1 { flags.append("single source") }
            else if total > 0 && corroborated == 0 { flags.append("uncorroborated") }
            for (label, docs) in conflicts where docs.contains(doc.objectID) { flags.append("conflict on \(label)") }
            let detail = total == 0 ? "States no name, amount or date that can be cross-checked."
                : "\(corroborated) of \(total) stated names, amounts and dates also appear in another case document."
            let quote = JobText.sentences(e.texts[doc.objectID] ?? "").first ?? doc.name
            rows.append(JobResultRow(title: doc.name, detail: detail, flags: flags, refs: [JobText.ref(doc, quote)]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        limitations.append("Corroboration here means the same name, amount or date appears in another case document; it is not independence and it is not a reliability grade.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Grade each source's reliability and independence with your reasons; the grade is yours.",
                                                       "Keep every conflict open with both sides until you resolve it."]))
    }
}

// MARK: - Issue / element / fact–evidence matrix

public nonisolated enum IssueMatrixExecutor {
    nonisolated static func key(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^a-z0-9₹$€£]"#, with: "", options: .regularExpression)
    }

    /// Field labels on which the case's documents give more than one value → the documents involved.
    static func conflictingLabels(_ f: StudioCaseFacts) -> [String: Set<UUID>] {
        var values: [String: [String: Set<UUID>]] = [:]
        for v in f.allFacts {
            let docs = Set(JobText.documents(of: v, in: f.documents).map(\.objectID))
            values[v.label, default: [:]][key(v.value), default: []].formUnion(docs)
        }
        var out: [String: Set<UUID>] = [:]
        for (label, byValue) in values where byValue.count > 1 {
            out[label] = byValue.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        }
        return out
    }

    /// Each stated fact (field facts and stated amounts) with the documents that support it; a fact
    /// stated by one document only is "single source"; a field the documents give different values
    /// for lists every value as conflicting — contrary evidence is never dropped.
    public static func run(_ e: JobEvidence, singleSourceFlag: String = "single source") -> JobRun {
        let f = e.facts
        let claims = f.allFacts + f.statedAmounts.map { StudioCaseValue(value: $0.value, label: "amount", refs: $0.refs) }
        guard !claims.isEmpty else {
            return JobText.blocked("The case's documents state no fact the ledger could read (no field, party or amount), so there is nothing to map.",
                                   "Add the facts or elements you need to prove by hand and link each to its document.")
        }
        var byLabel: [String: [String: (value: String, refs: [StudioEvidenceRef])]] = [:]
        var order: [String] = []
        for c in claims {
            let k = key(c.value)
            if byLabel[c.label] == nil { order.append(c.label) }
            var entry = byLabel[c.label, default: [:]][k] ?? (c.value, [])
            entry.refs += c.refs
            byLabel[c.label, default: [:]][k] = entry
        }
        var rows: [JobResultRow] = []
        for label in order {
            let values = byLabel[label] ?? [:]
            for (_, entry) in values.sorted(by: { $0.value.value < $1.value.value }) {
                let refDocs = Set(entry.refs.compactMap { JobText.document(of: $0, in: f.documents)?.objectID })
                let textDocs = Set(f.documents.filter { (e.texts[$0.objectID] ?? "").range(of: entry.value, options: .caseInsensitive) != nil }.map(\.objectID))
                let support = refDocs.union(textDocs)
                let names = f.documents.filter { support.contains($0.objectID) }.map(\.name)
                var flags: [String] = []
                if support.count <= 1 { flags.append(singleSourceFlag) }
                if support.isEmpty { flags.append("unsupported") }
                for (_, other) in values where key(other.value) != key(entry.value) {
                    flags.append("conflicting value: \(other.value)")
                }
                rows.append(JobResultRow(title: "\(label): \(entry.value)",
                                         detail: names.isEmpty ? "No document found stating it." : "Stated in: " + names.joined(separator: ", "),
                                         flags: flags, refs: Array(entry.refs.prefix(4))))
            }
        }
        let conflicts = rows.filter { $0.flags.contains { $0.hasPrefix("conflicting value") } }.count
        var next = ["Mark each fact or element supported, contradicted or unsupported; contrary evidence stays listed."]
        if conflicts > 0 { next.insert("Resolve or keep open \(conflicts) fact(s) the documents state differently.", at: 0) }
        return (.draft, JobResultContent(rows: rows, limitations: JobText.withheldLimitation(e.withheld)
                                         + ["Only facts the ledger read from the documents are listed; elements you must prove that no document states do not appear and must be added by hand."],
                                         nextActions: next))
    }
}

// MARK: - Quotes, statements and interview preparation

public nonisolated enum StatementExecutor {
    static let attribution = #"[“"].{3,}[”"]|\b(said|says|stated|told|testified|wrote|explained|admitted|denied|alleged|according to)\b"#

    /// Verbatim quoted or attributed statements, each with its speaker when the sentence names one.
    public static func quotes(_ e: JobEvidence) -> JobRun {
        var rows: [JobResultRow] = []
        for doc in e.facts.documents {
            let text = e.texts[doc.objectID] ?? ""
            let author = SpeakerAttribution.fromHeader(text, e.facts.named)
            for s in JobText.sentences(text) where JobText.matches(s, attribution) {
                let named = JobText.names(in: s, e.facts.named, persons: true)
                let a = SpeakerAttribution.resolve(s, named: named, author: author)
                let detail: String
                if let who = a.speaker { detail = "Speaker: \(who) (\(a.basis))" + (a.reported.isEmpty ? "" : "; reports words of " + a.reported.joined(separator: ", ")) }
                else if named.isEmpty { detail = "Speaker not identified in the sentence." }
                else { detail = "Speaker \(a.basis)." }
                rows.append(JobResultRow(title: s, detail: detail, flags: a.speaker == nil && !named.isEmpty ? ["verbatim", "speaker unassigned"] : ["verbatim"],
                                         refs: [JobText.ref(doc, s)]))
            }
        }
        guard !rows.isEmpty else {
            return JobText.blocked("The case's documents contain no quoted or attributed statement.", "Add the statements, transcripts or interview notes to the case.")
        }
        return (.draft, JobResultContent(rows: rows, limitations: JobText.withheldLimitation(e.withheld)
                                         + ["A statement is what someone said, not what happened; corrections are added as new entries, never over the original."],
                                         nextActions: ["Confirm each speaker against the original; a sentence that does not name one stays unattributed."]))
    }

    /// One row per person the documents name: the passages that mention them (the topics to cover),
    /// whether they appear in only one document, and that they are not yet interviewed.
    public static func interviewPlan(_ e: JobEvidence) -> JobRun {
        let persons = e.facts.named.filter { $0.label == "person" }
        guard !persons.isEmpty else {
            return JobText.blocked("The case's documents name no person, so there is no one to prepare for.", "Add the witnesses or subjects by hand, or include documents that name them.")
        }
        var rows: [JobResultRow] = []
        for p in persons {
            var refs: [StudioEvidenceRef] = []
            var docs = Set<UUID>()
            for doc in e.facts.documents {
                for s in JobText.sentences(e.texts[doc.objectID] ?? "") where s.range(of: p.value, options: .caseInsensitive) != nil {
                    refs.append(JobText.ref(doc, s)); docs.insert(doc.objectID)
                }
            }
            var flags = ["not yet interviewed"]
            if docs.count == 1 { flags.append("named in one document only") }
            let topics = refs.prefix(2).map { String(($0.quote ?? "").prefix(140)) }
            rows.append(JobResultRow(title: p.value, detail: refs.isEmpty ? "Named, but no passage found." : "\(refs.count) passage(s). Topics: " + topics.joined(separator: " / "),
                                     flags: flags, refs: Array((refs.isEmpty ? p.refs : refs).prefix(6))))
        }
        return (.draft, JobResultContent(rows: rows, limitations: JobText.withheldLimitation(e.withheld),
                                         nextActions: ["Write each question against the passage it comes from; a disputed point is put with both sources.",
                                                       "Record each interview as it happens; an unanswered request is recorded as unanswered, never as an admission."]))
    }
}

// MARK: - Causation and hypotheses

public nonisolated enum CausationExecutor {
    static let markers = #"\b(because|due to|caused|causing|led to|leads to|resulted in|results in|as a result|owing to|therefore|consequently|in order to)\b"#

    /// Every causal statement the documents make, as a hypothesis to test — never as a finding.
    public static func run(_ e: JobEvidence, askForAlternatives: Bool = true) -> JobRun {
        var rows: [JobResultRow] = []
        for doc in e.facts.documents {
            for s in JobText.sentences(e.texts[doc.objectID] ?? "") where JobText.matches(s, markers) {
                let names = JobText.names(in: s, e.facts.named)
                rows.append(JobResultRow(title: s, detail: names.isEmpty ? nil : "Names: " + names.joined(separator: ", "),
                                         flags: ["hypothesis — not a finding"], refs: [JobText.ref(doc, s)]))
            }
        }
        guard !rows.isEmpty else {
            return JobText.blocked("The case's documents state no cause or reason, so the analysis is inconclusive on the documents.",
                                   "State the candidate causes yourself and link the evidence for and against each.")
        }
        var next = ["Test each candidate cause against the evidence for and against it; a cause without evidence stays a hypothesis."]
        if askForAlternatives { next.append("Record at least one alternative explanation for each.") }
        return (.draft, JobResultContent(rows: rows, limitations: JobText.withheldLimitation(e.withheld)
                                         + ["A document saying why something happened is a claim to test, not an established cause."],
                                         nextActions: next))
    }
}

// MARK: - Money workpapers

public nonisolated enum MoneyExecutor {
    /// Every stated amount with its sentence; readable amounts with a stated currency are totalled per
    /// currency (never across currencies). An amount without a currency, or that is not one plain
    /// figure ("$2.75 million"), is listed and left out of every total.
    public static func run(_ e: JobEvidence) -> JobRun {
        let amounts = e.facts.statedAmounts
        guard !amounts.isEmpty else {
            return JobText.blocked("The case's documents state no amount, so there is nothing to schedule.", "Add the records that carry the amounts.")
        }
        var rows: [JobResultRow] = []
        var totals: [String: Decimal] = [:]
        var left = 0
        for a in amounts {
            let currency = FAMoney.currency(of: a.value)
            let value = FAMoney.value(of: a.value)
            var flags: [String] = []
            if currency.isEmpty { flags.append("currency not stated — not totalled") }
            if value == nil { flags.append("not one plain figure — not totalled") }
            if let value, !currency.isEmpty { totals[currency, default: 0] += value } else { left += 1 }
            rows.append(JobResultRow(title: a.value, detail: a.refs.first?.quote, flags: flags, refs: a.refs))
        }
        for (cur, sum) in totals.sorted(by: { $0.key < $1.key }) {
            rows.append(JobResultRow(title: "Stated amounts in \(cur): \(FAMoney.format(sum))",
                                     flags: ["sum of stated amounts — not a loss, damages or recovery figure", "duplicates not resolved"]))
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if left > 0 { limitations.append("\(left) amount(s) are left out of every total (no stated currency, or not one plain figure).") }
        limitations.append("A difference between figures is a difference to explain, not evidence of loss or fraud.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Classify each amount (movement, duplicate, reversal) before any total is relied on.",
                                                       "State the currency of every amount the documents leave unstated."]))
    }
}

// MARK: - Controlled disclosure review

public nonisolated enum DisclosureExecutor {
    static let patterns: [(String, String)] = [
        ("email address", #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#),
        ("phone number", #"(?<!\d)\+?\d[\d ().-]{8,}\d(?!\d)"#),
        ("national-ID-like number", #"\b\d{3}-\d{2}-\d{4}\b"#),
        ("long account-like number", #"\b\d{9,18}\b"#),
        ("health term", #"\b(diagnos\w*|prescri\w*|medical|patient|treatment|clinic\w*)\b"#),
    ]

    /// Per admitted document: the personal identifiers and sensitive terms found by pattern. Nothing
    /// is cleared automatically — every document is "not cleared" until a person clears it; sources the
    /// job may not read are outside the package by construction.
    public static func run(_ e: JobEvidence) -> JobRun {
        guard !e.facts.documents.isEmpty else {
            return JobText.blocked("No document is admitted for disclosure, so nothing can be shared.", "Include the documents you intend to share in the case's scope.")
        }
        var rows: [JobResultRow] = []
        for doc in e.facts.documents {
            let text = e.texts[doc.objectID] ?? ""
            var found: [String] = []
            for (label, p) in patterns {
                let n = JobText.count(text, p)
                if n > 0 { found.append("\(n) \(label)(s)") }
            }
            var flags = ["not cleared — needs your review"]
            if text.isEmpty { flags.append("unreadable — withhold") }
            flags += found.map { "redaction candidate: " + $0 }
            let quote = JobText.sentences(text).first ?? doc.name
            rows.append(JobResultRow(title: doc.name, detail: found.isEmpty ? "No identifier pattern found (patterns miss identifiers written in other forms)." : "Found: " + found.joined(separator: ", "),
                                     flags: flags, refs: [JobText.ref(doc, quote)]))
        }
        var limitations = JobText.withheldLimitation(e.withheld).map { $0 + " They are not part of any disclosure." }
        limitations.append("Pattern detection is a first pass; a person reviews every page. Effective redaction of produced bytes is verified by the production and redaction tools.")
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Clear, redact or withhold each document; anything not positively cleared stays withheld."]))
    }
}

// MARK: - Case data table

public nonisolated enum DataTableExecutor {
    /// Every structured value the ledger read from the case (field facts, stated amounts, stated
    /// dates) as one source-linked table, document by document.
    public static func run(_ e: JobEvidence) -> JobRun {
        let f = e.facts
        var rows: [JobResultRow] = []
        func docName(_ refs: [StudioEvidenceRef]) -> String? { refs.compactMap { JobText.document(of: $0, in: f.documents)?.name }.first }
        for v in f.allFacts { rows.append(JobResultRow(title: "\(v.label) = \(v.value)", detail: docName(v.refs), refs: Array(v.refs.prefix(2)))) }
        for a in f.statedAmounts { rows.append(JobResultRow(title: "amount = \(a.value)", detail: docName(a.refs), refs: a.refs)) }
        for d in f.statedDates { rows.append(JobResultRow(title: "date = \(JobText.day(d.date))", detail: docName(d.refs), date: JobText.day(d.date), refs: d.refs)) }
        guard !rows.isEmpty else {
            return JobText.blocked("The ledger read no structured value (field, amount or date) from the case's documents.", "Import a table or record, or add the values by hand.")
        }
        let covered = Set((f.allFacts + f.statedAmounts).flatMap(\.refs).compactMap { JobText.document(of: $0, in: f.documents)?.objectID }
                          + f.statedDates.flatMap(\.refs).compactMap(\.objectID))
        let silent = f.documents.filter { !covered.contains($0.objectID) }.count
        var limitations = JobText.withheldLimitation(e.withheld)
        if silent > 0 { limitations.append("\(silent) document(s) gave no structured value; an analysis over this table does not cover them.") }
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Define the analysis (filter, group, total); every result row keeps its source."]))
    }
}

// MARK: - Publication readiness

public nonisolated enum PublicationExecutor {
    /// The publication checklist: every stated fact with its sources (single-sourced ones flagged),
    /// and every person the documents name, whose reply opportunity must be on the reply log. The
    /// decision to publish is the editor's.
    public static func run(_ e: JobEvidence) -> JobRun {
        let facts = IssueMatrixExecutor.run(e, singleSourceFlag: "single-sourced — needs a second source")
        var rows = facts.state == .blocked ? [] : facts.content.rows
        for p in e.facts.named where p.label == "person" {
            rows.append(JobResultRow(title: "Reply opportunity: \(p.value)", detail: "Check the right-of-reply log before publication.",
                                     flags: ["reply not confirmed here"], refs: Array(p.refs.prefix(2))))
        }
        guard !rows.isEmpty else {
            return JobText.blocked("The case states no fact and names no person, so there is nothing to check for publication.", "Add the story's claims and sources.")
        }
        return (.draft, JobResultContent(rows: rows, limitations: JobText.withheldLimitation(e.withheld),
                                         nextActions: ["Publish, hold or kill is an editor's decision, recorded with reasons.",
                                                       "A claim without its required evidence or reply opportunity is held."]))
    }
}

// MARK: - Deadlines

public nonisolated enum DeadlineExecutor {
    static let words = #"\b(due|deadline|no later than|on or before|within \d+|expires?|expiry|must be (filed|served|paid)|by (the )?\d{1,2}(st|nd|rd|th)?)\b"#

    /// Dates the documents state in a deadline sentence, each unconfirmed until a person confirms it.
    public static func run(_ e: JobEvidence) -> JobRun {
        let dated = e.facts.statedDates.filter { JobText.matches($0.title, words) }.sorted { $0.date < $1.date }
        guard !dated.isEmpty else {
            return JobText.blocked("No document states a dated deadline.", "Enter each deadline with its rule or source; deadlines computed from rules are not calculated here.")
        }
        let rows = dated.map { d in
            JobResultRow(title: d.title, date: JobText.day(d.date), flags: ["unconfirmed", d.date < e.now ? "passed" : "upcoming"], refs: d.refs)
        }
        return (.draft, JobResultContent(rows: rows, limitations: ["Only deadlines a document states with its date are listed; deadlines that follow from a rule (e.g. 30 days after service) are not calculated."],
                                         nextActions: ["Confirm each deadline against its rule and source; it stays unconfirmed until you do."]))
    }
}

// MARK: - Same-person candidates

public nonisolated enum IdentityCandidateExecutor {
    /// Pairs of person names that may be the same person (one is contained in the other, or they share
    /// a surname). They stay separate — only a person merges them, reversibly.
    public static func run(_ e: JobEvidence) -> JobRun {
        let persons = e.facts.named.filter { $0.label == "person" }
        guard persons.count >= 2 else {
            return JobText.blocked("The case names fewer than two people, so there is no pair to compare.", "Add the records that name the people you are comparing.")
        }
        var rows: [JobResultRow] = []
        for i in persons.indices {
            for j in persons.indices where j > i {
                let a = persons[i].value, b = persons[j].value
                let ta = Set(a.lowercased().split(separator: " ").map(String.init)), tb = Set(b.lowercased().split(separator: " ").map(String.init))
                let surnameA = a.split(separator: " ").last.map { $0.lowercased() }, surnameB = b.split(separator: " ").last.map { $0.lowercased() }
                let reason: String?
                if ta.isSubset(of: tb) || tb.isSubset(of: ta) { reason = "One name is contained in the other." }
                else if let sa = surnameA, sa == surnameB, sa.count >= 3 { reason = "Same surname “\(a.split(separator: " ").last ?? "")”." }
                else { reason = nil }
                if let reason {
                    rows.append(JobResultRow(title: "\(a) / \(b)", detail: reason, flags: ["undecided — kept separate"],
                                             refs: Array((persons[i].refs + persons[j].refs).prefix(4))))
                }
            }
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if rows.isEmpty { limitations.append("No two names look alike; that does not prove they are different people.") }
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Decide each pair from the records (dates, places, relations); a merge is reversible."]))
    }
}

// MARK: - Actions and their effectiveness

public nonisolated enum ActionExecutor {
    /// Open items the case's own evidence raises — conflicting facts, uncorroborated or unreadable
    /// sources, undated documents — each a candidate action with no owner yet. Actions close only by a
    /// person, with a note.
    public static func register(_ e: JobEvidence) -> JobRun {
        var rows: [JobResultRow] = []
        let matrix = IssueMatrixExecutor.run(e)
        if matrix.state != .blocked {
            for r in matrix.content.rows where r.flags.contains(where: { $0.hasPrefix("conflicting value") }) {
                rows.append(JobResultRow(title: "Resolve conflicting fact — \(r.title)", detail: r.detail, flags: ["open — no action recorded"], refs: r.refs))
            }
        }
        let reliability = ReliabilityExecutor.run(e)
        if reliability.state != .blocked {
            for r in reliability.content.rows where r.flags.contains("uncorroborated") {
                rows.append(JobResultRow(title: "Corroborate source — \(r.title)", detail: r.detail, flags: ["open — no action recorded"], refs: r.refs))
            }
        }
        for doc in e.facts.documents where (e.texts[doc.objectID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(JobResultRow(title: "Obtain a readable copy — \(doc.name)", flags: ["open — no action recorded"], refs: [JobText.ref(doc, doc.name)]))
        }
        guard !e.facts.documents.isEmpty else {
            return JobText.blocked("The case has no documents in scope, so no action follows from them.", "Record the actions your findings require by hand.")
        }
        var limitations = JobText.withheldLimitation(e.withheld)
        if rows.isEmpty { limitations.append("The documents raise no open item by these checks; actions your findings require are added by hand.") }
        return (.draft, JobResultContent(rows: rows, limitations: limitations,
                                         nextActions: ["Give each action an owner and a due date and link it to its finding; it closes only with your note."]))
    }

    /// The effectiveness review of the case's current action register: every action stays "not
    /// assessed" until a person records the evidence of effect and the verdict.
    public static func review(register: JobResultRecord?) -> JobRun {
        guard let register, register.state != .blocked else {
            return JobText.blocked("No action register has been run for this case, so there is nothing to review.", "Run the action register first and record the actions taken.")
        }
        guard !register.content.rows.isEmpty else {
            return JobText.blocked("The action register lists no action, so there is nothing to review.", "Record the actions taken in the register.")
        }
        let rows = register.content.rows.map { r in
            JobResultRow(title: r.title, detail: r.detail, flags: ["effectiveness not assessed"], refs: r.refs)
        }
        return (.draft, JobResultContent(rows: rows, limitations: ["Reviewed against the register saved \(JobText.day(register.createdAt)) by \(register.createdBy)."],
                                         nextActions: ["Record the evidence of effect and the verdict for each; an ineffective action reopens its finding."]))
    }
}
