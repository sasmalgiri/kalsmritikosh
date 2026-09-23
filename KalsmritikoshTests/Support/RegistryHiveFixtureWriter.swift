//
//  RegistryHiveFixtureWriter.swift
//  KalsmritikoshTests
//
//  HOST-2 test support — writes a real, structurally valid Windows registry hive
//  (REGF) so the reader is proved against bytes rather than a mock. Same role as
//  CFBFixtureWriter for .msg: if the fixture writer and the parser were both wrong
//  in the same way the tests would pass, so this writer is built strictly from the
//  published layout and lays out cells independently of how the parser walks them.
//
//  Cells are emitted POST-ORDER (data → vk → value list → child nk → subkey list →
//  parent nk), which lets every stored offset be known by the time it is written,
//  in a single forward pass.
//

import Foundation
@testable import Kalsmritikosh

struct RegistryHiveFixtureWriter {

    /// A value to store under a key.
    struct Val {
        let name: String
        let type: UInt32
        let data: Data
        /// When true the payload is packed into the vk data-offset field itself
        /// (the real format's small-value optimization), not a separate cell.
        let inline: Bool

        init(name: String, type: UInt32, data: Data, inline: Bool = false) {
            self.name = name; self.type = type; self.data = data; self.inline = inline
        }

        static func sz(_ name: String, _ text: String) -> Val {
            var d = Data()
            for unit in Array(text.utf16) + [0] {
                d.append(UInt8(unit & 0xFF)); d.append(UInt8(unit >> 8))
            }
            return Val(name: name, type: 1, data: d)
        }

        static func dword(_ name: String, _ value: UInt32, inline: Bool = false) -> Val {
            var le = value.littleEndian
            return Val(name: name, type: 4,
                       data: withUnsafeBytes(of: &le) { Data($0) }, inline: inline)
        }

        static func multiSZ(_ name: String, _ items: [String]) -> Val {
            var d = Data()
            for item in items {
                for unit in Array(item.utf16) + [0] {
                    d.append(UInt8(unit & 0xFF)); d.append(UInt8(unit >> 8))
                }
            }
            d.append(0); d.append(0)      // list terminator
            return Val(name: name, type: 7, data: d)
        }

        static func binary(_ name: String, _ bytes: [UInt8]) -> Val {
            Val(name: name, type: 3, data: Data(bytes))
        }
    }

    /// A key in the fixture tree.
    final class Key {
        let name: String
        let lastWritten: Date?
        let values: [Val]
        var children: [Key]

        init(_ name: String, lastWritten: Date? = nil, values: [Val] = [], children: [Key] = []) {
            self.name = name; self.lastWritten = lastWritten
            self.values = values; self.children = children
        }
    }

    /// Which subkey-list cell type to emit. The format allows all three and real
    /// hives use each, so the reader has to handle all three.
    enum SubkeyListKind { case lh, li, ri }

    var subkeyListKind: SubkeyListKind = .lh
    /// Written into the base block's embedded-name field (often the original path).
    var embeddedName = "\\??\\C:\\Users\\jdoe\\NTUSER.DAT"

    // MARK: - Build

