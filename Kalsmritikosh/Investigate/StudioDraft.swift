//
//  StudioDraft.swift
//  Kalsmritikosh
//
//  A2/A3 (investigation focus) — the bridge between a case and the persona studios. A studio form
//  (privilege log, SIU referral, net-worth statement, …) is PRE-FILLED from the case's own ledger —
//  its parties, dates, amounts and documents — and every pre-filled field carries the evidence it
//  came from. A field the investigator types or changes is an "investigator entry". The export gate
//  refuses a filled field that is neither: a deliverable handed to a court, regulator or editor
//  must say, for every line, whether it rests on a document or on the investigator's word.
//
//  Before this file, every studio was filled in by hand with no tie to the evidence — which broke
//  the claim–evidence contract for exactly the documents a user hands to someone else.
//

import Foundation

// MARK: - Provenance

/// Where a value came from in the case: the source version, the document, the evidence block,
/// and the words as the document states them.
public nonisolated struct StudioEvidenceRef: Codable, Hashable, Sendable {
    public var sourceVersionID: UUID?
    public var objectID: UUID?
    public var blockID: UUID?
    public var quote: String?

    public init(sourceVersionID: UUID? = nil, objectID: UUID? = nil, blockID: UUID? = nil, quote: String? = nil) {
        self.sourceVersionID = sourceVersionID; self.objectID = objectID; self.blockID = blockID; self.quote = quote
    }
}

/// One field's provenance. `prefilledValue` is what the case supplied; a field whose current value
/// differs from it has been changed by hand and counts as an investigator entry.
public nonisolated struct StudioFieldProvenance: Codable, Hashable, Sendable {
    public var evidence: [StudioEvidenceRef]
    public var prefilledValue: String?
    public var investigatorEntry: Bool
    /// Marked as the investigator's entry after its cited source failed to resolve (review R2/R1):
    /// printed as their entry, and it blocks approval — documentary support cannot be waived by a label.
    public var relabelledFromUnresolved: Bool?

    public init(evidence: [StudioEvidenceRef] = [], prefilledValue: String? = nil, investigatorEntry: Bool = false) {
        self.evidence = evidence; self.prefilledValue = prefilledValue; self.investigatorEntry = investigatorEntry
    }

    public static func fromCase(_ value: String, _ refs: [StudioEvidenceRef]) -> StudioFieldProvenance {
        StudioFieldProvenance(evidence: refs, prefilledValue: value)
    }
    public static let investigator = StudioFieldProvenance(investigatorEntry: true)
}

/// A studio's provenance map, keyed by field path ("caption", "entries.<uuid>.date").
public typealias StudioProvenance = [String: StudioFieldProvenance]

public nonisolated enum StudioFieldStatus: String, Sendable, Equatable {
    case evidenced          // pre-filled from the case and unchanged
    case investigatorEntry  // typed or changed by the investigator, or marked as such
    case unsupported        // filled, but with neither
    case empty
}

