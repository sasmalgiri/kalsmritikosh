//
//  ImportQueueView.swift
//  Kalsmritikosh
//
//  W1-9 — the import queue: see each added file, pause or resume, skip one,
//  move one up or down, clear finished rows.
//

import SwiftUI

struct ImportQueueView: View {
    @Bindable var queue: ImportQueue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Import queue").font(.title3.bold())
                Spacer()
                if queue.paused {
                    Button("Resume") { queue.resume() }
                } else {
                    Button("Pause") { queue.pause() }.disabled(!queue.isActive)
                }
                Button("Clear finished") { queue.clearFinished() }
            }
            Text(queue.paused ? "Paused — the current file finishes first, so nothing is left half-read."
                              : "\(queue.pendingCount) file\(queue.pendingCount == 1 ? "" : "s") waiting or running.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(queue.items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(item.state)).foregroundStyle(color(item.state))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if let e = item.error { Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
                        }
                        Spacer()
                        if item.state == .pending {
                            Button { queue.move(item.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless).help("Move up")
                            Button { queue.move(item.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.borderless).help("Move down")
                            Button("Skip") { queue.skip(item.id) }.buttonStyle(.borderless)
                        } else {
                            Text(label(item.state)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func symbol(_ s: ImportQueue.State) -> String {
        switch s {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "forward.end"
        }
    }
    private func color(_ s: ImportQueue.State) -> Color {
        switch s {
        case .done: return .green
        case .failed: return .orange
        case .running: return .accentColor
        default: return .secondary
        }
    }
    private func label(_ s: ImportQueue.State) -> String {
        switch s {
        case .running: return "Reading…"
        case .done: return "Added"
        case .failed: return "Could not add"
        case .skipped: return "Skipped"
        case .pending: return "Waiting"
        }
    }
}
