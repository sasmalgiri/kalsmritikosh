//
//  CFBFixtureWriter.swift
//  KalsmritikoshTests
//
//  Minimal Microsoft Compound File Binary ([MS-CFB]) WRITER — test-only. It
//  exists so .msg parser probes can synthesize a REAL OLE2 container in-test
//  instead of committing an opaque binary blob: the fixture is readable,
//  deterministic, and documents the format it exercises.
//
//  Scope is exactly what the MSG probes need: 512-byte sectors, one FAT, a
//  directory chain, and the 64-byte MINI stream (every fixture stream is well
//  under the 4096-byte cutoff, which is where [MS-CFB] §2.4 requires small
//  streams to live — the same branch OLE2Reader.readEntryData takes). Storages
//  (for attachments) nest via an explicit child pointer.
//

import Foundation
@testable import Kalsmritikosh

struct CFBFixtureWriter {

    /// A stream, or a storage that owns nested streams (MSG attachments).
    struct Node {
        let name: String
        let data: Data?          // nil = storage
        var children: [Node] = []

        static func stream(_ name: String, _ data: Data) -> Node {
            Node(name: name, data: data)
        }
        static func storage(_ name: String, _ children: [Node]) -> Node {
            Node(name: name, data: nil, children: children)
        }
    }

    private let sectorSize = 512
    private let miniSectorSize = 64
    private let miniStreamCutoff = 4096

    private static let fatSect: UInt32   = 0xFFFF_FFFD
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSect: UInt32  = 0xFFFF_FFFF

    /// Flattened directory entry being assembled.
    private struct Entry {
        var name: String
        var type: UInt8            // 1 = storage, 2 = stream, 5 = root
        var child: Int32 = -1
        var right: Int32 = -1
        var startSector: UInt32 = 0
        var size: UInt64 = 0
    }

