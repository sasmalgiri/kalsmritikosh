//
//  CaseLedgerBriefing.swift
//  Kalsmritikosh
//
//  Unified-path program (owner, 2026-11-22), AI-18 — what the ledger already knows about a case,
//  written for the reader ahead of the documents: people and organisations (aliases, tier), the dated
//  timeline (approximate dates marked), relationships, typed fields (numbers, amounts, dates), domain
//  facts, statements (who said what), contradictions already found, memory, summaries and the case's
//  coverage gaps. Every line names the document it came from as [D<n>] — the same numbers the
//  documents carry — so the reader can check it and the verifier still checks every quote against the
//  document itself. A line whose document is not in the case is never written.
//
//  The text depends only on the ledger and the case's documents (stable order, no dates of the call),
//  so it is byte-identical across questions and the provider's cache holds it.
//
//  Not tested yet (owner 2026-11-22: implement now, test later).
//

import Foundation

public nonisolated struct CaseLedgerBriefing: Sendable, Equatable {
    public struct Entity: Sendable, Equatable { public var id: UUID; public var kind: String; public var value: String; public var tier: String; public var source: UUID; public var confidence: Double; public var aliases: [String] }
    public struct Event: Sendable, Equatable { public var id: UUID; public var kind: String; public var date: Date; public var endDate: Date?; public var title: String; public var summary: String?; public var source: UUID; public var dateConfidence: Double; public var tier: String }
    public struct Relationship: Sendable, Equatable { public var kind: String; public var from: String; public var to: String; public var source: UUID }
    public struct Field: Sendable, Equatable { public var type: String; public var value: String; public var confidence: Double; public var method: String; public var source: UUID }
    public struct Fact: Sendable, Equatable { public var subject: String; public var field: String; public var value: String; public var unit: String?; public var status: String; public var confidence: Double; public var source: UUID }
    public struct Statement: Sendable, Equatable { public var subject: String; public var predicate: String; public var object: String; public var agent: String; public var confidence: Double; public var source: UUID }
    public struct Contradiction: Sendable, Equatable {
        public var description: String; public var claimA: String; public var claimB: String; public var sourceA: UUID; public var sourceB: UUID?; public var severity: String
        /// AI-43: found by the AI (alone or with the rules), quote checked; false = rule-made only.
        public var foundByAI: Bool = false
    }
    public struct Memory: Sendable, Equatable { public var subject: String; public var narrative: String; public var sources: [UUID]; public var confidence: Double }
    public struct Summary: Sendable, Equatable { public var level: String; public var body: String; public var sources: [UUID]; public var confidence: Double }
    // Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet. The case's own work, each row tied to its documents.
    public struct Money: Sendable, Equatable { public var kind: String; public var amount: String; public var currency: String; public var date: String?; public var payer: String?; public var payee: String?; public var reference: String?; public var disputed: Bool; public var source: UUID }
    public struct Claim: Sendable, Equatable { public var subject: String; public var statement: String; public var review: String; public var conflict: String; public var sources: [UUID] }
    public struct MapLink: Sendable, Equatable { public var type: String; public var from: String; public var to: String; public var rationale: String; public var certainty: String?; public var sources: [UUID] }
    public struct Finding: Sendable, Equatable { public var kind: String; public var text: String; public var review: String; public var sources: [UUID] }
    public struct MethodCheck: Sendable, Equatable { public var method: String; public var observation: String; public var sources: [UUID] }
    public struct Intake: Sendable, Equatable { public var label: String; public var channel: String; public var suppliedBy: String?; public var claimedAuthor: String?; public var captured: String?; public var decision: String?; public var source: UUID }
    public struct VerifiedAnswer: Sendable, Equatable { public var question: String; public var answer: String; public var state: String; public var sources: [UUID] }
    public struct HistoryLine: Sendable, Equatable { public var story: String; public var item: String; public var version: Int; public var versions: Int; public var sources: [UUID] }
    /// A reference-shelf document (reference only — never evidence, never a [D<n>]).
    public struct ShelfDocument: Sendable, Equatable { public var title: String; public var passages: Int }

    /// The rows, as the repository read them.
    public struct Material: Sendable, Equatable {
        public var entities: [Entity] = []
        public var events: [Event] = []
        public var relationships: [Relationship] = []
        public var fields: [Field] = []
        public var facts: [Fact] = []
        public var statements: [Statement] = []
        public var contradictions: [Contradiction] = []
        public var memory: [Memory] = []
        public var summaries: [Summary] = []
        /// Documents of the case this Mac could not read (or read in part), with the reason.
        public var coverageGaps: [(name: String, reason: String)] = []
        // Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet.
        public var money: [Money] = []
        public var claims: [Claim] = []
        public var mapLinks: [MapLink] = []
        public var findings: [Finding] = []
        public var methodChecks: [MethodCheck] = []
        public var intake: [Intake] = []
        public var verifiedAnswers: [VerifiedAnswer] = []
        public var history: [HistoryLine] = []
        public var shelf: [ShelfDocument] = []
        /// AI split AI-45 (owner 2026-11-23) — the AI case picture: the AI's records (origin "picture"), each quote checked.
        public var aiRecords: [CaseAIRecord] = []
        /// How many of the case's documents the picture has read at their current text (nil: unknown).
        public var pictureRead: Int?
        /// Accuracy F4 (2026-11-25) — the case documents' texts (KnowledgeObject id → text), for the exact cross-document
        /// discrepancy list. Empty: no list.
        public var documentTexts: [UUID: String] = [:]
        public init() {}
        public static func == (a: Material, b: Material) -> Bool {
            a.entities == b.entities && a.events == b.events && a.relationships == b.relationships && a.fields == b.fields
                && a.facts == b.facts && a.statements == b.statements && a.contradictions == b.contradictions
                && a.memory == b.memory && a.summaries == b.summaries
                && a.money == b.money && a.claims == b.claims && a.mapLinks == b.mapLinks && a.findings == b.findings
                && a.methodChecks == b.methodChecks && a.intake == b.intake && a.verifiedAnswers == b.verifiedAnswers
                && a.history == b.history && a.shelf == b.shelf && a.aiRecords == b.aiRecords && a.pictureRead == b.pictureRead
                && a.documentTexts == b.documentTexts
                && a.coverageGaps.map { $0.name + "|" + $0.reason } == b.coverageGaps.map { $0.name + "|" + $0.reason }
        }
    }

    /// The briefing text (empty when the ledger knows nothing about the case's documents).
    public let text: String
    /// How many lines each section held and how many were left out for length (never silent).
    public let lineCounts: [String: (shown: Int, more: Int)]
    public static func == (a: CaseLedgerBriefing, b: CaseLedgerBriefing) -> Bool { a.text == b.text }

    /// Unified path AI-31 (owner 2026-11-22) — not tested yet. The neutral kind for a coverage
    /// gap's stated reason (most benign reading when the reason says nothing specific).
    static func missingKind(forReason reason: String) -> MissingEvidenceKind {
        let r = reason.lowercased()
        if ["password", "encrypt", "locked", "protected"].contains(where: r.contains) { return .encrypted }
        if ["corrupt", "damaged", "could not be read", "unreadable", "malformed"].contains(where: r.contains) { return .corrupt }
        if ["not yet", "pending", "queued", "waiting", "partly read", "ocr"].contains(where: r.contains) { return .deferredProcessing }
        if ["unsupported", "no reader", "format", "preserved"].contains(where: r.contains) { return .preservedOnly }
        if ["withheld", "redact", "privilege"].contains(where: r.contains) { return .redactedOut }
        return .searchedNotFound
    }

    /// AI-43 — the label of anything rule-made that stays in the briefing.
    public static let hintsTitle = "Hints (rule-made, unverified)"

    /// Accuracy F2 — the per-party money section.
    public static let partyMoneyTitle = "Money by party (who paid whom as the AI classified it; the app's exact sums per party and currency)"

    /// The most lines per section and the most characters of one line.
    public static let linesPerSection = 150
    static let lineLength = 300

    /// AI-45 — a line shortened to `lineLength` keeps its trailing [D<n>] tags (the reader and the verifier need them).
    static func clip(_ line: String, to length: Int = lineLength) -> String {
        guard line.count > length else { return line }
        var body = Substring(line), tags = ""
        if let r = line.range(of: #"(\s\[D\d+\])+\s*$"#, options: .regularExpression) {
            tags = String(line[r]).trimmingCharacters(in: .whitespaces)
            body = line[..<r.lowerBound]
        }
        let room = max(20, length - tags.count - 2)
        return String(body.prefix(room)).trimmingCharacters(in: .whitespaces) + "…" + (tags.isEmpty ? "" : " " + tags)
    }

    /// Build the briefing: `number` maps a document (KnowledgeObject id) to its [D<n>] number.
    /// AI split AI-45 (owner 2026-11-23): the briefing IS the AI case picture (`picture`); the older rule sections are built
    /// only on the retired path (RetiredPaths .ruleBriefingFacts on).
    public static func build(_ m: Material, number: [UUID: Int]) -> CaseLedgerBriefing {
        RetiredPaths.isOn(.ruleBriefingFacts) ? legacy(m, number: number) : picture(m, number: number)
    }

    /// AI split AI-45 (owner 2026-11-23) — the AI case picture as the briefing. Sections, in a fixed order:
    /// the AI's records made while reading the whole case (people and organisations with type and role, dated events,
    /// facts and money, relationships, conflicts, the AI's hypotheses, gaps and open questions) — every line quote-checked
    /// and tagged [D<n>]; the case's own records (money records, map links, findings, methods review, intake); exact items
    /// (coverage and counts, what was not read, kind of evidence missing, the reference shelf). Rule-made material appears
    /// only while the case has no AI picture yet, under "Hints (rule-made, unverified)". Nothing question-specific (verified
    /// answers, AI suggestions, records written while answering a question) is here, so the prefix is the same for every
    /// question until the documents or the picture change.
    static func picture(_ m: Material, number: [UUID: Int]) -> CaseLedgerBriefing {
        var out: [String] = []
        var counts: [String: (Int, Int)] = [:]
        func tag(_ id: UUID?) -> String? { id.flatMap { number[$0] }.map { "[D\($0)]" } }
        func tags(_ ids: [UUID]) -> String? {
            let t = Array(Set(ids.compactMap { number[$0] })).sorted().map { "[D\($0)]" }
            return t.isEmpty ? nil : t.joined(separator: " ")
        }
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            let shown = Array(lines.prefix(linesPerSection))
            counts[title] = (shown.count, lines.count - shown.count)
            out.append("## " + title)
            // Accuracy D6: a discrepancy line is already fitted (its descriptions shortened); it is never cut.
            out.append(contentsOf: shown.map { title == Self.discrepancyTitle ? $0 : clip($0) })
            if lines.count > shown.count { out.append("(\(lines.count - shown.count) more not listed here; they are in the documents.)") }
        }
        let records = m.aiRecords.filter { $0.origin == "picture" }
        func of(_ k: CaseAIRecord.Kind) -> [CaseAIRecord] {
            records.filter { $0.kind == k }.sorted { ($0.text.lowercased(), $0.id.uuidString) < ($1.text.lowercased(), $1.id.uuidString) }
        }
        let checked = "(found by AI, quote checked)"
        section("People and organisations " + checked, of(.entity).compactMap { r in
            guard let t = tag(r.document) else { return nil }
            return "- \(r.text) — \(r.entityType ?? "other")\(r.role.map { "; " + $0 } ?? "") \(t)"
        })
        func dayKey(_ r: CaseAIRecord) -> (Int, Int, Int, String) {
            let d = VerifiedAnswerComposer.values(in: r.dateText ?? "").dates.first
            return (d?.year ?? 9_999, d?.month ?? 13, d?.day ?? 32, r.text.lowercased() + r.id.uuidString)
        }
        section("Dated events " + checked, of(.event).sorted { dayKey($0) < dayKey($1) }.compactMap { r in
            guard let t = tag(r.document) else { return nil }
            return "- \(r.dateText ?? "undated"): \(r.text) \(t)"
        })
        section("Facts and money " + checked, of(.fact).compactMap { r in tag(r.document).map { "- \(r.text) \($0)" } })
        // AI split AI-48 (owner 2026-11-23): the AI classified the money; the app sums it exactly (per currency, never mixed).
        let money = CaseAIUnderstanding.money(records)
        section("Money figures (the AI's classification, the app's exact sums)", money.figures.compactMap { f in
            f.sum.map { "- \(f.figure): \($0)" }
        })
        // Accuracy F2 (FAIR3 root cause, 2026-11-25): each party's own money — in, out, kept (in − out) and the balances its
        // documents quote — instead of one total over every payer. Case-level, so the prefix stays stable between questions.
        section(Self.partyMoneyTitle, money.flows.map { CaseAIUnderstanding.flowLine($0, number: number) })
        section("Relationships " + checked, of(.relationship).compactMap { r in
            guard let t = tag(r.document) else { return nil }
            return "- \(r.from ?? "?") — \(r.relation ?? "related to") — \(r.to ?? "?") \(t)"
        })
        var conflicts: [String] = of(.conflict).compactMap { r in
            guard let a = tag(r.document) else { return nil }
            let b = tag(r.documentB) ?? a
            func cut(_ q: String?) -> String {
                let q = q ?? ""
                guard q.count > 100 else { return q }
                return String(q.prefix(100)).split(separator: " ").dropLast().joined(separator: " ") + "…"
            }
            // Accuracy G5: two figures that differ only by rounding at their stated precision are said so (exact).
            let rounding = CaseAgent.roundingNote(between: r.quote ?? "", and: r.quoteB ?? "").map { " (app, exact: " + $0 + ")" } ?? ""
            return "- \(r.text): \u{201C}\(cut(r.quote))\u{201D} \(a) / \u{201C}\(cut(r.quoteB))\u{201D} \(b)" + rounding
        }
        conflicts += m.contradictions.compactMap { c in
            guard c.foundByAI, let a = tag(c.sourceA) else { return nil }
            let b = c.sourceB.flatMap { tag($0) }.map { " vs " + $0 } ?? ""
            let rounding = CaseAgent.roundingNote(between: c.claimA, and: c.claimB).map { " (app, exact: " + $0 + ")" } ?? ""
            return "- \(c.description): \"\(c.claimA)\" / \"\(c.claimB)\" \(a)\(b)" + rounding
        }
        section("Conflicts " + checked, conflicts)
        // Accuracy F4 (FAIR3 root cause, 2026-11-25): exact cross-document mismatches the app found, for the AI to judge.
        section(Self.discrepancyTitle, Self.discrepancies(texts: m.documentTexts, number: number, records: records))
        section("Hypotheses (the AI's own, NOT findings; their quotes checked)", of(.hypothesis).map { r in
            let t = tag(r.document).map { " " + $0 } ?? ""
            return "- \(r.text) (\(r.supporting.count) quote\(r.supporting.count == 1 ? "" : "s") for, \(r.against.count) against)\(t)"
        })
        section("Gaps, open tasks and questions for you (the AI's)", (of(.task) + of(.question)).map { r in
            "- (\(r.kind == .task ? "task" : "question for you")) \(r.text)"
        })
        // The case's own records (made by people, or AI work the app checked), each tied to its documents.
        section("Money (the case's money records)", m.money.compactMap { r in
            guard let t = tag(r.source) else { return nil }
            let parties = [r.payer.map { "from " + $0 }, r.payee.map { "to " + $0 }].compactMap { $0 }.joined(separator: " ")
            return "- \(r.date ?? "undated"): \(r.kind) \(r.amount)\(r.currency.isEmpty ? "" : " " + r.currency)\(parties.isEmpty ? "" : " " + parties)\(r.reference.map { " (ref " + $0 + ")" } ?? "")\(r.disputed ? " — disputed" : "") \(t)"
        })
        section("Case map links (placed by investigators)", m.mapLinks.compactMap { l in
            guard let t = tags(l.sources) else { return nil }
            return "- \(l.from) — \(l.type) — \(l.to)\(l.certainty.map { " [" + $0 + "]" } ?? ""): \(l.rationale) \(t)"
        })
        section("Findings and their review", m.findings.compactMap { f in
            guard let t = tags(f.sources) else { return nil }
            return "- (\(f.kind); \(f.review)) \(f.text) \(t)"
        })
        section("Methods review results", m.methodChecks.compactMap { c in
            guard let t = tags(c.sources) else { return nil }
            return "- \(c.method): \(c.observation) \(t)"
        })
        section("Who supplied what (intake)", m.intake.compactMap { i in
            guard let t = tag(i.source) else { return nil }
            let who = [i.suppliedBy.map { "supplied by " + $0 }, i.claimedAuthor.map { "claims author " + $0 }, i.captured.map { "captured " + $0 }]
                .compactMap { $0 }.joined(separator: "; ")
            return "- \(i.label) via \(i.channel)\(who.isEmpty ? "" : " — " + who)\(i.decision.map { " (" + $0 + ")" } ?? "") \(t)"
        })
        // Rule-made material only while there is no AI picture yet, labelled as hints.
        if records.isEmpty {
            let df = DateFormatter(); df.dateFormat = "d MMM yyyy"
            df.timeZone = TimeZone(identifier: "UTC"); df.locale = Locale(identifier: "en_US_POSIX")
            section(Self.hintsTitle + ": dated items", m.events.compactMap { e in
                guard let t = tag(e.source), !e.title.isEmpty else { return nil }
                let approx = e.dateConfidence < 0.6 ? " (date approximate)" : ""
                return "- \(df.string(from: e.date))\(approx): \(e.title) \(t)"
            })
            section(Self.hintsTitle + ": names seen in the documents", m.entities.compactMap { e in
                guard let t = tag(e.source), !e.value.isEmpty else { return nil }
                let aka = e.aliases.isEmpty ? "" : " (also written: " + e.aliases.prefix(6).joined(separator: ", ") + ")"
                return "- \(e.value)\(aka) \(t)"
            })
        }
        // Exact items.
        var coverage: [String] = []
        if !records.isEmpty || m.pictureRead != nil {
            coverage.append("- Documents in the case: \(number.count)")
            if let read = m.pictureRead { coverage.append("- Read whole by the AI for this picture: \(read) of \(number.count)") }
            let byKind = CaseAIRecord.Kind.allCases.compactMap { k -> String? in
                let n = records.filter { $0.kind == k }.count
                let plural = ["entity": "entities", "relationship": "relationships", "hypothesis": "hypotheses"][k.rawValue] ?? k.rawValue + "s"
                return n == 0 ? nil : "\(n) \(n == 1 ? k.rawValue : plural)"
            }
            coverage.append("- Records the AI made, each quote checked: \(records.count)" + (byKind.isEmpty ? "" : " (" + byKind.joined(separator: ", ") + ")"))
        }
        section("Coverage (exact)", coverage)
        section("Not read on this Mac", m.coverageGaps.map { "- \($0.name): \($0.reason)" })
        section("Kind of evidence missing", m.coverageGaps.map { gap in
            "- " + MissingEvidence(requestedField: gap.name, kind: Self.missingKind(forReason: gap.reason), documentsSearched: number.count).disclosure()
        })
        if !m.shelf.isEmpty, !out.isEmpty {
            section("Your reference shelf (reference material, NOT case evidence; never cite it as [D<n>])",
                    m.shelf.map { "- \($0.title) (\($0.passages) passage\($0.passages == 1 ? "" : "s"))" })
        }
        guard !out.isEmpty else { return CaseLedgerBriefing(text: "", lineCounts: [:]) }
        let head = records.isEmpty ? """
        === Case briefing: what the app knows about this case's documents ===
        Each line ends with the document it came from, as [D<n>]. The briefing can be incomplete or wrong; \
        the documents decide. Quote only from the documents, never from this briefing.
        """ : """
        === Case picture: what the AI found in this case's documents (every line quote-checked) and the case's own records ===
        Each line ends with the document it came from, as [D<n>]. The picture can be incomplete; the documents decide. \
        Quote only from the documents, never from this picture.
        """
        return CaseLedgerBriefing(text: head + "\n" + out.joined(separator: "\n") + "\n=== End of the case briefing ===",
                                  lineCounts: counts.mapValues { (shown: $0.0, more: $0.1) })
    }

    /// The briefing before AI-45 (retired path: RetiredPaths .ruleBriefingFacts on).
    static func legacy(_ m: Material, number: [UUID: Int]) -> CaseLedgerBriefing {
        var out: [String] = []
        var counts: [String: (Int, Int)] = [:]
        func tag(_ id: UUID) -> String? { number[id].map { "[D\($0)]" } }
        func tags(_ ids: [UUID]) -> String? {
            let t = ids.compactMap { number[$0] }.sorted().map { "[D\($0)]" }
            return t.isEmpty ? nil : t.joined(separator: " ")
        }
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            let shown = Array(lines.prefix(linesPerSection))
            counts[title] = (shown.count, lines.count - shown.count)
            out.append("## " + title)
            out.append(contentsOf: shown.map { clip($0) })
            if lines.count > shown.count { out.append("(\(lines.count - shown.count) more not listed here; they are in the documents.)") }
        }
        let df = DateFormatter(); df.dateFormat = "d MMM yyyy"
        df.timeZone = TimeZone(identifier: "UTC"); df.locale = Locale(identifier: "en_US_POSIX")

        // AI-43 (owner 2026-11-23, AI does the thinking): rule entity kinds ("DENMAN — location"), rule relationships
        // (names that appear together) and rule-only contradictions are no longer passed as facts. Names stay, without
        // a kind, in a section labelled as hints; the AI decides who is who.
        let ruleFacts = RetiredPaths.isOn(.ruleBriefingFacts)
        if ruleFacts {
            section("People and organisations", m.entities.compactMap { e in
                guard let t = tag(e.source), !e.value.isEmpty else { return nil }
                let aka = e.aliases.isEmpty ? "" : " (also written: " + e.aliases.prefix(6).joined(separator: ", ") + ")"
                return "- \(e.value) — \(e.kind)\(aka), tier \(e.tier) \(t)"
            })
        }
        section("Timeline", m.events.compactMap { e in
            guard let t = tag(e.source), !e.title.isEmpty else { return nil }
            let approx = e.dateConfidence < 0.6 ? " (date approximate)" : ""
            let end = e.endDate.map { " to " + df.string(from: $0) } ?? ""
            return "- \(df.string(from: e.date))\(end)\(approx): \(e.title)\(e.summary.map { " — " + $0 } ?? "") \(t)"
        })
        if ruleFacts {
            section("Relationships", m.relationships.compactMap { r in
                guard let t = tag(r.source) else { return nil }
                return "- \(r.from) — \(r.kind) — \(r.to) \(t)"
            })
        }
        section("Recorded values (numbers, amounts, dates)", m.fields.compactMap { f in
            guard let t = tag(f.source), !f.value.isEmpty else { return nil }
            let read = f.method == "ocr" ? " (read from a scan)" : ""
            return "- \(f.type): \(f.value)\(read) \(t)"
        })
        section("Facts", m.facts.compactMap { f in
            guard let t = tag(f.source) else { return nil }
            return "- \(f.subject): \(f.field) = \(f.value)\(f.unit.map { " " + $0 } ?? "") \(t)"
        })
        section("Statements (who said what)", m.statements.compactMap { s in
            guard let t = tag(s.source) else { return nil }
            return "- \(s.subject) \(s.predicate) \(s.object) \(t)"
        })
        section(ruleFacts ? "Conflicts already found" : "Conflicts already found (found by AI, quote checked)", m.contradictions.compactMap { c in
            guard ruleFacts || c.foundByAI, let a = tag(c.sourceA) else { return nil }
            let b = c.sourceB.flatMap(tag).map { " vs " + $0 } ?? ""
            let rounding = CaseAgent.roundingNote(between: c.claimA, and: c.claimB).map { " (app, exact: " + $0 + ")" } ?? ""
            return "- \(c.description): \"\(c.claimA)\" / \"\(c.claimB)\" \(a)\(b)" + rounding
        })
        section("What the app has distilled", m.memory.compactMap { mo in
            guard let t = tags(mo.sources) else { return nil }
            return "- \(mo.subject): \(mo.narrative) \(t)"
        })
        section("Summaries", m.summaries.compactMap { s in
            guard let t = tags(s.sources) else { return nil }
            return "- (\(s.level)) \(s.body) \(t)"
        })
        // Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet. The case's own work, every line tied to its
        // documents; a row with no case document is never written.
        section("Money (the case's money records)", m.money.compactMap { r in
            guard let t = tag(r.source) else { return nil }
            let parties = [r.payer.map { "from " + $0 }, r.payee.map { "to " + $0 }].compactMap { $0 }.joined(separator: " ")
            return "- \(r.date ?? "undated"): \(r.kind) \(r.amount)\(r.currency.isEmpty ? "" : " " + r.currency)\(parties.isEmpty ? "" : " " + parties)\(r.reference.map { " (ref " + $0 + ")" } ?? "")\(r.disputed ? " — disputed" : "") \(t)"
        })
        section("Claims register", m.claims.compactMap { c in
            guard let t = tags(c.sources) else { return nil }
            return "- \(c.subject): \(c.statement) (review: \(c.review); conflict: \(c.conflict)) \(t)"
        })
        section("Case map links (placed by investigators)", m.mapLinks.compactMap { l in
            guard let t = tags(l.sources) else { return nil }
            return "- \(l.from) — \(l.type) — \(l.to)\(l.certainty.map { " [" + $0 + "]" } ?? ""): \(l.rationale) \(t)"
        })
        section("Findings and their review", m.findings.compactMap { f in
            guard let t = tags(f.sources) else { return nil }
            return "- (\(f.kind); \(f.review)) \(f.text) \(t)"
        })
        section("Methods review results", m.methodChecks.compactMap { c in
            guard let t = tags(c.sources) else { return nil }
            return "- \(c.method): \(c.observation) \(t)"
        })
        section("Who supplied what (intake)", m.intake.compactMap { i in
            guard let t = tag(i.source) else { return nil }
            let who = [i.suppliedBy.map { "supplied by " + $0 }, i.claimedAuthor.map { "claims author " + $0 }, i.captured.map { "captured " + $0 }]
                .compactMap { $0 }.joined(separator: "; ")
            return "- \(i.label) via \(i.channel)\(who.isEmpty ? "" : " — " + who)\(i.decision.map { " (" + $0 + ")" } ?? "") \(t)"
        })
        section("Answers already verified in this case", m.verifiedAnswers.compactMap { a in
            guard let t = tags(a.sources) else { return nil }
            return "- Q: \(a.question) — A (\(a.state)): \(a.answer) \(t)"
        })
        section("Reconstructed history", m.history.compactMap { h in
            guard let t = tags(h.sources) else { return nil }
            return "- \(h.story) (version \(h.version) of \(h.versions)): \(h.item) \(t)"
        })
        if !ruleFacts {
            section(Self.hintsTitle + ": names seen in the documents", m.entities.compactMap { e in
                guard let t = tag(e.source), !e.value.isEmpty else { return nil }
                let aka = e.aliases.isEmpty ? "" : " (also written: " + e.aliases.prefix(6).joined(separator: ", ") + ")"
                return "- \(e.value)\(aka) \(t)"
            })
        }
        section("Not read on this Mac", m.coverageGaps.map { "- \($0.name): \($0.reason)" })
        // Unified path AI-31 (owner 2026-11-22) — not tested yet. What KIND of evidence is missing
        // for the case (MissingEvidenceTaxonomy, neutral wording — a gap is never proof of anything).
        section("Kind of evidence missing", m.coverageGaps.map { gap in
            let kind = Self.missingKind(forReason: gap.reason)
            return "- " + MissingEvidence(requestedField: gap.name, kind: kind, documentsSearched: number.count).disclosure()
        })

        // Unified path AI-38 (owner 2026-11-22, round 2) — not tested yet. The reference shelf: its own labelled
        // section, never evidence and never numbered as a case document.
        if !m.shelf.isEmpty, !out.isEmpty {
            section("Your reference shelf (reference material, NOT case evidence; never cite it as [D<n>])",
                    m.shelf.map { "- \($0.title) (\($0.passages) passage\($0.passages == 1 ? "" : "s"))" })
        }
        guard !out.isEmpty else { return CaseLedgerBriefing(text: "", lineCounts: [:]) }
        let head = """
        === Case briefing: what the app extracted from this case's documents ===
        Each line ends with the document it came from, as [D<n>]. The briefing can be incomplete or wrong; \
        the documents decide. Quote only from the documents, never from this briefing.
        """
        return CaseLedgerBriefing(text: head + "\n" + out.joined(separator: "\n") + "\n=== End of the case briefing ===",
                            lineCounts: counts.mapValues { (shown: $0.0, more: $0.1) })
    }
}

