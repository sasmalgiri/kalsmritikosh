//
//  SystemArchiveReader.swift
//  Kalsmritikosh
//
//  Unified path IN-24 (owner 2026-11-22, round 2) — not tested yet.
//
//  Reads RAR (RAR4 and RAR5) and 7z archives through the libarchive that ships
//  with macOS (/usr/lib/libarchive.2.dylib, BSD licence). The library is loaded
//  at run time with dlopen/dlsym: the SDK carries libarchive.2.tbd but no
//  header, so the handful of C entry points used here are declared below as
//  @convention(c) function types. No project link change, no new package.
//
//  App Store note (owner was told, 2026-11-22): this uses Apple's own system BSD
//  library and libarchive's own clean-room RAR decoder; no proprietary unRAR
//  source is included, linked or reimplemented in the app.
//
//  The reader is sequential (libarchive streams members in archive order) and
//  synchronous; one instance must be used from one task only. Every member's
//  bytes are streamed to disk in bounded chunks with a hard byte cap, so the
//  container safety limits (per-member cap, ratio, budgets) stay with the caller.
//

import Foundation
import OSLog
import Darwin

/// The dlopen'd libarchive entry points. `nil` when the library or a required
/// symbol is missing (never expected on macOS 26, but handled as "unsupported").
nonisolated final class SystemArchiveLibrary: @unchecked Sendable {
    typealias NewFn = @convention(c) () -> OpaquePointer?
    typealias ArchiveIntFn = @convention(c) (OpaquePointer?) -> Int32
    typealias OpenFilenameFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    typealias NextHeaderFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias EntryStringFn = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias EntryInt64Fn = @convention(c) (OpaquePointer?) -> Int64
    typealias EntryModeFn = @convention(c) (OpaquePointer?) -> UInt16   // mode_t is 16-bit on Darwin
    typealias ReadDataFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    typealias FilterBytesFn = @convention(c) (OpaquePointer?, Int32) -> Int64

    let readNew: NewFn
    let supportRar: ArchiveIntFn
    let supportRar5: ArchiveIntFn
    let support7zip: ArchiveIntFn
    let openFilename: OpenFilenameFn
    let nextHeader: NextHeaderFn
    let entryPathnameUTF8: EntryStringFn?
    let entryPathname: EntryStringFn
    let entrySize: EntryInt64Fn
    let entrySizeIsSet: ArchiveIntFn?
    let entryFiletype: EntryModeFn?
    let entryIsEncrypted: ArchiveIntFn?
    let readData: ReadDataFn
    let readDataSkip: ArchiveIntFn
    let readFree: ArchiveIntFn
    let errorString: EntryStringFn
    let filterBytes: FilterBytesFn?

    /// Loaded once per process.
    static let shared: SystemArchiveLibrary? = SystemArchiveLibrary()

    private init?() {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else {
            KalsmritikoshLog.ingestion.error("SystemArchiveLibrary: libarchive could not be loaded")
            return nil
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let readNew = sym("archive_read_new", NewFn.self),
              let supportRar = sym("archive_read_support_format_rar", ArchiveIntFn.self),
              let supportRar5 = sym("archive_read_support_format_rar5", ArchiveIntFn.self),
              let support7zip = sym("archive_read_support_format_7zip", ArchiveIntFn.self),
              let openFilename = sym("archive_read_open_filename", OpenFilenameFn.self),
              let nextHeader = sym("archive_read_next_header", NextHeaderFn.self),
              let entryPathname = sym("archive_entry_pathname", EntryStringFn.self),
              let entrySize = sym("archive_entry_size", EntryInt64Fn.self),
              let readData = sym("archive_read_data", ReadDataFn.self),
              let readDataSkip = sym("archive_read_data_skip", ArchiveIntFn.self),
              let readFree = sym("archive_read_free", ArchiveIntFn.self),
              let errorString = sym("archive_error_string", EntryStringFn.self) else {
            KalsmritikoshLog.ingestion.error("SystemArchiveLibrary: a required libarchive symbol is missing")
            return nil
        }
        self.readNew = readNew; self.supportRar = supportRar; self.supportRar5 = supportRar5
        self.support7zip = support7zip; self.openFilename = openFilename; self.nextHeader = nextHeader
        self.entryPathname = entryPathname; self.entrySize = entrySize; self.readData = readData
        self.readDataSkip = readDataSkip; self.readFree = readFree; self.errorString = errorString
        self.entryPathnameUTF8 = sym("archive_entry_pathname_utf8", EntryStringFn.self)
        self.entrySizeIsSet = sym("archive_entry_size_is_set", ArchiveIntFn.self)
        self.entryFiletype = sym("archive_entry_filetype", EntryModeFn.self)
        self.entryIsEncrypted = sym("archive_entry_is_encrypted", ArchiveIntFn.self)
        self.filterBytes = sym("archive_filter_bytes", FilterBytesFn.self)
    }

    static var isAvailable: Bool { shared != nil }
}

nonisolated enum SystemArchiveError: Error, Sendable, Equatable {
    case libraryUnavailable
    case openFailed(String)
    case headerFailed(String)
    case readFailed(String)
    case encrypted(String)
    case exceededCap
    case unwritable
}

nonisolated struct SystemArchiveMember: Sendable {
    let ordinal: Int
    let path: String
    /// Declared uncompressed size; nil when the archive does not record one.
    let size: Int64?
    let isDirectory: Bool
    let isEncrypted: Bool
}

/// One sequential pass over a RAR/7z archive. Not Sendable: use it inside one synchronous scope.
nonisolated final class SystemArchiveReader {
    // libarchive status codes (archive.h).
    private static let ok: Int32 = 0, eof: Int32 = 1, warn: Int32 = -20, failed: Int32 = -25, fatal: Int32 = -30

    private let lib: SystemArchiveLibrary
    private var archive: OpaquePointer?
    private var ordinal = -1
    private var current: OpaquePointer?

    init(url: URL) throws {
        guard let lib = SystemArchiveLibrary.shared else { throw SystemArchiveError.libraryUnavailable }
        self.lib = lib
        guard let a = lib.readNew() else { throw SystemArchiveError.openFailed("archive_read_new returned nil") }
        archive = a
        _ = lib.supportRar(a); _ = lib.supportRar5(a); _ = lib.support7zip(a)
        let rc = url.path.withCString { lib.openFilename(a, $0, 64 * 1024) }
        if rc != Self.ok && rc != Self.warn {
            let message = lastError()
            _ = lib.readFree(a); archive = nil
            throw SystemArchiveError.openFailed(message)
        }
    }

    deinit {
        if let a = archive { _ = lib.readFree(a) }
    }

    private func lastError() -> String {
        guard let a = archive, let s = lib.errorString(a) else { return "unknown libarchive error" }
        return String(cString: s)
    }

    /// Compressed bytes consumed from the archive file so far (-1 = the raw file), when the library exposes it.
    var compressedBytesRead: Int64? {
        guard let a = archive, let f = lib.filterBytes else { return nil }
        return f(a, -1)
    }

    /// The next member header, or nil at the end of the archive. Unread member data is skipped automatically.
    func next() throws -> SystemArchiveMember? {
        guard let a = archive else { return nil }
        var entry: OpaquePointer?
        let rc = lib.nextHeader(a, &entry)
        if rc == Self.eof { current = nil; return nil }
        if rc != Self.ok && rc != Self.warn { throw SystemArchiveError.headerFailed(lastError()) }
        guard let e = entry else { return nil }
        current = e
        ordinal += 1
        let raw = (lib.entryPathnameUTF8?(e)).flatMap { String(validatingCString: $0) }
            ?? lib.entryPathname(e).map { String(cString: $0) } ?? "member-\(ordinal)"
        let sizeSet = lib.entrySizeIsSet.map { $0(e) != 0 } ?? true
        let mode = lib.entryFiletype?(e) ?? 0
        let isDir = (mode & 0o170000) == 0o040000 || raw.hasSuffix("/")
        let encrypted = (lib.entryIsEncrypted?(e) ?? 0) != 0
        return SystemArchiveMember(ordinal: ordinal, path: raw, size: sizeSet ? lib.entrySize(e) : nil,
                                   isDirectory: isDir, isEncrypted: encrypted)
    }

    /// Stream the current member's bytes to `destination`, never writing more than `maxBytes`.
    /// Returns the byte count. Throws `.exceededCap` (the partial file is removed) or a read error.
    func extractCurrent(to destination: URL, maxBytes: Int64) throws -> Int64 {
        guard let a = archive, current != nil else { throw SystemArchiveError.readFailed("no current member") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else { throw SystemArchiveError.unwritable }
        var written: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var failure: SystemArchiveError?
        while true {
            let n = buffer.withUnsafeMutableBytes { lib.readData(a, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                let message = lastError()
                let lower = message.lowercased()
                failure = (lower.contains("encrypt") || lower.contains("passphrase") || lower.contains("password"))
                    ? .encrypted(message) : .readFailed(message)
                break
            }
            written += Int64(n)
            if written > maxBytes { failure = .exceededCap; break }
            do { try handle.write(contentsOf: buffer[0..<n]) }
            catch {
                KalsmritikoshLog.ingestion.error("SystemArchiveReader: write failed — \(error.localizedDescription, privacy: .public)")
                failure = .unwritable; break
            }
        }
        do { try handle.close() } catch {
            KalsmritikoshLog.ingestion.error("SystemArchiveReader: close failed — \(error.localizedDescription, privacy: .public)")
        }
        if let failure {
            do { try FileManager.default.removeItem(at: destination) } catch {
                KalsmritikoshLog.ingestion.error("SystemArchiveReader: partial member not removed — \(error.localizedDescription, privacy: .public)")
            }
            throw failure
        }
        return written
    }

    /// Every member header (data skipped) — the manifest for the archive loader.
    static func listMembers(url: URL, limit: Int) throws -> [SystemArchiveMember] {
        let reader = try SystemArchiveReader(url: url)
        var out: [SystemArchiveMember] = []
        while out.count < limit, let m = try reader.next() { out.append(m) }
        return out
    }
}
