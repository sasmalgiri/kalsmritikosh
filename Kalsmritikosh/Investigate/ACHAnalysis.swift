//
//  ACHAnalysis.swift
//  Kalsmritikosh
//
//  Analysis of Competing Hypotheses (ACH) — Richards Heuer's structured analytic
//  technique. Its defining feature is a MATRIX: hypotheses across the top,
//  evidence down the side, each cell rated for how consistent the evidence is
//  with that hypothesis. The robust answer is the hypothesis with the FEWEST
//  inconsistencies — reached by trying to DISCONFIRM, not to confirm. The matrix
//  aids judgment; it never computes a verdict.
//
//  Investigator workflow review 2026-10-30, I3: a cell nobody has rated is UNASSESSED, not
//  neutral — it carries no information and is shown as such; the matrix reports its rating
//  coverage; hypotheses with the same score are presented together; and with no
//  discriminating assessed evidence the analysis states that no preference is established.
//  An evidence row may carry a structured citation (an exact source version and quote); a row
//  without one is the investigator's own note and is labelled so.
//
//  Pure Codable value; persisted by ACHRepository (schema v152, v166). The report renderer is
//  pure text, reused for copy / export / print.
//

import Foundation

/// How consistent a piece of evidence is with a hypothesis. Only *disconfirming*
/// ratings carry weight (Heuer): the score counts inconsistencies.
public nonisolated enum ACHConsistency: String, Codable, Sendable, CaseIterable, Equatable {
    case veryConsistent, consistent, neutral, inconsistent, veryInconsistent

    /// Compact matrix glyphs (CC / C / N / I / II).
    public var symbol: String {
        switch self {
        case .veryConsistent: return "CC"
        case .consistent: return "C"
        case .neutral: return "N"
        case .inconsistent: return "I"
        case .veryInconsistent: return "II"
        }
    }
    public var label: String {
        switch self {
        case .veryConsistent: return "Very consistent"
        case .consistent: return "Consistent"
        case .neutral: return "Neutral / N/A"
        case .inconsistent: return "Inconsistent"
        case .veryInconsistent: return "Very inconsistent"
        }
    }
    /// Inconsistency points — only I / II count against a hypothesis.
    public var inconsistencyWeight: Int {
        switch self {
        case .veryInconsistent: return 2
        case .inconsistent: return 1
        default: return 0
        }
    }

    /// The glyph for a cell nobody has rated. Distinct from N: it says nothing about the evidence.
    public static let unassessedSymbol = "—"
    public static let unassessedLabel = "Unassessed"
}

public nonisolated struct ACHHypothesis: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public init(text: String) { self.text = text }
}

public nonisolated struct ACHEvidence: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    /// Free text: a document number, a note on where it came from. With no `citation` this is the
    /// investigator's own note, not a source.
    public var source: String = ""
    /// A structured citation — an exact source version (and quote) in the case's scope. Optional;
    /// older rows have none.
    public var citation: StudioEvidenceRef?
    /// §2 — the citation's verification when last checked by the case's evidence verifier
    /// ("verified" / "unverified"); nil = never checked. A citation counts only when verified.
    public var citationState: String?
    public var citationDetail: String?
    public init(text: String, source: String = "", citation: StudioEvidenceRef? = nil, citationState: String? = nil, citationDetail: String? = nil) {
        self.text = text; self.source = source; self.citation = citation; self.citationState = citationState; self.citationDetail = citationDetail
    }
    /// True when the row carries a citation (a source version, document or passage identifier).
    public var hasCitation: Bool { citation?.sourceVersionID != nil || citation?.objectID != nil || citation?.blockID != nil }
    /// True when the citation was VERIFIED against the source in the case — the only cited state.
    /// An identifier alone, or a typed quote that did not verify, is the investigator's note.
    public var isCited: Bool { hasCitation && citationState == "verified" }
}

