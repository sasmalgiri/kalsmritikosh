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
    public init() {}

    public static let manifestName = "manifest.json"

    public enum BackupError: Error, Sendable {
        case manifestMissing
        case restoreIncomplete(missing: [String])
        case notADatabaseBackup
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
        nowEpoch: Double
    ) throws -> BackupManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var entries: [BackupEntry] = []
        func copyIn(_ src: URL, kind: BackupEntry.Kind) throws {
            let name = src.lastPathComponent
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            let data = try Data(contentsOf: dst)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            entries.append(BackupEntry(relativePath: name, byteSize: Int64(data.count),
                                       sha256: digest, kind: kind))
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
                                              createdAtEpoch: nowEpoch, entries: entries)
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
        let present = Set(manifest.entries.map(\.relativePath)
            .filter { fm.fileExists(atPath: backupFolder.appendingPathComponent($0).path) })
        return (manifest, RestoreValidator.validate(manifest: manifest, presentPaths: present))
    }

    /// Restore into `targetFolder` ONLY when the backup is complete. Returns
    /// the manifest restored; throws restoreIncomplete (naming the missing
    /// files) rather than performing a partial restore.
    @discardableResult
    public func restore(backupFolder: URL, into targetFolder: URL) throws -> BackupManifest {
        let (manifest, verdict) = try inspect(backupFolder: backupFolder)
        guard manifest.databaseEntry != nil else { throw BackupError.notADatabaseBackup }
        guard verdict.ok else { throw BackupError.restoreIncomplete(missing: verdict.missing) }
        let fm = FileManager.default
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        // REMOVE THE OUTGOING DATABASE'S SIDECARS FIRST. SQLite recovers a
        // `-wal` against whatever main file it finds beside it. Restoring a
        // `knowledge.sqlite` on top of the PREVIOUS database's leftover
        // `-wal`/`-shm` would let SQLite replay one database's log into
        // another's pages — corruption produced by the recovery feature.
        // Entries from this backup (which may legitimately include a `-wal`)
        // are copied in immediately below, so this only clears what is stale.
        if let dbName = manifest.databaseEntry?.relativePath {
            for suffix in ["-wal", "-shm"] {
                let sidecar = targetFolder.appendingPathComponent(dbName + suffix)
                if fm.fileExists(atPath: sidecar.path) { try? fm.removeItem(at: sidecar) }
            }
        }
        for entry in manifest.entries {
            let src = backupFolder.appendingPathComponent(entry.relativePath)
            let dst = targetFolder.appendingPathComponent(entry.relativePath)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
        return manifest
    }
}
