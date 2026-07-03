//
//  SavedQueriesView.swift
//  Kalsmritikosh
//
//  HISTORY Phase J.7 — Vol 28 §Core Workspace. List of bookmarked
//  questions saved from AskView. Tapping "Run" copies the question
//  to a pasteboard and surfaces a hint; future v2 will wire the
//  re-run directly through MasterBrain so the user doesn't bounce
//  back to AskView.
//
//  Reading-only-ish surface — no editing of the question text in
//  v1; the user re-saves with a tweak if they want a variant.
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct SavedQueriesView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [SavedQuery] = []
    @State private var copiedID: SavedQuery.ID?
    /// Phase J.21 — re-run via InvestigationRunner. Tracks the
    /// in-flight item so the button can show a spinner, and the
    /// active investigation for sheet display.
    @State private var runningID: SavedQuery.ID?
    @State private var activeInvestigation: Investigation?
    @State private var runError: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(AuroraBackdrop(intensity: 0.5))
        .task { await reload() }
        .sheet(item: $activeInvestigation) { inv in
            SavedQueryInvestigationSheet(
                investigation: inv,
                error: runError,
                inFlight: runningID != nil,
                onClose: {
                    activeInvestigation = nil
                    runningID = nil
                    runError = nil
                }
            )
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "bookmark")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved questions")
                    .font(Theme.display(28, .bold))
                Text("Questions you bookmarked — re-ask them in Ask or re-run an investigation in one click.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(items.count)")
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
        if items.isEmpty {
            empty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        row(for: item)
                    }
                }
                .padding(14)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            Text("No saved questions yet.")
                .font(.title3.weight(.medium))
            Text("Type a question in Ask Atlas and tap the bookmark icon next to the input field to save it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for item: SavedQuery) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.question)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                Spacer()
                if let category = item.category {
                    Text(category)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
            HStack(spacing: 6) {
                Text("Saved \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                if let lastRun = item.lastRunAt {
                    Text("· last run \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button {
                    Task { await reinvestigate(item) }
                } label: {
                    if runningID == item.id {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Investigating…")
                        }
                    } else {
                        Label("Re-investigate", systemImage: "magnifyingglass.circle")
                    }
                }
                .disabled(appState.investigationRunner == nil || runningID != nil)
                Button {
                    copyToClipboard(item)
                } label: {
                    Label(
                        copiedID == item.id ? "Copied" : "Copy to Ask Atlas",
                        systemImage: copiedID == item.id ? "checkmark" : "doc.on.doc"
                    )
                }
                Button(role: .destructive) {
                    Task { await delete(item) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 12)
    }

    // MARK: - I/O

    private func reload() async {
        guard let repo = appState.savedQueries else { return }
        let list = (try? await repo.recent()) ?? []
        await MainActor.run { self.items = list }
    }

    /// Phase J.21 — one-click re-investigation. The runner streams
    /// updates into the sheet; the InvestigationsRepository auto-
    /// saves the result to Notebook on `.finished` so the user can
    /// compare runs over time.
    private func reinvestigate(_ item: SavedQuery) async {
        guard let runner = appState.investigationRunner else { return }
        await MainActor.run {
            runError = nil
            runningID = item.id
            activeInvestigation = Investigation(question: item.question)
        }
        Task {
            for await update in runner.investigate(question: item.question) {
                await MainActor.run { apply(update: update, for: item) }
            }
            await MainActor.run {
                runningID = nil
            }
            // Stamp last-run timestamp.
            if let repo = appState.savedQueries {
                try? await repo.touchLastRun(id: item.id)
                await reload()
            }
        }
    }

    private func apply(update: InvestigationUpdate, for item: SavedQuery) {
        switch update {
        case .planReady(let plan):
            activeInvestigation = plan
        case .stepStarted:
            break
        case .stepCompleted(let stepID, let answer):
            guard var inv = activeInvestigation,
                  let idx = inv.steps.firstIndex(where: { $0.id == stepID }) else { return }
            inv.steps[idx].answer = answer
            activeInvestigation = inv
        case .synthesizing:
            break
        case .finished(let inv):
            activeInvestigation = inv
        case .failed(let reason):
            runError = reason
        }
    }

    private func delete(_ item: SavedQuery) async {
        guard let repo = appState.savedQueries else { return }
        try? await repo.delete(item.id)
        await reload()
    }

    /// Copy to system pasteboard and stamp last-run. The user pastes
    /// into AskView in v1; a future commit can wire MasterBrain
    /// re-run directly so the round-trip disappears.
    private func copyToClipboard(_ item: SavedQuery) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.question, forType: .string)
        #endif
        copiedID = item.id
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                if copiedID == item.id { copiedID = nil }
            }
        }
        Task {
            guard let repo = appState.savedQueries else { return }
            try? await repo.touchLastRun(id: item.id)
            await reload()
        }
    }
}

/// Phase J.21 — sheet showing the streaming investigation triggered
/// from the Saved Queries tab. Mirrors AskView's InvestigationSheet
/// shape but standalone so the two callers stay decoupled.
private struct SavedQueryInvestigationSheet: View {
    let investigation: Investigation
    let error: String?
    let inFlight: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass.circle")
                    .foregroundStyle(.tint)
                Text("Re-investigation")
                    .font(.headline)
                Spacer()
                if inFlight {
                    ProgressView().controlSize(.small)
                }
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Text(investigation.question)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if investigation.steps.isEmpty {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Planning sub-questions…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(investigation.steps.enumerated()), id: \.element.id) { idx, step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(idx + 1).")
                                    .foregroundStyle(.tint)
                                Text(step.question)
                                    .font(.callout.weight(.medium))
                                Spacer()
                                if step.answer == nil {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            if let answer = step.answer {
                                Text(answer.answerText ?? answer.body)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.leading, 18)
                            }
                        }
                    }
                    if let synthesis = investigation.synthesis, !synthesis.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.tint)
                                Text("Synthesis").font(.headline)
                            }
                            Text(synthesis)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(.tint.opacity(0.08), in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 280, maxHeight: 480)
            Text("This run was auto-saved to your Notebook.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 620)
    }
}