/// What the assessed matrix establishes about a preference — descriptive, never a finding.
public nonisolated enum ACHPreference: Equatable, Sendable {
    /// No cell has been rated.
    case noAssessment
    /// Cells are rated, but no evidence row discriminates between hypotheses (every assessed row
    /// rates the same across them, or the scores are all equal).
    case noDiscriminatingEvidence
    /// Two or more hypotheses share the fewest inconsistency points.
    case tied([ACHHypothesis], score: Int)
    /// One hypothesis alone has the fewest inconsistency points, on assessed, diagnostic evidence.
    case leading(ACHHypothesis, score: Int, runnerUpScore: Int, diagnostic: [ACHEvidence])

    /// The hypothesis the matrix singles out, when it does.
    public var leading: ACHHypothesis? {
        if case .leading(let h, _, _, _) = self { return h }
        return nil
    }
    /// Every hypothesis with the fewest points (one when leading, several when tied, none otherwise).
    public var candidates: [ACHHypothesis] {
        switch self {
        case .leading(let h, _, _, _): return [h]
        case .tied(let hs, _): return hs
        default: return []
        }
    }
}

public nonisolated enum ACHConfidence: String, Codable, Sendable, CaseIterable {
    case low, moderate, high
    public var label: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }
}

public nonisolated struct ACHConclusion: Codable, Hashable, Sendable {
    public var leadingHypothesisID: UUID?
    public var confidence: ACHConfidence = .moderate
    public var summary: String = ""
    public init() {}
}

