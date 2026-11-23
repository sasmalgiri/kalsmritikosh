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
        public init() {}
        public static func == (a: Material, b: Material) -> Bool {
            a.entities == b.entities && a.events == b.events && a.relationships == b.relationships && a.fields == b.fields
                && a.facts == b.facts && a.statements == b.statements && a.contradictions == b.contradictions
                && a.memory == b.memory && a.summaries == b.summaries
                && a.money == b.money && a.claims == b.claims && a.mapLinks == b.mapLinks && a.findings == b.findings
                && a.methodChecks == b.methodChecks && a.intake == b.intake && a.verifiedAnswers == b.verifiedAnswers
                && a.history == b.history && a.shelf == b.shelf
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

    /// The most lines per section and the most characters of one line.
    public static let linesPerSection = 150
    static let lineLength = 300

    /// Build the briefing: `number` maps a document (KnowledgeObject id) to its [D<n>] number.
    public static func build(_ m: Material, number: [UUID: Int]) -> CaseLedgerBriefing {
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
            out.append(contentsOf: shown.map { String($0.prefix(lineLength)) })
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
            return "- \(c.description): \"\(c.claimA)\" / \"\(c.claimB)\" \(a)\(b)"
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
