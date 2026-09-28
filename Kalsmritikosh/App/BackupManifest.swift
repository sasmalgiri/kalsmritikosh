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

/// F17 — what a backup preserves. A ledger-only backup holds the database (and its sidecars); the
/// original files and the managed evidence vault are NOT inside it, so it cannot by itself re-open
/// evidence bytes. Stated in the manifest so "Backup OK" never implies more than it holds.
public enum BackupCoverage: String, Sendable, Codable, Equatable {
    case ledgerOnly
    case ledgerAndVault
}

public struct BackupManifest: Sendable, Equatable, Codable {
    public let createdAtEpoch: Double
    public let schemaVersion: Int
    public let entries: [BackupEntry]
    /// nil for manifests written before F17 (their coverage was never recorded).
    public let coverage: BackupCoverage?

    public init(createdAtEpoch: Double, schemaVersion: Int, entries: [BackupEntry], coverage: BackupCoverage? = nil) {
        self.createdAtEpoch = createdAtEpoch
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.coverage = coverage
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
        entries: [BackupEntry],
        coverage: BackupCoverage? = nil
    ) -> BackupManifest {
        BackupManifest(
            createdAtEpoch: createdAtEpoch,
            schemaVersion: schemaVersion,
            entries: entries.sorted { $0.relativePath < $1.relativePath },
            coverage: coverage)
    }
}

public struct RestoreVerdict: Sendable, Equatable {
    public let ok: Bool
    public let missing: [String]
    public let note: String
    /// F17 — present but with the wrong size or SHA-256.
    public let corrupt: [String]
    /// F17 — manifest paths that are absolute, climb out with "..", are empty, or repeat.
    public let unsafe: [String]

    public init(ok: Bool, missing: [String], note: String, corrupt: [String] = [], unsafe: [String] = []) {
        self.ok = ok
        self.missing = missing
        self.note = note
        self.corrupt = corrupt
        self.unsafe = unsafe
    }
}

/// F17 — what inspection actually measured for one manifest path.
public struct ObservedBackupFile: Sendable, Equatable {
    public let byteSize: Int64
    public let sha256: String
    public init(byteSize: Int64, sha256: String) { self.byteSize = byteSize; self.sha256 = sha256 }
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

    /// F17 — a manifest path is safe only when it is relative, non-empty and never climbs out of the
    /// backup folder ("..", absolute, or a leading "~").
    public nonisolated static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0 == ".." || $0.isEmpty }
    }

    /// F17 — CONTENT verification. OK only when: every path is safe and unique, the database entry
    /// exists, and every entry is present with exactly its recorded size AND SHA-256. Presence alone
    /// (the old check) let a flipped byte, a truncated-then-padded file or a forged path pass.
    public nonisolated static func validate(
        manifest: BackupManifest,
        observed: [String: ObservedBackupFile]
    ) -> RestoreVerdict {
        var seen = Set<String>()
        var unsafe: [String] = []
        for e in manifest.entries {
            if !isSafeRelativePath(e.relativePath) || !seen.insert(e.relativePath).inserted { unsafe.append(e.relativePath) }
        }
        let missing = manifest.entries.map(\.relativePath).filter { observed[$0] == nil }.sorted()
        let corrupt = manifest.entries.filter { e in
            guard let o = observed[e.relativePath] else { return false }
            return o.byteSize != e.byteSize || o.sha256.lowercased() != e.sha256.lowercased()
        }.map(\.relativePath).sorted()
        let coverageNote = manifest.coverage == .ledgerAndVault
            ? " Includes the evidence vault."
            : " Ledger only: original files and the managed evidence vault are not in this backup."
        guard unsafe.isEmpty else {
            return RestoreVerdict(ok: false, missing: missing, note: "The manifest lists unsafe or duplicate paths — refused.",
                                  corrupt: corrupt, unsafe: unsafe.sorted())
        }
        guard let db = manifest.databaseEntry else {
            return RestoreVerdict(ok: false, missing: missing, note: "No database in the backup — cannot restore.", corrupt: corrupt)
        }
        if observed[db.relativePath] == nil {
            return RestoreVerdict(ok: false, missing: missing, note: "The database file is missing from the restore set.", corrupt: corrupt)
        }
        if !corrupt.isEmpty {
            return RestoreVerdict(ok: false, missing: missing,
                                  note: "\(corrupt.count) item(s) do not match their recorded size and checksum — the backup is damaged.",
                                  corrupt: corrupt)
        }
        if !missing.isEmpty {
            return RestoreVerdict(ok: false, missing: missing,
                                  note: "Database present, but \(missing.count) item(s) are missing — restore is incomplete.")
        }
        return RestoreVerdict(ok: true, missing: [],
                              note: "Verified: all \(manifest.entries.count) item(s) match their recorded size and checksum." + coverageNote)
    }
}