public nonisolated enum StudioExportGate {
    /// The status of one field given its current value.
    public static func status(of value: String, provenance: StudioFieldProvenance?) -> StudioFieldStatus {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return .empty }
        guard let p = provenance else { return .unsupported }
        if p.investigatorEntry { return .investigatorEntry }
        if let pre = p.prefilledValue {
            if pre.trimmingCharacters(in: .whitespacesAndNewlines) != v { return .investigatorEntry }
            return p.evidence.isEmpty ? .unsupported : .evidenced
        }
        return p.evidence.isEmpty ? .unsupported : .evidenced
    }

    /// The filled fields that carry neither evidence nor an investigator-entry mark, by path.
    public static func unsupportedFields(_ values: [String: String], provenance: StudioProvenance?) -> [String] {
        values.keys.sorted().filter { status(of: values[$0] ?? "", provenance: provenance?[$0]) == .unsupported }
    }

    /// Mark every unsupported field as an investigator entry (the investigator vouches for them);
    /// returns the paths marked, for the audit trail.
    @discardableResult
    public static func markUnsupportedAsInvestigatorEntries(_ values: [String: String], provenance: inout StudioProvenance?) -> [String] {
        let paths = unsupportedFields(values, provenance: provenance)
        var p = provenance ?? [:]
        for path in paths { p[path] = .investigator }
        provenance = p
        return paths
    }

    /// Mark the given fields as investigator entries (the investigator vouches for them). Those in
    /// `unresolved` had a citation that failed: they are flagged, so approval stays blocked for them.
    public static func markAsInvestigatorEntries(_ paths: [String], unresolved: Set<String> = [], provenance: inout StudioProvenance?) {
        var p = provenance ?? [:]
        for path in paths {
            var e = StudioFieldProvenance.investigator
            if unresolved.contains(path) { e.relabelledFromUnresolved = true }
            p[path] = e
        }
        provenance = p
    }

    /// The appendix printed with an exported studio report: how many lines rest on documents and
    /// how many on the investigator's word, and the sources cited.
    /// Key prefixes of the source digest a prefill records (named people/organisations, stated amounts).
    public static let namedPrefix = "sources.named.", amountPrefix = "sources.amount."

    /// "Named in the case documents" and "Amounts stated" — each line with the sentence it comes from.
    /// Listed for the investigator; nothing here assigns a role or a finding.
    public static func sourceDigest(_ provenance: StudioProvenance?) -> String {
        guard let provenance else { return "" }
        func lines(_ prefix: String) -> [String] {
            provenance.keys.filter { $0.hasPrefix(prefix) }.sorted { (Int($0.dropFirst(prefix.count)) ?? 0) < (Int($1.dropFirst(prefix.count)) ?? 0) }
                .compactMap { k in
                    guard let f = provenance[k], let v = f.prefilledValue else { return nil }
                    return "- \(v)" + (f.evidence.first?.quote.map { " — \u{201C}\($0.prefix(200))\u{201D}" } ?? "")
                }
        }
        let n = lines(namedPrefix), a = lines(amountPrefix)
        var out = ""
        if !n.isEmpty { out += "\n## Named in the case documents\n\n" + n.joined(separator: "\n") + "\n" }
        if !a.isEmpty { out += "\n## Amounts stated in the case documents\n\n" + a.joined(separator: "\n") + "\n" }
        return out
    }

    public static func provenanceAppendix(_ values: [String: String], provenance: StudioProvenance?) -> String {
        var evidenced = 0, entered = 0
        var sources: [String] = []
        for path in values.keys.sorted() {
            switch status(of: values[path] ?? "", provenance: provenance?[path]) {
            case .evidenced:
                evidenced += 1
                for r in provenance?[path]?.evidence ?? [] {
                    if let q = r.quote, !q.isEmpty { sources.append("- \(path): \u{201C}\(q.prefix(160))\u{201D}") }
                }
            case .investigatorEntry: entered += 1
            default: break
            }
        }
        let digest = sourceDigest(provenance)
        guard evidenced + entered > 0 || !digest.isEmpty else { return "" }
        var out = digest
        guard evidenced + entered > 0 else { return out }
        out += "\n## Appendix — Sources of the entries above\n\n"
        out += "\(evidenced) entr\(evidenced == 1 ? "y" : "ies") taken from the case's documents; "
        out += "\(entered) entered by the investigator.\n\n"
        if !sources.isEmpty { out += sources.prefix(60).joined(separator: "\n") + "\n" }
        return out
    }
}

public nonisolated enum StudioExportError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedFields([String])
    public var errorDescription: String? {
        switch self {
        case .unsupportedFields(let f):
            return "\(f.count) field(s) have neither a source in the case nor an investigator-entry mark: "
                + f.prefix(8).joined(separator: ", ")
        }
    }
}

// MARK: - What the case supplies

/// A value the case states, with where it says it.
public nonisolated struct StudioCaseValue: Sendable, Hashable {
    public let value: String
    public let label: String
    public let refs: [StudioEvidenceRef]
    public init(value: String, label: String, refs: [StudioEvidenceRef]) {
        self.value = value; self.label = label; self.refs = refs
    }
}

/// A document in the case.
public nonisolated struct StudioCaseDocument: Sendable, Hashable {
    public let objectID: UUID
    public let sourceVersionID: UUID?
    public let name: String
    public let date: Date?
}

/// A dated event in the case.
public nonisolated struct StudioCaseEvent: Sendable, Hashable {
    public let date: Date
    public let title: String
    public let refs: [StudioEvidenceRef]
}

