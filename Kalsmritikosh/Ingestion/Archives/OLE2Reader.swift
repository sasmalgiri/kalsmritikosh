//
//  OLE2Reader.swift
//  Kalsmritikosh
//
//  Microsoft OLE2 compound-file reader. .msg (Outlook), .doc (old-Word),
//  and embedded MSOLE streams all live in this container format. We
//  ported it from the sibling mailin/ MSGParser so the email loader
//  can finally parse .msg natively instead of falling back to the
//  binary stub. PSTLoader (G4.9 follow-up) reuses the same reader.
//
//  The format spec — Microsoft's [MS-CFB] "Compound File Binary File
//  Format" — defines a 512-byte header, a FAT-style sector chain, a
//  red-black directory tree of named streams, and a parallel mini-
//  stream for entries below 4 KB. We only implement the read path
//  and only the surface area the MSG parser needs (no writes, no
//  red-black rebalancing).
//

import Foundation

/// Reads a Microsoft Compound File Binary (CFB / OLE2) document and
/// exposes its directory tree of named streams.
public nonisolated struct OLE2Reader: Sendable {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let fatSectors: [Int]
    private let miniStreamCutoff: Int
    private let fat: [Int32]
    private let miniFat: [Int32]
    private let directories: [DirectoryEntry]
    private let miniStreamData: Data

    private static let maxChainLength = 100_000
    private static let maxDirCount = 500_000

    public struct DirectoryEntry: Sendable {
        public let index: Int
        public let name: String
        public let type: UInt8
        public let startSector: Int
        public let size: Int
        public let childID: Int
        public let leftSiblingID: Int
        public let rightSiblingID: Int
    }

    public enum OLE2Error: Error, Sendable {
        case invalidFormat(String)
    }

    public init(data: Data) throws {
        guard data.count >= 512 else {
            throw OLE2Error.invalidFormat("File too small for OLE2")
        }
        guard data[0] == 0xD0, data[1] == 0xCF, data[2] == 0x11, data[3] == 0xE0,
              data[4] == 0xA1, data[5] == 0xB1, data[6] == 0x1A, data[7] == 0xE1 else {
            throw OLE2Error.invalidFormat("Not a valid OLE2 compound document (bad magic bytes)")
        }
        self.data = data

        let sectorSizePower = Int(Self.readUInt16(data, offset: 30))
        guard sectorSizePower >= 7 && sectorSizePower <= 16 else {
            throw OLE2Error.invalidFormat("Invalid sector size power: \(sectorSizePower)")
        }
        self.sectorSize = 1 << sectorSizePower
        let miniSectorSizePower = Int(Self.readUInt16(data, offset: 32))
        guard miniSectorSizePower >= 0 && miniSectorSizePower <= 16 else {
            throw OLE2Error.invalidFormat("Invalid mini sector size power: \(miniSectorSizePower)")
        }
        self.miniSectorSize = 1 << miniSectorSizePower
        self.miniStreamCutoff = Int(Self.readUInt32(data, offset: 56))

        let fatSectorCount = Int(Self.readUInt32(data, offset: 44))
        let firstDirSector = Int(Self.readInt32(data, offset: 48))
        let firstMiniFatSector = Int(Self.readInt32(data, offset: 60))
        let miniFatSectorCount = Int(Self.readUInt32(data, offset: 64))
        let difatFirstSector = Int(Self.readInt32(data, offset: 68))
        let difatSectorCount = Int(Self.readUInt32(data, offset: 72))

        // The header carries the first 109 FAT-sector pointers inline;
        // anything beyond that lives in the DIFAT chain.
        var fatSectorList: [Int] = []
        for i in 0..<min(fatSectorCount, 109) {
            let sector = Int(Self.readInt32(data, offset: 76 + i * 4))
            if sector >= 0 { fatSectorList.append(sector) }
        }
        if difatSectorCount > 0 && difatFirstSector >= 0 {
            var difatSector = difatFirstSector
            var difatRead = 0
            while difatSector >= 0 && difatRead < difatSectorCount && difatRead < 1000 {
                let base = 512 + difatSector * self.sectorSize
                guard base >= 0 && base < data.count else { break }
                let entriesPerSector = (self.sectorSize / 4) - 1
                for i in 0..<entriesPerSector {
                    let pos = base + i * 4
                    guard pos + 4 <= data.count else { break }
                    let s = Int(Self.readInt32(data, offset: pos))
                    if s >= 0 { fatSectorList.append(s) }
                }
                let nextPos = base + entriesPerSector * 4
                difatSector = nextPos + 4 <= data.count ? Int(Self.readInt32(data, offset: nextPos)) : -1
                difatRead += 1
            }
        }
        self.fatSectors = fatSectorList
        self.fat = Self.buildFAT(data: data, fatSectors: fatSectorList, sectorSize: self.sectorSize)

        let dirChain = Self.buildChain(startSector: firstDirSector, fat: self.fat)
        self.directories = Self.readDirectories(data: data, chain: dirChain, sectorSize: self.sectorSize)

        if firstMiniFatSector >= 0 && miniFatSectorCount > 0 {
            let miniFatChain = Self.buildChain(startSector: firstMiniFatSector, fat: self.fat)
            self.miniFat = Self.readFATFromChain(data: data, chain: miniFatChain, sectorSize: self.sectorSize)
        } else {
            self.miniFat = []
        }
        if let rootDir = self.directories.first, rootDir.size > 0 {
            let rootChain = Self.buildChain(startSector: rootDir.startSector, fat: self.fat)
            self.miniStreamData = Self.readStreamData(data: data, chain: rootChain, sectorSize: self.sectorSize, streamSize: rootDir.size)
        } else {
            self.miniStreamData = Data()
        }
    }

    // MARK: - Directory tree traversal

    /// In-order walk of the red-black tree of children rooted at the
    /// given directory entry. The format stores children in a balanced
    /// tree, but we only read — so a recursive in-order traversal with
    /// a visited set is enough.
    public func childrenOf(directoryIndex: Int) -> [DirectoryEntry] {
        guard directoryIndex >= 0 && directoryIndex < directories.count else { return [] }
        let parent = directories[directoryIndex]
        guard parent.childID >= 0 && parent.childID < directories.count else { return [] }
        var result: [DirectoryEntry] = []
        var visited = Set<Int>()
        collectTree(parent.childID, into: &result, visited: &visited)
        return result
    }

    private func collectTree(_ nodeIndex: Int, into result: inout [DirectoryEntry], visited: inout Set<Int>) {
        guard nodeIndex >= 0 && nodeIndex < directories.count && visited.insert(nodeIndex).inserted else { return }
        guard result.count < Self.maxDirCount else { return }
        let node = directories[nodeIndex]
        collectTree(node.leftSiblingID, into: &result, visited: &visited)
        result.append(node)
        collectTree(node.rightSiblingID, into: &result, visited: &visited)
    }

    /// Raw bytes of a directory entry. Uses the mini-stream when the
    /// entry is smaller than `miniStreamCutoff` and the entry isn't
    /// the root (`type == 5`), per [MS-CFB] §2.4.
    public func readEntryData(_ entry: DirectoryEntry) -> Data {
        if entry.size < miniStreamCutoff && entry.type != 5 {
            let chain = Self.buildChain(startSector: entry.startSector, fat: miniFat)
            return Self.readMiniStreamData(miniStream: miniStreamData, chain: chain, miniSectorSize: miniSectorSize, streamSize: entry.size)
        } else {
            let chain = Self.buildChain(startSector: entry.startSector, fat: fat)
            return Self.readStreamData(data: data, chain: chain, sectorSize: sectorSize, streamSize: entry.size)
        }
    }

    /// Root-level entries (children of the implicit root directory at
    /// index 0). The MSG layout puts `__substg1.0_*` streams and one
    /// `__properties_version1.0` blob directly here.
    public func rootChildren() -> [DirectoryEntry] {
        childrenOf(directoryIndex: 0)
    }

    // MARK: - Static helpers (FAT + sector chains)

    private static func buildFAT(data: Data, fatSectors: [Int], sectorSize: Int) -> [Int32] {
        var fat: [Int32] = []
        for sector in fatSectors {
            let offset = 512 + sector * sectorSize
            let entries = sectorSize / 4
            for i in 0..<entries {
                let pos = offset + i * 4
                if pos + 4 <= data.count {
                    fat.append(readInt32(data, offset: pos))
                }
            }
        }
        return fat
    }

    private static func buildChain(startSector: Int, fat: [Int32]) -> [Int] {
        var chain: [Int] = []
        var current = startSector
        var seen = Set<Int>()
        while current >= 0 && current < fat.count && !seen.contains(current) && chain.count < maxChainLength {
            chain.append(current)
            seen.insert(current)
            let next = Int(fat[current])
            if next == -2 || next == -1 { break } // ENDOFCHAIN or FREESECT
            current = next
        }
        return chain
    }

    private static func readDirectories(data: Data, chain: [Int], sectorSize: Int) -> [DirectoryEntry] {
        var dirs: [DirectoryEntry] = []
        let entriesPerSector = sectorSize / 128
        for sector in chain {
            let base = 512 + sector * sectorSize
            for i in 0..<entriesPerSector {
                let offset = base + i * 128
                guard offset + 128 <= data.count else { continue }

                let rawNameLen = Int(readUInt16(data, offset: offset + 64))
                let nameLen = (rawNameLen / 2) * 2
                let nameData = data[offset..<(offset + min(nameLen, 64))]
                let name = String(data: nameData, encoding: .utf16LittleEndian)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""

                let type = data[offset + 66]
                // [MS-CFB] §2.6.1 directory entry layout: Left Sibling ID at
                // +68, Right Sibling ID at +72, Child ID at +76. (These were
                // previously read swapped — child from +68 — which made
                // rootChildren() return nothing for standard compound files
                // whose stream tree hangs off the Child pointer at +76.)
                let leftID = Int(readInt32(data, offset: offset + 68))
                let rightID = Int(readInt32(data, offset: offset + 72))
                let childID = Int(readInt32(data, offset: offset + 76))
                let startSector = Int(readInt32(data, offset: offset + 116))
                let size: Int
                if sectorSize == 4096 {
                    size = Int(readUInt64(data, offset: offset + 120))
                } else {
                    size = Int(readUInt32(data, offset: offset + 120))
                }
                if type > 0 {
                    dirs.append(DirectoryEntry(
                        index: dirs.count,
                        name: name, type: type,
                        startSector: startSector, size: max(0, size),
                        childID: childID, leftSiblingID: leftID, rightSiblingID: rightID
                    ))
                }
                if dirs.count >= maxDirCount { return dirs }
            }
        }
        return dirs
    }

    private static func readStreamData(data: Data, chain: [Int], sectorSize: Int, streamSize: Int) -> Data {
        var result = Data()
        for sector in chain {
            let offset = 512 + sector * sectorSize
            let end = min(offset + sectorSize, data.count)
            guard offset >= 0 && offset < data.count else { break }
            result.append(data[offset..<end])
        }
        return Data(result.prefix(max(0, streamSize)))
    }

    private static func readMiniStreamData(miniStream: Data, chain: [Int], miniSectorSize: Int, streamSize: Int) -> Data {
        var result = Data()
        for sector in chain {
            let offset = sector * miniSectorSize
            let end = min(offset + miniSectorSize, miniStream.count)
            guard offset >= 0 && offset < miniStream.count else { break }
            result.append(miniStream[offset..<end])
        }
        return Data(result.prefix(max(0, streamSize)))
    }

    private static func readFATFromChain(data: Data, chain: [Int], sectorSize: Int) -> [Int32] {
        var entries: [Int32] = []
        for sector in chain {
            let base = 512 + sector * sectorSize
            for i in 0..<(sectorSize / 4) {
                let pos = base + i * 4
                if pos + 4 <= data.count {
                    entries.append(readInt32(data, offset: pos))
                }
            }
        }
        return entries
    }

    // MARK: - Binary read helpers

    nonisolated static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    nonisolated static func readInt32(_ data: Data, offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(data, offset: offset))
    }

    nonisolated static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(data[offset + i]) << (i * 8)
        }
        return result
    }
}

