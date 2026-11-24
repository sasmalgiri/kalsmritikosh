//
//  RotateKeysRow.swift
//  Kalsmritikosh
//
//  ALCOA ALC-21 (owner 2026-11-24) — Settings ▸ Your data ▸ Encryption: "Rotate keys…". A confirmation names what changes
//  (a new ledger key and recovery key, the sealed originals re-sealed, a new audit-chain key; older backups need the old
//  recovery key), then the ledger closes, is rotated and opens again.
//

import SwiftUI
import os

struct RotateKeysRow: View {
    @Environment(AppState.self) private var appState
    @State private var confirming = false
    @State private var running = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(running ? "Rotating keys…" : "Rotate keys…") { confirming = true }
                .disabled(running || appState.database?.key == nil)
                .help("Make a new ledger key and recovery key, re-seal the kept originals and start a new audit-chain key")
            if let result { Text(result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .confirmationDialog("Rotate the keys?", isPresented: $confirming) {
            Button("Rotate keys") { Task { await rotate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The ledger closes for a moment and opens again under a new key. Your recovery key changes: write down the new one afterwards. Backups made before now still need the recovery key you have today.")
        }
    }

    private func rotate() async {
        running = true
        defer { running = false }
        result = await appState.rotateKeys(actor: InvestigatorProfile.name)
        KalsmritikoshLog.ui.info("Key rotation finished from Settings")
    }
}