/// Everything a studio can be pre-filled from, read once from the case's ledger.
public nonisolated struct StudioCaseFacts: Sendable {
    public let caseTitle: String
    public let parties: [StudioCaseValue]       // people and organisations named by role or as subjects
    public let dates: [StudioCaseValue]         // dated fields (decision date, incident date, …)
    public let amounts: [StudioCaseValue]
    public let identifiers: [StudioCaseValue]   // case / claim / policy / docket numbers
    public let documents: [StudioCaseDocument]
    public let events: [StudioCaseEvent]
    public let allFacts: [StudioCaseValue]      // every fact, field label → value
    /// People and organisations the documents name (no role — the role is the investigator's call).
    public let named: [StudioCaseValue]
    /// Amounts the documents state, each with the sentence it appears in.
    public let statedAmounts: [StudioCaseValue]
    /// Calendar dates the documents state with an explicit year, each titled by the sentence it
    /// appears in — what a document dates even when no ledger event was recognised there.
    /// Relative dates ("today", "this morning") are never here: they resolve to the reading day.
    public let statedDates: [StudioCaseEvent]

    public init(caseTitle: String, parties: [StudioCaseValue], dates: [StudioCaseValue], amounts: [StudioCaseValue],
                identifiers: [StudioCaseValue], documents: [StudioCaseDocument], events: [StudioCaseEvent],
                allFacts: [StudioCaseValue], named: [StudioCaseValue] = [], statedAmounts: [StudioCaseValue] = [],
                statedDates: [StudioCaseEvent] = []) {
        self.caseTitle = caseTitle; self.parties = parties; self.dates = dates; self.amounts = amounts
        self.identifiers = identifiers; self.documents = documents; self.events = events; self.allFacts = allFacts
        self.named = named; self.statedAmounts = statedAmounts; self.statedDates = statedDates
    }

    public static let empty = StudioCaseFacts(caseTitle: "", parties: [], dates: [], amounts: [], identifiers: [],
                                              documents: [], events: [], allFacts: [])

    /// The first value whose field label is one of `fields` (normalized names), with its refs.
    public func first(_ fields: [String]) -> StudioCaseValue? {
        let wanted = fields.map(FactSchemaRegistry.normalizeField)
        for f in wanted { if let v = allFacts.first(where: { FactSchemaRegistry.normalizeField($0.label) == f }) { return v } }
        return nil
    }

    /// Every value for one of `fields`, de-duplicated by value.
    public func all(_ fields: [String]) -> [StudioCaseValue] {
        let wanted = Set(fields.map(FactSchemaRegistry.normalizeField))
        var seen = Set<String>()
        return allFacts.filter { wanted.contains(FactSchemaRegistry.normalizeField($0.label)) && seen.insert($0.value.lowercased()).inserted }
    }
}

