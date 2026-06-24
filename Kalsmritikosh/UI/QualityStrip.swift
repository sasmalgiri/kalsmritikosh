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

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        }
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
    /// `Confidence: strong · Evidence: N claims, M files, K formats · Timeliness: newest <date>, covers <range>[, gap <range>] · Conflicts: 0`
    public static func formatLine(_ answer: VerifiedAnswer) -> String {
        var parts: [String] = []
        parts.append("Confidence: \(confidenceWord(answer.confidence))")

        let claimCount = answer.citations.count
        let fileCount = Set(answer.citations.map(\.objectID)).count
        parts.append("Evidence: \(claimCount) claim\(plural(claimCount)), \(fileCount) file\(plural(fileCount))")

        if let report = answer.report {
            var timeliness: [String] = []
            if let newest = report.newestEvidenceDate {
                timeliness.append("newest \(newest.formatted(date: .abbreviated, time: .omitted))")
            }
            // Only surface "covers X%" when there's a real intent-window
            // signal — otherwise `coverage` is nil and the line is misleading.
            if let coverage = report.coverage, coverage > 0 {
                timeliness.append("covers \(Int(coverage * 100))% of window")
            }
            for gap in report.coverageGaps.prefix(1) {
                timeliness.append("gap \(formatInterval(gap))")
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
