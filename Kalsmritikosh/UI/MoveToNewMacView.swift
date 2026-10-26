//
//  MoveToNewMacView.swift
//  Kalsmritikosh
//
//  U-5 — a guided "Move to a new Mac" sheet, built only from what already exists:
//   1. a verified backup to a drive/folder (Database.backupSnapshot + BackupService, then
//      BackupService.inspect on the written folder — the same path as "Back up now…");
//   2. the recovery key (AppState.revealRecoveryKey, behind Touch ID / the Mac password);
//   3. what to do on the new Mac;
//   4. verification of a backup folder (BackupService.inspect) and of the open ledger.
//  The recovery key is shown on screen only when asked for and is never logged.
//

import SwiftUI
import os
#if canImport(AppKit)
import AppKit
#endif

/// A button that opens the guide; place it in the backup area of Settings ▸ Data.
struct MoveToNewMacButton: View {
    @State private var showing = false
    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Move to a new Mac…", systemImage: "macbook.and.arrow.forward")
        }
        .help("A step-by-step guide: a verified backup, your recovery key, and what to do on the new Mac.")
        .sheet(isPresented: $showing) { MoveToNewMacView { showing = false } }
    }
}

struct MoveToNewMacView: View {
    @Environment(AppState.self) private var appState
    let close: () -> Void

    @State private var step = 1
    // Step 1
    @State private var backingUp = false
    @State private var backupFolder: URL?
    @State private var backupStatus: String?
    @State private var backupVerified = false
    // Step 2
    @State private var revealed: String?
    @State private var keyProblem: String?
    @State private var keyKept = false
    // Step 4
    @State private var checkStatus: String?
    @State private var checkPassed: Bool?

