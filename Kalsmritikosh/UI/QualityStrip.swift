//
//  QualityStrip.swift
//  Kalsmritikosh
//
//  T11 — Compact one-line answer-quality summary. Words before numbers,
//  no raw floats. Tapping "Conflicts: K" expands a list of contradiction
//  sources. While ingest is running, a header line shows "Answered from
//  X% of your archive".
//

import SwiftUI

public struct QualityStrip: View {
    public let answer: VerifiedAnswer
    @State private var conflictsExpanded = false
    /// G3 Phase 5 — "Why this answer?" disclosure. Renders the typed
    /// walk-path chain that the bond engine produced for this answer.
    @State private var walkExpanded = false
    /// Phase J.1 — "How did Kalsmritikosh answer this?" disclosure. Renders
    /// the captured ReasoningTrace: path, retrieval shape, expert
    /// pipeline membership, assumptions, uncertainties.
    @State private var planExpanded = false
    /// G3 Phase 5 UI — optional callback for walk-step row taps. When
    /// non-nil, tapping a step row hands the first evidence KO id back
    /// so the parent can reveal the source (typically in Finder). nil =
    /// rows are read-only.
    public var onEvidenceTap: (@MainActor (UUID) -> Void)?

    public init(
        answer: VerifiedAnswer,
        onEvidenceTap: (@MainActor (UUID) -> Void)? = nil
    ) {
        self.answer = answer
        self.onEvidenceTap = onEvidenceTap
    }

