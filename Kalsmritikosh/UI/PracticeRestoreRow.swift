//
//  PracticeRestoreRow.swift
//  Kalsmritikosh
//
//  ALCOA ALC-16 (owner 2026-11-24) — Settings ▸ Backups: the last practice restore (monthly, and on demand) and a button
//  to run one now. The latest backup is restored into a temporary owner-only folder and checked, never over this ledger.
//

import SwiftUI
import os

struct PracticeRestoreRow: View {
    @Environment(AppState.self) private var appState
    @State private var last: PracticeRestore.Result?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(running ? "Practising…" : "Practise a restore now") { Task { await runNow() } }
                    .disabled(running || appState.database == nil)
                    .help("Restores your latest backup into a temporary folder, checks it, and removes it. Your ledger is not touched.")
                Text("Runs by itself once a month.").font(.caption2).foregroundStyle(.secondary)
            }
            Text(last?.line ?? "No practice restore has run yet.")
                .font(.caption).foregroundStyle(last.map { $0.ok ? Color.secondary : Color.orange } ?? .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { load() }
    }

    private func load() {
        guard let url = appState.database?.url else { return }
        last = PracticeRestore.last(besideLedgerAt: url)
    }

    private func runNow() async {
        guard let url = appState.database?.url else { return }
        running = true
        defer { running = false }
        let key = LedgerKeychain.load()
        last = await Task.detached(priority: .userInitiated) {
            PracticeRestore.run(besideLedgerAt: url, ledgerKey: key, trigger: "on demand")
        }.value
        KalsmritikoshLog.ui.info("Practice restore finished: \(last?.ok == true ? "ok" : "failed", privacy: .public)")
    }
}
