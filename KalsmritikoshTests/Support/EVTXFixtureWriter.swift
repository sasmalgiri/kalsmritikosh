//
//  EVTXFixtureWriter.swift
//  KalsmritikoshTests
//
//  HOST-3 test support — writes a structurally valid Windows event log (EVTX).
//
//  Built strictly from the published fixed-offset layout, and only the CONTAINER:
//  file header, 64 KB chunks, record framing with id + FILETIME + size trailer,
//  and UTF-16 strings in the payload where BinXML would put them. It deliberately
//  does NOT synthesize BinXML templates, because the parser does not resolve them
//  — a fixture that faked a template would be testing an understanding neither
//  side has, which is exactly how a fixture writer and a parser end up wrong in
//  the same way and pass.
//

import Foundation
@testable import Kalsmritikosh

struct EVTXFixtureWriter {

    struct Record {
        let id: UInt64
        let written: Date?
        /// Strings placed in the payload where BinXML would carry them.
        let strings: [String]
    }

    /// Set to leave the header's dirty flag on — a log copied while in use.
    var dirty = false
    /// Declare more chunks than are written, which is what a truncated copy looks
    /// like on disk.
    var overDeclareChunks = 0

    func build(records: [Record], recordsPerChunk: Int = 64) -> Data {
        // Split records across chunks the way Windows does.
        var chunks: [Data] = []
        var index = 0
        while index < records.count || chunks.isEmpty {
            let slice = Array(records[index..<min(index + recordsPerChunk, records.count)])
            chunks.append(Self.chunk(records: slice))
            index += recordsPerChunk
            if index >= records.count { break }
        }

        var header = Data("ElfFile\0".utf8)
        header += Self.u64(0)                                   // 0x08 first chunk number
        header += Self.u64(UInt64(max(0, chunks.count - 1)))    // 0x10 last chunk number
        header += Self.u64(UInt64((records.map(\.id).max() ?? 0) + 1))  // 0x18 next record id
        header += Self.u32(128)                                 // 0x20 header size
        header += Self.u16(1)                                    // 0x24 minor version
        header += Self.u16(3)                                    // 0x26 major version
        header += Self.u16(4096)                                 // 0x28 header block size
        header += Self.u16(UInt16(chunks.count + overDeclareChunks))   // 0x2A chunk count
        header += Data(repeating: 0, count: 0x78 - header.count)
        header += Self.u32(dirty ? 0x0001 : 0x0000)              // 0x78 flags
        header += Self.u32(0)                                    // 0x7C checksum (unverified)
        header += Data(repeating: 0, count: EVTXReader.headerSize - header.count)

        return chunks.reduce(into: header) { $0 += $1 }
    }

    /// A file with a valid signature but nothing after the header.
    func buildHeaderOnly() -> Data { build(records: []) }

    // MARK: - Chunk

    private static func chunk(records: [Record]) -> Data {
        var body = Data()
        for record in records {
            var payload = Data()
            for string in record.strings {
                // UTF-16LE, NUL-separated — the encoding BinXML uses for names and
                // string values, which is what the reader harvests.
                for unit in Array(string.utf16) {
                    payload.append(UInt8(unit & 0xFF)); payload.append(UInt8(unit >> 8))
                }
                payload += Data([0x00, 0x00])
            }
            // 24-byte record header + payload + 4-byte size trailer.
            let size = UInt32(24 + payload.count + 4)
            var record$ = Data([0x2A, 0x2A, 0x00, 0x00])
            record$ += u32(size)
            record$ += u64(record.id)
            record$ += filetime(record.written)
            record$ += payload
            record$ += u32(size)
            body += record$
        }

        var chunk = Data("ElfChnk\0".utf8)
        chunk += u64(UInt64(records.first?.id ?? 0))    // 0x08 first record number
        chunk += u64(UInt64(records.last?.id ?? 0))     // 0x10 last record number
        chunk += u64(UInt64(records.first?.id ?? 0))    // 0x18 first record id
        chunk += u64(UInt64(records.last?.id ?? 0))     // 0x20 last record id
        chunk += u32(128)                                // 0x28 header size
        chunk += u32(0)                                  // 0x2C last record data offset
        // 0x30 free-space offset: where records END. The reader stops here, so
        // stale bytes beyond it are never read as records.
        chunk += u32(UInt32(EVTXReader.recordsOffsetInChunk + body.count))
        chunk += u32(0)                                  // 0x34 records checksum (unverified)
        chunk += Data(repeating: 0, count: EVTXReader.recordsOffsetInChunk - chunk.count)
        chunk += body
        chunk += Data(repeating: 0, count: EVTXReader.chunkSize - chunk.count)
        return chunk
    }

    // MARK: - Primitives

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u64(_ v: UInt64) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func filetime(_ date: Date?) -> Data {
        guard let date else { return Data(repeating: 0, count: 8) }
        let ticks = UInt64((date.timeIntervalSince1970 + 11_644_473_600.0) * 10_000_000.0)
        return u64(ticks)
    }
}
