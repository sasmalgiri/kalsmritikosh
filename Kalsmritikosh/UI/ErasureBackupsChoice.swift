//
//  ErasureBackupsChoice.swift
//  Kalsmritikosh
//
//  SEC-07 — after a case or person erasure, the backups this Mac made before it still hold what was erased. The receipt
//  names them; this control offers deleting them as an explicit, confirmed choice. Nothing is deleted without it.
//

import SwiftUI

struct ErasureBackupsChoice: View {
    @Environment(AppState.self) private var appState
    let outcome: AppState.ErasureOutcome
    @State private var confirm = false
    @State private var result: String?

    var body: some View {
        if outcome.report.refused == nil, !outcome.backupsBefore.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Button("Delete backups made before this erasure…", role: .destructive) { confirm = true }
                    .disabled(reason: result != nil ? "Already done for this erasure." : nil, remedy: "See the result below.")
                    .accessibilityIdentifier("erasure.deleteEarlierBackups")
                if let result { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            // A later erasure is a new choice: the previous one's result does not carry over.
            .onChange(of: outcome.erasedAt) { result = nil }
            .confirmationDialog("Delete \(outcome.backupsBefore.count) backup(s) made before this erasure?", isPresented: $confirm) {
                Button("Delete backups", role: .destructive) {
                    result = appState.deleteBackups(madeBefore: outcome.erasedAt).summary
                }
                Button("Keep them", role: .cancel) {}
            } message: {
                Text("The backup folders this Mac made before the erasure are removed: \(outcome.backupsBefore.map(\.name).joined(separator: ", ")). They also hold everything else that was in your ledger then. A folder that is no longer that backup is kept. Copies you moved or made yourself are not known to the app. This cannot be undone.")
            }
        }
    }
}
