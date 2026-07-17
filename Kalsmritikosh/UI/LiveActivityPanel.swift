//
//  LiveActivityPanel.swift
//  Kalsmritikosh
//
//  Persistent "what's going on right now" window, pinned to the bottom-left
//  (the sidebar corner). Unlike the old auto-hiding ingest/maintenance pills,
//  this panel is ALWAYS visible so the user can glance at the corner at any
//  time and see live work: ingest in flight, memory distillation, and idle
//  maintenance. It reads AppState's push-updated @Observable properties
//  directly, so it needs no polling loop (the 2s LiveMetrics poller only runs
//  while the full Live tab is open). Tap it to open the full Live dashboard.
//

import SwiftUI

struct LiveActivityPanel: View {
    @Environment(AppState.self) private var appState
    /// Jump to the full Live dashboard for detail.
    let onOpen: () -> Void

    /// Live parse/embed progress, refreshed on a light poll while the panel is
    /// on screen (it always is — it lives in the sidebar).
    @State private var progress = AppState.IngestProgress()

    private var ingesting: Bool { appState.ingestActiveCount > 0 || progress.parsing }
    private var distilling: Bool { appState.isDistillingMemory }
    private var maintaining: Bool { appState.maintenanceActive }
    private var embedding: Bool { progress.embedding }
    private var anyActive: Bool { ingesting || distilling || maintaining || embedding }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 7) {
                header
                Divider().opacity(0.5)
                ingestRow
                if progress.parsing {
                    progressBar("Reading documents", done: progress.filesDone, total: progress.filesTotal)
                }
                if progress.embedding {
                    progressBar("Indexing meaning", done: progress.embedDone, total: progress.embedTotal)
                }
                if distilling { activityRow("brain.head.profile", "Distilling memory…", tint: Theme.brand, pulse: true) }
                maintenanceRow
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((anyActive ? Theme.brand : Color.secondary).opacity(0.22), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Live activity — tap for the full dashboard")
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: anyActive)
        .task {
            // Light poll (~2s) while the sidebar is on screen, so the bars
            // track parse + embed progress without a heavy always-on loop.
            while !Task.isCancelled {
                progress = await appState.ingestProgress()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// A labeled "done / total" progress bar with a percentage.
    private func progressBar(_ label: String, done: Int, total: Int) -> some View {
        let frac = total > 0 ? Double(done) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(done)/\(total) · \(Int(frac * 100))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            ProgressView(value: frac)
                .progressViewStyle(.linear)
                .tint(Theme.brand)
        }
    }

    /// Title line: a pulsing dot + "Working…" when anything is running, or a
    /// calm "All caught up" when idle.
    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(anyActive ? Theme.brand : Color.green)
                .frame(width: 8, height: 8)
                .overlay {
                    if anyActive {
                        Circle().stroke(Theme.brand.opacity(0.4), lineWidth: 5)
                            .scaleEffect(1.4).opacity(0.6)
                    }
                }
                .symbolEffect(.pulse, isActive: anyActive)
            Text(anyActive ? "Working…" : "All caught up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// Ingest is always shown — it's the activity users most want to confirm.
    @ViewBuilder
    private var ingestRow: some View {
        if ingesting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reading \(appState.ingestActiveCount) file\(appState.ingestActiveCount == 1 ? "" : "s")…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                    if let last = appState.ingestLastFile {
                        Text(last)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            activityRow("checkmark.circle.fill", "Reading idle", tint: .green, pulse: false)
        }
    }

    @ViewBuilder
    private var maintenanceRow: some View {
        if maintaining, let status = appState.maintenanceStatus {
            activityRow("moon.zzz.fill", status, tint: Theme.brand, pulse: true)
        }
    }

    private func activityRow(_ symbol: String, _ text: String, tint: Color, pulse: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: pulse)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
