//
//  RegistryHiveReader.swift
//  Kalsmritikosh
//
//  HOST-2 — reader for the Windows registry hive format (REGF): NTUSER.DAT,
//  UsrClass.dat, SOFTWARE, SYSTEM, SAM, SECURITY. Pure Swift, read-only, no
//  dependency, no Windows API. Structured like OLE2Reader: this file understands
//  ONLY the container format; turning keys and values into evidence is the
//  structural parser's job.
//
//  Layout (documented in Microsoft's "Windows registry file format" and the
//  widely-replicated community specification):
//    - 4096-byte base block: "regf", sequence numbers, last-written FILETIME,
//      version, ROOT CELL offset, hive-bins data size, embedded hive name.
//    - hive bins from offset 4096, each "hbin".
//    - cells inside bins: int32 size (NEGATIVE = allocated, positive = free),
//      then 2-byte signature + body. Every offset stored in a cell is relative
//      to the start of the hive-bins data (4096), not to the file.
//    - "nk" key node, "vk" value, "lf"/"lh"/"li"/"ri" subkey lists, "db" big data.
//
//  Robustness rules, because a hive recovered from a seized machine is routinely
//  truncated or partly overwritten: every read is bounds-checked, every offset is
//  validated before use, already-visited cells are refused (a corrupt hive can
//  point a subkey list back at its own parent and a naive walk never returns),
//  and nothing here ever traps. Unreadable regions are reported, not guessed.
//

import Foundation

public struct RegistryHiveReader: Sendable {

    // MARK: - Public model

    public struct Key: Sendable {
        /// Backslash-separated path from the root, excluding the root's own name.
        public let path: String
        public let name: String
        /// Key last-written time — one of the most load-bearing facts in a hive.
        public let lastWritten: Date?
        public let values: [Value]
    }

    public struct Value: Sendable {
        /// Empty name means the key's default value, shown as "(default)".
        public let name: String
        public let type: ValueType
        /// Rendered for citation. Binary stays described, never invented.
        public let rendered: String
        public let byteCount: Int
    }

    public enum ValueType: UInt32, Sendable {
        case none = 0, sz = 1, expandSZ = 2, binary = 3, dword = 4
        case dwordBigEndian = 5, link = 6, multiSZ = 7, qword = 11

        public var label: String {
            switch self {
            case .none: return "REG_NONE"
            case .sz: return "REG_SZ"
            case .expandSZ: return "REG_EXPAND_SZ"
            case .binary: return "REG_BINARY"
            case .dword: return "REG_DWORD"
            case .dwordBigEndian: return "REG_DWORD_BIG_ENDIAN"
            case .link: return "REG_LINK"
            case .multiSZ: return "REG_MULTI_SZ"
            case .qword: return "REG_QWORD"
            }
        }
    }

    public enum ReaderError: Error, Sendable {
        case notAHive
        case truncated
        case rootUnreadable
    }

    /// Hive name as recorded inside the base block (often the original path).
    public let embeddedName: String
    /// Base-block last-written time.
    public let lastWritten: Date?
    public let majorVersion: UInt32
    public let minorVersion: UInt32
    /// Non-fatal problems found while walking. Surfaced as parser warnings.
    public private(set) var problems: [String] = []

    private let data: Data
    private let binsStart = 4096
    private let binsSize: Int
    private let rootOffset: UInt32

    /// Walk budgets. A SOFTWARE hive holds hundreds of thousands of keys; this is
    /// a citation adapter, so it stops at a stated ceiling rather than pretending.
    public static let maxKeys = 20_000
    public static let maxValuesPerKey = 512
    public static let maxDepth = 32

    // MARK: - Init

