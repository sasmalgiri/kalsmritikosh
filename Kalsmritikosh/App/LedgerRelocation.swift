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

    public static func copy(database: Database, sourceDatabaseURL: URL, toParent parent: URL) async throws -> LedgerRelocationReport {
        let fm = FileManager.default
        let scoped = parent.startAccessingSecurityScopedResource()
        defer { if scoped { parent.stopAccessingSecurityScopedResource() } }

        let destDir = parent.appendingPathComponent(folderName, isDirectory: true)
        let destDB = destDir.appendingPathComponent("knowledge.sqlite")
        if fm.fileExists(atPath: destDB.path) { throw LedgerRelocationError.destinationHasLedger(destDir) }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // 1. Consistent database snapshot — after every open studio's pending writes landed (review R5).
        try await StudioStorage.requireAllSaved()
        try await database.backupSnapshot(to: destDB)
        let copy = try Database(url: destDB, key: database.key)
        let check = try await copy.query("PRAGMA quick_check;", []).first?.string(0) ?? "no result"
        guard check == "ok" else { throw LedgerRelocationError.integrityFailed(check) }

        // 2. Everything else beside the database, hash-verified.
        let srcDir = sourceDatabaseURL.deletingLastPathComponent()
        var files = 0
        var bytes: Int64 = 0
        let skip: Set<String> = ["knowledge.sqlite", "knowledge.sqlite-wal", "knowledge.sqlite-shm"]
        if let walker = fm.enumerator(at: srcDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            while let item = walker.nextObject() as? URL {
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else { continue }
                let rel = item.path.replacingOccurrences(of: srcDir.path + "/", with: "")
                if skip.contains(rel) { continue }
                let target = destDir.appendingPathComponent(rel)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { continue }
                try fm.copyItem(at: item, to: target)
                guard try sha256(item) == sha256(target) else { throw LedgerRelocationError.hashMismatch(rel) }
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }

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

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
