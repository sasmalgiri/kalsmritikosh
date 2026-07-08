//
//  EvalDashboardView.swift
//  Kalsmritikosh
//
//  HISTORY Phase F.4 — dashboard for past NarrativeEvalKit reports.
//  Reads persisted JSON reports from Application Support and shows
//  each run's aggregate metrics with a delta arrow against the
//  previous run. The dev can see at a glance whether the last
//  composer change moved the numbers up or down without piping
//  markdown to a file by hand.
//
//  This view is intentionally read-only. To trigger an eval run,
//  set KALSMRITIKOSH_NARRATIVE_EVAL=1 in the scheme environment and run
//  the in-app SmokeTest — each run auto-persists via the existing
//  NarrativeEvalReportStore hook in SmokeTest.swift.
//

import SwiftUI

public struct EvalDashboardView: View {
    @State private var reports: [NarrativeEvalKit.Report] = []
    @State private var loading = true

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.tint)
            Text("Narrative Eval")
                .font(.headline)
            Spacer()
            Text("\(reports.count) runs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if reports.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(reports.indices, id: \.self) { idx in
                        let report = reports[idx]
                        let previous: NarrativeEvalKit.Report? =
                            idx + 1 < reports.count ? reports[idx + 1] : nil
                        reportCard(report: report, previous: previous)
                    }
                }
                .padding(14)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("No eval runs persisted yet.")
                .font(.title3.weight(.medium))
            Text("Set KALSMRITIKOSH_NARRATIVE_EVAL=1 in the Run scheme's Environment, then run the in-app SmokeTest. Each run lands in this list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportCard(report: NarrativeEvalKit.Report, previous: NarrativeEvalKit.Report?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.headline)
            HStack(spacing: 20) {
                metricCell(label: "coverage", value: report.avgChapterCoverage, prev: previous?.avgChapterCoverage, higherIsBetter: true)
                metricCell(label: "cite/sent", value: report.avgCitationDensity, prev: previous?.avgCitationDensity, higherIsBetter: true)
                metricCell(label: "contradiction", value: report.avgContradictionRecall, prev: previous?.avgContradictionRecall, higherIsBetter: true)
                metricCell(label: "conf RMSE", value: report.confidenceRMSE, prev: previous?.confidenceRMSE, higherIsBetter: false)
            }
            Text("\(report.scores.count) questions")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private func metricCell(label: String, value: Double, prev: Double?, higherIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(String(format: "%.2f", value))
                    .font(.title3.monospacedDigit())
                if let prev {
                    let delta = value - prev
                    if abs(delta) >= 0.005 {
                        let improving = higherIsBetter ? (delta > 0) : (delta < 0)
                        let arrow = delta > 0 ? "arrow.up.right" : "arrow.down.right"
                        Image(systemName: arrow)
                            .font(.caption)
                            .foregroundStyle(improving ? Color.green : Color.orange)
                    }
                }
            }
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        reports = await NarrativeEvalReportStore.shared.loadRecent(limit: 20)
    }
}