    public init(data: Data) throws {
        guard data.count >= 4096 else { throw ReaderError.truncated }
        guard data.prefix(4) == Data("regf".utf8) else { throw ReaderError.notAHive }
        self.data = data
        self.majorVersion = Self.u32(data, 0x14) ?? 0
        self.minorVersion = Self.u32(data, 0x18) ?? 0
        self.rootOffset = Self.u32(data, 0x24) ?? 0
        let declaredBins = Int(Self.u32(data, 0x28) ?? 0)
        // Trust the SMALLER of declared size and what the file actually holds — a
        // truncated hive declares the size it had before it was cut.
        self.binsSize = min(declaredBins, data.count - 4096)
        self.lastWritten = Self.filetime(data, 0x0C)
        self.embeddedName = Self.utf16(data.subdata(in: 0x30..<min(0x70, data.count)))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        if declaredBins > data.count - 4096 {
            problems.append("Hive declares \(declaredBins) bytes of bin data but only "
                            + "\(data.count - 4096) are present — file is truncated.")
        }
    }

    // MARK: - Walk

    /// Every reachable key in a stable, depth-first, name-sorted order, each with
    /// its values. Sorted so the same hive always yields the same citation order.
    public mutating func keys() throws -> [Key] {
        guard let root = keyNode(at: rootOffset) else { throw ReaderError.rootUnreadable }
        var out: [Key] = []
        var visited = Set<UInt32>()
        walk(root, parentPath: "", depth: 0, visited: &visited, into: &out)
        return out
    }

    private mutating func walk(_ node: KeyNode, parentPath: String, depth: Int,
                               visited: inout Set<UInt32>, into out: inout [Key]) {
        if out.count >= Self.maxKeys {
            if !problems.contains(where: { $0.hasPrefix("Stopped after") }) {
                problems.append("Stopped after \(Self.maxKeys) keys; deeper keys not indexed.")
            }
            return
        }
        if depth > Self.maxDepth {
            problems.append("Stopped at depth \(Self.maxDepth) under \(parentPath).")
            return
        }
        // A corrupt or deliberately-damaged hive can make a subkey list point back
        // up its own chain. Refusing a repeat offset is what keeps this terminating.
        guard visited.insert(node.offset).inserted else {
            problems.append("Cycle refused at offset \(node.offset) under \(parentPath).")
            return
        }

        let path = parentPath.isEmpty ? node.name : parentPath + "\\" + node.name
        out.append(Key(path: path, name: node.name,
                       lastWritten: node.lastWritten, values: values(of: node)))

        let children = subkeys(of: node).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        for child in children {
            walk(child, parentPath: path, depth: depth + 1, visited: &visited, into: &out)
        }
    }

    // MARK: - Key nodes

    private struct KeyNode {
        let offset: UInt32
        let name: String
        let lastWritten: Date?
        let subkeyCount: UInt32
        let subkeyListOffset: UInt32
        let valueCount: UInt32
        let valueListOffset: UInt32
    }

    private func keyNode(at offset: UInt32) -> KeyNode? {
        guard let body = cellBody(at: offset), body.count >= 78,
              Self.signature(body) == "nk" else { return nil }
        let flags = Self.u16(body, 0x02) ?? 0
        let nameLength = Int(Self.u16(body, 0x48) ?? 0)
        guard nameLength >= 0, 0x4C + nameLength <= body.count else { return nil }
        let nameBytes = body.subdata(in: (body.startIndex + 0x4C)..<(body.startIndex + 0x4C + nameLength))
        // KEY_COMP_NAME (0x20): the name is single-byte, not UTF-16.
        let name = (flags & 0x0020) != 0 ? Self.latin1(nameBytes) : Self.utf16(nameBytes)
        return KeyNode(
            offset: offset,
            name: name,
            lastWritten: Self.filetime(body, 0x04),
            subkeyCount: Self.u32(body, 0x14) ?? 0,
            subkeyListOffset: Self.u32(body, 0x1C) ?? 0xFFFF_FFFF,
            valueCount: Self.u32(body, 0x24) ?? 0,
            valueListOffset: Self.u32(body, 0x28) ?? 0xFFFF_FFFF)
    }

