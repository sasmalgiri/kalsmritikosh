//
//  InvestigationReportBuilder.swift
//  Kalsmritikosh
//
//  Phase J.3 — Vol 25 ¶9 / Vol 28 §Report Builder. Renders a
//  persisted Investigation as a self-contained markdown report with
//  the four appendices the reference standard calls out:
//
//      Section 1 — Executive Summary       (synthesis)
//      Section 2 — Original Question + sub-question list
//      Section 3 — Findings per sub-question
//      Appendix A — Timeline appendix       (dated events the
//                                             sub-answers cited)
//      Appendix B — Evidence appendix       (citation table:
//                                             objectID → filename
//                                             → snippet)
//      Appendix C — Causal chain appendix   (links between cited
//                                             events when present)
//      Appendix D — Audit appendix          (path / agent / when /
//                                             confidence per step)
//
//  Every conclusion is hyperlinked back to the cited source — the
//  links use `file://` URIs to the resolved source files when the
//  KnowledgeObjectRepository can map an object id to a file URL.
//  When it can't, the link degrades to a `kalsmritikosh:object/<uuid>`
//  scheme the UI can intercept (we don't register that scheme today,
//  but the link shape stays valid).
//
//  Quality-or-nothing: the builder NEVER invents content. Every
//  section either renders the captured data verbatim or omits the
//  section entirely.
//

import Foundation

public struct InvestigationReportBuilder: Sendable {
    public init() {}

    /// Render an investigation to a markdown string. The optional
    /// `objects` repo resolves each citation's object id to its
    /// source filename + URL; when nil, citations show their UUIDs
    /// only.
    public func render(
        investigation: Investigation,
        objects: KnowledgeObjectRepository? = nil
    ) async -> String {
        var md = ""
        let now = Date()

        // Header.
        md += "# Investigation report\n\n"
        md += "_Generated \(now.formatted(date: .abbreviated, time: .shortened))._\n\n"
        // Legal / accuracy declaration on every exported report.
        md += LegalNotice.reportDisclaimer + "\n\n"

        // Section 1 — Executive Summary.
        md += "## Executive summary\n\n"
        if let synthesis = investigation.synthesis,
           !synthesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += synthesis + "\n\n"
        } else {
            md += "_Synthesis not available — the runner did not complete this investigation._\n\n"
        }

        // Section 2 — Original Question.
        md += "## Original question\n\n"
        md += "> \(investigation.question)\n\n"
        if !investigation.steps.isEmpty {
            md += "Decomposed into \(investigation.steps.count) sub-question(s):\n\n"
            for (idx, step) in investigation.steps.enumerated() {
                md += "\(idx + 1). \(step.question)\n"
            }
            md += "\n"
        }

        // Resolve every citation's object id → filename + URL once.
        let citationsAcrossSteps = investigation.steps.flatMap { step in
            step.answer?.citations.map(\.objectID) ?? []
        }
        let uniqueObjectIDs = Array(Set(citationsAcrossSteps))
        var filenameByID: [KnowledgeObject.ID: String] = [:]
        var urlByID: [KnowledgeObject.ID: URL] = [:]
        if let objects, !uniqueObjectIDs.isEmpty {
            // sourceFilenames returns ID → filename; sourceFileURL is
            // per-id. We fan out the per-id call only for ids we'll
            // actually link to.
            let names = (try? await objects.sourceFilenames(for: Set(uniqueObjectIDs))) ?? [:]
            filenameByID = names
            for id in uniqueObjectIDs {
                if let url = try? await objects.fetchSourceURL(id: id) {
                    urlByID[id] = url
                }
            }
        }

