//
//  SyncSettingsView.swift
//  Kalsmritikosh
//
//  X-5 — Settings ▸ Your data ▸ Sync through a folder: choose the folder, set or enter the
//  passphrase, sync now, see the devices, conflicts, waiting changes and refused batches,
//  and stop syncing (everything stays on this Mac and in the folder).
//

import SwiftUI
import AppKit
import os

struct SyncSettingsSection: View {
    @Environment(AppState.self) private var appState
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var folder: URL?
    @State private var mode: AppState.SyncSetup = .createNew
    @State private var message: String?
    @State private var working = false
    @State private var conflicts: [(id: String, what: String, kept: String, other: String, at: Date)] = []
    @State private var problems: (quarantined: [String], waiting: Int) = ([], 0)
    @State private var configured = SyncSettings.isConfigured

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync through a folder").font(.subheadline.weight(.semibold))
            Text("Keeps your notes, tags, groups, highlights, PDF marks and the files you added in the app in step with your other Macs and your iPhone or iPad, through a folder you choose (iCloud Drive, Dropbox, a shared or USB disk). Everything in it is encrypted with your passphrase. The app makes no connection; the folder's own service moves the files.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if configured { configuredView } else { setupView }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .task { await refresh() }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $mode) {
                Text("Start syncing from this Mac").tag(AppState.SyncSetup.createNew)
                Text("Join a sync folder another device made").tag(AppState.SyncSetup.joinExisting)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            HStack {
                Button("Choose folder…") { choose() }
                Text(folder?.path ?? "No folder chosen").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            SecureField("Sync passphrase", text: $passphrase)
            if mode == .createNew {
                SecureField("Passphrase again", text: $confirm)
                Text("Use the same passphrase on every device. It cannot be recovered: without it the folder cannot be read.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(mode == .createNew ? "Start syncing" : "Join") { Task { await setUp() } }
                .disabled(working || folder == nil || passphrase.isEmpty || (mode == .createNew && passphrase != confirm))
        }
    }

    private var configuredView: some View {
        VStack(alignment: .leading, spacing: 6) {
            let status = SyncStatus.shared
            HStack {
                Button(working ? "Syncing…" : "Sync now") { Task { working = true; await appState.syncNow(); working = false; await refresh() } }
                    .disabled(working)
                if let last = status.lastSync {
                    Text("Last synced \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = status.lastSummary {
                Text("Last sync: \(s.changesApplied) change\(s.changesApplied == 1 ? "" : "s") received, \(s.changesSent) sent, \(s.filesReceived) file\(s.filesReceived == 1 ? "" : "s") received, \(s.filesSent) sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = status.lastError { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if problems.waiting > 0 {
                Text("\(problems.waiting) change\(problems.waiting == 1 ? " is" : "s are") waiting for a document this Mac does not have yet; they apply once it arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !problems.quarantined.isEmpty {
                DisclosureGroup("Refused changes (\(problems.quarantined.count))") {
                    ForEach(problems.quarantined, id: \.self) { Text($0).font(.caption2) }
                }.font(.caption)
            }
            if !conflicts.isEmpty {
                DisclosureGroup("Conflicts (\(conflicts.count))") {
                    ForEach(conflicts, id: \.id) { c in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.what).font(.caption.weight(.semibold))
                                Text("Kept: \(c.kept)").font(.caption2)
                                Text("Other device: \(c.other)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Dismiss") { Task { await appState.dismissSyncConflict(c.id); await refresh() } }
                                .buttonStyle(.borderless).font(.caption2)
                        }
                    }
                }.font(.caption)
            }
            Button("Stop syncing on this Mac") {
                appState.stopSyncing(); configured = false
                message = "Syncing is off on this Mac. Everything already here stays, and the folder is left as it is."
            }
            .controlSize(.small)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Choose a folder every device can reach — for example in iCloud Drive or Dropbox."
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func setUp() async {
        guard let folder else { return }
        working = true
        defer { working = false }
        do {
            try await appState.configureSync(folder: folder, passphrase: passphrase, mode: mode)
            passphrase = ""; confirm = ""
            configured = SyncSettings.isConfigured
            message = configured ? "Syncing is on." : nil
        } catch {
            KalsmritikoshLog.app.error("Sync setup failed: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
        }
        await refresh()
    }

    private func refresh() async {
        configured = SyncSettings.isConfigured
        conflicts = await appState.syncConflicts()
        problems = await appState.syncProblems()
    }
}
