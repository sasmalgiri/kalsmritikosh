//
//  AlertsView.swift
//  Kalsmritikosh
//
//  W3-4 / N-11 — alerts raised after imports (contradictions, gaps, watchlist
//  names, changed answers) and the questions you watch.
//

import SwiftUI

struct AlertsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var alerts: [ProductAlert] = []
    @State private var pinned: [PinnedQuestion] = []
    @State private var newQuestion = ""
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Alerts").font(.title3.bold())
                Spacer()
                Button("Mark all read") { Task { try? await appState.alertsRepository?.markAllRead(); await load() } }
            }
            if ProductModuleFlags.isEnabled(.questionMonitors) {
                GroupBox("Questions you watch") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Pin a question to re-ask after each import", text: $newQuestion).textFieldStyle(.roundedBorder)
                            Button("Watch") {
                                Task { _ = try? await appState.pinnedQuestions?.pin(newQuestion); newQuestion = ""; await load() }
                            }.disabled(newQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button(checking ? "Checking…" : "Check now") {
                                Task {
                                    checking = true
                                    if let a = appState.alertsRepository { await appState.rerunPinnedQuestions(alerts: a) }
                                    checking = false
                                    await load()
                                }
                            }.disabled(checking || pinned.isEmpty)
                        }
                        ForEach(pinned) { q in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(q.question).font(.callout)
                                    Text(q.lastCheckedAt.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Not checked yet")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Stop watching") { Task { try? await appState.pinnedQuestions?.unpin(q.id); await load() } }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
            }
            List(alerts) { a in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if !a.read { Circle().fill(.orange).frame(width: 7, height: 7) }
                        Text(a.title).font(.callout.weight(a.read ? .regular : .semibold))
                    }
                    if let d = a.detail { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(4) }
                    Text("\(a.kind) · \(a.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 280)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 620)
        .task { await load() }
    }

    private func load() async {
        alerts = (try? await appState.alertsRepository?.recent()) ?? []
        pinned = (try? await appState.pinnedQuestions?.all()) ?? []
    }
}
