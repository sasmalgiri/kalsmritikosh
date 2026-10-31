//
//  PendingRestore.swift
//  Kalsmritikosh
//
//  Implementation brief §11 — restoring a backup from inside the app. A ledger is never replaced
//  while it is open: "Restore from a backup…" verifies the chosen backup, remembers it (a
//  security-scoped bookmark) and quits; the next launch restores it BEFORE the ledger opens, with
//  the same verified, staged, roll-back-on-failure restore as everywhere else. A complete backup's
//  originals land next to the ledger and the ledger's sources are relinked to them.
//  Nothing is lost: the ledger being replaced is first copied to a "Before restore" folder beside it.
//  A backup made with another Mac's key asks for that ledger's recovery key (the boot recovery-key
//  screen); a key that does not open it cancels the restore and the current ledger opens unchanged.
//

import Foundation
import os

nonisolated enum PendingRestore {
    static let bookmarkKey = "pendingRestoreBackupBookmark"

    /// Where the schedule is kept. The test host keeps it in a suite of its own per process: CI runs
    /// test hosts in parallel processes sharing the app's defaults, and one host's restore must
    /// never consume another's schedule (nor the owner's).
    static let store: UserDefaults = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return .standard }
        return UserDefaults(suiteName: "kalsmritikosh.tests.pendingRestore.\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
    }()

    enum Outcome: Sendable, Equatable {
        case none
        case restored(String)
        case failed(String)
        /// The backup is encrypted with a key this Mac does not hold.
        case needsKey(String)
    }

    /// Verify `backupFolder` and remember it for the next launch. Returns a problem, or nil.
    static func schedule(backupFolder: URL) -> String? {
        do {
            let (_, verdict) = try BackupService().inspect(backupFolder: backupFolder)
            guard verdict.ok else { return "This backup did not verify, so it was not scheduled for restore." }
            let bookmark = try backupFolder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            store.set(bookmark, forKey: bookmarkKey)
            return nil
        } catch {
            KalsmritikoshLog.storage.error("Restore not scheduled: \(error.localizedDescription, privacy: .public)")
            return "That folder isn't a backup that can be restored: \(error.localizedDescription)"
        }
    }

    static var isScheduled: Bool { store.data(forKey: bookmarkKey) != nil }

    static func cancel() { store.removeObject(forKey: bookmarkKey) }

    /// Run a scheduled restore into the folder that holds `databaseURL`. Call before the ledger opens.
    static func performIfScheduled(databaseURL: URL, recoveryKey: LedgerKey?, nowEpoch: Double = Date().timeIntervalSince1970) async -> Outcome {
        guard let data = store.data(forKey: bookmarkKey) else { return .none }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
            cancel()
            return .failed("The backup chosen for restore could not be found (is its drive connected?). Your ledger was not changed.")
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let target = databaseURL.deletingLastPathComponent()
        do {
            let kept = try keepCurrent(databaseURL: databaseURL, nowEpoch: nowEpoch)
            let key = recoveryKey ?? LedgerKeychain.load()
            let map = try await BackupService().restoreComplete(backupFolder: folder, into: target, ledgerKey: key)
            cancel()
            var note = "Restored from “\(folder.lastPathComponent)”."
            if !map.originals.isEmpty { note += " \(map.originals.count) original file(s) were restored with it and the ledger's sources point to them." }
            if !map.notIncluded.isEmpty { note += " \(map.notIncluded.count) original(s) were not in the backup; add their folders again in Sources." }
            if let kept { note += " The ledger it replaced is kept in “\(kept.lastPathComponent)”." }
            KalsmritikoshLog.storage.info("Backup restored at boot: \(map.originals.count, privacy: .public) originals relinked")
            return .restored(note)
        } catch BackupService.BackupError.encryptedWithAnotherKey {
            if recoveryKey == nil {
                return .needsKey("The backup you chose to restore is encrypted with another Mac's key. Enter that ledger's recovery key to restore it.")
            }
            cancel()
            return .failed("That recovery key does not open the backup, so it was not restored. Your ledger was not changed.")
        } catch {
            KalsmritikoshLog.storage.error("Restore at boot failed: \(error.localizedDescription, privacy: .public)")
            cancel()
            return .failed("The backup was not restored (\(error.localizedDescription)). Your ledger was not changed.")
        }
    }

    /// Copy the ledger about to be replaced (with its -wal/-shm) into "Before restore <stamp>".
    static func keepCurrent(databaseURL: URL, nowEpoch: Double) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { return nil }
        let keep = databaseURL.deletingLastPathComponent().appendingPathComponent("Before restore \(Int(nowEpoch))", isDirectory: true)
        try fm.createDirectory(at: keep, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: keep.appendingPathComponent(src.lastPathComponent))
        }
        return keep
    }
}
