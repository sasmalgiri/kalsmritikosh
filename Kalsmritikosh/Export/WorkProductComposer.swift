//
//  WorkProductComposer.swift
//  Kalsmritikosh
//
//  Persona features Epic 3 (F4). The DETERMINISTIC composer: it assembles a
//  work product purely from ledger facts the user already has — dated events,
//  detected contradictions, and flagged gaps — with zero LLM involvement. This
//  is the guaranteed path (§9.6 "deterministic report works without an LLM").
//  A bounded LLM drafting + claim-verification pass (§9.3 steps 3–5) can later
//  polish the prose, but it may only rephrase claims the composer already
//  grounded — it can never introduce an unsupported sentence.
//
//  Every claim is labelled with its epistemic status; counts are deterministic
//  derivations; gaps are inferences that never assert wrongdoing.
//

import Foundation

public enum WorkProductComposer {

    /// One dated event paired with its source filename (for citation).
    public struct EventInput: Sendable {
        public let event: Event
        public let filename: String?
        public nonisolated init(event: Event, filename: String?) {
            self.event = event; self.filename = filename
        }
    }

    public static func compose(
        template: WorkProductTemplate,
        title: String,
        scopeNote: String,
        events: [EventInput],
        contradictions: [Contradiction],
        gaps: [GapNode],
        disclaimer: String?
    ) -> WorkProduct {
        let sorted = events.sorted { $0.event.date < $1.event.date }
        let table = chronologyTable(sorted)
        var wp = WorkProduct(template: template, title: title,
                             subtitle: template.displayName, disclaimer: disclaimer)

        switch template {
        case .generalSummary:
            wp.sections = [
                scopeSection(scopeNote, events: sorted, contradictions: contradictions, gaps: gaps),
                keyFindingsSection(sorted, contradictions: contradictions, gaps: gaps),
                contradictionsSection(contradictions),
                missingEvidenceSection(gaps)
            ]
            wp.table = table
        case .chronology:
            wp.sections = [scopeSection(scopeNote, events: sorted, contradictions: contradictions, gaps: gaps)]
            wp.table = table
        case .investigationFindings:
            wp.sections = [
                section("Mandate / scope", preamble: [scopeNote]),
                section("Materials reviewed", preamble: [
                    "\(sorted.count) dated events drawn from \(distinctSources(sorted)) source document(s)."
                ]),
                section("Methods", preamble: [
                    "Deterministic assembly from the on-device ledger: dated events, rule-based contradiction detection, and rule-based gap detection. No generative model was used; no external data was consulted."
                ]),
                findingsSection(sorted),
                contradictionsSection(contradictions),
                unresolvedQuestionsSection(gaps),
                limitationsSection()
            ]
            wp.table = table
        case .factMemo:
            wp.sections = [
                section("Question", preamble: [title]),
                keyFindingsSection(sorted, contradictions: contradictions, gaps: gaps, heading: "Short answer"),
                findingsSection(sorted, heading: "Supported facts"),
                contradictionsSection(contradictions, heading: "Disputed facts"),
                missingEvidenceSection(gaps, heading: "Missing proof")
            ]
        }
        return wp
    }

    /// Map a composed work product into the neutral export document (F3).
    public static func exportable(
        _ wp: WorkProduct,
        citationStyle: CitationStyle,
        manifest: ExportManifest
    ) -> ExportableDocument {
        let sections = wp.sections.map { section -> ExportSection in
            var paras = section.preamble
            for claim in section.claims {
                var line = "• [\(claim.status.displayName)] \(claim.text)"
                if !claim.supporting.isEmpty {
                    let labels = claim.supporting.map { $0.isResolved ? $0.displayLabel : "⚠ unresolved" }
                    line += " (sources: \(labels.joined(separator: "; ")))"
                }
                if !claim.contradicting.isEmpty {
                    line += " (conflicts: \(claim.contradicting.count))"
                }
                paras.append(line)
            }
            return ExportSection(title: section.title, paragraphs: paras)
        }
        return ExportableDocument(
            title: wp.title,
            subtitle: wp.subtitle,
            sections: sections,
            table: wp.table,
            citations: wp.allCitations,
            citationStyle: citationStyle,
            disclaimer: wp.disclaimer,
            manifest: manifest
        )
    }

    // MARK: - Sections

    private static func section(_ title: String, preamble: [String] = [], claims: [WorkProductClaim] = []) -> WorkProductSection {
        WorkProductSection(title: title, preamble: preamble, claims: claims)
    }

