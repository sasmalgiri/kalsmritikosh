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
//  Pure Codable value (persists on-device as JSON, no schema migration). The
//  report renderer is pure text, reused for copy / export / print.
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
}

public nonisolated struct ACHHypothesis: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public init(text: String) { self.text = text }
}

public nonisolated struct ACHEvidence: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String
    public var source: String = ""   // a document number / citation, optional
    public init(text: String, source: String = "") { self.text = text; self.source = source }
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

    public var hypotheses: [ACHHypothesis] = []
    public var evidence: [ACHEvidence] = []
    /// Cell ratings keyed by "evidenceID|hypothesisID"; absent = neutral.
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
    public func rating(_ e: ACHEvidence, _ h: ACHHypothesis) -> ACHConsistency {
        ratings[Self.key(e.id, h.id)] ?? .neutral
    }

    /// Total inconsistency points against a hypothesis (lower = more robust).
    public func inconsistencyScore(_ h: ACHHypothesis) -> Int {
        evidence.reduce(0) { $0 + rating($1, h).inconsistencyWeight }
    }

    /// Hypotheses ranked by fewest inconsistencies (the ACH ordering).
    public var ranking: [(hypothesis: ACHHypothesis, score: Int)] {
        hypotheses.map { ($0, inconsistencyScore($0)) }
            .sorted { $0.score < $1.score }
    }

    /// The hypothesis ACH points to (fewest inconsistencies). Advisory only —
    /// the analyst still records the conclusion explicitly.
    public var leastInconsistent: ACHHypothesis? { ranking.first?.hypothesis }

    /// Evidence is DIAGNOSTIC when it rates differently across hypotheses — that's
    /// what actually discriminates. Evidence rated the same everywhere carries no
    /// diagnostic value (Heuer: focus on the diagnostic items).
    public func isDiagnostic(_ e: ACHEvidence) -> Bool {
        guard hypotheses.count > 1 else { return false }
        let ratingsForE = hypotheses.map { rating(e, $0) }
        return Set(ratingsForE.map(\.symbol)).count > 1
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
                let cells = a.hypotheses.map { a.rating(e, $0).symbol }.joined(separator: " | ")
                let src = e.source.trimmed.isEmpty ? "" : " _(\(e.source))_"
                out += "| \(e.text)\(src) | \(cells) | \(a.isDiagnostic(e) ? "✓" : "") |\n"
            }
            out += "\n"

            // Inconsistency scores + ranking
            out += "## Inconsistency scores (fewest = most robust)\n\n"
            for (i, entry) in a.ranking.enumerated() {
                let idx = (a.hypotheses.firstIndex { $0.id == entry.hypothesis.id } ?? 0) + 1
                out += "\(i + 1). H\(idx) — \(entry.hypothesis.text): **\(entry.score)** inconsistency point\(entry.score == 1 ? "" : "s")\n"
            }
            out += "\n_Legend: CC very consistent · C consistent · N neutral · I inconsistent · II very inconsistent. Only I/II count against a hypothesis._\n\n"
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

        // Conclusion
        out += "## Conclusion\n\n"
        if let id = a.conclusion.leadingHypothesisID, let h = a.hypotheses.first(where: { $0.id == id }) {
            out += "**Leading hypothesis:** \(h.text)\n"
        } else {
            out += "**Leading hypothesis:** _Not selected._\n"
        }
        out += "**Confidence:** \(a.conclusion.confidence.label)\n\n"
        if !a.conclusion.summary.trimmed.isEmpty { out += "\(a.conclusion.summary)\n\n" }
        out += "---\n\n_ACH aids judgment; it does not compute a verdict. A low score means a hypothesis survives the evidence best, not that it is proven — if several remain viable, say so._\n"
        return out
    }
}
