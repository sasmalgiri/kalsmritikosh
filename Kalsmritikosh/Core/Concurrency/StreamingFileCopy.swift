//
//  StreamingFileCopy.swift
//  Kalsmritikosh
//
//  Speed PERF-25 (owner 2026-11-23) — not tested yet. The download manager's copy: every byte is read ONCE and both
//  written and hashed from the same 8 MB buffer (the old path copied, then re-read the copy to hash it). On the same
//  APFS volume the copy is a clone (no bytes move) and the digest is taken over the clone — the exact stored bytes.
//  `CopyResumeLog` records each finished file (its digest, size and modification stamps) so an interrupted copy of many
//  files resumes: a file is skipped only while its source AND its copy are unchanged since they were logged.
//

import Foundation
import CryptoKit
import Darwin
import os

public nonisolated enum StreamingFileCopy {
    /// 8 MB: large enough that a disk streams, small enough for several copies at once.
    public static let bufferBytes = 8 * 1_048_576

    public struct Measured: Sendable, Equatable {
        public let byteSize: Int64
        public let sha256: String
    }

    public enum CopyError: Error, LocalizedError {
        case open(String, Int32), read(Int32), write(Int32)
        public var errorDescription: String? {
            switch self {
            case .open(let p, let e): return "could not open \((p as NSString).lastPathComponent): \(String(cString: strerror(e)))"
            case .read(let e): return "read failed: \(String(cString: strerror(e)))"
            case .write(let e): return "write failed: \(String(cString: strerror(e)))"
            }
        }
    }

    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Copy `source` to `destination` (replaced if present) and return the size + SHA-256 of what was written, reading
    /// each byte once. A same-volume copy is cloned first and then hashed (one read). `progress` gets bytes done so far.
    public static func copyAndHash(from source: URL, to destination: URL, bufferBytes: Int = bufferBytes,
                                   progress: ((Int64) -> Void)? = nil) throws -> Measured {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if clonefile(source.path, destination.path, 0) == 0 {
            return try hash(destination, bufferBytes: bufferBytes, progress: progress)
        }
        let inFD = open(source.path, O_RDONLY)
        guard inFD >= 0 else { throw CopyError.open(source.path, errno) }
        defer { close(inFD) }
        var st = stat()
        let mode: mode_t = fstat(inFD, &st) == 0 ? (st.st_mode & 0o777) : 0o644
        let outFD = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, mode)
        guard outFD >= 0 else { throw CopyError.open(destination.path, errno) }
        var outClosed = false
        defer { if !outClosed { close(outFD) } }
        _ = fcntl(inFD, F_RDAHEAD, 1)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(65_536, bufferBytes), alignment: 16_384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let n = read(inFD, buffer, max(65_536, bufferBytes))
            if n < 0 { if errno == EINTR { continue }; throw CopyError.read(errno) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            var written = 0
            while written < n {
                let w = write(outFD, buffer + written, n - written)
                if w < 0 { if errno == EINTR { continue }; throw CopyError.write(errno) }
                written += w
            }
            total += Int64(n)
            progress?(total)
        }
        // Keep the source's modification time, as FileManager's copy did.
        var times = [timespec](repeating: timespec(), count: 2)
        times[0] = st.st_atimespec; times[1] = st.st_mtimespec
        _ = futimens(outFD, &times)
        outClosed = true
        if close(outFD) != 0 { throw CopyError.write(errno) }
        return Measured(byteSize: total, sha256: hex(hasher.finalize()))
    }

    /// Size + SHA-256 of a file, streamed in `bufferBytes` reads (never the whole file in memory).
    public static func hash(_ url: URL, bufferBytes: Int = bufferBytes, progress: ((Int64) -> Void)? = nil) throws -> Measured {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CopyError.open(url.path, errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_RDAHEAD, 1)
        let size = max(65_536, bufferBytes)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let n = read(fd, buffer, size)
            if n < 0 { if errno == EINTR { continue }; throw CopyError.read(errno) }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            total += Int64(n)
            progress?(total)
        }
        return Measured(byteSize: total, sha256: hex(hasher.finalize()))
    }

    /// Size and modification time (ns) of a file, or nil.
    public static func stamp(_ url: URL) -> (size: Int64, mtimeNs: Int64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (Int64(st.st_size), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }
}