    /// Closed-corpus answer-state chip (Ledger-AI v28). Colour-codes the
    /// verdict so the user sees at a glance whether the archive actually
    /// supports the answer. Hidden when `.unknown` (gate not run yet).
    @ViewBuilder
    private var answerStatePill: some View {
        let state = answer.answerState
        let (color, icon): (Color, String) = {
            switch state {
            case .supported:             return (.green, "checkmark.seal.fill")
            case .partiallySupported:    return (.yellow, "circle.lefthalf.filled")
            case .contradicted:          return (.orange, "exclamationmark.triangle.fill")
            case .notFound:              return (.secondary, "questionmark.circle")
            case .insufficientlyIndexed: return (.blue, "hourglass")
            case .unknown:               return (.secondary, "circle")
            }
        }()
        HStack(spacing: 5) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(state.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if answer.answerState != .unknown {
                answerStatePill
            }
            if let report = answer.report,
               report.ingestCoverage < 1.0 {
                Text("Answered from \(Int(report.ingestCoverage * 100))% of your archive")
                    .font(.caption2.italic())
                    .foregroundStyle(.secondary)
            }
            Text(QualityStrip.formatLine(answer))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !answer.contradictions.isEmpty {
                Button {
                    conflictsExpanded.toggle()
                } label: {
                    Label(
                        conflictsExpanded ? "Hide conflicts" : "Show \(answer.contradictions.count) conflict\(answer.contradictions.count == 1 ? "" : "s")",
                        systemImage: conflictsExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                if conflictsExpanded {
                    ForEach(0..<answer.contradictions.count, id: \.self) { i in
                        let c = answer.contradictions[i]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.description).font(.caption.bold())
                            Text("• \(c.claimA)").font(.caption2)
                            Text("• \(c.claimB)").font(.caption2)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 6))
                    }
                }
            }
            if !answer.walkSteps.isEmpty {
                whyThisAnswer(steps: answer.walkSteps)
            }
            if let trace = answer.reasoningTrace {
                explainPlanDisclosure(trace)
            }
            if answer.citations.count >= 2 {
                evidenceRankingDisclosure(answer.citations)
            }
        }
    }

    /// Phase J.14 — top-3 citations by composite EvidenceScore. The
    /// ranker doesn't have access to event dates from this view, so
    /// freshness defaults to 0.5; independence + corroboration +
    /// provenance still produce a meaningful ordering.
    @State private var evidenceRankExpanded: Bool = false

    @ViewBuilder
    private func evidenceRankingDisclosure(_ citations: [VerifiedAnswer.Citation]) -> some View {
        Button {
            evidenceRankExpanded.toggle()
        } label: {
            Label(
                evidenceRankExpanded ? "Hide evidence ranking" : "Rank evidence",
                systemImage: evidenceRankExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        if evidenceRankExpanded {
            let ranked = EvidenceRanker().ranked(citations: citations).prefix(3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(ranked.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(format: "%.0f%%", pair.score.composite * 100))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 44, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pair.citation.snippet.isEmpty
                                 ? "object \(pair.citation.objectID.uuidString.prefix(8))"
                                 : String(pair.citation.snippet.prefix(120)))
                                .font(.caption)
                                .lineLimit(2)
                            HStack(spacing: 8) {
                                miniTerm("ind", value: pair.score.independence)
                                miniTerm("corr", value: pair.score.corroboration)
                                miniTerm("fresh", value: pair.score.freshness)
                                miniTerm("prov", value: pair.score.provenance)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func miniTerm(_ label: String, value: Double) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f", value * 100))
                .font(.caption2.monospacedDigit())
        }
    }

    // MARK: - Phase J.1: ExplainPlan disclosure

    @ViewBuilder
    private func explainPlanDisclosure(_ trace: ReasoningTrace) -> some View {
        Button {
            planExpanded.toggle()
        } label: {
            Label(
                planExpanded
                    ? "Hide reasoning plan"
                    : "How did Kalsmritikosh answer this?",
                systemImage: planExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        if planExpanded {
            VStack(alignment: .leading, spacing: 6) {
                planRow(label: "Path", value: trace.pathTaken)
                planRow(label: "Intent", value: trace.intent)
                if let category = trace.queryCategory {
                    planRow(label: "Category", value: category)
                }
                if !trace.retrievalLayers.isEmpty {
                    planRow(
                        label: "Retrieval",
                        value: trace.retrievalLayers.joined(separator: " → ")
                            + (trace.shortCircuitedAt.map { " (short-circuited at \($0))" } ?? "")
                    )
                }
                planRow(
                    label: "Counts",
                    value: countsLine(trace.retrievalCounts)
                )
                if !trace.expertIDs.isEmpty {
                    planRow(label: "Experts", value: trace.expertIDs.joined(separator: ", "))
                }
                if !trace.llmPurposes.isEmpty {
                    planRow(label: "LLM calls", value: trace.llmPurposes.joined(separator: ", "))
                }
                if !trace.assumptions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Assumptions / downgrades")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(trace.assumptions.enumerated()), id: \.offset) { _, line in
                            Text("• \(line)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !trace.uncertainties.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open uncertainties")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(Array(trace.uncertainties.enumerated()), id: \.offset) { _, line in
                            Text("• \(line)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func planRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func countsLine(_ c: ReasoningTrace.RetrievalCounts) -> String {
        var parts: [String] = []
        if c.events > 0 { parts.append("\(c.events) ev") }
        if c.entities > 0 { parts.append("\(c.entities) ent") }
        if c.chunks > 0 { parts.append("\(c.chunks) chunk") }
        if c.summaries > 0 { parts.append("\(c.summaries) sum") }
        if c.relationships > 0 { parts.append("\(c.relationships) rel") }
        if c.walkSteps > 0 { parts.append("\(c.walkSteps) walk") }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }

    // MARK: - G3 Phase 5: Why this answer?

    @ViewBuilder
    private func whyThisAnswer(steps: [WalkStep]) -> some View {
        Button {
            walkExpanded.toggle()
        } label: {
            Label(
                walkExpanded
                    ? "Hide reasoning path"
                    : "Why this answer? (\(steps.count) step\(steps.count == 1 ? "" : "s"))",
                systemImage: walkExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption)
        }
        .buttonStyle(.borderless)
        if walkExpanded {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { (idx, step) in
                    walkRow(index: idx, step: step)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: 6))
        }
    }

    /// One row in the walk-path disclosure. Tappable when an
    /// `onEvidenceTap` closure is wired AND the step has at least one
    /// evidence KO id — the closure reveals the first source.
    @ViewBuilder
    private func walkRow(index: Int, step: WalkStep) -> some View {
        let tappable = onEvidenceTap != nil && !step.evidenceObjectIDs.isEmpty
        HStack(alignment: .center, spacing: 4) {
            Text("\(index + 1).")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(step.fromFact.displayName)
                .font(.caption.bold())
                .foregroundStyle(QualityStrip.color(for: step.fromFact))
            Image(systemName: "arrow.right")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(QualityStrip.label(forBond: step.bond))
                .font(.caption.monospaced())
                .foregroundStyle(.tint)
            Image(systemName: "arrow.right")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(step.toFact.displayName)
                .font(.caption.bold())
                .foregroundStyle(QualityStrip.color(for: step.toFact))
            if !step.evidenceObjectIDs.isEmpty {
                Text("(\(step.evidenceObjectIDs.count) src)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if tappable {
                    Image(systemName: "arrow.up.right.square")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let cb = onEvidenceTap,
                  let firstID = step.evidenceObjectIDs.first else { return }
            cb(firstID)
        }
    }

    /// Builds the one-line strip text:
    /// `Confidence: strong · Evidence: N claims, M files [, K dropped] · Agreement: X% · Timeliness: newest <date>, fresh X%, covers Y%, gap <range> · Conflicts: 0`
    public static func formatLine(_ answer: VerifiedAnswer) -> String {
        var parts: [String] = []
        parts.append("Confidence: \(confidenceWord(answer.confidence))")

        let claimCount = answer.citations.count
        let fileCount = Set(answer.citations.map(\.objectID)).count
        var evidence = "Evidence: \(claimCount) claim\(plural(claimCount)), \(fileCount) file\(plural(fileCount))"
        if let dropped = answer.report?.droppedUnverifiable, dropped > 0 {
            evidence += ", \(dropped) dropped"
        }
        parts.append(evidence)

        if let report = answer.report {
            // G2-5 — surface agreement when it's actually informative.
            // Agreement is the share of claims that don't contradict each
            // other. A perfect 1.0 is the boring default; below ~0.9
            // means at least one pairwise conflict slipped through.
            if report.agreementScore < 0.99, claimCount > 1 {
                parts.append("Agreement: \(Int(report.agreementScore * 100))%")
            }

            var timeliness: [String] = []
            if let newest = report.newestEvidenceDate {
                timeliness.append("newest \(newest.formatted(date: .abbreviated, time: .omitted))")
            }
            // G2-5 — freshness is the exponential-decay factor on age.
            // nil for historical intents where staleness is expected.
            if let fresh = report.freshness {
                timeliness.append("fresh \(Int(fresh * 100))%")
            }
            // Only surface "covers X%" when there's a real intent-window
            // signal — otherwise `coverage` is nil and the line is misleading.
            if let coverage = report.coverage, coverage > 0 {
                timeliness.append("covers \(Int(coverage * 100))% of window")
            }
            // G2-5 — surface up to three coverage gaps; older code only
            // showed one even when several existed. Beyond three the line
            // becomes noise.
            let gaps = report.coverageGaps.prefix(3)
            for gap in gaps {
                timeliness.append("gap \(formatInterval(gap))")
            }
            if report.coverageGaps.count > gaps.count {
                timeliness.append("+\(report.coverageGaps.count - gaps.count) more gap\(plural(report.coverageGaps.count - gaps.count))")
            }
            if !timeliness.isEmpty {
                parts.append("Timeliness: \(timeliness.joined(separator: ", "))")
            }
        }

        parts.append("Conflicts: \(answer.contradictions.count)")
        return parts.joined(separator: " · ")
    }

    private static func confidenceWord(_ c: Confidence) -> String {
        switch c.value {
        case 0.7...: return "strong"
        case 0.4..<0.7: return "moderate"
        default: return "weak"
        }
    }

    private static func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

    /// G3 Phase 5 polish — map raw bond names (snake_case ontology
    /// keys) to short English phrases for the walk-path UI. Unknown
    /// bonds fall back to a space-separated form so a new bond rule
    /// added to Ontology.rules still renders without crashing.
    private static func label(forBond raw: String) -> String {
        switch raw {
        case "affiliated_with": return "is affiliated with"
        case "signed_by": return "signed by"
        case "party_a": return "is party A of"
        case "party_b": return "is party B of"
        case "amends": return "amends"
        case "owns": return "owns"
        case "delivered_by": return "delivered by"
        case "issued_by": return "issued by"
        case "issued_to": return "issued to"
        case "invoice_for": return "invoice for"
        case "delivers_for": return "delivers for"
        case "sent_by": return "sent by"
        case "received_by": return "received by"
        case "discusses": return "discusses"
        case "about": return "about"
        case "attended_by": return "attended by"
        case "made_by": return "made by"
        default: return raw.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func formatInterval(_ i: DateInterval) -> String {
        "\(i.start.formatted(date: .abbreviated, time: .omitted))–\(i.end.formatted(date: .abbreviated, time: .omitted))"
    }

    /// G4.8 — color-code FactType so the eye can pick out subjects vs
    /// objects in the walk path at a glance. Same swatches the future
    /// timeline / dossier UI should reuse.
    fileprivate static func color(for type: FactType) -> Color {
        switch type {
        case .person:        return .blue
        case .organization:  return .orange
        case .project:       return .green
        case .contract:      return .purple
        case .amendment:     return .indigo
        case .invoice:       return .pink
        case .delivery:      return .teal
        case .email:         return .cyan
        case .meeting:       return .mint
        case .decision:      return .yellow
        }
    }
}