public nonisolated struct ACHAnalysis: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var question: String = ""
    public var createdAt: Date
    public var updatedAt: Date
    public var history: [StudioAuditEntry]?

    public var hypotheses: [ACHHypothesis] = []
    public var evidence: [ACHEvidence] = []
    /// Cell ratings keyed by "evidenceID|hypothesisID"; absent = UNASSESSED (not neutral — a
    /// neutral rating is an explicit `.neutral` entry).
    public var ratings: [String: ACHConsistency] = [:]
    public var assumptions: [String] = []
    public var indicators: [String] = []   // "indicators to watch" (Heuer step 8)
    public var conclusion: ACHConclusion = ACHConclusion()

    public init(title: String, now: Date) {
        self.id = UUID(); self.title = title; self.createdAt = now; self.updatedAt = now
    }

    // MARK: Matrix access

    public static func key(_ evidenceID: UUID, _ hypothesisID: UUID) -> String {
        "\(evidenceID.uuidString)|\(hypothesisID.uuidString)"
    }
    /// The rating of a cell, or nil when nobody has rated it.
    public func rating(_ e: ACHEvidence, _ h: ACHHypothesis) -> ACHConsistency? {
        ratings[Self.key(e.id, h.id)]
    }
    /// The matrix glyph for a cell: its rating's symbol, or the unassessed dash.
    public func symbol(_ e: ACHEvidence, _ h: ACHHypothesis) -> String {
        rating(e, h)?.symbol ?? ACHConsistency.unassessedSymbol
    }

    /// Total inconsistency points against a hypothesis (lower = more robust). An unassessed cell
    /// adds nothing — which is why the score is read with `assessedCount` beside it.
    public func inconsistencyScore(_ h: ACHHypothesis) -> Int {
        evidence.reduce(0) { $0 + (rating($1, h)?.inconsistencyWeight ?? 0) }
    }
    /// How many of this hypothesis's cells are rated.
    public func assessedCount(_ h: ACHHypothesis) -> Int {
        evidence.filter { rating($0, h) != nil }.count
    }

    // MARK: Coverage

    public var cellCount: Int { evidence.count * hypotheses.count }
    public var assessedCellCount: Int {
        evidence.reduce(0) { n, e in n + hypotheses.filter { rating(e, $0) != nil }.count }
    }
    public var unassessedCellCount: Int { cellCount - assessedCellCount }
    /// 0…1; 0 when there are no cells.
    public var coverage: Double { cellCount == 0 ? 0 : Double(assessedCellCount) / Double(cellCount) }
    public var isFullyAssessed: Bool { cellCount > 0 && assessedCellCount == cellCount }
    /// The (evidence, hypothesis) pairs still to rate, in matrix order.
    public var unassessedCells: [(evidence: ACHEvidence, hypothesis: ACHHypothesis)] {
        var out: [(ACHEvidence, ACHHypothesis)] = []
        for e in evidence { for h in hypotheses where rating(e, h) == nil { out.append((e, h)) } }
        return out
    }
    /// True when every cell of this evidence row is rated.
    public func isFullyAssessed(_ e: ACHEvidence) -> Bool {
        !hypotheses.isEmpty && hypotheses.allSatisfy { rating(e, $0) != nil }
    }

    /// Hypotheses ranked by fewest inconsistencies (the ACH ordering). Equal scores keep the
    /// matrix order, so a tie is visible as adjacent equal scores.
    public var ranking: [(hypothesis: ACHHypothesis, score: Int)] {
        hypotheses.map { ($0, inconsistencyScore($0)) }
            .sorted { $0.score < $1.score }
    }

    /// What the ratings establish. A sole leading hypothesis needs (a) rated cells, (b) at least one
    /// fully assessed evidence row that rates differently across hypotheses, and (c) a unique
    /// lowest score. Otherwise the result is a tie, or no preference at all.
    public var preference: ACHPreference {
        guard hypotheses.count > 1, assessedCellCount > 0 else { return .noAssessment }
        let diagnostic = evidence.filter { isDiagnostic($0) }
        let ranked = ranking
        guard let best = ranked.first else { return .noAssessment }
        let top = ranked.filter { $0.score == best.score }.map(\.hypothesis)
        if top.count > 1 {
            // Every hypothesis equal on the points → nothing discriminates; some equal → a tie.
            return top.count == hypotheses.count ? .noDiscriminatingEvidence : .tied(top, score: best.score)
        }
        guard !diagnostic.isEmpty else { return .noDiscriminatingEvidence }
        let runnerUp = ranked.dropFirst().first?.score ?? best.score
        return .leading(best.hypothesis, score: best.score, runnerUpScore: runnerUp, diagnostic: diagnostic)
    }

    /// The hypothesis ACH singles out — only when one alone has the fewest inconsistencies on
    /// assessed, discriminating evidence. Nil for an unrated matrix, a tie, or evidence that
    /// rates the same everywhere. Advisory only — the analyst still records the conclusion.
    public var leastInconsistent: ACHHypothesis? { preference.leading }

    /// Evidence is DIAGNOSTIC when it is FULLY ASSESSED and rates differently across hypotheses —
    /// that's what actually discriminates. Evidence rated the same everywhere carries no
    /// diagnostic value (Heuer: focus on the diagnostic items); evidence with an unassessed cell
    /// cannot be called diagnostic yet.
    public func isDiagnostic(_ e: ACHEvidence) -> Bool {
        guard hypotheses.count > 1, isFullyAssessed(e) else { return false }
        return Set(hypotheses.compactMap { rating(e, $0)?.symbol }).count > 1
    }

    /// The index label of a hypothesis ("H2") in matrix order.
    public func label(of h: ACHHypothesis) -> String {
        "H\((hypotheses.firstIndex { $0.id == h.id } ?? 0) + 1)"
    }

    /// The preference in words, for the screen and the report. Descriptive of the ratings; it
    /// never turns a score into a probability or a finding.
    public var preferenceStatement: String {
        let unrated = unassessedCellCount
        switch preference {
        case .noAssessment:
            return cellCount == 0 ? "No cells to rate yet."
                : "No cell is rated yet (\(cellCount) unassessed). No preference is established."
        case .noDiscriminatingEvidence:
            var s = "No assessed evidence distinguishes the hypotheses, so no preference is established."
            if unrated > 0 { s += " \(unrated) cell\(unrated == 1 ? " is" : "s are") still unassessed." }
            return s
        case .tied(let hs, let score):
            var s = hs.map { label(of: $0) }.joined(separator: ", ") + " tie at \(score) inconsistency point\(score == 1 ? "" : "s"); no preference is established between them."
            if unrated > 0 { s += " \(unrated) cell\(unrated == 1 ? " is" : "s are") still unassessed." }
            return s
        case .leading(let h, let score, let runnerUp, let diagnostic):
            let items = diagnostic.prefix(4).map { e in
                "\(e.text.prefix(60))\(e.text.count > 60 ? "…" : "") (" + hypotheses.map { "\(label(of: $0)) \(symbol(e, $0))" }.joined(separator: ", ") + ")"
            }
            var s = "\(label(of: h)) has the fewest inconsistency points (\(score), against \(runnerUp) for the next), on \(diagnostic.count) diagnostic item\(diagnostic.count == 1 ? "" : "s"): " + items.joined(separator: "; ") + "."
            if unrated > 0 { s += " \(unrated) cell\(unrated == 1 ? " is" : "s are") still unassessed, so this can change." }
            s += " A score describes the ratings; it is not a probability or a finding."
            return s
        }
    }

    // MARK: Progress

    /// A fully-worked example so users can see a rated matrix immediately.
    public static func sample(now: Date) -> ACHAnalysis {
        var a = ACHAnalysis(title: "Why is the injury date inconsistent?", now: now)
        a.question = "What best explains the claimant's injury date differing across the intake form, recorded statement, and physician note in claim CL-2291?"
        let h1 = ACHHypothesis(text: "Transcription error at intake")
        let h2 = ACHHypothesis(text: "Claimant's recollection genuinely changed")
        let h3 = ACHHypothesis(text: "Deliberate misrepresentation")
        a.hypotheses = [h1, h2, h3]
        let e1 = ACHEvidence(text: "Physician note date matches the medical record", source: "med-record.pdf")
        let e2 = ACHEvidence(text: "Intake form was hand-keyed from a phone call", source: "intake-form.pdf")
        let e3 = ACHEvidence(text: "Claimant volunteered the discrepancy unprompted", source: "statement.m4a")
        let e4 = ACHEvidence(text: "No financial motive found in the file", source: "financials")
        a.evidence = [e1, e2, e3, e4]
        func rate(_ e: ACHEvidence, _ h: ACHHypothesis, _ c: ACHConsistency) { a.ratings[Self.key(e.id, h.id)] = c }
        rate(e1, h1, .consistent);        rate(e1, h2, .neutral);          rate(e1, h3, .neutral)
        rate(e2, h1, .veryConsistent);    rate(e2, h2, .consistent);       rate(e2, h3, .inconsistent)
        rate(e3, h1, .consistent);        rate(e3, h2, .consistent);       rate(e3, h3, .veryInconsistent)
        rate(e4, h1, .neutral);           rate(e4, h2, .neutral);          rate(e4, h3, .veryInconsistent)
        a.assumptions = ["The medical record itself is authentic and correctly dated."]
        a.indicators = ["A second altered document would raise the misrepresentation hypothesis."]
        a.conclusion.leadingHypothesisID = h1.id
        a.conclusion.confidence = .moderate
        a.conclusion.summary = "The evidence is least inconsistent with a transcription error at intake; misrepresentation is heavily contradicted by the unprompted disclosure and absence of motive. Recommend a targeted re-interview before any coverage decision."
        StudioAudit.record(&a.history, "Worked example created", at: now)
        return a
    }

    public var isReady: Bool { hypotheses.count >= 2 && !evidence.isEmpty }
    public var completionFraction: Double {
        var done = 0.0
        if !question.trimmed.isEmpty { done += 0.25 }
        if hypotheses.count >= 2 { done += 0.25 }
        if !evidence.isEmpty { done += 0.25 }
        if !conclusion.summary.trimmed.isEmpty || conclusion.leadingHypothesisID != nil { done += 0.25 }
        return done
    }
}

