//
//  LiveActivityPanel.swift
//  Kalsmritikosh
//
//  The little "what's happening" window pinned to the sidebar corner. Shows a
//  plain-language status line, a progress bar, the granular pipeline stages
//  (Parse → Chunk → Embed → Entities → Events → Links — so the token/embedding
//  path is visible, not just "reading"), and Pause / Resume / Stop controls
//  while a bulk ingest is running. Tap the card for the full Live dashboard.
//

import SwiftUI

struct LiveActivityPanel: View {
    @Environment(AppState.self) private var appState
    /// Jump to the full Live dashboard for detail.
    let onOpen: () -> Void

    /// Live parse/embed progress, refreshed on a light ~2s poll while the panel
    /// is on screen (it always is — it lives in the sidebar).
    @State private var progress = AppState.IngestProgress()
    /// Per-stage cumulative counters (Parse/Chunk/Embed/Entities/Events/…) so the
    /// user can watch EVERY ingest path advance, including the embedding path.
    @State private var stages: [PipelineMetrics.Stage: Int] = [:]
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

    /// Pause/Resume/Stop only make sense for a bulk pass (the only cancellable
    /// unit); single-file watcher/boost ingests leave `ingestRunState == .idle`.
    private var showControls: Bool { appState.ingestRunState != .idle }

    private var title: String {
        if appState.ingestRunState == .paused { return "Paused" }
        switch stage {
        case .reading:    return "Reading your files…"
        case .search:     return "Getting search ready…"
        case .organizing: return "Organizing…"
        case .tidying:    return "Tidying up…"
        case .ready:      return "Ready"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onOpen) { card }
                .buttonStyle(.plain)
                .help("What the app is doing — tap for details")
            if showControls { controls }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: busy)
        .animation(.easeInOut(duration: 0.2), value: appState.ingestRunState)
        .task {
            while !Task.isCancelled {
                progress = await appState.ingestProgress()
                stages = await appState.pipelineMetrics?.snapshot() ?? [:]
                now = Date()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.ingestRunState == .paused ? Color.orange : (busy ? Theme.brand : Color.green))
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse, isActive: busy && appState.ingestRunState != .paused)
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
                let remaining = max(0, progress.filesTotal - progress.filesDone)
                if remaining > 0 {
                    Text("\(remaining) item\(remaining == 1 ? "" : "s") remaining")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let current = appState.ingestCurrentFile {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.brand)
                        Text("now: \(current)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else if stage == .search, progress.embedTotal > 0 {
                bar(progress.embedDone, progress.embedTotal)
            }
            // Granular pipeline stages — visible during ingest / embedding so the
            // user sees WHICH path is advancing (including the embedding path).
            if stage == .reading || stage == .search {
                stageGrid
            }
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

    // MARK: - Pipeline stage chips

    /// The full ingest path, in order. `.embedded` is the token/vector path the
    /// user specifically wanted surfaced.
    private static let stageOrder: [PipelineMetrics.Stage] =
        [.parse, .chunked, .embedded, .entities, .events, .relationships]

    private func shortLabel(_ s: PipelineMetrics.Stage) -> String {
        switch s {
        case .parse:         return "Parse"
        case .chunked:       return "Chunk"
        case .embedded:      return "Embed"
        case .entities:      return "Entities"
        case .events:        return "Events"
        case .relationships: return "Links"
        default:             return s.rawValue.capitalized
        }
    }

    private var stageGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 3) {
            ForEach(Self.stageOrder, id: \.self) { s in
                let n = stages[s] ?? 0
                HStack(spacing: 3) {
                    Text(shortLabel(s))
                        .foregroundStyle(.secondary)
                    Text("\(n)")
                        .foregroundStyle(n > 0 ? Theme.brand : .secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(n > 0 ? 1 : 0.4)
            }
        }
        .padding(.top, 1)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if appState.ingestRunState == .paused {
                ctlButton("Resume", "play.fill", tint: Theme.brand) { appState.resumeIngest() }
            } else {
                ctlButton("Pause", "pause.fill", tint: Theme.brand) { appState.pauseIngest() }
            }
            ctlButton("Stop", "stop.fill", tint: .red) { appState.stopIngest() }
            Spacer(minLength: 0)
            if appState.ingestRunState == .stopping {
                Text("Stopping…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .disabled(appState.ingestRunState == .stopping)
    }

    private func ctlButton(_ label: String, _ icon: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(tint.opacity(0.14), in: Capsule())
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
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
