//
//  SecureStaging.swift
//  Kalsmritikosh
//
//  ALCOA ALC-15 (owner 2026-11-24; DATA-25) — secure staging. Plaintext working copies of a person's documents — an
//  unlocked original (ProtectedSourceUnlockService), a captured byte snapshot (SourceByteCapture, the exact-byte reopen),
//  OCR page images, team-swarm pieces fetched in, and the exact original handed to another app — are staged in the
//  owner-only vault staging area beside the evidence vault (`<ledger folder>/EvidenceVault-staging`, folder 0700, each
//  staging folder 0700, files 0600), never in the shared temporary folder, and removed securely after use: the file's
//  content is first truncated to nothing (its data blocks released) and then the file is removed. At launch every
//  leftover older than an hour (a crash, a forced quit, a hand-off) is removed the same way.
//
//  Honest scope: on an SSD with APFS a truncate-then-remove cannot promise the old blocks are physically overwritten;
//  what it guarantees is that no readable copy is left anywhere the app put one, inside the app's own container.
//

import Foundation
import os

public nonisolated enum SecureStaging {

    public static let folderName = "EvidenceVault-staging"
    public static let minimumAge: TimeInterval = 3600

    private static let configured = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Set the staging area beside the open ledger (at boot). Before that (or with no ledger), an owner-only folder in
    /// the app's temporary folder is used.
    public static func configure(besideLedgerAt ledgerURL: URL) {
        configured.withLock { $0 = ledgerURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true) }
    }

    /// The staging area (created 0700 on first use).
    public static var root: URL {
        configured.withLock { $0 } ?? FileManager.default.temporaryDirectory.appendingPathComponent("kalsmritikosh-staging", isDirectory: true)
    }

    /// A fresh owner-only staging folder (0700) named `<prefix><uuid>`.
    public static func makeDirectory(_ prefix: String) throws -> URL {
        let fm = FileManager.default
        let base = root
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        let dir = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Write `data` as an owner-only file (0600) in a staging folder.
    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Make every file under `url` owner-only (0600; folders 0700) — for a copy written by another API.
    public static func restrict(_ url: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        do { try fm.setAttributes([.posixPermissions: isDir.boolValue ? 0o700 : 0o600], ofItemAtPath: url.path) } catch {
            KalsmritikoshLog.app.notice("Staging: permissions not set: \(String(describing: type(of: error)), privacy: .public)")
        }
        guard isDir.boolValue, let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let inner as URL in walker {
            let dir = (try? inner.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            do { try fm.setAttributes([.posixPermissions: dir ? 0o700 : 0o600], ofItemAtPath: inner.path) } catch {
                KalsmritikoshLog.app.notice("Staging: permissions not set: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Remove a staged file or folder securely: each file's content is truncated first, then everything is removed.
    /// Returns false when something could not be removed (logged).
    @discardableResult
    public static func remove(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        var files: [URL] = []
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue, let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let inner as URL in walker where (try? inner.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(inner) }
        } else if !isDir.boolValue {
            files = [url]
        }
        for f in files {
            do {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
                let handle = try FileHandle(forWritingTo: f)
                try handle.truncate(atOffset: 0)
                try handle.synchronize()
                try handle.close()
            } catch {
                KalsmritikoshLog.app.notice("Staging: a file could not be emptied before removal: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        if isDir.boolValue { restrict(url) }
        do { try fm.removeItem(at: url) } catch {
            KalsmritikoshLog.app.error("Staging: a staged copy could not be removed: \(error.localizedDescription, privacy: .private)")
            return false
        }
        return true
    }

    /// At launch: remove every leftover in the staging area older than `minimumAge`; returns how many were removed.
    @discardableResult
    public static func sweep(now: Date = Date(), minimumAge: TimeInterval = minimumAge) -> Int {
        let fm = FileManager.default
        let base = root
        guard fm.fileExists(atPath: base.path) else { return 0 }
        let items: [URL]
        do { items = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: []) } catch {
            KalsmritikoshLog.app.notice("Staging sweep: the staging area could not be listed: \(String(describing: type(of: error)), privacy: .public)")
            return 0
        }
        var removed = 0
        for url in items {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            if remove(url) { removed += 1 }
        }
        return removed
    }
}