/// Reads a case's facts, events and documents from the ledger for the studios. Read-only; it never
/// writes. The caller supplies the case's authorized source versions (the same scope the case's
/// answers and findings use), so a studio never sees a document outside the case.
public actor StudioCaseFactsReader {
    private let facts: GenericFactRepository
    private let events: EventsRepository
    private let objects: KnowledgeObjectRepository
    private let entities: EntitiesRepository?

    public init(facts: GenericFactRepository, events: EventsRepository, objects: KnowledgeObjectRepository,
                entities: EntitiesRepository? = nil) {
        self.facts = facts; self.events = events; self.objects = objects; self.entities = entities
    }

    /// The sentence of `content` that contains `value` (for the quote a reader can check).
    nonisolated static func sentence(containing value: String, in content: String) -> String? {
        guard let r = content.range(of: value) else { return nil }
        let enders: Set<Character> = [".", "!", "?", "\n"]
        var start = r.lowerBound, end = r.upperBound
        while start > content.startIndex, !enders.contains(content[content.index(before: start)]) { start = content.index(before: start) }
        while end < content.endIndex, !enders.contains(content[end]) { end = content.index(after: end) }
        if end < content.endIndex { end = content.index(after: end) }
        let s = content[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(300))
    }

    /// An amount as the text writes it: "$2.75" followed by "million" in the document is "$2.75 million".
    nonisolated static func amountAsWritten(_ value: String, in content: String) -> String {
        guard let r = content.range(of: value) else { return value }
        let rest = content[r.upperBound...].prefix(16)
        for scale in [" million", " billion", " thousand", " trillion", " crore", " lakh"] where rest.lowercased().hasPrefix(scale) {
            return value + scale
        }
        return value
    }

    /// A one-word person name ("Reyna") expanded to the fullest form the same document spells out
    /// ("Brooke E. Reyna") — first names and initials directly before it. Verbatim from the text.
    nonisolated static func fullName(_ surname: String, in content: String) -> String? {
        let pattern = #"(?:(?:[A-Z][a-z]+|[A-Z]\.)\s+){1,3}"# + NSRegularExpression.escapedPattern(for: surname) + #"\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = content as NSString
        let stop: Set<String> = ["The", "A", "An", "According", "Judge", "Attorney", "General", "Mr", "Mrs", "Ms", "Dr", "Assistant", "Acting", "U.S.", "In", "On"]
        let candidates = re.matches(in: content, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
            .map { c -> String in
                var words = c.split(separator: " ").map(String.init)
                while let f = words.first, stop.contains(f.trimmingCharacters(in: .punctuationCharacters)) || stop.contains(f) { words.removeFirst() }
                return words.joined(separator: " ")
            }
            .filter { $0.contains(" ") && $0 != surname }
        return candidates.max { $0.count < $1.count }
    }

    /// A date entity's day, only when its text names an explicit year ("March 3, 2009"); a relative
    /// date ("today") resolves to the reading day and is not evidence of when anything happened.
    nonisolated static func statedDay(raw: String, normalized: String?) -> Date? {
        guard raw.range(of: #"\b(1[5-9]|20)\d{2}\b"#, options: .regularExpression) != nil,
              let n = normalized?.uppercased() else { return nil }
        return ISO8601DateFormatter().date(from: n)
    }

    /// Names, amounts and explicit dates from the ledger's entities for each case document, kept only
    /// when the document's text states them verbatim (so every line can be checked against its quote).
    func namesAndAmounts(objectIDs: Set<UUID>, versionOf: [UUID: UUID] = [:]) async throws
        -> (named: [StudioCaseValue], amounts: [StudioCaseValue], dates: [StudioCaseEvent]) {
        guard let entities else { return ([], [], []) }
        var named: [StudioCaseValue] = [], amounts: [StudioCaseValue] = [], dates: [StudioCaseEvent] = []
        var seenNames = Set<String>(), seenAmounts = Set<String>(), seenDates = Set<String>()
        for id in objectIDs.sorted(by: { $0.uuidString < $1.uuidString }).prefix(60) {
            guard let content = try await objects.fetchContent(id: id) else { continue }
            for e in try await entities.findByMentionSource(id) where e.qualityTier != .t3 {
                var v = e.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if e.kind == .money { v = Self.amountAsWritten(v, in: content) }
                if e.kind == .person, !v.contains(" "), let full = Self.fullName(v, in: content) { v = full }
                guard v.count >= 2, let quote = Self.sentence(containing: v, in: content) else { continue }
                // The exact source version the passage was read from (review R1).
                let ref = StudioEvidenceRef(sourceVersionID: versionOf[id], objectID: id, quote: quote)
                switch e.kind {
                case .person, .organization:
                    guard v.contains(" "), seenNames.insert(v.lowercased()).inserted else { continue }
                    named.append(StudioCaseValue(value: v, label: e.kind == .person ? "person" : "organisation", refs: [ref]))
                case .money:
                    guard v.rangeOfCharacter(from: .decimalDigits) != nil, seenAmounts.insert(v.lowercased()).inserted else { continue }
                    amounts.append(StudioCaseValue(value: v, label: "amount", refs: [ref]))
                case .date:
                    guard let day = Self.statedDay(raw: v, normalized: e.normalizedValue),
                          seenDates.insert(id.uuidString + "|" + quote).inserted else { continue }
                    dates.append(StudioCaseEvent(date: day, title: quote, refs: [ref]))
                default: continue
                }
            }
        }
        return (Array(named.prefix(40)), Array(amounts.prefix(40)), Array(dates.prefix(200)))
    }

    nonisolated static let partyFields: Set<String> = ["plaintiff", "defendant", "petitioner", "respondent", "appellant",
        "appellee", "claimant", "insured", "applicant", "employer", "employee", "complainant", "accused", "counterparty",
        "recallingfirm", "manufacturer", "author", "recipient", "subject", "witness", "victim", "suspect"]
    nonisolated static let identifierFields: Set<String> = ["casenumber", "claimnumber", "policynumber", "docketnumber",
        "invoicenumber", "referencenumber", "accountnumber", "recallnumber", "inspectionnumber"]

    public func read(caseTitle: String, sourceVersionIDs: Set<UUID>) async throws -> StudioCaseFacts {
        guard !sourceVersionIDs.isEmpty else { return StudioCaseFacts(caseTitle: caseTitle, parties: [], dates: [], amounts: [],
                                                                      identifiers: [], documents: [], events: [], allFacts: []) }
        let rows = try await facts.facts(inSourceVersionIDs: sourceVersionIDs)
        let versionOfBlock = try await facts.sourceVersions(forBlockIDs: rows.flatMap(\.sourceBlockIDs))
        func refs(_ f: GenericFact) -> [StudioEvidenceRef] {
            f.sourceBlockIDs.prefix(4).map { StudioEvidenceRef(sourceVersionID: versionOfBlock[$0], blockID: $0, quote: f.rawMatch ?? f.value) }
        }
        let all = rows.map { StudioCaseValue(value: $0.value, label: $0.field, refs: refs($0)) }
        let parties = rows.filter { Self.partyFields.contains($0.field) }.map { StudioCaseValue(value: $0.value, label: $0.field, refs: refs($0)) }
        let dates = rows.filter { FactSchemaRegistry.expectedShape(of: $0.field) == .date && $0.field != "date" }
            .map { StudioCaseValue(value: $0.value, label: $0.field, refs: refs($0)) }
        let amounts = rows.filter { FactSchemaRegistry.expectedShape(of: $0.field) == .money || $0.field == "amount" }
            .map { StudioCaseValue(value: $0.value, label: $0.field, refs: refs($0)) }
        let identifiers = rows.filter { Self.identifierFields.contains($0.field) }
            .map { StudioCaseValue(value: $0.value, label: $0.field, refs: refs($0)) }

        let objectIDs = try await objects.objectIDs(inSourceVersionIDs: sourceVersionIDs)
        // One case version per document, so every reference names the version it was read from.
        let versionOf = try await objects.sourceVersionsByObject(inSourceVersionIDs: sourceVersionIDs)
            .compactMapValues { $0.sorted { $0.uuidString < $1.uuidString }.first }
        let caseEvents = try await events.forSourceVersions(sourceVersionIDs, limit: 400)
            .filter(\.hasTrustworthyDate)
            .sorted { $0.date < $1.date }
            .map { StudioCaseEvent(date: $0.date, title: $0.title,
                                   refs: [StudioEvidenceRef(sourceVersionID: versionOf[$0.sourceObjectID], objectID: $0.sourceObjectID,
                                                            quote: String(($0.summary ?? $0.title).prefix(200)))]) }

        let names = try await objects.sourceFilenames(for: objectIDs)
        let documents = objectIDs.sorted { (names[$0] ?? "") < (names[$1] ?? "") }
            .map { StudioCaseDocument(objectID: $0, sourceVersionID: versionOf[$0], name: names[$0] ?? "Document", date: nil) }

        let (named, stated, statedDates) = try await namesAndAmounts(objectIDs: objectIDs, versionOf: versionOf)
        return StudioCaseFacts(caseTitle: caseTitle, parties: parties, dates: dates, amounts: amounts,
                               identifiers: identifiers, documents: documents, events: caseEvents, allFacts: all,
                               named: named, statedAmounts: stated, statedDates: statedDates)
    }
}

// MARK: - Pre-fill helpers shared by every studio

public nonisolated enum StudioPrefill {
    /// Record who the documents name and the amounts they state (StudioExportGate.sourceDigest
    /// prints them). Replaces any earlier digest so a re-fill reflects the case as it is now.
    public static func recordSourceDigest(from c: StudioCaseFacts, into provenance: inout StudioProvenance) {
        for k in provenance.keys where k.hasPrefix(StudioExportGate.namedPrefix) || k.hasPrefix(StudioExportGate.amountPrefix) {
            provenance[k] = nil
        }
        for (i, v) in c.named.enumerated() { provenance["\(StudioExportGate.namedPrefix)\(i)"] = .fromCase(v.value, v.refs) }
        for (i, v) in c.statedAmounts.enumerated() { provenance["\(StudioExportGate.amountPrefix)\(i)"] = .fromCase(v.value, v.refs) }
    }

    /// Set a field from the case when the case states it: writes the value and its provenance.
    public static func set(_ field: inout String, path: String, from value: StudioCaseValue?, into provenance: inout StudioProvenance) {
        guard let value, field.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        field = value.value
        provenance[path] = .fromCase(value.value, value.refs)
    }

    /// Set a field from a composed string with explicit refs (e.g. a caption built from two parties).
    public static func set(_ field: inout String, path: String, value: String, refs: [StudioEvidenceRef], into provenance: inout StudioProvenance) {
        guard !value.isEmpty, field.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        field = value
        provenance[path] = .fromCase(value, refs)
    }

    public static func isoDay(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}
