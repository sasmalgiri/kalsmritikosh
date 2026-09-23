//
//  HealthPanelView.swift
//  Kalsmritikosh
//
//  U-3.3 (W-6) — the Health & Self-check panel. Renders a HealthReport:
//  invariant badges (green/amber/red) at the top so a violation is visible
//  at a glance, then coverage rows with per-state counts. Decoupled from
//  data gathering — it takes a HealthReport, so the pure evaluator (and its
//  CI test) is the source of truth for when the panel goes red. A "Run
//  self-check" action re-gathers the report.
//

import SwiftUI

public struct HealthPanelView: View {
    let report: HealthReport
    let isRunning: Bool
    let onRunSelfCheck: () -> Void

    public init(report: HealthReport, isRunning: Bool = false,
                onRunSelfCheck: @escaping () -> Void = {}) {
        self.report = report
        self.isRunning = isRunning
        self.onRunSelfCheck = onRunSelfCheck
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            invariantsSection
            Divider()
            coverageSection
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Health & self-check").font(.headline)
                Text(statusSummary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRunSelfCheck) {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run self-check", systemImage: "checkmark.circle")
                }
            }
            .disabled(isRunning)
        }
    }

    private var invariantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(report.invariants) { inv in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: inv.status))
                        .foregroundStyle(color(for: inv.status))
                        .imageScale(.small)
                    Text(inv.title).font(.callout)
                    Spacer()
                    if inv.status != .pass {
                        Text(inv.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(inv.title): \(inv.status.rawValue). \(inv.detail)")
            }
        }
    }

    private var coverageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Coverage").font(.subheadline.weight(.semibold))
            ForEach(report.coverage) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(row.title).font(.callout)
                        Spacer()
                        Text("\(row.total)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !row.states.isEmpty {
                        Text(row.states.map { "\($0.label): \($0.count)" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Status styling

    private var statusColor: Color { color(for: report.worstStatus) }
    private var statusIcon: String { icon(for: report.worstStatus) }
    private var statusSummary: String {
        switch report.worstStatus {
        case .pass: return "All \(report.measuredCount) measured check(s) passing."
        case .warn: return "Working — some checks still settling."
        case .fail: return "A check failed — see the red items below."
        // Never "all passing": nothing has been measured yet.
        case .notMeasured: return "Nothing to check yet — ingest an archive first."
        }
    }

    private func color(for s: HealthInvariant.Status) -> Color {
        switch s {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        // Grey, deliberately: not green, and not an alarm either.
        case .notMeasured: return .secondary
        }
    }
    private func icon(for s: HealthInvariant.Status) -> String {
        switch s {
        case .pass: return "checkmark.seal.fill"
        case .warn: return "clock.badge.exclamationmark"
        case .fail: return "xmark.octagon.fill"
        case .notMeasured: return "circle.dashed"
        }
    }
}
