//
//  FileDigestCache.swift
//  Kalsmritikosh
//
//  Speed PERF-24 (owner 2026-11-23) — not tested yet. A file's SHA-256 is reused while its identity on disk is
//  unchanged: same standardized path, inode, size and modification time to the nanosecond. Any change re-reads
//  the bytes, and a digest is remembered only when the file did not change while it was read. Bounded; cleared
//  when full. Used where the same on-disk file is re-hashed on each look (cited-source check, authenticity).
//

import Foundation
import os

public nonisolated enum FileDigestCache {
    private struct FileStamp: Hashable, Sendable {
        let path: String
        let inode: UInt64
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanos: Int
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [FileStamp: String]())
    private static let capacity = 1_024

    private static func stamp(of url: URL) -> FileStamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return FileStamp(path: url.standardizedFileURL.path, inode: UInt64(st.st_ino), size: Int64(st.st_size),
                         mtimeSeconds: Int(st.st_mtimespec.tv_sec), mtimeNanos: Int(st.st_mtimespec.tv_nsec))
    }

    /// The digest `compute(url)` would return, reused while the file is unchanged.
    public static func sha256(of url: URL, compute: (URL) throws -> String) throws -> String {
        guard let before = stamp(of: url) else { return try compute(url) }
        if let hit = cache.withLock({ $0[before] }) { return hit }
        let digest = try compute(url)
        if stamp(of: url) == before {
            cache.withLock { c in
                if c.count >= capacity { c.removeAll(keepingCapacity: true) }
                c[before] = digest
            }
        }
        return digest
    }
}
