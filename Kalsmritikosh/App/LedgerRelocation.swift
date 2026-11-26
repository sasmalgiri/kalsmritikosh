//
//  LedgerRelocation.swift
//  Kalsmritikosh
//
//  W1-8 — move the ledger to another disk (ported in spirit from mailin's
//  ArchiveRelocator). The ledger is one folder: knowledge.sqlite plus the
//  evidence vault, index caches and receipts beside it, all derived from the
//  database URL at boot. So relocating = a verified copy of that folder and a
//  bookmark that boot follows.
//
//  Safety rules:
//   * The database is copied with SQLite's Online Backup (`Database.backupSnapshot`),
//     a consistent snapshot of the live database (never a raw copy of a file that
//     is being written), encrypted with the same ledger key (W2-7), and the copy
//     must pass PRAGMA quick_check.
//   * Every other file is copied and its SHA-256 compared with the original.
//   * The switch takes effect at the next launch; the copy on this Mac is kept.
//   * Boot never silently opens a stale copy: if the disk is absent, or this
//     Mac's copy has newer changes, it opens this Mac's copy and says why.
//   * Nothing is deleted.
//

import Foundation
import CryptoKit
import os

public struct LedgerRelocationReport: Sendable {
    public let destination: URL
    public let filesCopied: Int
    public let bytesCopied: Int64
}

public enum LedgerRelocationError: Error, LocalizedError {
    case destinationHasLedger(URL), integrityFailed(String), hashMismatch(String), notBooted
    public var errorDescription: String? {
        switch self {
        case .destinationHasLedger(let u): return "\(u.lastPathComponent) already contains an Investigations Made Easy ledger. Choose an empty folder."
        case .integrityFailed(let m):      return "The copied database failed its integrity check (\(m)). Nothing was switched."
        case .hashMismatch(let f):         return "\(f) did not copy exactly. Nothing was switched."
        case .notBooted:                   return "The ledger is not open yet."
        }
    }
}

public enum LedgerRelocation {

    static let folderName = "Investigations Made Easy Ledger"
    private static let bookmarkKey = "kalsmritikosh.ledger.relocatedBookmark"
    private static let pathKey = "kalsmritikosh.ledger.relocatedPath"

    /// Where the relocated ledger lives, for display.
    public static var relocatedPath: String? { UserDefaults.standard.string(forKey: pathKey) }

    // MARK: - Copy

    /// S16 (SEC-03) — a path (relative to the ledger folder) inside the vault's opened-copies folder.
    /// ALCOA ALC-15 — the staging area (unlocked originals, captures, page images in use) is never carried either.
    static func isOpenedPlaintext(_ rel: String) -> Bool {
        rel == "EvidenceVault-open" || rel.hasPrefix("EvidenceVault-open/") || rel == SecureStaging.folderName || rel.hasPrefix(SecureStaging.folderName + "/")
    }

    public static func copy(database: Database, sourceDatabaseURL: URL, toParent parent: URL) async throws -> LedgerRelocationReport {
        let fm = FileManager.default
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }

        let destDir = parent.appendingPathComponent(folderName, isDirectory: true)
        let destDB = destDir.appendingPathComponent("knowledge.sqlite")
        // Speed PERF-25 (owner 2026-11-23) — not tested yet. A copy this app started and did not finish (its resume log is
        // still there) is resumed: the database snapshot is taken again, files already copied and unchanged are kept.
        let resumeLogURL = destDir.appendingPathComponent(CopyResumeLog.fileName)
        let resuming = fm.fileExists(atPath: resumeLogURL.path)
        if fm.fileExists(atPath: destDB.path), !resuming { throw LedgerRelocationError.destinationHasLedger(destDir) }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let log = CopyResumeLog(folder: destDir)
        if !resuming { log.record(relativePath: ".started", source: destDir, copy: destDir, measured: .init(byteSize: 0, sha256: "")) }
        if resuming {
            for suffix in ["", "-wal", "-shm"] {
                let u = URL(fileURLWithPath: destDB.path + suffix)
                if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }   // our own unfinished snapshot, taken again below
            }
        }

        // 1. Consistent database snapshot — after every open studio's pending writes landed (review R5).
        try await StudioStorage.requireAllSaved()
        try await database.backupSnapshot(to: destDB)
        let copy = try Database(url: destDB, key: database.key)
        let check = try await copy.query("PRAGMA quick_check;", []).first?.string(0) ?? "no result"
        guard check == "ok" else { throw LedgerRelocationError.integrityFailed(check) }

        // 2. Everything else beside the database, hash-verified.
        let srcDir = sourceDatabaseURL.deletingLastPathComponent()
        let skip: Set<String> = ["knowledge.sqlite", "knowledge.sqlite-wal", "knowledge.sqlite-shm", CopyResumeLog.fileName]
        var plan: [(src: URL, rel: String, size: Int64)] = []
        if let walker = fm.enumerator(at: srcDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            while let item = walker.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                let rel = item.path.replacingOccurrences(of: srcDir.path + "/", with: "")
                if skip.contains(rel) { continue }
                // S16 (SEC-03) — opened plaintext copies of sealed originals never travel (they are rebuilt from the vault).
                if Self.isOpenedPlaintext(rel) { continue }
                let target = destDir.appendingPathComponent(rel)
                // A file that was already there before this copy began is not ours: it is kept and not counted.
                if fm.fileExists(atPath: target.path), log.reusable(relativePath: rel, source: item, copy: target) == nil, !resuming { continue }
                plan.append((item, rel, Int64(values.fileSize ?? 0)))
            }
        }
        // Speed PERF-25 (owner 2026-11-23) — not tested yet. Each file is read ONCE: the bytes written are the bytes hashed,
        // and the copy is then compared with the source's digest taken in that same pass (a clone on the same volume is
        // hashed over the clone). Files in parallel with work stealing; each finished file is logged for a resume.
        try WorkStealingQueue.perform(count: plan.count, workers: WorkStealingQueue.copyWidth()) { i in
            let p = plan[i]
            let target = destDir.appendingPathComponent(p.rel)
            if log.reusable(relativePath: p.rel, source: p.src, copy: target) != nil { return }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let written = try StreamingFileCopy.copyAndHash(from: p.src, to: target)
            guard written.byteSize == StreamingFileCopy.stamp(target)?.size else { throw LedgerRelocationError.hashMismatch(p.rel) }
            log.record(relativePath: p.rel, source: p.src, copy: target, measured: written)
        }
        let files = plan.count
        let bytes = plan.reduce(Int64(0)) { $0 + $1.size }
        log.remove()

        // 3. Remember it; boot follows from the next launch.
        let bookmark = try parent.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(destDir.path, forKey: pathKey)
        KalsmritikoshLog.storage.info("Ledger copied to another disk: \(files, privacy: .public) files + database, verified")
        return LedgerRelocationReport(destination: destDir, filesCopied: files + 1,
                                      bytesCopied: bytes + Int64((try? destDB.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    /// Go back to the copy on this Mac (the disk copy is left in place).
    public static func useThisMac() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
    }

    // MARK: - Boot

    /// The database boot should open, and a notice when it could not follow the relocation.
    public static func bootURL() -> (url: URL, notice: String?) {
        let local = DatabaseLocations.defaultDatabaseURL
        guard ProductModuleFlags.isEnabled(.ledgerRelocation),
              let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return (local, nil) }
        var stale = false
        guard let parent = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return (local, "Investigations Made Easy could not find the disk that holds your ledger, so it opened the copy on this Mac. Changes made now are on this Mac only.")
        }
        // Kept open for the life of the app: the ledger is used continuously.
        _ = parent.startAccessingSecurityScopedResource()
        let remote = parent.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("knowledge.sqlite")
        let fm = FileManager.default
        guard fm.fileExists(atPath: remote.path) else {
            return (local, "The disk that holds your ledger is not connected, so Investigations Made Easy opened the copy on this Mac. Changes made now are on this Mac only.")
        }
        // Never open a disk copy that is behind this Mac's copy.
        let localDate = (try? local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let remoteDate = (try? remote.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if localDate.timeIntervalSince(remoteDate) > 60, remoteDate < localDate {
            return (local, "This Mac's copy of the ledger has changes the disk copy does not, so Investigations Made Easy opened this Mac's copy. Copy the ledger to the disk again in Settings to bring it up to date.")
        }
        return (remote, nil)
    }

    // MARK: - Deep dive 2 (#6) — the other copy

    /// The other copy of the ledger at `ledgerURL`, when it is on this Mac's disks now: the disk copy while this Mac's copy
    /// is open, this Mac's copy while the disk copy is open. Erasure records (the register, the list of backups) are kept
    /// beside both. Empty in the test host (the defaults it shares hold the owner's relocation).
    static func otherCopies(of ledgerURL: URL) -> [URL] {
        guard !TestHost.isActive else { return [] }
        let folder = relocatedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return otherCopies(of: ledgerURL, local: DatabaseLocations.defaultDatabaseURL, relocatedFolder: folder)
    }

    nonisolated static func otherCopies(of ledgerURL: URL, local: URL, relocatedFolder: URL?) -> [URL] {
        guard let relocatedFolder else { return [] }
        let remote = relocatedFolder.appendingPathComponent(local.lastPathComponent)
        let here = ledgerURL.deletingLastPathComponent().standardizedFileURL.path
        let other: URL
        if here == local.deletingLastPathComponent().standardizedFileURL.path {
            other = remote
        } else if here == relocatedFolder.standardizedFileURL.path {
            other = local
        } else {
            return []
        }
        return FileManager.default.fileExists(atPath: other.path) ? [other] : []
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
