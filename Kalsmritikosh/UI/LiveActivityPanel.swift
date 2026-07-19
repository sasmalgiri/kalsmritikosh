//
//  LiveActivityPanel.swift
//  Kalsmritikosh
//
//  The little "what's happening" window pinned to the sidebar corner. Kept
//  deliberately simple: one plain-language status line, and — when there's
//  measurable work — a single progress bar. No jargon. Tap it for the full
//  Live dashboard.
//

import SwiftUI

struct LiveActivityPanel: View {
    @Environment(AppState.self) private var appState
    /// Jump to the full Live dashboard for detail.
    let onOpen: () -> Void

    /// Live parse/embed progress, refreshed on a light ~2s poll while the panel
    /// is on screen (it always is — it lives in the sidebar).
    @State private var progress = AppState.IngestProgress()
    /// Ticked on each poll so elapsed/ETA on active processes stay live.
    @State private var now = Date()

    private enum Stage { case reading, search, organizing, tidying, ready }

    private var stage: Stage {
        if appState.ingestActiveCount > 0 || progress.parsing { return .reading }
        if progress.embedding { return .search }
        if appState.isDistillingMemory { return .organizing }
        if appState.maintenanceActive { return .tidying }
        return .ready
    }

    private var busy: Bool { stage != .ready }

    private var title: String {
        switch stage {
        case .reading:    return "Reading your files…"
        case .search:     return "Getting search ready…"
        case .organizing: return "Organizing…"
        case .tidying:    return "Tidying up…"
        case .ready:      return "Ready"
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(busy ? Theme.brand : Color.green)
                        .frame(width: 8, height: 8)
                        .symbolEffect(.pulse, isActive: busy)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if stage == .reading, progress.filesTotal > 0 {
                    bar(progress.filesDone, progress.filesTotal)
                } else if stage == .search, progress.embedTotal > 0 {
                    bar(progress.embedDone, progress.embedTotal)
                }
                // Every other named background task (milestone rebuild, gap /
                // contradiction scans, memory distillation) with a start time,
                // live elapsed, and — when measurable — % + ETA.
                if !appState.activeProcesses.isEmpty {
                    Divider().padding(.top, 2)
                    ForEach(appState.activeProcesses) { activityRow($0) }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((busy ? Theme.brand : Color.secondary).opacity(0.22), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("What the app is doing — tap for details")
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: busy)
        .task {
            while !Task.isCancelled {
                progress = await appState.ingestProgress()
                now = Date()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// One named background task: title, live status line, and a bar when the
    /// work is measurable.
    private func activityRow(_ a: ProcessActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.brand)
                    .symbolEffect(.pulse)
                Text(a.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(a.statusLine(now: now))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let frac = a.fraction {
                ProgressView(value: frac)
                    .progressViewStyle(.linear)
                    .tint(Theme.brand)
            }
        }
    }

    /// A simple bar with a trailing "done/total · %" so the count is honest and
    /// legible (not just a bare percentage that can read 100% mid-scan).
    private func bar(_ done: Int, _ total: Int) -> some View {
        let frac = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
        return HStack(spacing: 8) {
            ProgressView(value: frac)
                .progressViewStyle(.linear)
                .tint(Theme.brand)
            Text("\(done)/\(total) · \(Int(frac * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}
