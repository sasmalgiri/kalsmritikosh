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

    public init(answer: VerifiedAnswer) {
        self.answer = answer
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

    private static func formatInterval(_ i: DateInterval) -> String {
        "\(i.start.formatted(date: .abbreviated, time: .omitted))–\(i.end.formatted(date: .abbreviated, time: .omitted))"
    }
}