    private var encrypted: Bool { appState.database?.key != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Move to a new Mac").font(.title2.bold())
                Spacer()
                Text("Step \(step) of 4").font(.callout).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step), total: 4)
                .accessibilityLabel("Step \(step) of 4")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch step {
                    case 1: stepBackup
                    case 2: stepRecoveryKey
                    case 3: stepNewMac
                    default: stepVerify
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Close", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 1 {
                    Button("Back") { step -= 1 }
                }
                if step < 4 {
                    Button("Next") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 440)
    }

    // MARK: - Step 1 — verified backup

    private var stepBackup: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("1. Make a verified backup", "externaldrive.badge.checkmark")
            Text("Save a copy of your ledger to an external drive or a folder you can reach from the new Mac. The copy is a consistent snapshot, and every file is checked against its recorded size and SHA-256 right after it is written.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Your original documents and the evidence vault are not in this backup. Copy the folders that hold your original files to the new Mac too (or keep them on a drive you will connect there).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    backUp()
                } label: {
                    if backingUp { Label("Backing up…", systemImage: "hourglass") }
                    else { Label("Back up now…", systemImage: "externaldrive.badge.plus") }
                }
                .disabled(backingUp || appState.database == nil)
                if backingUp { ProgressView().controlSize(.small) }
            }
            if appState.database == nil {
                Text("The ledger is not open yet, so there is nothing to back up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let backupStatus {
                Label(backupStatus, systemImage: backupVerified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(backupVerified ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Same sequence as Settings ▸ Data ▸ "Back up now…", followed by a verification read of
    /// the folder that was just written.
    private func backUp() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose an external drive or folder to save your Investigations Made Easy backup into."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        guard let database = appState.database else { return }
        backingUp = true
        backupStatus = nil
        backupVerified = false
        Task {
            let dbURL = DatabaseLocations.defaultDatabaseURL
            let dest = dir.appendingPathComponent("Investigations Made Easy-Backup-\(Int(Date().timeIntervalSince1970))")
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("kalsmritikosh-backup-\(UUID().uuidString)", isDirectory: true)
            defer {
                do { try FileManager.default.removeItem(at: scratch) } catch {
                    KalsmritikoshLog.ui.error("Move to new Mac: scratch cleanup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let snapshot = scratch.appendingPathComponent(dbURL.lastPathComponent)
                try await database.backupSnapshot(to: snapshot)
                _ = try BackupService().createBackup(
                    databaseURL: snapshot, originalURLs: [], destination: dest,
                    schemaVersion: SchemaMigrations.latestVersion,
                    nowEpoch: Date().timeIntervalSince1970)
                let (_, verdict) = try BackupService().inspect(backupFolder: dest)
                backupFolder = dest
                if verdict.ok {
                    backupVerified = true
                    backupStatus = "Backed up and verified: \u{201C}\(dest.lastPathComponent)\u{201D}. Keep this folder; you will need it on the new Mac."
                } else {
                    backupStatus = "The backup was written but did not verify (\(Self.describe(verdict))). Try again, ideally on a different drive."
                }
            } catch {
                KalsmritikoshLog.ui.error("Move to new Mac: backup failed: \(error.localizedDescription, privacy: .public)")
                backupStatus = "Backup failed: \(error.localizedDescription)"
            }
            backingUp = false
        }
        #endif
    }

    // MARK: - Step 2 — recovery key

    private var stepRecoveryKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("2. Have your recovery key", "key.fill")
            if encrypted {
                Text("Your ledger, and so this backup, is encrypted (AES-256). The key lives in this Mac's Keychain and never leaves it, not even with Migration Assistant. On the new Mac the app asks for the recovery key the first time it opens the ledger. Investigations Made Easy cannot recover it for you.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("The same key is under Settings ▸ Data ▸ Encryption ▸ Show recovery key. Showing it asks for Touch ID or your Mac password.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(revealed == nil ? "Show recovery key…" : "Hide recovery key") {
                        if revealed != nil { revealed = nil; return }
                        Task {
                            switch await appState.revealRecoveryKey() {
                            case .success(let text):
                                revealed = text; keyProblem = nil
                            case .failure(let error):
                                // The error never contains the key; only the failure is logged.
                                KalsmritikoshLog.ui.error("Move to new Mac: recovery key not shown: \(error.localizedDescription, privacy: .public)")
                                keyProblem = "The recovery key was not shown: \(error.localizedDescription)"
                            }
                        }
                    }
                    #if canImport(AppKit)
                    if let revealed {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(revealed, forType: .string)
                        }
                    }
                    #endif
                }
                if let revealed {
                    Text(revealed).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
                if let keyProblem { Text(keyProblem).font(.caption).foregroundStyle(.red) }
                Toggle("I have written the recovery key down and stored it somewhere safe (not only on this Mac).", isOn: $keyKept)
                    .font(.callout)
            } else {
                Text("The ledger is not open yet, so its encryption status and recovery key cannot be shown. Open the app fully, then come back to this step.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 3 — on the new Mac

    private var stepNewMac: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("3. On the new Mac", "macbook")
            Text("Simplest: use Apple's Migration Assistant when you set up the new Mac. It moves the app together with its ledger. The ledger's key is kept for this Mac only and does not move, so the first time you open Investigations Made Easy on the new Mac it asks for the recovery key from step 2 — enter it once and the new Mac keeps it.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Starting fresh instead: install Investigations Made Easy from the App Store with the same Apple ID (your purchase carries over), and connect the drive with your backup. Then choose Settings ▸ Data ▸ Restore from a backup…: the app quits, restores the backup when it opens again, and asks for the recovery key from step 2. A backup made with “Back up everything…” brings the original files too, so citations open without re-adding your folders.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Either way, if your original folders are in a different place on the new Mac, add them again in Sources so citations can open the original files.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 4 — verify

    private var stepVerify: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepTitle("4. Verify", "checkmark.seal")
            Text("Check a backup folder against its manifest: every file must be present with the recorded size and SHA-256. This reads the backup only; it changes nothing.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let backupFolder {
                    Button("Check the backup made in step 1") { check(backupFolder) }
                }
                Button("Check a backup folder…") { chooseAndCheck() }
            }
            if let checkStatus {
                Label(checkStatus, systemImage: checkPassed == true ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(checkPassed == true ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Label(encrypted
                  ? "On this Mac the ledger is open and encrypted (AES-256, key in the Keychain)."
                  : "On this Mac the ledger is not open yet.",
                  systemImage: encrypted ? "lock.shield.fill" : "lock.open")
                .font(.callout)
            Text("On the new Mac, open this guide again and run the check there: a backup that verifies on both Macs arrived intact.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseAndCheck() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Check Backup"
        panel.message = "Choose a backup folder to verify."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        check(dir)
        #endif
    }

    private func check(_ folder: URL) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let (manifest, verdict) = try BackupService().inspect(backupFolder: folder)
            checkPassed = verdict.ok
            checkStatus = verdict.ok
                ? "Backup OK — schema v\(manifest.schemaVersion). \(verdict.note)"
                : "This backup did not verify: \(Self.describe(verdict))."
        } catch {
            KalsmritikoshLog.ui.error("Move to new Mac: backup check failed: \(error.localizedDescription, privacy: .public)")
            checkPassed = false
            checkStatus = "That folder isn't a valid backup (no readable manifest.json)."
        }
    }

    // MARK: - Helpers

    private static func describe(_ v: RestoreVerdict) -> String {
        if !v.unsafe.isEmpty { return "unsafe paths in its manifest: \(v.unsafe.joined(separator: ", "))" }
        if !v.corrupt.isEmpty { return "files that don't match their checksum: \(v.corrupt.joined(separator: ", "))" }
        if !v.missing.isEmpty { return "missing: \(v.missing.joined(separator: ", "))" }
        return v.note
    }

    private func stepTitle(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Theme.brand).accessibilityHidden(true)
            Text(title).font(.title3.bold())
        }
    }
}
