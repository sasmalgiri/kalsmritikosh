//
//  AppState+Sync.swift
//  Kalsmritikosh
//
//  X-5 — sync through a folder, from the app's side: set it up (new store or join one),
//  sync now, sync when the app comes forward and every few minutes while it is open, and
//  read in the notes and files that arrived. Only with "Sync through a folder" on.
//

import Foundation
import os

@MainActor
final class SyncStatus {
    static let shared = SyncStatus()
    var lastSummary: SyncEngine.Summary?
    var lastError: String?
    var lastSync: Date?
    var running = false
    var timer: Task<Void, Never>?
}

extension AppState {
    enum SyncSetup: Sendable { case createNew, joinExisting }

    /// Set up syncing to `folder`. `createNew` starts a store there; `joinExisting` opens one
    /// another device made (the passphrase must match).
    func configureSync(folder: URL, passphrase: String, mode: SyncSetup) async throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let store: SyncStore = try await Task.detached {
            switch mode {
            case .createNew: return try SyncStore.create(at: folder, passphrase: passphrase)
            case .joinExisting: return try SyncStore.open(at: folder, passphrase: passphrase)
            }
        }.value
        try SyncSettings.remember(folder: folder)
        try SyncSettings.saveStoreKey(store.key, storeID: store.info.storeID)
        await syncNow()
    }

    /// Stop syncing on this Mac. The folder and everything already here are kept.
    func stopSyncing() {
        SyncStatus.shared.timer?.cancel()
        SyncStatus.shared.timer = nil
        SyncSettings.forget()
    }

    func syncIfConfigured() async {
        guard ProductModuleFlags.isEnabled(.folderSync), SyncSettings.isConfigured else { return }
        await syncNow()
    }

    /// One sync: read the other devices' changes, then send this Mac's.
    func syncNow() async {
        let status = SyncStatus.shared
        guard ProductModuleFlags.isEnabled(.folderSync), !status.running, let database,
              let folder = SyncSettings.folder(), let key = SyncSettings.storeKey(),
              let notes = NotesStore.standard, let intake = CaptureIntake.folder else { return }
        status.running = true
        defer { status.running = false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            guard FileManager.default.fileExists(atPath: folder.path) else {
                status.lastError = "The sync folder is not available right now (is the disk or cloud folder connected?)."
                return
            }
            let store = try SyncStore.open(at: folder, key: key)
            let engine = SyncEngine(database: database, store: store, deviceID: SyncSettings.deviceID,
                                    deviceName: SyncSettings.deviceName, signingKey: try SyncSettings.signingKey(),
                                    notes: notes, intakeFolder: intake)
            let summary = try await engine.sync()
            status.lastSummary = summary
            status.lastError = nil
            status.lastSync = Date()
            for note in summary.notesChanged { await readNote(note) }
            if summary.intakeChanged { _ = await readCaptureIntake() }
            ensureSyncTimer()
        } catch {
            KalsmritikoshLog.app.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            status.lastError = error.localizedDescription
        }
    }

    /// Sync every five minutes while the app is open (and the module is on).
    func ensureSyncTimer() {
        let status = SyncStatus.shared
        guard status.timer == nil else { return }
        status.timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, !Task.isCancelled else { return }
                await self.syncIfConfigured()
            }
        }
    }

    /// Conflicts the person has not dismissed yet, newest first.
    func syncConflicts() async -> [(id: String, what: String, kept: String, other: String, at: Date)] {
        guard let database else { return [] }
        let rows = (try? await database.query("""
            SELECT id, tbl, field, kept_value, other_value, detected_at FROM sync_conflicts
            WHERE resolved_at IS NULL ORDER BY detected_at DESC LIMIT 200;
            """, [])) ?? []
        return rows.compactMap { r in
            guard let id = r.string(0) else { return nil }
            return (id, "\(r.string(1) ?? "?") · \(r.string(2) ?? "?")", r.string(3) ?? "", r.string(4) ?? "",
                    Date(timeIntervalSince1970: r.double(5) ?? 0))
        }
    }

    func dismissSyncConflict(_ id: String) async {
        try? await database?.exec("UPDATE sync_conflicts SET resolved_at = ? WHERE id = ?;", [.date(Date()), .text(id)])
    }

    /// Batches that failed verification, and changes waiting for a document.
    func syncProblems() async -> (quarantined: [String], waiting: Int) {
        guard let database else { return ([], 0) }
        let q = (try? await database.query("SELECT device, seq, reason FROM sync_quarantine ORDER BY seen_at DESC LIMIT 50;", [])) ?? []
        let w = Int((try? await database.query("SELECT COUNT(*) FROM sync_pending WHERE applied_at IS NULL;", []))?.first?.int(0) ?? 0)
        return (q.map { "\($0.string(0)?.prefix(8) ?? "?") #\($0.int(1) ?? 0): \($0.string(2) ?? "")" }, w)
    }
}
