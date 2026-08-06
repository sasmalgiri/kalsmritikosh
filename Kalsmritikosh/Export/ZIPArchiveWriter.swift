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
        var local = Data()
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

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
