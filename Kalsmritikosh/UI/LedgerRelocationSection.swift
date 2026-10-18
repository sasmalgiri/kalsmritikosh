//
//  LedgerRelocationSection.swift
//  Kalsmritikosh
//
//  W1-8 — Settings ▸ Your data: copy the ledger to another disk (verified), see
//  where it lives, or go back to the copy on this Mac.
//

import SwiftUI
import UniformTypeIdentifiers
import os

struct LedgerRelocationSection: View {
    @Environment(AppState.self) private var appState
    @State private var choosing = false
    @State private var working = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ledger location").font(.subheadline.weight(.semibold))
            if let notice = appState.ledgerLocationNotice {
                Label(notice, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(LedgerRelocation.relocatedPath.map { "Set to: \($0)" } ?? "On this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Copy the ledger to another disk. The copy is checked before anything changes, Investigation Docs Made Easy uses it from the next launch, and the copy on this Mac is kept.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(working ? "Copying…" : "Copy ledger to another disk…") { choosing = true }
                    .disabled(working)
                if LedgerRelocation.relocatedPath != nil {
                    Button("Use the copy on this Mac") {
                        LedgerRelocation.useThisMac()
                        status = "From the next launch, Investigation Docs Made Easy will use the copy on this Mac. The disk copy was left in place."
                    }
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await copy(to: folder) }
        }
    }

    private func copy(to folder: URL) async {
        guard let db = appState.database else { status = LedgerRelocationError.notBooted.localizedDescription; return }
        working = true
        defer { working = false }
        do {
            let r = try await LedgerRelocation.copy(database: db, sourceDatabaseURL: db.url, toParent: folder)
            let size = ByteCountFormatter.string(fromByteCount: r.bytesCopied, countStyle: .file)
            status = "Copied and verified \(r.filesCopied) files (\(size)) to \(r.destination.path). Quit and reopen Investigation Docs Made Easy to use it."
        } catch {
            status = error.localizedDescription
            KalsmritikoshLog.storage.error("Ledger relocation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