/// Speed PERF-25 (owner 2026-11-23) — not tested yet. A per-copy log of finished files (JSON lines, appended as each file
/// is done) kept in the staging folder, so an interrupted multi-file copy resumes where it stopped.
public nonisolated final class CopyResumeLog: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public let relativePath: String
        public let sourcePath: String
        public let sourceSize: Int64
        public let sourceMtimeNs: Int64
        public let byteSize: Int64
        public let sha256: String
        public let copyMtimeNs: Int64
    }

    public static let fileName = ".copy-resume.jsonl"
    private let url: URL
    private let state: OSAllocatedUnfairLock<[String: Entry]>

    /// The log in `folder` (read when it exists; a damaged line is ignored and that file is copied again).
    public init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName)
        var loaded: [String: Entry] = [:]
        if let data = FileManager.default.contents(atPath: url.path) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                do {
                    let e = try JSONDecoder().decode(Entry.self, from: Data(line))
                    loaded[e.relativePath] = e
                } catch {
                    KalsmritikoshLog.storage.debug("CopyResumeLog: a damaged line is ignored (that file is copied again)")
                }
            }
        }
        state = OSAllocatedUnfairLock(initialState: loaded)
    }

    /// The logged result for `relativePath` when the source and the copy in `folder` are both unchanged since then.
    public func reusable(relativePath: String, source: URL, copy: URL) -> StreamingFileCopy.Measured? {
        guard let e = state.withLock({ $0[relativePath] }), e.sourcePath == source.standardizedFileURL.path,
              let s = StreamingFileCopy.stamp(source), s.size == e.sourceSize, s.mtimeNs == e.sourceMtimeNs,
              let c = StreamingFileCopy.stamp(copy), c.size == e.byteSize, c.mtimeNs == e.copyMtimeNs
        else { return nil }
        return StreamingFileCopy.Measured(byteSize: e.byteSize, sha256: e.sha256)
    }

    /// Record a finished file (best effort: a log that cannot be written only means that file is copied again).
    public func record(relativePath: String, source: URL, copy: URL, measured: StreamingFileCopy.Measured) {
        guard let s = StreamingFileCopy.stamp(source), let c = StreamingFileCopy.stamp(copy) else { return }
        let e = Entry(relativePath: relativePath, sourcePath: source.standardizedFileURL.path, sourceSize: s.size,
                      sourceMtimeNs: s.mtimeNs, byteSize: measured.byteSize, sha256: measured.sha256, copyMtimeNs: c.mtimeNs)
        state.withLock { st in
            st[relativePath] = e
            do {
                var line = try JSONEncoder().encode(e)
                line.append(UInt8(ascii: "\n"))
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: line)
            } catch {
                KalsmritikoshLog.storage.error("CopyResumeLog: not written (the file is copied again on a resume): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Remove the log (when the copy is complete).
    public func remove() {
        do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } } catch {
            KalsmritikoshLog.storage.error("CopyResumeLog: not removed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Copy (or reuse a logged copy of) `source` to `folder/relativePath`, hashing in the same pass.
    public func copy(_ source: URL, to folder: URL, relativePath: String) throws -> StreamingFileCopy.Measured {
        let dst = folder.appendingPathComponent(relativePath)
        if let done = reusable(relativePath: relativePath, source: source, copy: dst) { return done }
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Speed PERF-38 torrent (owner 2026-11-23) — not tested yet: the read is paced by the source disk's lane.
        let m = try VolumeReadLanes.withReadBlocking(source) { try StreamingFileCopy.copyAndHash(from: source, to: dst) }
        record(relativePath: relativePath, source: source, copy: dst, measured: m)
        return m
    }
}
