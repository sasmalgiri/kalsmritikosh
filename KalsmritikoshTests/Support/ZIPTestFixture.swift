//
//  ZIPTestFixture.swift
//  KalsmritikoshTests
//
//  USF-M2 test support — builds synthetic ZIP bytes (STORED / DEFLATE / encrypted-flag / corrupt)
//  so container safety + ingestion can be exercised without shipping binary fixtures. CRC is left 0
//  (ZIPReader does not verify it). Synthetic data only.
//

import Foundation
import Compression

enum ZIPTestFixture {

    struct Entry {
        let name: String
        let data: Data
        let method: UInt16       // 0 = STORED, 8 = DEFLATE
        let encrypted: Bool
        let corrupt: Bool        // method 8 with junk payload → inflate fails
        let declaredUncompressed: Int?   // override the recorded uncompressed size (for size/ratio tests)

        init(name: String, data: Data, method: UInt16 = 0, encrypted: Bool = false,
             corrupt: Bool = false, declaredUncompressed: Int? = nil) {
            self.name = name; self.data = data; self.method = method; self.encrypted = encrypted
            self.corrupt = corrupt; self.declaredUncompressed = declaredUncompressed
        }
    }

    static func stored(_ name: String, _ text: String) -> Entry { Entry(name: name, data: Data(text.utf8), method: 0) }
    static func deflated(_ name: String, _ text: String) -> Entry { Entry(name: name, data: Data(text.utf8), method: 8) }
    static func directory(_ name: String) -> Entry { Entry(name: name.hasSuffix("/") ? name : name + "/", data: Data(), method: 0) }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    private static func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private static func rawDeflate(_ input: Data) -> Data {
        let dstCap = max(64, input.count + 64)
        var dst = Data(count: dstCap)
        let n = dst.withUnsafeMutableBytes { d -> Int in
            input.withUnsafeBytes { s -> Int in
                guard let db = d.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                let sb = s.bindMemory(to: UInt8.self).baseAddress
                return compression_encode_buffer(db, dstCap, sb ?? UnsafePointer(db), input.count, nil, COMPRESSION_ZLIB)
            }
        }
        dst.count = n
        return dst
    }

    /// Build a ZIP from the given entries.
    static func build(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let payload: Data
            let method = e.method
            if e.method == 8 {
                payload = e.corrupt ? Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55]) : rawDeflate(e.data)
            } else {
                payload = e.data
            }
            let localOffset = out.count
            let nameBytes = Array(e.name.utf8)
            let flags = e.encrypted ? 0x0001 : 0x0000
            let uncompressed = e.declaredUncompressed ?? e.data.count

            // Local file header.
            out.append(contentsOf: le32(0x04034b50))
            out.append(contentsOf: le16(20))              // version needed
            out.append(contentsOf: le16(flags))
            out.append(contentsOf: le16(Int(method)))
            out.append(contentsOf: le16(0))               // mod time
            out.append(contentsOf: le16(0))               // mod date
            out.append(contentsOf: le32(0))               // crc32 (not verified)
            out.append(contentsOf: le32(payload.count))   // compressed size
            out.append(contentsOf: le32(uncompressed))    // uncompressed size
            out.append(contentsOf: le16(nameBytes.count))
            out.append(contentsOf: le16(0))               // extra len
            out.append(contentsOf: nameBytes)
            out.append(payload)

            // Central directory header.
            central.append(contentsOf: le32(0x02014b50))
            central.append(contentsOf: le16(20))          // version made by
            central.append(contentsOf: le16(20))          // version needed
            central.append(contentsOf: le16(flags))       // +8
            central.append(contentsOf: le16(Int(method))) // +10
            central.append(contentsOf: le16(0))           // mod time
            central.append(contentsOf: le16(0))           // mod date
            central.append(contentsOf: le32(0))           // crc32
            central.append(contentsOf: le32(payload.count))   // +20 compressed
            central.append(contentsOf: le32(uncompressed))    // +24 uncompressed
            central.append(contentsOf: le16(nameBytes.count)) // +28
            central.append(contentsOf: le16(0))           // +30 extra
            central.append(contentsOf: le16(0))           // +32 comment
            central.append(contentsOf: le16(0))           // disk number
            central.append(contentsOf: le16(0))           // internal attrs
            central.append(contentsOf: le32(0))           // external attrs
            central.append(contentsOf: le32(localOffset)) // +42 local header offset
            central.append(contentsOf: nameBytes)
        }
        let cdOffset = out.count
        let cdSize = central.count
        out.append(central)
        // EOCD.
        out.append(contentsOf: le32(0x06054b50))
        out.append(contentsOf: le16(0))                   // disk num
        out.append(contentsOf: le16(0))                   // cd start disk
        out.append(contentsOf: le16(entries.count))       // entries this disk
        out.append(contentsOf: le16(entries.count))       // total entries
        out.append(contentsOf: le32(cdSize))
        out.append(contentsOf: le32(cdOffset))
        out.append(contentsOf: le16(0))                   // comment len
        return out
    }

    /// Write a ZIP built from entries to a temp file and return its URL.
    static func writeZIP(_ entries: [Entry], named name: String = "archive.zip") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usfm2-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try build(entries).write(to: url)
        return url
    }
}
