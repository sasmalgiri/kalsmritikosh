//
//  BackupService.swift
//  Kalsmritikosh
//
//  G2/Stage-11 / AT-15 — the thin I/O layer on top of the pure
//  BackupManifest core. It copies the database and the named original
//  sources into a backup folder, records each file's real size + sha256 in
//  a manifest.json, and restores by validating that manifest against what is
//  actually present before copying anything back. HONEST: a restore whose
//  manifest lists originals that are missing is refused with the missing
//  files named — never a silent partial restore.
//
//  Deterministic file set (caller supplies the URLs); no network; no app
//  singletons — testable against a temp directory.
//

import Foundation
import CryptoKit

public struct BackupService: Sendable {
    public init() { self.failPromotionAfter = nil }

    public static let manifestName = "manifest.json"

    public enum BackupError: Error, Sendable {
        case manifestMissing
        case restoreIncomplete(missing: [String])
        case notADatabaseBackup
        /// F19 — a manifest path that is unsafe, duplicated, or a symlink.
        case unsafeEntry(String)
        /// F19 — entries whose bytes do not match the manifest (in the backup or the staged copy).
        case damaged([String])
        /// F19 — the staged database failed SQLite's integrity check.
        case databaseUnusable(String)
        /// F19 — promotion stopped part-way; everything was rolled back.
        case promotionFailed(String)
    }

    /// Copy the database + originals into `destination`, writing a manifest.
    /// Returns the manifest actually written. `relativePath` for each file is
    /// its last path component (stable, no absolute paths leak into the backup).
    @discardableResult
    public func createBackup(
        databaseURL: URL,
        originalURLs: [URL],
        destination: URL,
        schemaVersion: Int,
        nowEpoch: Double,
        coverage: BackupCoverage = .ledgerOnly
    ) throws -> BackupManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var entries: [BackupEntry] = []
        var usedNames = Set<String>()
        func copyIn(_ src: URL, kind: BackupEntry.Kind) throws {
            // F17 — a UNIQUE relative path per entry: two originals named "letter.txt" used to share
            // one backup path, so the second overwrote the first and the manifest listed it twice.
            let name = Self.uniqueName(for: src.lastPathComponent, taken: &usedNames)
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            let measured = try Self.measure(dst)      // streaming — never the whole file in memory
            entries.append(BackupEntry(relativePath: name, byteSize: measured.byteSize,
                                       sha256: measured.sha256, kind: kind))
        }
        try copyIn(databaseURL, kind: .database)
        // NOTE: the `-wal` / `-shm` sidecars are NOT added here. The caller
        // passes them in `originalURLs` (see SettingsView), so adding them
        // again would write two manifest entries with the same relativePath.
        // The connection runs in WAL mode, so those sidecars matter — the
        // caller also checkpoints first (`Database.checkpointWAL`) so the main
        // file is self-contained and the copy cannot catch a torn state.
        for u in originalURLs { try copyIn(u, kind: .originalSource) }

