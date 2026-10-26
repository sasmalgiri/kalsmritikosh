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
import SQLCipher

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
        /// W2-7 — the backup's ledger is encrypted with a key this Mac does not hold.
        case encryptedWithAnotherKey
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
        var usedNames = Self.reservedNames
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
    /// `taken` holds lowercased names: the backup folder usually sits on a case-insensitive
    /// volume, where "Letter.txt" and "letter.txt" are the same file.
    static func uniqueName(for name: String, taken: inout Set<String>) -> String {
        if taken.insert(name.lowercased()).inserted { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if taken.insert(candidate.lowercased()).inserted { return candidate }
            n += 1
        }
    }

    /// Control files a backup or signed snapshot writes beside the copied files. An original
    /// with one of these names is renamed ("manifest-2.json") so it can never replace — or be
    /// replaced by — the manifest, the signature or the sources map. Lowercased.
    static let reservedNames: Set<String> = [manifestName.lowercased(), "signature.json", "kalsnapshot-sources.json"]

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
    /// W2-7 — an encrypted backup is checked with `ledgerKey` (this Mac's key by default). One made
    /// with another Mac's key throws `encryptedWithAnotherKey`; restore again with that ledger's
    /// recovery key, which boot then keeps.
    @discardableResult
    public func restore(backupFolder: URL, into targetFolder: URL,
                        ledgerKey: LedgerKey? = LedgerKeychain.load()) throws -> BackupManifest {
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
        let stagedDB = staging.appendingPathComponent(dbEntry.relativePath)
        if LedgerFileState.of(stagedDB) == .encrypted {
            guard let ledgerKey else { throw BackupError.encryptedWithAnotherKey }
            var probe: OpaquePointer?
            defer { sqlite3_close(probe) }
            if sqlite3_open_v2(stagedDB.path, &probe, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let h = probe {
                do { try LedgerCipher.apply(ledgerKey, to: h) }
                catch LedgerEncryptionError.wrongKey { throw BackupError.encryptedWithAnotherKey }
            }
        }
        if let problem = Database.quickCheck(fileAt: stagedDB, key: ledgerKey) {
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

    // MARK: - Complete backup (brief §11)

    public static let sourcesMapName = "backup-sources.json"

    /// What a complete backup carries besides the ledger: each original's backup path, keyed by the
    /// ledger's file id, and the sources that could not be read (kept as external dependencies).
    public struct SourcesMap: Codable, Sendable, Equatable {
        public var originals: [String: String]      // file id → relative path inside the backup
        public var notIncluded: [String]            // original locations that could not be read
    }

    /// Ledger snapshot + every readable original (under `originals/`) + the sources map, all in one
    /// manifest with sizes and SHA-256. `databaseSnapshot` must be a consistent snapshot (the caller
    /// takes it with the online backup API).
    @discardableResult
    public func createCompleteBackup(databaseSnapshot: URL, originals: [(fileID: UUID, url: URL)], notIncluded: [String],
                                     destination: URL, schemaVersion: Int, nowEpoch: Double) throws -> BackupManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.appendingPathComponent("originals", isDirectory: true), withIntermediateDirectories: true)
        var entries: [BackupEntry] = []
        var taken = Self.reservedNames
        let dbName = Self.uniqueName(for: databaseSnapshot.lastPathComponent, taken: &taken)
        let dbDst = destination.appendingPathComponent(dbName)
        if fm.fileExists(atPath: dbDst.path) { try fm.removeItem(at: dbDst) }
        try fm.copyItem(at: databaseSnapshot, to: dbDst)
        let dbMeasured = try Self.measure(dbDst)
        entries.append(BackupEntry(relativePath: dbName, byteSize: dbMeasured.byteSize, sha256: dbMeasured.sha256, kind: .database))
        var map = SourcesMap(originals: [:], notIncluded: notIncluded)
        var takenOriginals = Set<String>()
        for o in originals {
            let rel = "originals/" + Self.uniqueName(for: o.url.lastPathComponent, taken: &takenOriginals)
            let dst = destination.appendingPathComponent(rel)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            do { try fm.copyItem(at: o.url, to: dst) } catch { map.notIncluded.append(o.url.path); continue }
            let measured = try Self.measure(dst)
            entries.append(BackupEntry(relativePath: rel, byteSize: measured.byteSize, sha256: measured.sha256, kind: .originalSource))
            map.originals[o.fileID.uuidString] = rel
        }
        let mapURL = destination.appendingPathComponent(Self.sourcesMapName)
        try JSONEncoder().encode(map).write(to: mapURL)
        let mapMeasured = try Self.measure(mapURL)
        entries.append(BackupEntry(relativePath: Self.sourcesMapName, byteSize: mapMeasured.byteSize, sha256: mapMeasured.sha256, kind: .derivedExport))
        let manifest = BackupPlanner.manifest(schemaVersion: schemaVersion, createdAtEpoch: nowEpoch, entries: entries, coverage: .complete)
        try JSONEncoder().encode(manifest).write(to: destination.appendingPathComponent(Self.manifestName))
        return manifest
    }

    /// Restore a complete backup into `targetFolder` (verified, staged and failure-atomic, as
    /// `restore`), then relink the restored ledger's sources to the restored originals so every
    /// citation opens on this Mac without the old Mac's paths. Returns the sources not included.
    @discardableResult
    public func restoreComplete(backupFolder: URL, into targetFolder: URL,
                                ledgerKey: LedgerKey? = LedgerKeychain.load()) async throws -> SourcesMap {
        let manifest = try restore(backupFolder: backupFolder, into: targetFolder, ledgerKey: ledgerKey)
        guard manifest.coverage == .complete, let dbEntry = manifest.databaseEntry else { return SourcesMap(originals: [:], notIncluded: []) }
        let map = try JSONDecoder().decode(SourcesMap.self, from: Data(contentsOf: targetFolder.appendingPathComponent(Self.sourcesMapName)))
        let db = try Database(url: targetFolder.appendingPathComponent(dbEntry.relativePath), key: ledgerKey)
        for (fileID, rel) in map.originals {
            guard let id = UUID(uuidString: fileID), RestoreValidator.isSafeRelativePath(rel) else { continue }
            let restored = targetFolder.appendingPathComponent(rel).standardizedFileURL
            try await db.exec("UPDATE files SET url = ?, availability = 'available' WHERE id = ?;", [.text(restored.absoluteString), .uuid(id)])
        }
        await db.close()
        return map
    }
}
