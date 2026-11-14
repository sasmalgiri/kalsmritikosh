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

    /// `beforeRestore` (deep dive 2, #5): the copy of the ledger a restore keeps in "Before restore <time>" beside it.
    public enum Kind: String, Codable, Sendable { case ledger, complete, moveToNewMac, snapshot, beforeRestore }

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
            KalsmritikoshLog.storage.error("Backup log unreadable: \(error.localizedDescription, privacy: .private)")
            throw LogError.unreadable(error.localizedDescription)
        }
    }

    static func save(_ log: Log, besideLedgerAt ledgerURL: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let u = url(besideLedgerAt: ledgerURL)
        try enc.encode(log).write(to: u, options: .atomic)
        do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path) } catch {
            KalsmritikoshLog.storage.error("Backup log permissions not set: \(error.localizedDescription, privacy: .private)")
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

    /// The recorded backups made before `time` that were not deleted through the app. Deep dive 2 (#6): with the list beside
    /// each of `otherCopies` (the other copy of a moved ledger) too, once per backup; a backup deleted through either list is
    /// left out. Another copy's list that cannot be read is skipped (this Mac's own list still throws).
    static func madeBefore(_ time: Double, besideLedgerAt ledgerURL: URL, otherCopies: [URL] = []) throws -> [Entry] {
        var all = try load(besideLedgerAt: ledgerURL).entries
        for other in otherCopies where url(besideLedgerAt: other).standardizedFileURL != url(besideLedgerAt: ledgerURL).standardizedFileURL {
            do { all += try load(besideLedgerAt: other).entries } catch {
                KalsmritikoshLog.storage.error("The other ledger copy's backup list was not read: \(error.localizedDescription, privacy: .public)")
            }
        }
        let deleted = Set(all.filter { $0.deletedAt != nil }.map(\.id))
        var seen = Set<UUID>()
        let live = all.filter { $0.deletedAt == nil && $0.createdAt < time && !deleted.contains($0.id) && seen.insert($0.id).inserted }
        return live.sorted { $0.createdAt < $1.createdAt }
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
    /// it is still the recorded backup (`isRecordedBackup`); anything else is kept and named. Deep dive 2 (#6): the lists
    /// beside `otherCopies` (the other copy of a moved ledger) are worked through too, each backup once, and a deletion is
    /// marked in every list that has it.
    static func deleteBackups(madeBefore time: Double, besideLedgerAt ledgerURL: URL, otherCopies: [URL] = []) -> DeletionResult {
        var result = DeletionResult()
        let own = url(besideLedgerAt: ledgerURL).standardizedFileURL
        let locations = [ledgerURL] + otherCopies.filter { url(besideLedgerAt: $0).standardizedFileURL != own }
        var logs: [(at: URL, log: Log)] = []
        for (i, at) in locations.enumerated() {
            do { logs.append((at, try load(besideLedgerAt: at))) } catch {
                guard i > 0 else {
                    result.kept.append("the list of backups could not be read, so nothing was deleted")
                    return result
                }
                KalsmritikoshLog.storage.error("The other ledger copy's backup list was not read: \(error.localizedDescription, privacy: .public)")
                result.kept.append("the list of backups beside the other copy of this ledger could not be read, so the backups only it lists were not deleted")
            }
        }
        let fm = FileManager.default
        var deletedAt: [UUID: Double] = [:]
        var handled = Set<UUID>()
        var changed = Set<Int>()
        for l in logs.indices {
            for i in logs[l].log.entries.indices where logs[l].log.entries[i].deletedAt == nil && logs[l].log.entries[i].createdAt < time {
                let e = logs[l].log.entries[i]
                if let when = deletedAt[e.id] { logs[l].log.entries[i].deletedAt = when; changed.insert(l); continue }
                guard handled.insert(e.id).inserted else { continue }
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
                guard isRecordedBackup(folder, entry: e) else {
                    result.kept.append("\(line(e)) — the folder there is no longer that backup")
                    continue
                }
                do { try fm.removeItem(at: folder) } catch {
                    KalsmritikoshLog.storage.error("Backup not deleted: \(error.localizedDescription, privacy: .private)")
                }
                if fm.fileExists(atPath: folder.path) {
                    result.kept.append("\(line(e)) — it could not be removed (delete it in Finder)")
                } else {
                    let now = Date().timeIntervalSince1970
                    logs[l].log.entries[i].deletedAt = now
                    deletedAt[e.id] = now
                    changed.insert(l)
                    result.deleted.append(e)
                }
            }
        }
        for l in changed.sorted() {
            do { try save(logs[l].log, besideLedgerAt: logs[l].at) } catch {
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
            KalsmritikoshLog.storage.notice("Backup folder has no readable manifest: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    /// Whether `folder` is still the recorded backup `entry`: a backup by its manifest's creation time; a "Before restore"
    /// copy (deep dive 2, #5) by its own marker — the same creation time, and every ledger file it listed still there at
    /// the size it had. Anything else (a folder replaced, reused or emptied) is not deleted.
    static func isRecordedBackup(_ folder: URL, entry: Entry) -> Bool {
        guard entry.kind == .beforeRestore else { return isRecordedBackup(folder, createdAt: entry.createdAt) }
        guard folder.lastPathComponent.hasPrefix(beforeRestorePrefix) else { return false }
        do {
            let marker = try JSONDecoder().decode(BeforeRestoreMarker.self, from: Data(contentsOf: folder.appendingPathComponent(beforeRestoreMarkerName)))
            guard abs(marker.createdAt - entry.createdAt) < 0.001, !marker.files.isEmpty else { return false }
            for (name, size) in marker.files {
                guard RestoreValidator.isSafeRelativePath(name) else { return false }
                let attrs = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
                guard (attrs[.size] as? NSNumber)?.int64Value == size else { return false }
            }
            return true
        } catch {
            KalsmritikoshLog.storage.notice("Before-restore copy has no readable marker: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Deep dive 2 (#5) — the copy of the ledger a restore keeps

    /// The folder-name start of the copy a restore keeps ("Before restore <seconds>").
    static let beforeRestorePrefix = "Before restore "
    /// The marker written inside that copy: when it was made and the ledger files it holds (name → size).
    static let beforeRestoreMarkerName = "before-restore.json"

    struct BeforeRestoreMarker: Codable, Equatable, Sendable {
        var createdAt: Double
        var files: [String: Int64]
    }

    /// Write the marker of a "Before restore" copy (after its files are copied).
    static func writeBeforeRestoreMarker(in folder: URL, createdAt: Double) throws {
        var files: [String: Int64] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name != beforeRestoreMarkerName {
            let attrs = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            files[name] = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(BeforeRestoreMarker(createdAt: createdAt, files: files)).write(to: folder.appendingPathComponent(beforeRestoreMarkerName), options: .atomic)
    }
}
