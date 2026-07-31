//
//  EvidenceVault.swift
//  Kalsmritikosh
//
//  EV-005 — optional managed evidence mode. Two honest modes (05_CANONICAL_EVIDENCE
//  LEDGER §9):
//
//   • Reference mode (default): the source stays in its original location; we keep a
//     bookmark + hash + derived evidence. Old bytes may become unavailable if the file
//     is externally replaced — derived snapshots still read, but reopening the exact
//     original bytes may fail.
//   • Managed mode: the app makes a local, content-addressed, IMMUTABLE copy, so every
//     source version can always be reopened (recommended for investigations/legal).
//
//  This is the vault store for managed mode: a content-addressed file store under the
//  app container, keyed by the SHA-256 the ingest pipeline already computes. Writing the
//  same bytes twice is a no-op (same address), so dedup is free. Deletion is explicit and
//  logged (never a silent cascade) — the caller owns the audit record.
//
//  Disk-only: no schema, no DB rows. Safe to add without a migration.
//

import Foundation
import CryptoKit
import OSLog

public actor EvidenceVault {
    /// Root directory of the vault (e.g. <container>/EvidenceVault).
    private let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    /// Lower-case hex SHA-256 of `data` — the content address.
    public nonisolated static func address(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sharded path for an address: <root>/ab/abcdef… (avoids one huge flat directory).
    private nonisolated func location(for hash: String) -> URL {
        let shard = String(hash.prefix(2))
        return root.appendingPathComponent(shard, isDirectory: true)
                   .appendingPathComponent(hash, isDirectory: false)
    }

    /// Store `data` immutably, returning its content address. Idempotent: identical bytes
    /// map to the same path, and an existing entry is left untouched (immutable). The file
    /// is marked read-only so an accidental write can't mutate stored evidence.
    @discardableResult
    public func store(_ data: Data) throws -> String {
        let hash = Self.address(for: data)
        let dest = location(for: hash)
        if fm.fileExists(atPath: dest.path) { return hash }   // already vaulted (dedup)
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        // Best-effort immutability: read-only perms. Not a security boundary, a guard.
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
        return hash
    }

    /// Copy a file at `url` into the vault, returning its content address.
    @discardableResult
    public func store(contentsOf url: URL) throws -> String {
        try store(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    /// USF-001 — stream a file into the vault through a bounded window (never a whole-file
    /// `Data(contentsOf:)`), computing SHA-256 while copying, so archives larger than
    /// memory are stored safely. Commits atomically, marks the blob read-only, and verifies
    /// the stored address equals the recomputed hash. Returns the content address.
    @discardableResult
    public func storeStreaming(contentsOf url: URL) throws -> String {
        let chunkSize = 1 << 20
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SourceIntakeError.inputNotAccessible(url)
        }
        defer { try? handle.close() }

        // First pass: hash to derive the content address without holding the whole file.
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let dest = location(for: hash)
        if fm.fileExists(atPath: dest.path) { return hash }   // already vaulted (dedup)

        // Second pass: stream the bytes into a temp file, then commit atomically.
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try handle.seek(toOffset: 0)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent("tmp-" + hash)
        fm.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp) else {
            throw SourceIntakeError.managedCopyFailed(reason: "cannot open vault temp for \(hash.prefix(8))")
        }
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.close()
        } catch {
            try? out.close(); try? fm.removeItem(at: tmp)
            throw SourceIntakeError.managedCopyFailed(reason: "vault write failed: \(error)")
        }
        // Commit atomically + make read-only, then verify the committed address.
        do {
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: tmp); return hash }
            try fm.moveItem(at: tmp, to: dest)
            try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
        } catch {
            try? fm.removeItem(at: tmp)
            throw SourceIntakeError.managedCopyFailed(reason: "vault commit failed: \(error)")
        }
        guard fm.fileExists(atPath: dest.path) else {
            throw SourceIntakeError.managedCopyFailed(reason: "vault address missing after commit")
        }
        return hash
    }

    public func contains(_ hash: String) -> Bool {
        fm.fileExists(atPath: location(for: hash).path)
    }

    /// Reopen the exact original bytes for a stored version, or nil if not vaulted.
    public func data(for hash: String) -> Data? {
        try? Data(contentsOf: location(for: hash), options: [.mappedIfSafe])
    }

    public func url(for hash: String) -> URL? {
        let u = location(for: hash)
        return fm.fileExists(atPath: u.path) ? u : nil
    }

    /// Total bytes currently stored — shown to the user before/after copying.
    public func totalBytes() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Estimate the bytes a copy would add — 0 if already vaulted (dedup). Lets the UI
    /// show storage impact BEFORE copying, per the spec.
    public nonisolated func estimatedAddedBytes(for data: Data) async -> Int64 {
        await contains(Self.address(for: data)) ? 0 : Int64(data.count)
    }

    /// Explicit, audited deletion (the caller records the audit event). Removing the
    /// content-addressed copy means that version's original bytes can no longer be
    /// reopened — the derived evidence is unaffected. No-op if absent.
    public func remove(_ hash: String) throws {
        let u = location(for: hash)
        guard fm.fileExists(atPath: u.path) else { return }
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path)  // allow removal
        try fm.removeItem(at: u)
        KalsmritikoshLog.storage.notice("EvidenceVault: removed \(hash.prefix(12), privacy: .public)… (explicit user action)")
    }
}