    /// Build a valid CFB file whose root directory holds `nodes`.
    func build(_ nodes: [Node]) -> Data {
        // 1 — Flatten the tree into directory entries (root at index 0),
        //     laying every stream's bytes into the mini stream.
        var entries: [Entry] = [Entry(name: "Root Entry", type: 5)]
        var miniStream = Data()

        /// Append `nodes` as siblings; returns the index of the first one.
        func appendSiblings(_ nodes: [Node]) -> Int32 {
            guard !nodes.isEmpty else { return -1 }
            var indices: [Int] = []
            for node in nodes {
                if let data = node.data {
                    // Stream: place at the next free mini sector, pad to 64.
                    let startMini = UInt32(miniStream.count / miniSectorSize)
                    miniStream.append(data)
                    let remainder = miniStream.count % miniSectorSize
                    if remainder != 0 {
                        miniStream.append(Data(repeating: 0, count: miniSectorSize - remainder))
                    }
                    entries.append(Entry(name: node.name, type: 2,
                                         startSector: startMini, size: UInt64(data.count)))
                    indices.append(entries.count - 1)
                } else {
                    entries.append(Entry(name: node.name, type: 1))
                    indices.append(entries.count - 1)
                }
            }
            // Recurse into storages AFTER reserving this level's indices, so
            // sibling numbering stays contiguous and predictable.
            for (offset, node) in nodes.enumerated() where node.data == nil {
                entries[indices[offset]].child = appendSiblings(node.children)
            }
            // Right-sibling chain: OLE2Reader.collectTree walks left→self→right,
            // so a pure right chain yields the nodes in declaration order.
            for i in 0..<(indices.count - 1) {
                entries[indices[i]].right = Int32(indices[i + 1])
            }
            return Int32(indices[0])
        }
        entries[0].child = appendSiblings(nodes)

        // 2 — Sector budget.
        let dirSectors = max(1, Int(ceil(Double(entries.count) / 4.0)))
        let miniSectorCount = miniStream.count / miniSectorSize
        let miniStreamSectors = Int(ceil(Double(miniStream.count) / Double(sectorSize)))
        let miniFatSectors = miniSectorCount == 0 ? 0
            : Int(ceil(Double(miniSectorCount * 4) / Double(sectorSize)))
        let nonFat = dirSectors + miniStreamSectors + miniFatSectors
        var fatSectors = 1
        while fatSectors < Int(ceil(Double(fatSectors + nonFat) / 128.0)) { fatSectors += 1 }

        let firstDir = fatSectors
        let firstMiniStream = firstDir + dirSectors
        let firstMiniFat = firstMiniStream + miniStreamSectors
        let totalSectors = fatSectors + nonFat

        entries[0].startSector = miniStreamSectors == 0 ? Self.endOfChain : UInt32(firstMiniStream)
        entries[0].size = UInt64(miniStream.count)

        // 3 — FAT: mark its own sectors, then chain dir / mini-stream / miniFAT.
        var fat = [UInt32](repeating: Self.freeSect, count: fatSectors * 128)
        for s in 0..<fatSectors { fat[s] = Self.fatSect }
        func chain(from start: Int, count: Int) {
            guard count > 0 else { return }
            for i in 0..<(count - 1) { fat[start + i] = UInt32(start + i + 1) }
            fat[start + count - 1] = Self.endOfChain
        }
        chain(from: firstDir, count: dirSectors)
        chain(from: firstMiniStream, count: miniStreamSectors)
        chain(from: firstMiniFat, count: miniFatSectors)

        // 4 — MiniFAT: each stream's mini sectors run consecutively, and every
        //     stream here fits one 64-byte sector or a short run of them.
        var miniFat = [UInt32](repeating: Self.freeSect,
                               count: max(0, miniFatSectors * 128))
        for entry in entries where entry.type == 2 {
            let sectors = max(1, Int(ceil(Double(entry.size) / Double(miniSectorSize))))
            let start = Int(entry.startSector)
            for i in 0..<(sectors - 1) { miniFat[start + i] = UInt32(start + i + 1) }
            miniFat[start + sectors - 1] = Self.endOfChain
        }

        // 5 — Assemble.
        var out = [UInt8](repeating: 0, count: 512 + totalSectors * sectorSize)

        func put16(_ v: UInt16, at off: Int) {
            out[off] = UInt8(v & 0xFF); out[off + 1] = UInt8((v >> 8) & 0xFF)
        }
        func put32(_ v: UInt32, at off: Int) {
            for i in 0..<4 { out[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
        }
        func put64(_ v: UInt64, at off: Int) {
            for i in 0..<8 { out[off + i] = UInt8((v >> (8 * UInt64(i))) & 0xFF) }
        }
        func sectorOffset(_ s: Int) -> Int { 512 + s * sectorSize }

        // Header.
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        for (i, b) in magic.enumerated() { out[i] = b }
        put16(0x003E, at: 24)                      // minor version
        put16(0x0003, at: 26)                      // major version (v3)
        put16(0xFFFE, at: 28)                      // little-endian
        put16(9, at: 30)                           // 2^9 = 512-byte sectors
        put16(6, at: 32)                           // 2^6 = 64-byte mini sectors
        put32(0, at: 40)                           // dir sector count (0 in v3)
        put32(UInt32(fatSectors), at: 44)
        put32(UInt32(firstDir), at: 48)
        put32(UInt32(miniStreamCutoff), at: 56)
        put32(miniFatSectors == 0 ? Self.endOfChain : UInt32(firstMiniFat), at: 60)
        put32(UInt32(miniFatSectors), at: 64)
        put32(Self.endOfChain, at: 68)             // first DIFAT sector: none
        put32(0, at: 72)                           // DIFAT sector count
        for i in 0..<109 {                         // DIFAT: first 109 FAT sectors
            put32(i < fatSectors ? UInt32(i) : Self.freeSect, at: 76 + i * 4)
        }

        // FAT sectors.
        for (i, value) in fat.enumerated() {
            put32(value, at: sectorOffset(0) + i * 4)
        }
        // MiniFAT sectors.
        for (i, value) in miniFat.enumerated() where miniFatSectors > 0 {
            put32(value, at: sectorOffset(firstMiniFat) + i * 4)
        }
        // Mini stream payload.
        for (i, byte) in miniStream.enumerated() {
            out[sectorOffset(firstMiniStream) + i] = byte
        }
        // Directory entries (128 bytes each).
        for (index, entry) in entries.enumerated() {
            let base = sectorOffset(firstDir) + index * 128
            let utf16 = Array(entry.name.utf16.prefix(31))
            for (i, unit) in utf16.enumerated() { put16(unit, at: base + i * 2) }
            put16(UInt16((utf16.count + 1) * 2), at: base + 64)   // includes NUL
            out[base + 66] = entry.type
            out[base + 67] = 1                                    // black
            put32(UInt32(bitPattern: -1), at: base + 68)          // left sibling
            put32(UInt32(bitPattern: entry.right), at: base + 72)
            put32(UInt32(bitPattern: entry.child), at: base + 76)
            put32(entry.startSector, at: base + 116)
            put64(entry.size, at: base + 120)
        }
        return Data(out)
    }

    // MARK: - MSG helpers

    /// `__substg1.0_<PPPP><TTTT>` stream name for a MAPI property tag.
    static func substgName(id: UInt16, type: UInt16) -> String {
        String(format: "__substg1.0_%04X%04X", id, type)
    }

    /// A unicode-string MAPI property stream (type 0x001F = UTF-16LE).
    static func unicodeProperty(id: MAPIPropertyID, _ value: String) -> Node {
        var bytes = Data()
        for unit in value.utf16 {
            bytes.append(UInt8(unit & 0xFF)); bytes.append(UInt8((unit >> 8) & 0xFF))
        }
        return .stream(substgName(id: id.rawValue, type: 0x001F), bytes)
    }

    /// A binary MAPI property stream (type 0x0102).
    static func binaryProperty(id: MAPIPropertyID, _ value: Data) -> Node {
        .stream(substgName(id: id.rawValue, type: 0x0102), value)
    }
}
