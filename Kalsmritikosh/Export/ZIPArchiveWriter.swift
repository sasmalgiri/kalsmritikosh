//
//  ZIPArchiveWriter.swift
//  Kalsmritikosh
//
//  A tiny, dependency-free ZIP container writer used to assemble OOXML packages (DOCX / XLSX are ZIP archives
//  of XML parts). Pure value-in / Data-out, fully offline, no third-party library. It writes STORE entries
//  (no compression) with a correct CRC-32 per entry, a central directory, and an end-of-central-directory
//  record — the minimum a conformant ZIP/OOXML reader requires.
//
//  Determinism: entries are emitted in the exact order added, with a FIXED DOS timestamp (1980-01-01 00:00),
//  so the same inputs always produce byte-identical output — a property the export tests rely on. There is no
//  Date.now() call anywhere here.
//

import Foundation
import zlib
import os

/// Assembles a ZIP archive from named byte parts, STORE method, deterministic bytes.
public struct ZIPArchiveWriter {
    /// One archive member: an archive-relative path (forward slashes) and its raw bytes.
    public struct Entry: Sendable {
        public let path: String
        public let data: Data
        public nonisolated init(path: String, data: Data) { self.path = path; self.data = data }
    }

    private var entries: [Entry] = []
    public nonisolated init() {}

    public mutating func addFile(path: String, data: Data) { entries.append(Entry(path: path, data: data)) }
    public mutating func addFile(path: String, text: String) { addFile(path: path, data: Data(text.utf8)) }

    /// Serialize all added entries into a complete ZIP archive.
    public func build() -> Data {
        // Speed PERF-30 (owner 2026-11-23) — not tested yet. One allocation for the whole archive.
        var local = Data()
        local.reserveCapacity(entries.reduce(0) { $0 + 30 + $1.path.utf8.count + $1.data.count })
        var central = Data()
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = 0x0021   // 1980-01-01 (day 1, month 1, year 0 since 1980)

        for entry in entries {
            let nameBytes = Data(entry.path.utf8)
            let crc = Self.crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(local.count)

            // Local file header.
            local.appendLE(UInt32(0x0403_4b50))   // signature
            local.appendLE(UInt16(20))             // version needed
            local.appendLE(UInt16(0))              // general purpose flag
            local.appendLE(UInt16(0))              // compression method: store
            local.appendLE(dosTime)
            local.appendLE(dosDate)
            local.appendLE(crc)
            local.appendLE(size)                   // compressed size == uncompressed (store)
            local.appendLE(size)
            local.appendLE(UInt16(nameBytes.count))
            local.appendLE(UInt16(0))              // extra field length
            local.append(nameBytes)
            local.append(entry.data)

            // Central directory header.
            central.appendLE(UInt32(0x0201_4b50))  // signature
            central.appendLE(UInt16(20))           // version made by
            central.appendLE(UInt16(20))           // version needed
            central.appendLE(UInt16(0))            // flag
            central.appendLE(UInt16(0))            // compression: store
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))            // extra length
            central.appendLE(UInt16(0))            // comment length
            central.appendLE(UInt16(0))            // disk number start
            central.appendLE(UInt16(0))            // internal attributes
            central.appendLE(UInt32(0))            // external attributes
            central.appendLE(offset)               // local header offset
            central.append(nameBytes)
        }

        var out = local
        let centralOffset = UInt32(out.count)
        out.append(central)

        // End of central directory record.
        out.appendLE(UInt32(0x0605_4b50))          // signature
        out.appendLE(UInt16(0))                    // disk number
        out.appendLE(UInt16(0))                    // central dir start disk
        out.appendLE(UInt16(entries.count))        // entries on this disk
        out.appendLE(UInt16(entries.count))        // total entries
        out.appendLE(UInt32(central.count))        // central dir size
        out.appendLE(centralOffset)                // central dir offset
        out.appendLE(UInt16(0))                    // comment length
        return out
    }

    // MARK: - CRC-32 (IEEE 802.3, the ZIP standard)

    /// Speed PERF-30 (owner 2026-11-23) — not tested yet. zlib's crc32 (the system library, word-at-a-time) over the
    /// bytes in place, in pieces of at most 1 GiB (its length is a 32-bit uInt); same values as the table-driven loop.
    nonisolated static func crc32(_ data: Data) -> UInt32 {
        var crc: uLong = zlib.crc32(0, nil, 0)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = min(raw.count - offset, 1 << 30)
                crc = zlib.crc32(crc, base + offset, uInt(n))
                offset += n
            }
        }
        return UInt32(truncatingIfNeeded: crc)
    }
}

/// Speed PERF-30 (owner 2026-11-23) — not tested yet. The same STORE archive as `ZIPArchiveWriter.build()` (same bytes,
/// same fixed timestamp), written member by member straight to a file: only one member's bytes and the small central
/// directory are held in memory. Written beside the destination and moved into place when finished.
public nonisolated final class ZIPFileStreamer {
    private let handle: FileHandle
    private let temp: URL
    private let destination: URL
    private var central = Data()
    private var count = 0
    private var offset: UInt64 = 0
    private var finished = false

    public init(writingTo url: URL) throws {
        destination = url
        temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: temp)
    }

    deinit {
        if !finished {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
        }
    }

    public func add(path: String, data: Data) throws {
        let name = Data(path.utf8)
        let crc = ZIPArchiveWriter.crc32(data)
        let size = UInt32(truncatingIfNeeded: data.count)
        var header = Data()
        header.reserveCapacity(30 + name.count)
        header.zipLE32(0x0403_4b50)
        header.zipLE16(20); header.zipLE16(0); header.zipLE16(0); header.zipLE16(0); header.zipLE16(0x0021)
        header.zipLE32(crc); header.zipLE32(size); header.zipLE32(size)
        header.zipLE16(UInt16(name.count)); header.zipLE16(0)
        header.append(name)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        central.zipLE32(0x0201_4b50); central.zipLE16(20); central.zipLE16(20); central.zipLE16(0); central.zipLE16(0)
        central.zipLE16(0); central.zipLE16(0x0021); central.zipLE32(crc); central.zipLE32(size); central.zipLE32(size)
        central.zipLE16(UInt16(name.count)); central.zipLE16(0); central.zipLE16(0); central.zipLE16(0); central.zipLE16(0)
        central.zipLE32(0); central.zipLE32(UInt32(truncatingIfNeeded: offset))
        central.append(name)
        offset += UInt64(header.count + data.count)
        count += 1
    }

    /// Writes the central directory and moves the archive into place.
    public func finish() throws {
        var tail = central
        tail.zipLE32(0x0605_4b50); tail.zipLE16(0); tail.zipLE16(0)
        tail.zipLE16(UInt16(truncatingIfNeeded: count)); tail.zipLE16(UInt16(truncatingIfNeeded: count))
        tail.zipLE32(UInt32(truncatingIfNeeded: central.count)); tail.zipLE32(UInt32(truncatingIfNeeded: offset)); tail.zipLE16(0)
        try handle.write(contentsOf: tail)
        try handle.close()
        finished = true
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }
}

fileprivate nonisolated extension Data {
    mutating func zipLE16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func zipLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