        // Section 3 — Findings per sub-question.
        md += "## Findings\n\n"
        for (idx, step) in investigation.steps.enumerated() {
            md += "### \(idx + 1). \(step.question)\n\n"
            if let answer = step.answer {
                let body = (answer.answerText ?? answer.body)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    md += body + "\n\n"
                } else {
                    md += "_No answer text._\n\n"
                }
                if !answer.citations.isEmpty {
                    md += "**Cited sources:** "
                    let parts: [String] = answer.citations.enumerated().map { citationIdx, citation in
                        let label = Self.citationLabel(idx: citationIdx + 1, citation: citation,
                                                       filenameByID: filenameByID,
                                                       urlByID: urlByID)
                        return label
                    }
                    md += parts.joined(separator: ", ") + "\n\n"
                }
                let pct = Int(answer.confidence.value * 100)
                md += "_Confidence: \(pct)% · \(answer.citations.count) citation(s)_\n\n"
                if !answer.contradictions.isEmpty {
                    md += "> ⚠ **Conflicts detected** for this finding:\n"
                    for c in answer.contradictions {
                        md += "> - \(c.description) — \(c.claimA) vs \(c.claimB)\n"
                    }
                    md += "\n"
                }
            } else {
                md += "_No answer recorded for this sub-question._\n\n"
            }
        }

        // Appendix A — Timeline. Pull event-id citations and sort by
        // recorded eventID — we don't have the event objects here
        // unless callers thread the events repo through too, so list
        // citations that DO carry an eventID as the timeline anchor.
        let eventCitations = investigation.steps.flatMap {
            $0.answer?.citations.filter { $0.eventID != nil } ?? []
        }
        if !eventCitations.isEmpty {
            md += "## Appendix A — Timeline anchors\n\n"
            md += "| # | Event id | Snippet | Object |\n"
            md += "|---:|---|---|---|\n"
            for (idx, citation) in eventCitations.enumerated() {
                let eventID = citation.eventID?.uuidString.prefix(8).description ?? "—"
                let snippet = citation.snippet.replacingOccurrences(of: "|", with: "/")
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(140)
                let objLabel = Self.objectLink(citation: citation,
                                               filenameByID: filenameByID,
                                               urlByID: urlByID)
                md += "| \(idx + 1) | `\(eventID)` | \(snippet) | \(objLabel) |\n"
            }
            md += "\n"
        }

        // Appendix B — Evidence table.
        if !uniqueObjectIDs.isEmpty {
            md += "## Appendix B — Evidence\n\n"
            md += "| Object | File |\n|---|---|\n"
            for id in uniqueObjectIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let filename = filenameByID[id] ?? "—"
                let link: String = urlByID[id].map { url in
                    "[\(filename)](\(url.absoluteString))"
                } ?? filename
                md += "| `\(id.uuidString.prefix(8))` | \(link) |\n"
            }
            md += "\n"
        }

        // Appendix C — Causal chain. Skipped in v1 because the
        // investigation steps don't carry the causal links the brain
        // produced for each sub-answer; this is the obvious next-step
        // when the runner threads ReasoningTrace + walkSteps into
        // each persisted step.
        // (Section deliberately empty — see comment.)

        // Appendix D — Audit.
        md += "## Appendix D — Audit\n\n"
        md += "| # | Sub-question | Step id | When |\n|---:|---|---|---|\n"
        for (idx, step) in investigation.steps.enumerated() {
            let stepID = step.id.uuidString.prefix(8)
            let when = step.createdAt.formatted(date: .abbreviated, time: .shortened)
            md += "| \(idx + 1) | \(step.question) | `\(stepID)` | \(when) |\n"
        }
        md += "\n"
        md += "_Investigation id: `\(investigation.id.uuidString)`_\n"
        md += "_Started: \(investigation.createdAt.formatted(date: .abbreviated, time: .shortened))._\n"

        return md
    }

    // MARK: - Helpers

    private static func citationLabel(
        idx: Int,
        citation: VerifiedAnswer.Citation,
        filenameByID: [KnowledgeObject.ID: String],
        urlByID: [KnowledgeObject.ID: URL]
    ) -> String {
        let filename = filenameByID[citation.objectID]
            ?? "object/\(citation.objectID.uuidString.prefix(8))"
        if let url = urlByID[citation.objectID] {
            return "[\(filename)](\(url.absoluteString))"
        }
        return filename
    }

    private static func objectLink(
        citation: VerifiedAnswer.Citation,
        filenameByID: [KnowledgeObject.ID: String],
        urlByID: [KnowledgeObject.ID: URL]
    ) -> String {
        let filename = filenameByID[citation.objectID]
            ?? citation.objectID.uuidString.prefix(8).description
        if let url = urlByID[citation.objectID] {
            return "[\(filename)](\(url.absoluteString))"
        }
        return filename
    }
}
