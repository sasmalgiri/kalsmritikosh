//
//  PracticeRestore.swift
//  Kalsmritikosh
//
//  ALCOA ALC-16 (owner 2026-11-24; DATA-26) — available. A backup is only proven by a restore. Once a month (and when
//  the person asks, Settings ▸ Backups ▸ Practise a restore) the latest backup this Mac made is restored into a
//  temporary owner-only folder (SecureStaging) — never over the open ledger — through the same verified restore path a
//  real restore uses (manifest, every file's size and SHA-256, the signature, the ledger's quick check), then the restored
//  ledger is opened with this Mac's key and checked (integrity check, schema version, its audit chain and cases read).
//  The copy is then removed securely. The result is kept beside the ledger (practice-restore-log.json) and shown.
//

import Foundation
import SQLCipher
import os

public nonisolated enum PracticeRestore {

    public struct Result: Codable, Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var ranAt: Double
        public var trigger: String
        public var backupName: String?
        public var backupCreatedAt: Double?
        public var ok: Bool
        public var steps: [String]
        public var problem: String?

        public var line: String {
            let when = BackupLog.stamp(ranAt)
            guard let name = backupName else { return "Practice restore \(when): \(problem ?? "no backup to practise with")." }
            let made = backupCreatedAt.map { " (made \(BackupLog.stamp($0)))" } ?? ""
            return ok ? "Practice restore \(when) of “\(name)”\(made): restored and checked — \(steps.joined(separator: "; "))."
                      : "Practice restore \(when) of “\(name)”\(made) FAILED: \(problem ?? "unknown problem")."
        }
    }

    static let fileName = "practice-restore-log.json"
    /// How often the scheduled practice runs.
    public static let interval: TimeInterval = 30 * 86_400

    static func url(besideLedgerAt ledgerURL: URL) -> URL { ledgerURL.deletingLastPathComponent().appendingPathComponent(fileName) }

    /// Every kept result, oldest first (an unreadable log is logged and read as none).
    public static func results(besideLedgerAt ledgerURL: URL) -> [Result] {
        let u = url(besideLedgerAt: ledgerURL)
        guard FileManager.default.fileExists(atPath: u.path) else { return [] }
        do { return try JSONDecoder().decode([Result].self, from: Data(contentsOf: u)) } catch {
            KalsmritikoshLog.storage.error("Practice restore log unreadable: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    public static func last(besideLedgerAt ledgerURL: URL) -> Result? { results(besideLedgerAt: ledgerURL).last }

    /// Due when none ran yet or the last ran over `interval` ago.
    public static func isDue(besideLedgerAt ledgerURL: URL, now: Date = Date()) -> Bool {
        guard let last = last(besideLedgerAt: ledgerURL) else { return true }
        return now.timeIntervalSince1970 - last.ranAt >= interval
    }

    static func keep(_ r: Result, besideLedgerAt ledgerURL: URL) {
        var all = results(besideLedgerAt: ledgerURL)
        all.append(r)
        do { try JSONEncoder().encode(Array(all.suffix(24))).write(to: url(besideLedgerAt: ledgerURL), options: .atomic) } catch {
            KalsmritikoshLog.storage.error("Practice restore result not kept: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The latest backup this Mac made that was not deleted (a ledger or complete backup).
    static func latestBackup(besideLedgerAt ledgerURL: URL) throws -> BackupLog.Entry? {
        try BackupLog.load(besideLedgerAt: ledgerURL).entries
            .filter { $0.deletedAt == nil && ($0.kind == .ledger || $0.kind == .complete) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Restore the latest backup into a temporary owner-only folder, check it, remove it; keep and return the result.
    @discardableResult
    public static func run(besideLedgerAt ledgerURL: URL, ledgerKey: LedgerKey?, trigger: String, now: Date = Date()) -> Result {
        var r = Result(ranAt: now.timeIntervalSince1970, trigger: trigger, backupName: nil, backupCreatedAt: nil, ok: false, steps: [], problem: nil)
        defer { keep(r, besideLedgerAt: ledgerURL) }
        let entry: BackupLog.Entry
        do {
            guard let e = try latestBackup(besideLedgerAt: ledgerURL) else { r.problem = "this Mac has made no backup yet"; return r }
            entry = e
        } catch {
            r.problem = "the list of backups could not be read (\(error.localizedDescription))"
            return r
        }
        r.backupName = entry.name
        r.backupCreatedAt = entry.createdAt
        var folder = URL(fileURLWithPath: entry.path, isDirectory: true)
        if let bookmark = entry.bookmark {
            var stale = false
            do { folder = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) } catch {
                KalsmritikoshLog.storage.notice("Practice restore: the backup's bookmark did not resolve; its path is used: \(error.localizedDescription, privacy: .private)")
            }
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let work: URL
        do { work = try SecureStaging.makeDirectory("practice-") } catch {
            r.problem = "no room to practise (\(error.localizedDescription))"
            return r
        }
        defer { SecureStaging.remove(work) }
        let target = work.appendingPathComponent("ledger", isDirectory: true)
        let manifest: BackupManifest
        do {
            let restored = try BackupService().restoreVerified(backupFolder: folder, into: target, ledgerKey: ledgerKey)
            manifest = restored.manifest
            r.steps.append("\(manifest.entries.count) file(s) matched their size and SHA-256")
            r.steps.append("signature \(String(describing: restored.signature))")
        } catch {
            KalsmritikoshLog.storage.error("Practice restore failed: \(error.localizedDescription, privacy: .private)")
            r.problem = "the backup did not restore (\(error.localizedDescription))"
            return r
        }
        guard let db = manifest.databaseEntry.map({ target.appendingPathComponent($0.relativePath) }) else {
            r.problem = "the backup holds no ledger"
            return r
        }
        do {
            r.steps += try checkLedger(db, key: LedgerFileState.of(db) == .encrypted ? ledgerKey : nil)
            r.ok = true
        } catch {
            KalsmritikoshLog.storage.error("Practice restore: the restored ledger failed its check: \(error.localizedDescription, privacy: .private)")
            r.problem = "the restored ledger failed its check (\(error.localizedDescription))"
        }
        return r
    }

    struct CheckFailure: Error, LocalizedError { let why: String; var errorDescription: String? { why } }

    /// Open the restored ledger read-only and check it: the full integrity check, its schema version, and that its cases
    /// and audit chain read.
    static func checkLedger(_ url: URL, key: LedgerKey?) throws -> [String] {
        if let problem = Database.quickCheck(fileAt: url, key: key) { throw CheckFailure(why: problem) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = handle else {
            sqlite3_close(handle)
            throw CheckFailure(why: "the restored ledger did not open")
        }
        defer { sqlite3_close(h) }
        if let key { try LedgerCipher.apply(key, to: h) }
        func scalar(_ sql: String) throws -> String {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { throw CheckFailure(why: "could not read: \(sql)") }
            defer { sqlite3_finalize(st) }
            guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { throw CheckFailure(why: "no answer to: \(sql)") }
            return String(cString: c)
        }
        let integrity = try scalar("PRAGMA integrity_check;")
        guard integrity == "ok" else { throw CheckFailure(why: "integrity check: \(integrity)") }
        let version = Int(try scalar("PRAGMA user_version;")) ?? 0
        guard version <= SchemaMigrations.latestVersion else { throw CheckFailure(why: "schema \(version) is newer than this app") }
        var steps = ["integrity check ok", "schema v\(version)"]
        for (label, table) in [("cases", "investigation_cases"), ("sealed audit events", "audit_chain"), ("source versions", "source_versions")] {
            let exists = (try? scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)';")) == "1"
            guard exists else { continue }
            steps.append("\(try scalar("SELECT COUNT(*) FROM \(table);")) \(label) read")
        }
        return steps
    }
}