// MARK: - Accuracy F4: cross-document discrepancies (app-found, exact, for the AI to judge)

extension CaseLedgerBriefing {
    /// The section title (never a conclusion: the AI judges what a difference means).
    public static let discrepancyTitle = "Cross-document discrepancies (app-found, for the AI to judge; exact matches only, a difference may have an innocent reason)"
    static let maxDiscrepancies = 40

    /// One dated mention of a key (a reference code, an account with an amount, an amount with a name) in one document line.
    struct KeyedMention: Sendable {
        let key: String
        let label: String
        let document: Int
        let day: VerifiedAnswerComposer.Day
        let amounts: Set<Double>
    }

    /// Amounts written in a line as money ("$180,000", "180,000.00", "180000.00", "€ 500.000,00" via CaseAgent), dates removed
    /// first; 100 or more.
    static func lineAmounts(_ line: String) -> Set<Double> {
        let undated = CaseAgent.asciiDigits(line).replacingOccurrences(of: #"\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b|\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b"#, with: " ", options: .regularExpression)
        var out = Set<Double>()
        for a in CaseAgent.amounts(in: undated) { out.insert(NSDecimalNumber(decimal: a.value).doubleValue) }
        // Money written without a currency, in any style: 180,000 · 180,000.00 · 1,80,000.00 · 180.000,00 · 180000.00 · 180000,00.
        if let re = try? NSRegularExpression(pattern: #"(?<![\d.,'])(\d{1,2}(?:,\d{2})+,\d{3}(?:\.\d{2})?|\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d{1,3}(?:\.\d{3})+,\d{2}|\d{1,3}(?:'\d{3})+(?:\.\d{2})?|\d+[.,]\d{2})(?![\d.,]*\d)"#) {
            let ns = undated as NSString
            for m in re.matches(in: undated, range: NSRange(location: 0, length: ns.length)) {
                if let d = CaseAgent.parseNumber(ns.substring(with: m.range(at: 1))) { out.insert(NSDecimalNumber(decimal: d).doubleValue) }
            }
        }
        return out.filter { $0 >= 100 }
    }

    /// The capitalised name words of a line (4+ letters, months, weekdays and common ledger words aside), lower-cased.
    static func nameWords(_ line: String) -> Set<String> {
        let skip: Set<String> = ["january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
                                 "december", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "total", "balance",
                                 "payment", "transfer", "wire", "date", "amount", "invoice", "account", "bank", "debit", "credit", "opening",
                                 "closing", "statement", "reference", "from", "with", "this", "that", "page", "limited", "outgoing", "incoming"]
        var out = Set<String>()
        for w in line.split(whereSeparator: { !$0.isLetter }) where w.count >= 4 && (w.first?.isUppercase ?? false) {
            let l = w.lowercased()
            if !skip.contains(l) { out.insert(l) }
        }
        return out
    }

    /// Accuracy G2: the same day under some reading of each (a swappable date whose document's order is unknown).
    static func sameDay(_ a: VerifiedAnswerComposer.Day, _ b: VerifiedAnswerComposer.Day) -> Bool { DateOrder.sameDay(a, b) }

    static func show(_ d: VerifiedAnswerComposer.Day) -> String { DateOrder.show(d) }

    /// Accuracy G2 — two documents' dates for one key agree when some date of each is the same day, or within
    /// `CaseAIUnderstanding.settlementDays` (a payment's sending and receiving days on two banks' statements).
    static func agree(_ a: [VerifiedAnswerComposer.Day], _ b: [VerifiedAnswerComposer.Day]) -> Bool {
        a.contains { x in b.contains { y in sameDay(x, y) || (DateOrder.daysApart(x, y).map { $0 <= CaseAIUnderstanding.settlementDays } ?? false) } }
    }

    /// Days from `a` to `b` (positive: b is later); a missing year takes the other's (or 2000 when both lack it).
    static func days(from a: VerifiedAnswerComposer.Day, to b: VerifiedAnswerComposer.Day) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let ya = a.year ?? b.year ?? 2000, yb = b.year ?? a.year ?? 2000
        guard let da = cal.date(from: DateComponents(year: ya, month: a.month, day: a.day ?? 1)),
              let db = cal.date(from: DateComponents(year: yb, month: b.month, day: b.day ?? 1)) else { return nil }
        return cal.dateComponents([.day], from: da, to: db).day
    }