    func build(root: Key) -> Data {
        var bin = Data()                    // cell area, starts at bins-relative 32
        let cellBase = 32

        /// Appends a cell body and returns its bins-relative offset.
        func emit(_ body: Data) -> UInt32 {
            let offset = UInt32(cellBase + bin.count)
            // size field + body, padded up to a multiple of 8; negative = allocated.
            var padded = 4 + body.count
            if padded % 8 != 0 { padded += 8 - (padded % 8) }
            var size = Int32(-padded).littleEndian
            bin.append(withUnsafeBytes(of: &size) { Data($0) })
            bin.append(body)
            bin.append(Data(repeating: 0, count: padded - 4 - body.count))
            return offset
        }

        /// Emits a key and everything below it, returning the key node's offset.
        func emitKey(_ key: Key, parent: UInt32) -> UInt32 {
            // 1. value data cells, then vk cells.
            var vkOffsets: [UInt32] = []
            for value in key.values {
                var dataOffset: UInt32 = 0xFFFF_FFFF
                var rawSize = UInt32(value.data.count)
                if value.inline {
                    var packed: UInt32 = 0
                    for (i, byte) in value.data.prefix(4).enumerated() {
                        packed |= UInt32(byte) << (8 * UInt32(i))
                    }
                    dataOffset = packed
                    rawSize = UInt32(value.data.count) | 0x8000_0000
                } else if !value.data.isEmpty {
                    dataOffset = emit(value.data)
                }

                var vk = Data("vk".utf8)
                vk += Self.u16(UInt16(value.name.utf8.count))       // name length
                vk += Self.u32(rawSize)                             // data size (high bit = inline)
                vk += Self.u32(dataOffset)
                vk += Self.u32(value.type)
                vk += Self.u16(0x0001)                              // VALUE_COMP_NAME: ASCII name
                vk += Self.u16(0)                                   // spare
                vk += Data(value.name.utf8)
                vkOffsets.append(emit(vk))
            }

            // 2. value list: a bare array of vk offsets.
            var valueListOffset: UInt32 = 0xFFFF_FFFF
            if !vkOffsets.isEmpty {
                var list = Data()
                for o in vkOffsets { list += Self.u32(o) }
                valueListOffset = emit(list)
            }

            // 3. The key node must exist before its children can name it as parent,
            //    but its own body needs the subkey-list offset. Real hives resolve
            //    this with a fixed-size record, so reserve the slot and patch it.
            var nkBody = Data("nk".utf8)
            nkBody += Self.u16(parent == 0xFFFF_FFFF ? 0x002C : 0x0020)  // KEY_COMP_NAME (+hive entry for root)
            nkBody += Self.filetime(key.lastWritten)
            nkBody += Self.u32(0)                                        // access bits
            nkBody += Self.u32(parent)
            nkBody += Self.u32(UInt32(key.children.count))
            nkBody += Self.u32(0)                                        // volatile subkeys
            nkBody += Self.u32(0xFFFF_FFFF)                              // subkey list — patched below
            nkBody += Self.u32(0xFFFF_FFFF)                              // volatile subkey list
            nkBody += Self.u32(UInt32(key.values.count))
            nkBody += Self.u32(valueListOffset)
            nkBody += Self.u32(0xFFFF_FFFF)                              // security
            nkBody += Self.u32(0xFFFF_FFFF)                              // class name
            nkBody += Data(repeating: 0, count: 20)                      // largest-* + workvar
            nkBody += Self.u16(UInt16(key.name.utf8.count))              // key name length
            nkBody += Self.u16(0)                                        // class name length
            nkBody += Data(key.name.utf8)
            let nkOffset = emit(nkBody)

            // 4. Children, then the subkey list, then patch the reserved slot.
            if !key.children.isEmpty {
                var childOffsets: [UInt32] = []
                for child in key.children { childOffsets.append(emitKey(child, parent: nkOffset)) }

                let listOffset: UInt32
                switch subkeyListKind {
                case .lh, .li:
                    var list = Data(subkeyListKind == .lh ? "lh".utf8 : "li".utf8)
                    list += Self.u16(UInt16(childOffsets.count))
                    for o in childOffsets {
                        list += Self.u32(o)
                        if subkeyListKind == .lh { list += Self.u32(0) }   // name hash, unused by the reader
                    }
                    listOffset = emit(list)
                case .ri:
                    // Index root: each entry points at a separate one-entry lh list,
                    // which is how large hives fan out.
                    var leaves: [UInt32] = []
                    for o in childOffsets {
                        var leaf = Data("lh".utf8)
                        leaf += Self.u16(1)
                        leaf += Self.u32(o)
                        leaf += Self.u32(0)
                        leaves.append(emit(leaf))
                    }
                    var ri = Data("ri".utf8)
                    ri += Self.u16(UInt16(leaves.count))
                    for l in leaves { ri += Self.u32(l) }
                    listOffset = emit(ri)
                }

                // Patch the subkey-list offset inside the already-emitted nk body:
                // cell start = nkOffset - 32 within `bin`, +4 size header, +0x1C field.
                let field = Int(nkOffset) - cellBase + 4 + 0x1C
                let patch = Self.u32(listOffset)
                bin.replaceSubrange(field..<(field + 4), with: patch)
            }

            return nkOffset
        }

        let rootOffset = emitKey(root, parent: 0xFFFF_FFFF)

        // Hive bins data: one hbin, padded to a 4096 multiple.
        var binsSize = 32 + bin.count
        if binsSize % 4096 != 0 { binsSize += 4096 - (binsSize % 4096) }
        var hbin = Data("hbin".utf8)
        hbin += Self.u32(0)                          // this bin's offset within the bins data
        hbin += Self.u32(UInt32(binsSize))
        hbin += Data(repeating: 0, count: 32 - hbin.count)
        hbin += bin
        hbin += Data(repeating: 0, count: binsSize - hbin.count)

        // Base block.
        var base = Data("regf".utf8)
        base += Self.u32(1)                          // primary sequence
        base += Self.u32(1)                          // secondary sequence (equal = clean)
        base += Self.filetime(Date(timeIntervalSince1970: 1_773_480_413))
        base += Self.u32(1)                          // major
        base += Self.u32(3)                          // minor
        base += Self.u32(0)                          // file type: primary
        base += Self.u32(1)                          // format: direct memory load
        base += Self.u32(rootOffset)
        base += Self.u32(UInt32(binsSize))
        base += Self.u32(1)                          // clustering factor
        var nameField = Data()
        for unit in Array(embeddedName.utf16.prefix(31)) {
            nameField.append(UInt8(unit & 0xFF)); nameField.append(UInt8(unit >> 8))
        }
        nameField += Data(repeating: 0, count: 64 - nameField.count)
        base += nameField
        base += Data(repeating: 0, count: 0x1FC - base.count)
        base += Self.u32(Self.checksum(base))
        base += Data(repeating: 0, count: 4096 - base.count)

        return base + hbin
    }

    // MARK: - Primitives

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    /// 100-nanosecond intervals since 1601-01-01; zero means "never written".
    private static func filetime(_ date: Date?) -> Data {
        guard let date else { return Data(repeating: 0, count: 8) }
        let ticks = UInt64((date.timeIntervalSince1970 + 11_644_473_600.0) * 10_000_000.0)
        var le = ticks.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }
    /// XOR of the first 508 bytes taken as little-endian u32s (0 and 0xFFFFFFFF
    /// are replaced in the real format; irrelevant for a fixture).
    private static func checksum(_ d: Data) -> UInt32 {
        var acc: UInt32 = 0
        var i = d.startIndex
        while i + 4 <= d.startIndex + 508 && i + 4 <= d.endIndex {
            let word = UInt32(d[i]) | (UInt32(d[i + 1]) << 8)
                     | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
            acc ^= word
            i += 4
        }
        return acc
    }
}
