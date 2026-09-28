//
//  BackupManifest.swift
//  Kalsmritikosh
//
//  G2/Stage-11 — the deterministic core of backup/restore. The pure model
//  describes WHAT a backup contains (the database + the originals + any
//  derived exports, each with size and checksum) and validates a restore
//  against what is actually present. File I/O (copying, hashing) lives in a
//  thin service on top; this core is pure and testable, and it is HONEST:
//  a raw database copy with missing originals is reported incomplete, never
//  silently "ok".
//

import Foundation

public struct BackupEntry: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case database, originalSource, derivedExport
    }
    public let relativePath: String
    public let byteSize: Int64
    public let sha256: String
    public let kind: Kind

    public init(relativePath: String, byteSize: Int64, sha256: String, kind: Kind) {
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.kind = kind
    }
}

public struct BackupManifest: Sendable, Equatable, Codable {
    public let createdAtEpoch: Double
    public let schemaVersion: Int
    public let entries: [BackupEntry]

    public init(createdAtEpoch: Double, schemaVersion: Int, entries: [BackupEntry]) {
        self.createdAtEpoch = createdAtEpoch
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public var databaseEntry: BackupEntry? { entries.first { $0.kind == .database } }
    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.byteSize } }
}

public enum BackupPlanner {
    /// Assemble a manifest with entries in a DETERMINISTIC order (by path),
    /// so two backups of the same content produce byte-identical manifests.
    public nonisolated static func manifest(
        schemaVersion: Int,
        createdAtEpoch: Double,
        entries: [BackupEntry]
    ) -> BackupManifest {
        BackupManifest(
            createdAtEpoch: createdAtEpoch,
            schemaVersion: schemaVersion,
            entries: entries.sorted { $0.relativePath < $1.relativePath })
    }
}

public struct RestoreVerdict: Sendable, Equatable {
    public let ok: Bool
    public let missing: [String]
    public let note: String
}

public enum RestoreValidator {
    /// A restore is OK only when the database entry is present AND every
    /// entry's path is present. A raw db copy with missing originals is
    /// reported (ok == false, the missing paths named), not silently valid.
    public nonisolated static func validate(
        manifest: BackupManifest,
        presentPaths: Set<String>
    ) -> RestoreVerdict {
        let missing = manifest.entries.map(\.relativePath)
            .filter { !presentPaths.contains($0) }
            .sorted()
        guard let db = manifest.databaseEntry else {
            return RestoreVerdict(ok: false, missing: missing,
                                  note: "No database in the backup — cannot restore.")
        }
        if !presentPaths.contains(db.relativePath) {
            return RestoreVerdict(ok: false, missing: missing,
                                  note: "The database file is missing from the restore set.")
        }
        if missing.isEmpty {
            return RestoreVerdict(ok: true, missing: [],
                                  note: "Complete: database and all \(manifest.entries.count) item(s) present.")
        }
        return RestoreVerdict(ok: false, missing: missing,
                              note: "Database present, but \(missing.count) item(s) are missing — restore is incomplete.")
    }
}