        let manifest = BackupPlanner.manifest(schemaVersion: schemaVersion,
                                              createdAtEpoch: nowEpoch, entries: entries, coverage: coverage)
        let json = try JSONEncoder().encode(manifest)
        try json.write(to: destination.appendingPathComponent(Self.manifestName))
        return manifest
    }

    /// Validate a backup folder against its manifest WITHOUT copying — the
    /// honest pre-restore check the UI shows before touching anything.
    public func inspect(backupFolder: URL) throws -> (manifest: BackupManifest, verdict: RestoreVerdict) {
        let fm = FileManager.default
        let manifestURL = backupFolder.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifestURL) else { throw BackupError.manifestMissing }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)
        // F17 — verify CONTENT: stream-hash every entry that exists (never following an unsafe path
        // out of the backup folder) and compare size + SHA-256 with the manifest.
        var observed: [String: ObservedBackupFile] = [:]
        for entry in manifest.entries where RestoreValidator.isSafeRelativePath(entry.relativePath) {
            let url = backupFolder.appendingPathComponent(entry.relativePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  let measured = try? Self.measure(url) else { continue }
            observed[entry.relativePath] = measured
        }
        return (manifest, RestoreValidator.validate(manifest: manifest, observed: observed))
    }

    /// F17 — size + SHA-256 of a file, streamed in 1 MiB chunks.
    static func measure(_ url: URL) throws -> ObservedBackupFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return ObservedBackupFile(byteSize: size, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// "letter.txt", then "letter-2.txt", "letter-3.txt", … in input order (deterministic).
    static func uniqueName(for name: String, taken: inout Set<String>) -> String {
        if taken.insert(name).inserted { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if taken.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    /// F19 — test hook: throw after this many files have been promoted (simulates a mid-restore
    /// failure such as a full disk). nil in production.
    let failPromotionAfter: Int?
    init(failPromotionAfter: Int?) { self.failPromotionAfter = failPromotionAfter }

    /// Restore into `targetFolder` ONLY when the backup verifies. F19 — failure-atomic:
    ///  1. the backup must pass content verification (sizes, checksums, safe unique paths) and
    ///     contain no symlinked entries;
    ///  2. every file is copied into a FRESH staging folder beside the target (same volume), the
    ///     staged copies are re-verified, and the staged database must pass `PRAGMA quick_check`;
    ///  3. only then are files promoted — each existing target file (and any stale `-wal`/`-shm`
    ///     of the outgoing database) is first MOVED aside, never deleted, so a failure at any point
    ///     moves everything back and the previous data survives intact.
    /// The caller must not restore over a database that is open (the app never does: restore is
    /// not exposed while a ledger is live).
    @discardableResult
    public func restore(backupFolder: URL, into targetFolder: URL) throws -> BackupManifest {
        let (manifest, verdict) = try inspect(backupFolder: backupFolder)
        guard let dbEntry = manifest.databaseEntry else { throw BackupError.notADatabaseBackup }
        guard verdict.unsafe.isEmpty else { throw BackupError.unsafeEntry(verdict.unsafe.joined(separator: ", ")) }
        guard verdict.corrupt.isEmpty else { throw BackupError.damaged(verdict.corrupt) }
        guard verdict.ok else { throw BackupError.restoreIncomplete(missing: verdict.missing) }
        let fm = FileManager.default
        for e in manifest.entries {
            let attrs = try fm.attributesOfItem(atPath: backupFolder.appendingPathComponent(e.relativePath).path)
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { throw BackupError.unsafeEntry(e.relativePath) }
        }

        // 2. Stage + verify.
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        let parent = targetFolder.deletingLastPathComponent()
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(targetFolder.lastPathComponent).restore-\(token)", isDirectory: true)
        let aside = parent.appendingPathComponent(".\(targetFolder.lastPathComponent).previous-\(token)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for e in manifest.entries {
            let dst = staging.appendingPathComponent(e.relativePath)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: backupFolder.appendingPathComponent(e.relativePath), to: dst)
            let staged = try Self.measure(dst)
            guard staged.byteSize == e.byteSize, staged.sha256 == e.sha256.lowercased() else {
                throw BackupError.damaged([e.relativePath])
            }
        }
        if let problem = Database.quickCheck(fileAt: staging.appendingPathComponent(dbEntry.relativePath)) {
            throw BackupError.databaseUnusable(problem)
        }

        // 3. Promote with rollback. Stale sidecars of the OUTGOING database are moved aside too:
        // SQLite would otherwise replay one database's `-wal` into another's pages.
        var displaced: [(target: URL, saved: URL)] = []
        var promoted: [URL] = []
        let managedPaths = manifest.entries.map(\.relativePath)
            + ["-wal", "-shm"].map { dbEntry.relativePath + $0 }.filter { s in !manifest.entries.contains { $0.relativePath == s } }
        do {
            try fm.createDirectory(at: aside, withIntermediateDirectories: true)
            for rel in managedPaths {
                let target = targetFolder.appendingPathComponent(rel)
                guard fm.fileExists(atPath: target.path) else { continue }
                let saved = aside.appendingPathComponent(rel)
                try fm.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target, to: saved)
                displaced.append((target, saved))
            }
            for (i, e) in manifest.entries.enumerated() {
                if let limit = failPromotionAfter, i >= limit { throw BackupError.promotionFailed(e.relativePath) }
                let target = targetFolder.appendingPathComponent(e.relativePath)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staging.appendingPathComponent(e.relativePath), to: target)
                promoted.append(target)
            }
        } catch {
            // Roll back: remove what was promoted, put every displaced file back where it was.
            for url in promoted { try? fm.removeItem(at: url) }
            for d in displaced.reversed() { try? fm.moveItem(at: d.saved, to: d.target) }
            try? fm.removeItem(at: aside)
            throw error
        }
        try? fm.removeItem(at: aside)
        return manifest
    }
}
