//
//  ZipWriter.swift
//  Kalsmritikosh
//
//  Minimal, dependency-free PKZIP writer used to assemble real .docx and
//  .xlsx files (both are ZIP containers of XML). Uses the STORE method
//  (no compression) — valid per the ZIP spec and immune to the subtle
//  bugs a hand-rolled DEFLATE encoder would risk, at the cost of larger
//  files. Office opens STORE-method OOXML without complaint.
//
//  Writes: local file headers + file data + central directory + end-of-
//  central-directory record, with correct CRC-32 and offsets.
//

import Foundation

public struct ZipWriter {

    public struct Entry: Sendable {
        public let path: String   // e.g. "word/document.xml"
        public let data: Data
        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public init() {}

    /// Build a ZIP archive (STORE method) from the given entries.
    public func archive(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        var offsets: [Int] = []

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = Self.crc32(entry.data)
            let size = UInt32(entry.data.count)
            offsets.append(out.count)

            // ── Local file header ──
            out.appendLE(UInt32(0x04034b50))   // signature
            out.appendLE(UInt16(20))           // version needed
            out.appendLE(UInt16(0))            // flags
            out.appendLE(UInt16(0))            // method: 0 = store
            out.appendLE(UInt16(0))            // mod time
            out.appendLE(UInt16(0x21))         // mod date (1980-01-01)
            out.appendLE(crc)                  // CRC-32
            out.appendLE(size)                 // compressed size
            out.appendLE(size)                 // uncompressed size
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))            // extra len
            out.append(contentsOf: nameBytes)
            out.append(entry.data)

            // ── Central directory record ──
            central.appendLE(UInt32(0x02014b50))  // signature
            central.appendLE(UInt16(20))          // version made by
            central.appendLE(UInt16(20))          // version needed
            central.appendLE(UInt16(0))           // flags
            central.appendLE(UInt16(0))           // method
            central.appendLE(UInt16(0))           // mod time
            central.appendLE(UInt16(0x21))        // mod date
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))           // extra len
            central.appendLE(UInt16(0))           // comment len
            central.appendLE(UInt16(0))           // disk number start
            central.appendLE(UInt16(0))           // internal attrs
            central.appendLE(UInt32(0))           // external attrs
            central.appendLE(UInt32(offsets[offsets.count - 1]))  // local header offset
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = out.count
        out.append(central)

        // ── End of central directory ──
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))                        // disk number
        out.appendLE(UInt16(0))                        // disk with central dir
        out.appendLE(UInt16(entries.count))            // entries on this disk
        out.appendLE(UInt16(entries.count))            // total entries
        out.appendLE(UInt32(central.count))            // central dir size
        out.appendLE(UInt32(centralOffset))            // central dir offset
        out.appendLE(UInt16(0))                        // comment len
        return out
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