    private static func scopeSection(_ scopeNote: String, events: [EventInput], contradictions: [Contradiction], gaps: [GapNode]) -> WorkProductSection {
        var lines = [scopeNote]
        if let range = dateRange(events) { lines.append("Covered period: \(range).") }
        lines.append("This report is assembled deterministically from the ledger; every dated line cites its source, and unresolved conflicts and gaps are shown rather than hidden.")
        return section("Scope", preamble: lines)
    }

    private static func keyFindingsSection(_ events: [EventInput], contradictions: [Contradiction], gaps: [GapNode], heading: String = "Key findings") -> WorkProductSection {
        var claims: [WorkProductClaim] = []
        claims.append(WorkProductClaim(
            text: "\(events.count) dated event(s) are in scope\(dateRange(events).map { ", spanning \($0)" } ?? "").",
            status: .deterministicDerivation))
        let highSev = contradictions.filter { $0.severity == .high }.count
        claims.append(WorkProductClaim(
            text: "\(contradictions.count) contradiction(s) detected (\(highSev) high severity).",
            status: .deterministicDerivation))
        claims.append(WorkProductClaim(
            text: "\(gaps.count) missing-evidence gap(s) flagged. Absence is not proof of anything.",
            status: .inference))
        return section(heading, claims: claims)
    }

    private static func findingsSection(_ events: [EventInput], heading: String = "Findings") -> WorkProductSection {
        let claims = events.map { input -> WorkProductClaim in
            WorkProductClaim(
                text: "\(dateText(input.event.date)): \(input.event.title)",
                status: epistemicStatus(for: input.event),
                supporting: [citation(for: input)],
                confidence: input.event.confidence.value
            )
        }
        return section(heading, claims: claims)
    }

    private static func contradictionsSection(_ contradictions: [Contradiction], heading: String = "Contradictions") -> WorkProductSection {
        if contradictions.isEmpty {
            return section(heading, preamble: ["No contradictions were detected in scope."])
        }
        let claims = contradictions.map { c in
            WorkProductClaim(
                text: "\(c.description) — A: \(c.claimA) / B: \(c.claimB)",
                status: .sourceAssertion)
        }
        return section(heading, preamble: ["Conflicting evidence is shown with both sides; it is never averaged away."], claims: claims)
    }

    private static func missingEvidenceSection(_ gaps: [GapNode], heading: String = "Missing evidence") -> WorkProductSection {
        if gaps.isEmpty {
            return section(heading, preamble: ["No missing-evidence gaps were flagged in scope."])
        }
        let claims = gaps.map { g in
            WorkProductClaim(
                text: "[\(g.kind.displayName)] \(g.description) — \(g.reason)",
                status: .inference,
                confidence: g.confidence)
        }
        return section(heading, preamble: ["Expected-but-absent items. Each may simply live outside this archive; absence is not proof."], claims: claims)
    }

    private static func unresolvedQuestionsSection(_ gaps: [GapNode]) -> WorkProductSection {
        missingEvidenceSection(gaps, heading: "Unresolved questions")
    }

    private static func limitationsSection() -> WorkProductSection {
        section("Limitations", preamble: [
            "Kalsmritikosh organizes and links user-supplied records. It does not certify evidence, determine admissibility, or provide professional advice.",
            "Findings reflect only what has been ingested and indexed; anything outside the archive is not represented."
        ])
    }

    // MARK: - Chronology table (§9.4 Chronology report)

    private static func chronologyTable(_ events: [EventInput]) -> ExportTable? {
        guard !events.isEmpty else { return nil }
        let rows = events.map { input in
            [dateText(input.event.date),
             input.event.title,
             input.event.status.rawValue,
             input.filename ?? "—"]
        }
        return ExportTable(title: "Chronology",
                           columns: ["Date", "Event", "Status", "Source"],
                           rows: rows)
    }

    // MARK: - Helpers

    private static func citation(for input: EventInput) -> CitationRecord {
        let name = input.filename ?? "source"
        return CitationRecord(
            sourceVersionID: input.event.sourceObjectID,
            displayLabel: name,
            sourceTitle: name,
            date: input.event.date,
            isGeneratedSummary: false
        )
    }

    private static func epistemicStatus(for event: Event) -> EpistemicStatus {
        switch event.status.rawValue {
        case "observed":  return .directEvidence
        case "derived":   return .deterministicDerivation
        case "inferred":  return .inference
        default:          return .sourceAssertion
        }
    }

    private static func dateText(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .omitted)
    }

    private static func dateRange(_ events: [EventInput]) -> String? {
        guard let first = events.map(\.event.date).min(),
              let last = events.map(\.event.date).max() else { return nil }
        return "\(dateText(first)) – \(dateText(last))"
    }

    private static func distinctSources(_ events: [EventInput]) -> Int {
        Set(events.compactMap { $0.filename }).count
    }
}