    private func subkeys(of node: KeyNode) -> [KeyNode] {
        guard node.subkeyCount > 0, node.subkeyListOffset != 0xFFFF_FFFF else { return [] }
        return keyNodes(fromSubkeyList: node.subkeyListOffset, depth: 0)
    }

    /// Resolves lf/lh (with hashes), li (plain), and ri (index root pointing at
    /// further lists). `depth` bounds ri nesting.
    private func keyNodes(fromSubkeyList offset: UInt32, depth: Int) -> [KeyNode] {
        guard depth < 8, let body = cellBody(at: offset), body.count >= 4 else { return [] }
        let sig = Self.signature(body)
        let count = Int(Self.u16(body, 0x02) ?? 0)
        var result: [KeyNode] = []
        switch sig {
        case "lf", "lh":
            for i in 0..<count {
                let at = 0x04 + i * 8
                guard at + 4 <= body.count, let child = Self.u32(body, at) else { break }
                if let node = keyNode(at: child) { result.append(node) }
            }
        case "li":
            for i in 0..<count {
                let at = 0x04 + i * 4
                guard at + 4 <= body.count, let child = Self.u32(body, at) else { break }
                if let node = keyNode(at: child) { result.append(node) }
            }
        case "ri":
            for i in 0..<count {
                let at = 0x04 + i * 4
                guard at + 4 <= body.count, let list = Self.u32(body, at) else { break }
                result.append(contentsOf: keyNodes(fromSubkeyList: list, depth: depth + 1))
            }
        default:
            break
        }
        return result
    }

    // MARK: - Values

    private func values(of node: KeyNode) -> [Value] {
        guard node.valueCount > 0, node.valueListOffset != 0xFFFF_FFFF,
              let list = cellBody(at: node.valueListOffset) else { return [] }
        let count = min(Int(node.valueCount), Self.maxValuesPerKey)
        var out: [Value] = []
        for i in 0..<count {
            let at = i * 4
            guard at + 4 <= list.count, let vkOffset = Self.u32(list, at),
                  let value = value(at: vkOffset) else { continue }
            out.append(value)
        }
        return out
    }

    private func value(at offset: UInt32) -> Value? {
        guard let body = cellBody(at: offset), body.count >= 0x14,
              Self.signature(body) == "vk" else { return nil }
        let nameLength = Int(Self.u16(body, 0x02) ?? 0)
        let rawSize = Self.u32(body, 0x04) ?? 0
        let dataOffset = Self.u32(body, 0x08) ?? 0
        let typeRaw = Self.u32(body, 0x0C) ?? 0
        let flags = Self.u16(body, 0x10) ?? 0

        var name = ""
        if nameLength > 0, 0x14 + nameLength <= body.count {
            let bytes = body.subdata(in: (body.startIndex + 0x14)..<(body.startIndex + 0x14 + nameLength))
            // VALUE_COMP_NAME (0x0001): single-byte name.
            name = (flags & 0x0001) != 0 ? Self.latin1(bytes) : Self.utf16(bytes)
        }

        // High bit set = the value's data IS the 4 bytes of the data-offset field.
        let inline = (rawSize & 0x8000_0000) != 0
        let size = Int(rawSize & 0x7FFF_FFFF)
        var payload = Data()
        if inline {
            var le = dataOffset.littleEndian
            payload = withUnsafeBytes(of: &le) { Data($0) }.prefix(min(size, 4))
        } else if size > 0 {
            payload = readData(at: dataOffset, size: size)
        }

        let type = ValueType(rawValue: typeRaw)
        return Value(name: name.isEmpty ? "(default)" : name,
                     type: type ?? .binary,
                     rendered: Self.render(payload, as: type, declaredType: typeRaw),
                     byteCount: payload.count)
    }