// MARK: - MAPI property bag (Outlook .msg)

/// Typed bag of MAPI properties extracted from an OLE2 .msg file's
/// `__substg1.0_*` streams + `__properties_version1.0` blob. The MSG
/// format encodes property tags as the upper 16 bits = property ID
/// and the lower 16 bits = data type ([MS-OXCMSG]).
public struct MAPIPropertySet: Sendable {
    public var strings: [UInt16: String] = [:]
    public var binaries: [UInt16: Data] = [:]
    public var dates: [UInt16: Date] = [:]
    public var ints: [UInt16: UInt32] = [:]

    public nonisolated init() {}

    public nonisolated func stringProperty(_ id: MAPIPropertyID) -> String? { strings[id.rawValue] }
    public nonisolated func binaryProperty(_ id: MAPIPropertyID) -> Data? { binaries[id.rawValue] }
    public nonisolated func dateProperty(_ id: MAPIPropertyID) -> Date? { dates[id.rawValue] }
    public nonisolated func intProperty(_ id: MAPIPropertyID) -> UInt32? { ints[id.rawValue] }
}

/// Subset of MAPI property IDs used by the MSG email parser. Numeric
/// values come from [MS-OXPROPS].
public nonisolated enum MAPIPropertyID: UInt16, Sendable {
    case subject = 0x0037
    case body = 0x1000
    case htmlBody = 0x1013
    case rtfCompressed = 0x1009
    case senderName = 0x0C1A
    case senderEmailAddress = 0x0C1F
    case senderSmtpAddress = 0x5D01
    case displayTo = 0x0E04
    case displayCc = 0x0E03
    case displayBcc = 0x0E02
    case internetMessageId = 0x1035
    case inReplyToId = 0x1042
    case messageDeliveryTime = 0x0E06
    case clientSubmitTime = 0x0039
    case creationTime = 0x3007
    case lastModificationTime = 0x3008
    case importance = 0x0017
    case sensitivity = 0x0036
    case conversationTopic = 0x0070
    case references = 0x1039
    case replyToAddress = 0x0050
    case transportMessageHeaders = 0x007D
    case messageFlags = 0x0E07
    case messageSize = 0x0E08
    case displayName = 0x3001

    // Attachment properties (used by future attachment-extracting paths)
    case attachFilename = 0x3704
    case attachLongFilename = 0x3707
    case attachMimeTag = 0x370E
    case attachDataBinary = 0x3701
    case attachDataObject = 0x3703
    case attachContentId = 0x3712
    case attachFlags = 0x3714
    case attachSize = 0x0E20
}

