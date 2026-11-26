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
    /// When the erasure was made, and the backups this Mac made before it (deep dive batch 5: also from Settings ▸ Backups,
    /// read from the erasure register and the backup list after a relaunch).
    let erasedAt: Double
    let backupsBefore: [BackupLog.Entry]
    let refused: Bool
    /// Called after the person chose to delete them (the caller reads the list again).
    var onDeleted: () -> Void = {}
    @State private var confirm = false
    @State private var result: String?

    init(outcome: AppState.ErasureOutcome) {
        erasedAt = outcome.erasedAt
        backupsBefore = outcome.backupsBefore
        refused = outcome.report.refused != nil
    }

    init(pending: AppState.PendingErasureBackups, onDeleted: @escaping () -> Void = {}) {
        erasedAt = pending.erasedAt
        backupsBefore = pending.backups
        refused = false
        self.onDeleted = onDeleted
    }

    var body: some View {
        if !refused, !backupsBefore.isEmpty || result != nil {
            VStack(alignment: .leading, spacing: 4) {
                Button("Delete backups made before this erasure…", role: .destructive) { confirm = true }
                    .disabled(reason: result != nil ? "Already done for this erasure." : nil, remedy: "See the result below.")
                    .accessibilityIdentifier("erasure.deleteEarlierBackups")
                if let result { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            // A later erasure is a new choice: the previous one's result does not carry over.
            .onChange(of: erasedAt) { result = nil }
            .confirmationDialog("Delete \(backupsBefore.count) backup(s) made before this erasure?", isPresented: $confirm) {
                Button("Delete backups", role: .destructive) {
                    result = appState.deleteBackups(madeBefore: erasedAt).summary
                    onDeleted()
                }
                Button("Keep them", role: .cancel) {}
            } message: {
                Text("The backup folders this Mac made before the erasure are removed: \(backupsBefore.map(\.name).joined(separator: ", ")). They also hold everything else that was in your ledger then. A folder that is no longer that backup is kept. Copies you moved or made yourself are not known to the app. This cannot be undone.")
            }
        }
    }
}