    /// Value data, following a "db" big-data cell when the payload exceeded the
    /// 16344-byte single-cell limit.
    private func readData(at offset: UInt32, size: Int) -> Data {
        guard let body = cellBody(at: offset) else { return Data() }
        if size > 16_344, body.count >= 8, Self.signature(body) == "db" {
            let segments = Int(Self.u16(body, 0x02) ?? 0)
            guard let listOffset = Self.u32(body, 0x04), let list = cellBody(at: listOffset) else { return Data() }
            var joined = Data()
            for i in 0..<segments {
                let at = i * 4
                guard at + 4 <= list.count, let segOffset = Self.u32(list, at),
                      let segment = cellBody(at: segOffset) else { break }
                joined.append(segment.prefix(16_344))
                if joined.count >= size { break }
            }
            return joined.prefix(size)
        }
        return body.prefix(size)
    }

    // MARK: - Cells

    /// The body of the cell at a bins-relative offset, signature included, with
    /// the 4-byte size header stripped. Nil when the offset or size is not sane.
    private func cellBody(at offset: UInt32) -> Data? {
        guard offset != 0xFFFF_FFFF else { return nil }
        let absolute = binsStart + Int(offset)
        guard absolute >= binsStart, absolute + 4 <= binsStart + binsSize,
              absolute + 4 <= data.count else { return nil }
        guard let raw = Self.i32(data, absolute) else { return nil }
        // Negative size = allocated cell (in use). A positive size marks a freed
        // cell; we do not follow those, so nothing here reports deleted data as live.
        guard raw < 0 else { return nil }
        let size = Int(-raw)
        guard size > 4, absolute + size <= data.count else { return nil }
        return data.subdata(in: (absolute + 4)..<(absolute + size))
    }

    // MARK: - Rendering

    private static func render(_ payload: Data, as type: ValueType?, declaredType: UInt32) -> String {
        guard let type else { return "<type \(declaredType), \(payload.count) bytes>" }
        switch type {
        case .sz, .expandSZ, .link:
            return utf16(payload).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        case .multiSZ:
            return utf16(payload)
                .split(separator: "\0", omittingEmptySubsequences: true)
                .joined(separator: "; ")
        case .dword:
            guard let v = u32(payload, 0) else { return "<truncated DWORD>" }
            return String(v)
        case .dwordBigEndian:
            guard payload.count >= 4 else { return "<truncated DWORD>" }
            let b = [UInt8](payload.prefix(4))
            return String((UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3]))
        case .qword:
            guard payload.count >= 8 else { return "<truncated QWORD>" }
            var v: UInt64 = 0
            for (i, byte) in payload.prefix(8).enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
            return String(v)
        case .binary, .none:
            return "<binary \(payload.count) bytes>"
        }
    }

    // MARK: - Primitives (all bounds-checked; none of these can trap)

    private static func signature(_ d: Data) -> String {
        guard d.count >= 2 else { return "" }
        return String(decoding: d.prefix(2), as: UTF8.self)
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16? {
        let i = d.startIndex + at
        guard at >= 0, i + 2 <= d.endIndex else { return nil }
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32? {
        let i = d.startIndex + at
        guard at >= 0, i + 4 <= d.endIndex else { return nil }
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }

    private static func i32(_ d: Data, _ at: Int) -> Int32? {
        guard let v = u32(d, at) else { return nil }
        return Int32(bitPattern: v)
    }

    /// FILETIME → Date. 100-nanosecond intervals since 1601-01-01 UTC. Zero means
    /// "never written", which is a real state and must not become 1601.
    private static func filetime(_ d: Data, _ at: Int) -> Date? {
        guard let lo = u32(d, at), let hi = u32(d, at + 4) else { return nil }
        let ticks = (UInt64(hi) << 32) | UInt64(lo)
        guard ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }  // 1900…2100
        return Date(timeIntervalSince1970: seconds)
    }

    private static func utf16(_ d: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(d.count / 2)
        var i = d.startIndex
        while i + 1 < d.endIndex {
            units.append(UInt16(d[i]) | (UInt16(d[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func latin1(_ d: Data) -> String {
        String(d.map { Character(UnicodeScalar($0)) })
    }
}
