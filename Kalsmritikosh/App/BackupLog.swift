//
//  BackupLog.swift
//  Kalsmritikosh
//
//  SEC-07 — an erasure cannot rewrite a backup made before it. The backups this Mac makes are listed in a small file
//  BESIDE the ledger (`backup-log.json`, never part of a backup, so a restore never replaces it): the folder's name and
//  path, when it was made (the manifest's own time), its kind and, when macOS gives one, an app-scoped bookmark so the
//  folder can be found again later. No case content, no titles.
//
//  An erasure lists the backups made before it (the receipt says they still hold what was erased) and offers to delete
//  them; `deleteBackups(madeBefore:)` runs ONLY on that explicit choice. It deletes a folder only when its manifest is
//  still the recorded backup's (same creation time), so a folder that was replaced or reused is never removed. Copies
//  the person moved, renamed or made by hand are not known to the app.
//

import Foundation
import os

public nonisolated enum BackupLog {
    static let fileName = "backup-log.json"

    public enum Kind: String, Codable, Sendable { case ledger, complete, moveToNewMac, snapshot }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var kind: Kind
        /// The backup folder's name.
        public var name: String
        /// The folder's path when it was made.
        public var path: String
        /// The backup manifest's creation time (seconds since 1970).
        public var createdAt: Double
        /// App-scoped bookmark of the folder (nil when the system gave none).
        public var bookmark: Data?
        /// When the person chose to delete it and it was removed.
        public var deletedAt: Double?
    }

    struct Log: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry] = []
    }

    enum LogError: Error, LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let why): return "The list of backups this Mac made could not be read (\(why))." }
        }
    }

    static func url(besideLedgerAt ledgerURL: URL) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The log beside the ledger (empty when none was written). An unreadable log throws: it is never "no backups".
    static func load(besideLedgerAt ledgerURL: URL) throws -> Log {
        let u = url(besideLedgerAt: ledgerURL)
        guard FileManager.default.fileExists(atPath: u.path) else { return Log() }
        do { return try JSONDecoder().decode(Log.self, from: Data(contentsOf: u)) } catch {
            KalsmritikoshLog.storage.error("Backup log unreadable: \(error.localizedDescription, privacy: .public)")
            throw LogError.unreadable(error.localizedDescription)
        }
    }

    static func save(_ log: Log, besideLedgerAt ledgerURL: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let u = url(besideLedgerAt: ledgerURL)
        try enc.encode(log).write(to: u, options: .atomic)
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path) } catch {
            KalsmritikoshLog.storage.error("Backup log permissions not set: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Record a backup folder just made. Returns a problem for the person when it could not be recorded (never silent).
    @discardableResult
    static func record(folder: URL, kind: Kind, createdAt: Double, besideLedgerAt ledgerURL: URL) -> String? {
        var bookmark: Data?
        do { bookmark = try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) } catch {
            // Outside the sandbox (tests) or for a folder macOS will not bookmark: the path alone is kept.
            KalsmritikoshLog.storage.notice("Backup folder bookmark not made: \(error.localizedDescription, privacy: .public)")
        }
        let entry = Entry(id: UUID(), kind: kind, name: folder.lastPathComponent, path: folder.standardizedFileURL.path,
                          createdAt: createdAt, bookmark: bookmark, deletedAt: nil)
        do {
            var log = try load(besideLedgerAt: ledgerURL)
            log.entries.append(entry)
            try save(log, besideLedgerAt: ledgerURL)
            return nil
        } catch {
            KalsmritikoshLog.storage.error("Backup not recorded in the backup list: \(error.localizedDescription, privacy: .public)")
            return "This backup could not be added to the list of backups this Mac made, so a later erasure will not name it."
        }
    }

    /// The recorded backups made before `time` that were not deleted through the app.
    static func madeBefore(_ time: Double, besideLedgerAt ledgerURL: URL) throws -> [Entry] {
        try load(besideLedgerAt: ledgerURL).entries.filter { $0.deletedAt == nil && $0.createdAt < time }.sorted { $0.createdAt < $1.createdAt }
    }

    /// A backup's line for a receipt: its name, when it was made (with the zone) and where it was.
    public static func line(_ e: Entry) -> String {
        "“\(e.name)” (made \(stamp(e.createdAt)), at \(e.path))"
    }

    /// A time for the person, with its zone stated.
    public static func stamp(_ epoch: Double) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return df.string(from: Date(timeIntervalSince1970: epoch))
    }

    public struct DeletionResult: Sendable, Equatable {
        public var deleted: [Entry] = []
        /// Not at its recorded place any more (moved, renamed or already deleted outside the app).
        public var notFound: [Entry] = []
        /// Kept, with the reason (the folder is no longer that backup, or it could not be removed).
        public var kept: [String] = []
        public var summary: String {
            var parts: [String] = []
            if !deleted.isEmpty { parts.append("Deleted \(deleted.count) backup(s) made before the erasure: \(deleted.map(line).joined(separator: "; ")).") }
            if !notFound.isEmpty {
                parts.append("\(notFound.count) recorded backup(s) were not at their recorded place (moved, renamed or already deleted): \(notFound.map(line).joined(separator: "; ")). Delete any copy of them yourself.")
            }
            if !kept.isEmpty { parts.append("Not deleted: \(kept.joined(separator: "; ")).") }
            return parts.isEmpty ? "No backup made before the erasure is recorded on this Mac." : parts.joined(separator: " ")
        }
    }

    /// Delete the recorded backups made before `time` — only on the person's explicit choice. A folder is removed only when
    /// its manifest still has the recorded creation time; anything else is kept and named.
    static func deleteBackups(madeBefore time: Double, besideLedgerAt ledgerURL: URL) -> DeletionResult {
        var result = DeletionResult()
        var log: Log
        do { log = try load(besideLedgerAt: ledgerURL) } catch {
            result.kept.append("the list of backups could not be read, so nothing was deleted")
            return result
        }
        let fm = FileManager.default
        for i in log.entries.indices where log.entries[i].deletedAt == nil && log.entries[i].createdAt < time {
            let e = log.entries[i]
            var folder = URL(fileURLWithPath: e.path, isDirectory: true)
            if let bookmark = e.bookmark {
                var stale = false
                do { folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) } catch {
                    KalsmritikoshLog.storage.notice("Backup bookmark not resolved; using the recorded path: \(error.localizedDescription, privacy: .public)")
                }
            }
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard fm.fileExists(atPath: folder.path) else { result.notFound.append(e); continue }
            guard isRecordedBackup(folder, createdAt: e.createdAt) else {
                result.kept.append("\(line(e)) — the folder there is no longer that backup")
                continue
            }
            do { try fm.removeItem(at: folder) } catch {
                KalsmritikoshLog.storage.error("Backup not deleted: \(error.localizedDescription, privacy: .public)")
            }
            if fm.fileExists(atPath: folder.path) {
                result.kept.append("\(line(e)) — it could not be removed (delete it in Finder)")
            } else {
                log.entries[i].deletedAt = Date().timeIntervalSince1970
                result.deleted.append(e)
            }
        }
        if !result.deleted.isEmpty {
            do { try save(log, besideLedgerAt: ledgerURL) } catch {
                KalsmritikoshLog.storage.error("Backup list not updated after deletion: \(error.localizedDescription, privacy: .public)")
                result.kept.append("the list of backups was not updated (the deleted folders are gone)")
            }
        }
        KalsmritikoshLog.storage.notice("Backups before an erasure: \(result.deleted.count, privacy: .public) deleted, \(result.notFound.count, privacy: .public) not found, \(result.kept.count, privacy: .public) kept")
        return result
    }

    /// Whether `folder` holds the backup made at `createdAt` (its manifest says so).
    static func isRecordedBackup(_ folder: URL, createdAt: Double) -> Bool {
        let manifestURL = folder.appendingPathComponent(BackupService.manifestName)
        do {
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
            return abs(manifest.createdAtEpoch - createdAt) < 0.001
        } catch {
            KalsmritikoshLog.storage.notice("Backup folder has no readable manifest: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
