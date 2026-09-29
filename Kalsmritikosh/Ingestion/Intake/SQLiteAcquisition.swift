//
//  SQLiteAcquisition.swift
//  Kalsmritikosh
//
//  F03 — acquisition model for SQLite sources. There are two honest ways to preserve a database:
//
//    • EXACT BYTES — a database with no live WAL is one self-contained file; its bytes are captured
//      verbatim like any other source (forensic copy, hash = the file's hash).
//    • LOGICAL DERIVATIVE — a WAL-mode database keeps committed transactions in `-wal`, and copying
//      main + WAL one after the other is not a coherent state (a checkpoint between the copies mixes
//      two moments). Such a database is acquired through SQLite's online backup API inside ONE read
//      transaction, into a single self-contained file (journal_mode=DELETE). SQLite guarantees that
//      image is a committed point-in-time state even while another process writes. The derivative's
//      hash is the version identity; it identifies the derivative, not the original physical files,
//      and the record below says so (method, time, and each original member's role/length/digest).
//
//  Every downstream reader — loader, structural parser, vault, reopen, reprocessing — then consumes
//  the same single file, so no stage can silently fall back to main-file bytes.
//
//  Limitation: the derivative's bytes depend on the SQLite library that wrote it (header fields). An
//  unchanged WAL database re-acquired by a different SQLite version can therefore read as a NEW
//  version — the conservative direction; two different states are never merged.
//

import Foundation
import CryptoKit
import SQLite3

public nonisolated enum SQLiteAcquisition {

    /// One original physical member of the database at acquisition time.
    public nonisolated struct Member: Sendable, Hashable, Codable {
        public let role: String          // "main" | "wal"
        public let sizeBytes: Int64
        public let sha256: String
    }

    /// How a logical derivative was made. Stored with the intake receipt.
    public nonisolated struct Record: Sendable, Hashable, Codable {
        public let method: String        // "sqliteOnlineBackup"
        /// "live" = backed up from the original files in place; "stagedCopy" = the member files were
        /// copied under a checked acquisition boundary first (original could not be opened).
        public let source: String
        public let acquiredAt: Date
        public let members: [Member]
    }

    public enum AcquisitionError: Error, Sendable, Equatable {
        case backupFailed(String)
        case verifyFailed(String)
    }

    /// Whether `url` is a SQLite database in WAL mode (header bytes 18/19 = 2) or has a non-empty
    /// WAL beside it. Either needs a derivative: a WAL-mode main file copied alone cannot even be
    /// opened read-only (it needs a `-shm`), and its committed WAL frames would be lost. Whether the
    /// WAL happens to be empty at this instant must not decide it — a writer can append a moment later.
    public static func needsLogicalAcquisition(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 20), head.count == 20,
              head.prefix(16) == Data("SQLite format 3\u{0}".utf8) else { return false }
        let walMode = head[head.startIndex + 18] == 2 || head[head.startIndex + 19] == 2
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let walBytes = (try? wal.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return walMode || walBytes > 0
    }

    /// Acquire `url` (main file; its `-wal` beside it) into `destination` as one coherent file.
    /// Tries a live read-only backup of the original first; if the original cannot be opened, copies
    /// main + WAL into a staging directory under a checked boundary (retried when the pair changed)
    /// and backs up the staged pair. Throws `sourceChangedDuringCapture` rather than ever returning a
    /// derivative made from an incoherent pair.
    public static func acquire(_ url: URL, into destination: URL, now: Date = Date()) throws -> Record {
        let members = try physicalMembers(url)
        if (try? backup(from: url, readOnly: true, to: destination)) != nil {
            return Record(method: "sqliteOnlineBackup", source: "live", acquiredAt: now, members: members)
        }
        for _ in 0..<3 {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("sqlite-acq-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedMain = staging.appendingPathComponent(url.lastPathComponent)
            let before = try stat(url)
            try FileManager.default.copyItem(at: url, to: stagedMain)
            let wal = URL(fileURLWithPath: url.path + "-wal")
            if FileManager.default.fileExists(atPath: wal.path) {
                try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: stagedMain.path + "-wal"))
            }
            // The boundary: neither member may have changed across BOTH copies. A checkpoint rewrites
            // main; a commit appends to the WAL; either one makes this pair incoherent.
            guard try stat(url) == before else { continue }
            try backup(from: stagedMain, readOnly: false, to: destination)
            return Record(method: "sqliteOnlineBackup", source: "stagedCopy", acquiredAt: now, members: members)
        }
        throw SourceIntakeError.sourceChangedDuringCapture(url)
    }

    // MARK: - Internals

    private struct PairStat: Equatable {
        let mainSize: Int64, mainModified: Date?, walSize: Int64, walModified: Date?
    }

    private static func stat(_ url: URL) throws -> PairStat {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let m = try url.resourceValues(forKeys: keys)
        let w = try? URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: keys)
        return PairStat(mainSize: Int64(m.fileSize ?? 0), mainModified: m.contentModificationDate,
                        walSize: Int64(w?.fileSize ?? -1), walModified: w?.contentModificationDate)
    }

    /// Role, length and digest of each original member (metadata about the acquisition source).
    private static func physicalMembers(_ url: URL) throws -> [Member] {
        [("main", url), ("wal", URL(fileURLWithPath: url.path + "-wal"))].compactMap { role, u in
            guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
            defer { try? h.close() }
            var hasher = SHA256(); var size: Int64 = 0
            while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk); size += Int64(chunk.count)
            }
            return Member(role: role, sizeBytes: size,
                          sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    /// Online backup of `source` into a fresh single-file database at `destination`, verified.
    private static func backup(from source: URL, readOnly: Bool, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        var src: OpaquePointer?
        let flags = readOnly ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI) : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI)
        let uri = readOnly ? "file:\(source.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? source.path)?mode=ro"
                           : source.path
        guard sqlite3_open_v2(uri, &src, flags, nil) == SQLITE_OK, let srcDB = src else {
            let msg = src.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open source"
            sqlite3_close(src)
            throw AcquisitionError.backupFailed(msg)
        }
        defer { sqlite3_close(srcDB) }
        sqlite3_busy_timeout(srcDB, 2_000)
        var dest: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destDB = dest else {
            sqlite3_close(dest)
            throw AcquisitionError.backupFailed("cannot open destination")
        }
        var failure: String?
        if let b = sqlite3_backup_init(destDB, "main", srcDB, "main") {
            var rc: Int32
            repeat {
                // -1: every page in ONE step, i.e. under one read transaction on the source.
                rc = sqlite3_backup_step(b, -1)
                if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(25) }
            } while rc == SQLITE_BUSY || rc == SQLITE_LOCKED
            if rc != SQLITE_DONE { failure = String(cString: sqlite3_errmsg(destDB)) }
            sqlite3_backup_finish(b)
        } else {
            failure = String(cString: sqlite3_errmsg(destDB))
        }
        if failure == nil, sqlite3_exec(destDB, "PRAGMA journal_mode=DELETE;", nil, nil, nil) != SQLITE_OK {
            failure = String(cString: sqlite3_errmsg(destDB))
        }
        sqlite3_close(destDB)
        if let failure {
            try? FileManager.default.removeItem(at: destination)
            throw AcquisitionError.backupFailed(failure)
        }
        if let problem = Database.quickCheck(fileAt: destination) {
            try? FileManager.default.removeItem(at: destination)
            throw AcquisitionError.verifyFailed(problem)
        }
    }
}