extension OLE2Reader {
    /// Walks every `__substg1.0_*` stream in the root directory and
    /// fills a MAPIPropertySet. Also parses `__properties_version1.0`
    /// (the fixed-size property blob) for typed scalars: int, bool,
    /// and FILETIME dates.
    public func readMAPIProperties() -> MAPIPropertySet {
        var props = MAPIPropertySet()
        for entry in rootChildren() {
            if entry.name.hasPrefix("__substg1.0_") {
                parseSubstgEntry(entry, into: &props)
            } else if entry.name.lowercased() == "__properties_version1.0" {
                let streamData = readEntryData(entry)
                Self.parseFixedProperties(from: streamData, into: &props)
            }
        }
        return props
    }

    private func parseSubstgEntry(_ entry: DirectoryEntry, into props: inout MAPIPropertySet) {
        // Stream name format: __substg1.0_<PPPPTTTT> where PPPP is the
        // property ID (high 16 bits) and TTTT is the property type
        // (low 16 bits). Both hex.
        let tag = String(entry.name.dropFirst(12).prefix(8))
        guard let tagInt = UInt32(tag, radix: 16) else { return }
        let propID = UInt16(tagInt >> 16)
        let propType = UInt16(tagInt & 0xFFFF)
        let streamData = readEntryData(entry)

        switch propType {
        case 0x001F: // Unicode string
            if let str = String(data: streamData, encoding: .utf16LittleEndian)
                ?? String(data: streamData, encoding: .utf8) {
                props.strings[propID] = str
            }
        case 0x001E: // ANSI string
            if let str = String(data: streamData, encoding: .windowsCP1252)
                ?? String(data: streamData, encoding: .ascii)
                ?? String(data: streamData, encoding: .utf8) {
                props.strings[propID] = str
            }
        case 0x0102: // Binary
            props.binaries[propID] = streamData
        default:
            break
        }
    }