// MARK: - Report renderer (pure)

public enum ACHReportRenderer {

    public static func markdown(_ a: ACHAnalysis, generatedAt: Date) -> String {
        let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .short
        var out = LegalNotice.reportDisclaimer + "\n\n"
        out += "# Analysis of Competing Hypotheses — \(a.title.trimmed.isEmpty ? "Untitled" : a.title)\n\n"
        out += "**Question:** \(a.question.trimmed.isEmpty ? "_Not stated._" : a.question)\n"
        out += "**Method:** Analysis of Competing Hypotheses (Heuer, *Psychology of Intelligence Analysis*, 1999) — evidence rated for consistency against each hypothesis; the hypothesis with the fewest inconsistencies is preferred.\n"
        out += "**Generated:** \(df.string(from: generatedAt))\n\n---\n\n"

        // Hypotheses
        out += "## Hypotheses\n\n"
        if a.hypotheses.isEmpty { out += "_None._\n\n" }
        else {
            for (i, h) in a.hypotheses.enumerated() { out += "H\(i + 1). \(h.text)\n" }
            out += "\n"
        }

        // Matrix
        out += "## Consistency matrix\n\n"
        if !a.isReady { out += "_Add at least two hypotheses and one item of evidence._\n\n" }
        else {
            let header = "| Evidence | " + a.hypotheses.enumerated().map { "H\($0.offset + 1)" }.joined(separator: " | ") + " | Diagnostic |"
            let sep = "|---|" + String(repeating: "---|", count: a.hypotheses.count + 1)
            out += header + "\n" + sep + "\n"
            for e in a.evidence {
                let cells = a.hypotheses.map { a.symbol(e, $0) }.joined(separator: " | ")
                let src = citationNote(e)
                let diag = a.isDiagnostic(e) ? "✓" : (a.isFullyAssessed(e) ? "" : "not fully assessed")
                out += "| \(e.text)\(src) | \(cells) | \(diag) |\n"
            }
            out += "\n"
            out += "**Assessment coverage:** \(a.assessedCellCount) of \(a.cellCount) cells rated"
            out += a.unassessedCellCount == 0 ? ".\n\n" : "; \(a.unassessedCellCount) unassessed (shown as —).\n\n"

            // Inconsistency scores + ranking
            out += "## Inconsistency scores (fewest = most robust)\n\n"
            for (i, entry) in a.ranking.enumerated() {
                let idx = (a.hypotheses.firstIndex { $0.id == entry.hypothesis.id } ?? 0) + 1
                out += "\(i + 1). H\(idx) — \(entry.hypothesis.text): **\(entry.score)** inconsistency point\(entry.score == 1 ? "" : "s") (\(a.assessedCount(entry.hypothesis)) of \(a.evidence.count) cells rated)\n"
            }
            out += "\n**What the ratings establish:** \(a.preferenceStatement)\n"
            out += "\n_Legend: CC very consistent · C consistent · N neutral · I inconsistent · II very inconsistent · — unassessed. Only I/II count against a hypothesis; an unassessed cell counts for nothing and is not neutral._\n\n"
        }

        // Assumptions / indicators
        if !a.assumptions.isEmpty {
            out += "## Critical assumptions\n\n"
            for x in a.assumptions where !x.trimmed.isEmpty { out += "- \(x)\n" }
            out += "\n"
        }
        if !a.indicators.isEmpty {
            out += "## Indicators to watch\n\n"
            for x in a.indicators where !x.trimmed.isEmpty { out += "- \(x)\n" }
            out += "\n"
        }

        // Conclusion — clearly labelled as the analyst's opinion, distinct from the rated evidence above.
        out += "## Analyst's assessment (opinion)\n\n"
        out += "_The matrix and scores above are the evidence and its rating; the assessment below is the analyst's judgement drawn from them._\n\n"
        if let id = a.conclusion.leadingHypothesisID, let h = a.hypotheses.first(where: { $0.id == id }) {
            out += "**Leading hypothesis:** \(h.text)\n"
        } else {
            out += "**Leading hypothesis:** _Not selected._\n"
        }
        out += "**Confidence:** \(a.conclusion.confidence.label)\n\n"
        if !a.conclusion.summary.trimmed.isEmpty { out += "\(a.conclusion.summary)\n\n" }
        out += "---\n\n_ACH aids judgment; it does not compute a verdict. A low score means a hypothesis survives the evidence best, not that it is proven — if several remain viable, say so._\n"
        out += StudioAudit.appendix(a.history)
        return out
    }

    /// How an evidence row is sourced: a structured citation (exact version, quote) or the
    /// investigator's own note.
    static func citationNote(_ e: ACHEvidence) -> String {
        if e.isCited, let c = e.citation {
            var parts: [String] = []
            if let v = c.sourceVersionID { parts.append("version \(v.uuidString.prefix(8))") }
            if let q = c.quote?.trimmed, !q.isEmpty { parts.append("“\(q.prefix(120))\(q.count > 120 ? "…" : "")”") }
            if !e.source.trimmed.isEmpty { parts.append(e.source.trimmed) }
            return " _(cited, verified: \(parts.joined(separator: " · ")))_"
        }
        if e.hasCitation {
            // An identifier that was not verified against the source is not a citation.
            let why = e.citationState == nil ? "not verified against the source" : (e.citationDetail ?? "did not verify")
            return " _(investigator's note — citation unverified: \(why))_"
        }
        return e.source.trimmed.isEmpty ? " _(investigator's note — uncited)_" : " _(investigator's note — uncited: \(e.source.trimmed))_"
    }
}
