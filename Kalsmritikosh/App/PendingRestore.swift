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
//  RECOVERY-06: the erasure register beside the ledger (ErasureRegister) is never replaced by a restore;
//  a backup older than a full erase is refused, and erased cases and people that come back are erased
//  again when the ledger opens.
//

import Foundation
import os

nonisolated enum PendingRestore {
    static let bookmarkKey = "pendingRestoreBackupBookmark"

    /// Where the schedule is kept. The test host keeps it in a suite of its own per process: CI runs
    /// test hosts in parallel processes sharing the app's defaults, and one host's restore must
    /// never consume another's schedule (nor the owner's).
    static let store: UserDefaults = {
        guard TestHost.isActive else { return .standard }
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
        // RECOVERY-06 — a backup made before a full erase holds only erased data: refused, never restored.
        // (Cases and people erased after the backup are erased again when the ledger opens.)
        do {
            let (manifest, _) = try BackupService().inspect(backupFolder: folder)
            if let why = ErasureRegister.refusal(backupCreatedAt: manifest.createdAtEpoch, besideLedgerAt: databaseURL) {
                cancel()
                return .failed(why)
            }
        } catch {
            KalsmritikoshLog.storage.error("Restore not checked against the erasure register: \(error.localizedDescription, privacy: .public)")
            cancel()
            return .failed("The backup was not restored (\(error.localizedDescription)). Your ledger was not changed.")
        }
        do {
            let kept = try keepCurrent(databaseURL: databaseURL, nowEpoch: nowEpoch)
            // Deep dive 2 (#5) — the kept copy is a copy of the ledger: listed with this Mac's backups, so a later erasure
            // names it and "Delete backups made before this erasure" can remove it.
            let unlisted = kept.flatMap { BackupLog.record(folder: $0, kind: .beforeRestore, createdAt: nowEpoch, besideLedgerAt: databaseURL) }
            let key = recoveryKey ?? LedgerKeychain.load()
            let map = try await BackupService().restoreComplete(backupFolder: folder, into: target, ledgerKey: key)
            cancel()
            var note = "Restored from “\(folder.lastPathComponent)”."
            if !map.originals.isEmpty { note += " \(map.originals.count) original file(s) were restored with it and the ledger's sources point to them." }
            if !map.notIncluded.isEmpty { note += " \(map.notIncluded.count) original(s) were not in the backup; add their folders again in Sources." }
            if let kept { note += " The ledger it replaced is kept in “\(kept.lastPathComponent)”." }
            if let unlisted { note += " " + unlisted }
            // S11 — partial recovery is said, never shown as a verified complete case.
            if let u = map.unaccounted, !u.isEmpty { note += " \(u.count) source(s) the ledger names have no original in the backup and were not listed as left out; they show as missing." }
            if let c = map.changedSinceRecorded, !c.isEmpty { note += " \(c.count) original(s) had changed since they were recorded; the restored copy is not the version the ledger cites." }
            switch map.signature.flatMap(BackupSignatureState.init(rawValue:)) {
            case .absent?: note += " This backup's manifest is not signed (an older backup): its files match it, but it cannot be proved unaltered."
            case .notChecked?: note += " The backup's signature could not be checked with the key used."
            default: break
            }
            if (map.pausedOutbox ?? 0) + (map.pausedEffects ?? 0) > 0 {
                note += " \(map.pausedOutbox ?? 0) queued automation(s) and \(map.pausedEffects ?? 0) prepared hand-over(s) are paused: they may already have happened on the old Mac. Check each in its case before resuming."
            }
            note += " AI permissions are asked again, and you sign in again where needed: they are never in a backup."
            KalsmritikoshLog.storage.info("Backup restored at boot: \(map.originals.count, privacy: .public) originals relinked")
            return .restored(note)
        } catch BackupService.BackupError.manifestAltered {
            cancel()
            return .failed("The backup was not restored: its manifest was changed after the backup was made (the signature does not match). Your ledger was not changed. Use another backup.")
        } catch BackupService.BackupError.encryptedWithAnotherKey {
            if recoveryKey == nil {
                return .needsKey("The backup you chose to restore is encrypted with another Mac's key. Enter that ledger's recovery key to restore it.")
            }
            cancel()
            return .failed("That recovery key does not open the backup, so it was not restored. Your ledger was not changed.")
        } catch let notUndone as BackupService.RestoreNotUndone {
            // Deep dive 2 (#2) — never "not changed" when the undo itself did not finish.
            KalsmritikoshLog.storage.error("Restore at boot failed and was not fully undone: \(notUndone.localizedDescription, privacy: .private)")
            cancel()
            return .failed("The backup was not restored, and \(notUndone.localizedDescription). Quit and reopen the app before you work in the ledger.")
        } catch {
            KalsmritikoshLog.storage.error("Restore at boot failed: \(error.localizedDescription, privacy: .private)")
            cancel()
            return .failed("The backup was not restored (\(error.localizedDescription)). Your ledger was not changed.")
        }
    }

    /// Copy the ledger about to be replaced (with its -wal/-shm) into "Before restore <stamp>".
    static func keepCurrent(databaseURL: URL, nowEpoch: Double) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { return nil }
        // S11 (RECOVERY-09) — a repeated restore within the same second keeps its own copy instead of failing on the first.
        let stem = BackupLog.beforeRestorePrefix + "\(Int(nowEpoch))"
        var keep = databaseURL.deletingLastPathComponent().appendingPathComponent(stem, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: keep.path) {
            keep = databaseURL.deletingLastPathComponent().appendingPathComponent("\(stem)-\(n)", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: keep, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try fm.copyItem(at: src, to: keep.appendingPathComponent(src.lastPathComponent))
        }
        try BackupLog.writeBeforeRestoreMarker(in: keep, createdAt: nowEpoch)
        return keep
    }
}