    private static func parseFixedProperties(from data: Data, into props: inout MAPIPropertySet) {
        // The fixed-property blob starts with a per-section preamble
        // (8 or 32 bytes depending on the message context) followed by
        // 16-byte property records: 2B type, 2B id, 4B flags, 8B value.
        var offset = data.count >= 32 ? 32 : (data.count >= 8 ? 8 : 0)
        while offset + 16 <= data.count {
            let propType = readUInt16(data, offset: offset)
            let propID = readUInt16(data, offset: offset + 2)
            switch propType {
            case 0x0040: // PT_SYSTIME — Windows FILETIME (100ns ticks since 1601-01-01)
                let fileTime = readUInt64(data, offset: offset + 8)
                if fileTime > 0 {
                    let seconds = Double(fileTime) / 10_000_000.0 - 11_644_473_600.0
                    props.dates[propID] = Date(timeIntervalSince1970: seconds)
                }
            case 0x0003: // PT_LONG
                props.ints[propID] = readUInt32(data, offset: offset + 8)
            case 0x000B: // PT_BOOLEAN
                props.ints[propID] = UInt32(readUInt16(data, offset: offset + 8))
            default:
                break
            }
            offset += 16
        }
    }
}

// MARK: - LZFu (RTF compressed) decoder

/// Decodes a `rtfCompressed` MAPI property (LZFu / uncompressed MELA)
/// to a plain-string approximation of the RTF body. We only need the
/// text content — full RTF rendering is overkill for ingest. Returns
/// nil when the blob is empty, malformed, or larger than the 10 MB
/// sanity cap.
public nonisolated func decompressRTFLZFu(_ data: Data) -> String? {
    guard data.count >= 16 else { return nil }
    let compressedSize = OLE2Reader.readUInt32(data, offset: 0)
    let uncompressedSize = OLE2Reader.readUInt32(data, offset: 4)
    let magic = OLE2Reader.readUInt32(data, offset: 8)

    let lzfuMagic: UInt32 = 0x75465A4C // "LZFu"
    let melalMagic: UInt32 = 0x414C454D // "MELA" (uncompressed)

    guard compressedSize + 4 <= data.count else { return nil }
    guard uncompressedSize < 10_000_000 else { return nil }

    if magic == melalMagic {
        let start = 16
        let end = min(start + Int(uncompressedSize), data.count)
        guard start < end else { return nil }
        return String(data: data[start..<end], encoding: .ascii)
    }
    guard magic == lzfuMagic else { return nil }

    // LZFu uses a fixed 4-KB dictionary preloaded with a canonical RTF
    // preamble. The encoder writes back-references (offset, length)
    // pairs OR raw bytes; the control byte for each 8-symbol block
    // tells us which.
    let prebuf = "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
    var dict = Array(prebuf.utf8)
    dict.append(contentsOf: [UInt8](repeating: 0, count: max(0, 4096 - dict.count)))
    var dictWritePos = prebuf.utf8.count

    var output = Data()
    var pos = 16
    let endPos = min(Int(compressedSize) + 4, data.count)
    while pos < endPos && output.count < Int(uncompressedSize) {
        guard pos < data.count else { break }
        let control = data[pos]; pos += 1
        for bit in 0..<8 {
            guard pos < endPos && output.count < Int(uncompressedSize) else { break }
            if control & (1 << bit) != 0 {
                guard pos + 1 < data.count else { break }
                let hi = Int(data[pos])
                let lo = Int(data[pos + 1])
                pos += 2
                let offset = (hi << 4) | (lo >> 4)
                let length = (lo & 0x0F) + 2
                for j in 0..<length {
                    guard output.count < Int(uncompressedSize) else { break }
                    let byte = dict[(offset + j) % 4096]
                    output.append(byte)
                    dict[dictWritePos % 4096] = byte
                    dictWritePos += 1
                }
            } else {
                guard pos < data.count else { break }
                let byte = data[pos]; pos += 1
                output.append(byte)
                dict[dictWritePos % 4096] = byte
                dictWritePos += 1
            }
        }
    }
    guard let rtf = String(data: output, encoding: .ascii) else { return nil }
    // Strip the RTF control-word noise — we only want a text approximation.
    let stripped = rtf.replacingOccurrences(of: "\\\\[a-z]+[0-9]*\\s?", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "[{}]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.isEmpty ? nil : stripped
}