    /// Accuracy F4 (FAIR3 root cause, 2026-11-25) — the same reference code (or the same account with the same amount, or the
    /// same amount with the same name word) written with DIFFERENT dates in different documents, or a reference with the
    /// same date and different amounts; each with its documents and where each date falls next to the nearest dated money
    /// record of the AI's picture (other than the key's own). Exact text matching only; never stated as a conclusion.
    static func discrepancies(texts: [UUID: String], number: [UUID: Int], records: [CaseAIRecord]) -> [String] {
        guard texts.count >= 2 else { return [] }
        var mentions: [KeyedMention] = []
        for (id, text) in texts.sorted(by: { (number[$0.key] ?? 0) < (number[$1.key] ?? 0) }) {
            guard let n = number[id] else { continue }
            // Accuracy G2 (FAIR4 §5 item 4): the document's own day/month order ("03/09/2026" in an Irish statement is 3 Sept).
            let order = DateOrder.dayFirst(text)
            var lines: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let l = String(raw)
                if l.count > 300 { lines += ProceedingEventExtractor.rawSentences(of: l) } else { lines.append(l) }
            }
            for line in lines {
                let dated = VerifiedAnswerComposer.values(in: line).dates.filter { $0.day != nil }
                guard dated.count == 1, let first = dated.first else { continue }   // one date: the line's own
                let day = DateOrder.resolved(first, dayFirst: order)
                let amounts = lineAmounts(line)
                let ids = VerifiedAnswerComposer.identifiers(in: line)
                var keys: [(String, String)] = []
                for i in ids {
                    let isCode = i.token.contains(where: \.isLetter)
                    if isCode { keys.append(("ref:" + i.token.uppercased(), i.token)) }
                    // An account: keyed by its last four digits, so a masked and a full number of one account meet
                    // (universality); a docket-style number without letters ("22-1234") is no account.
                    else if i.token.allSatisfy(\.isNumber) {
                        let tail = String(i.token.suffix(4))
                        for a in amounts { keys.append(("acct:\(tail)|\(a)", "account …\(tail) with \(Self.amountText(a))")) }
                    }
                }
                if ids.isEmpty { for a in amounts where a >= 1_000 { for w in nameWords(line) { keys.append(("amt:\(a)|\(w)", "\(Self.amountText(a)) with \u{201C}\(w)\u{201D}")) } } }
                for (k, label) in keys { mentions.append(KeyedMention(key: k, label: label, document: n, day: day, amounts: amounts)) }
            }
        }
        // Dated money records (the AI's picture) for "where each date falls".
        let moneyDays: [(day: VerifiedAnswerComposer.Day, record: CaseAIRecord)] = records.compactMap { r in
            guard r.kind == .fact, r.entityType == CaseAIRecord.moneyType, CaseAIUnderstanding.movementKinds.contains(r.role ?? ""),
                  let d = VerifiedAnswerComposer.values(in: r.dateText ?? "").dates.first, d.day != nil else { return nil }
            return (DateOrder.resolved(d, dayFirst: r.document.flatMap { texts[$0] }.flatMap(DateOrder.dayFirst)), r)
        }
        var out: [(key: String, line: String, docs: Set<Int>)] = []
        for (key, group) in Dictionary(grouping: mentions, by: \.key).sorted(by: { $0.key < $1.key }) {
            guard Set(group.map(\.document)).count >= 2 else { continue }
            // Distinct dates (a missing year matches any year).
            var clusters: [(day: VerifiedAnswerComposer.Day, docs: [Int], amounts: Set<Double>)] = []
            for m in group {
                if let i = clusters.firstIndex(where: { sameDay($0.day, m.day) }) {
                    if !clusters[i].docs.contains(m.document) { clusters[i].docs.append(m.document) }
                    clusters[i].amounts.formUnion(m.amounts)
                    if clusters[i].day.year == nil, m.day.year != nil { clusters[i].day = m.day }
                } else { clusters.append((m.day, [m.document], m.amounts)) }
            }
            let label = group[0].label
            if clusters.count >= 2 {
                // Different dates must come from different documents (one document's own list of dates is not a mismatch).
                guard Set(clusters.flatMap(\.docs)).count >= 2, clusters.contains(where: { c in clusters.contains { $0.docs != c.docs } }) else { continue }
                // Accuracy G2 (FAIR4 §5 item 4): only when two documents share NO date for the key (under either reading, or
                // within settlement days). One document listing three transfers on an account, and another naming one of
                // them, is not a discrepancy (inv104 "account …8804 with 50,000").
                let byDoc = Dictionary(grouping: group, by: \.document).mapValues { $0.map(\.day) }
                let docs = byDoc.keys.sorted()
                let disagreeing = docs.contains { x in docs.contains { y in y > x && !agree(byDoc[x] ?? [], byDoc[y] ?? []) } }
                guard disagreeing else { continue }
                let token = key.hasPrefix("ref:") ? label : nil
                let parts = clusters.map { c -> String in
                    "\(show(c.day)) in " + c.docs.sorted().map { "[D\($0)]" }.joined(separator: " ")
                }
                // Accuracy D6 (FAIR5 §6 item 5): each comparison's decisive part (dates, days, the record's kind, its document)
                // is kept whole; only the record's description in parentheses is shortened to fit the line.
                let falls = clusters.compactMap { c -> (head: String, description: String, doc: String)? in
                    let candidates = moneyDays.filter { md in
                        guard let t = token else { return true }
                        return !(md.record.text.uppercased().contains(t.uppercased()) || (md.record.quote ?? "").uppercased().contains(t.uppercased()))
                    }
                    guard let near = candidates.compactMap({ md -> (Int, VerifiedAnswerComposer.Day, CaseAIRecord)? in
                        days(from: md.day, to: c.day).map { ($0, md.day, md.record) }
                    }).min(by: { abs($0.0) < abs($1.0) || (abs($0.0) == abs($1.0) && $0.2.id.uuidString < $1.2.id.uuidString) }) else { return nil }
                    let rel = near.0 == 0 ? "the same day as" : near.0 < 0 ? "\(-near.0) day\(near.0 == -1 ? "" : "s") before" : "\(near.0) day\(near.0 == 1 ? "" : "s") after"
                    let doc = near.2.document.flatMap { number[$0] }.map { " [D\($0)]" } ?? ""
                    return ("\(show(c.day)) is \(rel) the \(show(near.1)) \(near.2.role ?? "money record")", near.2.text, doc)
                }
                func composed(describing limit: Int) -> String {
                    var l = "- \(label): different dates across documents — " + parts.joined(separator: "; ")
                    if !falls.isEmpty {
                        l += ". Nearest dated money record: " + falls.map { f in
                            let d = Self.shortened(f.description, to: limit)
                            return f.head + (d.isEmpty ? "" : " (\(d))") + f.doc
                        }.joined(separator: "; ")
                    }
                    return l
                }
                var line = composed(describing: 90)
                for limit in [60, 40, 24, 0] where line.count > lineLength { line = composed(describing: limit) }
                out.append((key, line, Set(group.map(\.document))))
            } else if key.hasPrefix("ref:"), let c = clusters.first {
                // Same reference, same date, amounts that share nothing across documents.
                let byDoc = Dictionary(grouping: group, by: \.document).mapValues { $0.reduce(Set<Double>()) { $0.union($1.amounts) } }.filter { !$0.value.isEmpty }
                let sets = Array(byDoc.values)
                guard sets.count >= 2, sets.indices.contains(where: { i in sets.indices.contains { j in j > i && sets[i].isDisjoint(with: sets[j]) } }) else { continue }
                let parts = byDoc.keys.sorted().map { d in (byDoc[d] ?? []).sorted().map(Self.amountText).joined(separator: ", ") + " in [D\(d)]" }
                out.append((key, "- \(label): same date (\(show(c.day))), different amounts — " + parts.joined(separator: "; "), Set(byDoc.keys)))
            }
        }
        // An amount-with-name line whose documents a reference line already covers adds nothing.
        let refDocs = out.filter { $0.key.hasPrefix("ref:") }.map(\.docs)
        let kept = out.filter { o in !(o.key.hasPrefix("amt:") && refDocs.contains { o.docs.isSubset(of: $0) }) }
        // One amount-with-name mismatch per document set and dates (the same rows matched through several name words).
        var seen = Set<String>(), lines: [String] = []
        for o in kept {
            let sig = o.key.hasPrefix("amt:") ? (o.key.split(separator: "|").first.map(String.init) ?? o.key) + o.docs.sorted().map(String.init).joined(separator: ",") : o.key
            guard seen.insert(sig).inserted else { continue }
            lines.append(o.line)
        }
        return Array(lines.prefix(maxDiscrepancies))
    }

    /// Accuracy D6 — a description cut at a word boundary to at most `limit` characters ("…" when cut; empty at 0).
    static func shortened(_ s: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard s.count > limit else { return s }
        let cut = String(s.prefix(limit - 1))
        let words = cut.split(separator: " ")
        // A word cut in the middle is left out; a cut at a word's end keeps it.
        let atWordEnd = s.dropFirst(limit - 1).first.map { $0 == " " } ?? true
        let kept = atWordEnd || words.count <= 1 ? cut : words.dropLast().joined(separator: " ")
        return kept.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:(")) + "…"
    }

    static func amountText(_ v: Double) -> String {
        CaseAgent.format(Decimal(string: String(format: "%.2f", v), locale: Locale(identifier: "en_US_POSIX")) ?? 0, nil)
    }
}
