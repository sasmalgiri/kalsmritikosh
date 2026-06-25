//
//  PSTReader.swift
//  Kalsmritikosh
//
//  Microsoft Outlook PST/OST native parser. Walks the NDB (Node /
//  Block) B-trees, decodes the encrypted OST cyclic / permute streams
//  when needed, and parses each message's property context into a
//  MAPIPropertySet (the same type used by the .msg / OLE2 reader).
//
//  Ported from the sibling mailin/PSTParser. Wire format follows
//  Microsoft's [MS-PST] spec: 4-byte "!BDN" magic, version 23+ for
//  Unicode-mode files (older ANSI mode is also supported). OST uses
//  the same format plus a per-block symmetric encryption layer.
//

import Foundation
import OSLog

/// Single-thread (synchronous) reader for a Microsoft PST/OST archive.
/// Construct, call `readAllMessages`, done.
public nonisolated struct PSTReader: Sendable {
    private let data: Data
    private let isUnicode: Bool
    private let isOST: Bool
    private let encType: UInt8

    private static let maxBTreeDepth = 25
    private static let maxChainLength = 100_000
    private static let log = Logger(subsystem: "kalsmritikosh", category: "PSTReader")

    /// One parsed message — mirrors the subset of MAPI properties the
    /// email pipeline cares about (headers + body + threading + flags).
    public struct PSTMessage: Sendable {
        public var subject: String = ""
        public var senderName: String = ""
        public var senderEmail: String = ""
        public var displayTo: String = ""
        public var displayCc: String = ""
        public var displayBcc: String = ""
        public var bodyText: String = ""
        public var bodyHTML: String = ""
        public var internetMessageId: String?
        public var inReplyToId: String?
        public var references: String?
        public var replyToAddress: String?
        public var contentType: String?
        public var conversationTopic: String?
        public var importance: UInt32?
        public var sensitivity: UInt32?
        public var transportHeaders: String = ""
        public var deliveryTime: Date?
        public var creationTime: Date?
        public var lastModificationTime: Date?
        public var folderPath: String = ""
        public var hasAttachments: Bool = false
        public var messageSize: Int = 0
    }

    public struct NodeEntry: Sendable {
        public let nid: UInt32
        public let dataBid: UInt64
        public let subBid: UInt64
    }

    public struct BlockEntry: Sendable {
        public let bid: UInt64
        public let offset: UInt64
        public let size: UInt16
    }

    public enum PSTError: Error, Sendable {
        case invalidFormat(String)
        case blockNotFound
    }

    public init(data: Data) throws {
        guard data.count >= 564 else {
            throw PSTError.invalidFormat("File too small (\(data.count) bytes, need 564+)")
        }
        let magic = data[0..<4]
        guard magic == Data([0x21, 0x42, 0x44, 0x4E]) else {
            throw PSTError.invalidFormat("Not a PST/OST file (bad magic: !BDN expected)")
        }
        self.data = data

        let contentType = Self.readUInt16(data, offset: 8)
        self.isOST = contentType == 0x0024

        let version = Self.readUInt16(data, offset: 10)
        self.isUnicode = version >= 23

        self.encType = data[513]
        if isOST && encType != 0x00 && encType != 0x01 && encType != 0x02 {
            throw PSTError.invalidFormat("Unsupported OST encryption type: \(encType)")
        }
    }

    /// Walk the node B-tree, then for each NID whose low 5 bits indicate
    /// a regular message (0x0C), parse its property context. Errors on
    /// individual messages are logged and skipped — the goal is to
    /// surface as many readable messages as possible from a possibly
    /// corrupt archive.
    public func readAllMessages() throws -> [PSTMessage] {
        let nodeEntries = readNodeBTree()
        let blockEntries = readBlockBTree()

        let messageNodes = nodeEntries.filter { ($0.nid & 0x1F) == 0x0C }

        var messages: [PSTMessage] = []
        for node in messageNodes {
            do {
                let msg = try readMessage(node: node, blockEntries: blockEntries)
                messages.append(msg)
            } catch {
                Self.log.warning("PSTReader skipping NID \(node.nid, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return messages
    }

    // MARK: - NDB (Node + Block) B-tree readers

    private func readNodeBTree() -> [NodeEntry] {
        let rootOffset: Int = isUnicode
            ? Int(Self.readUInt64(data, offset: 224))
            : Int(Self.readUInt32(data, offset: 188))
        guard rootOffset > 0 && rootOffset < data.count else { return [] }
        return readNodeBTreePage(at: rootOffset, depth: 0)
    }

    private func readNodeBTreePage(at offset: Int, depth: Int) -> [NodeEntry] {
        guard depth < Self.maxBTreeDepth else { return [] }
        guard offset >= 0 && offset + 512 <= data.count else { return [] }

        let pageType = data[offset + 496]
        let entryCount = min(Int(data[offset + 488]), 40)

        if pageType == 0x81 {
            // Leaf — actual NodeEntry records.
            var entries: [NodeEntry] = []
            entries.reserveCapacity(entryCount)
            for i in 0..<entryCount {
                let base = offset + i * (isUnicode ? 32 : 16)
                guard base + (isUnicode ? 32 : 16) <= data.count else { break }
                if isUnicode {
                    let nid = Self.readUInt32(data, offset: base)
                    let dataBid = Self.readUInt64(data, offset: base + 8)
                    let subBid = Self.readUInt64(data, offset: base + 16)
                    entries.append(NodeEntry(nid: nid, dataBid: dataBid, subBid: subBid))
                } else {
                    let nid = Self.readUInt32(data, offset: base)
                    let dataBid = UInt64(Self.readUInt32(data, offset: base + 4))
                    let subBid = UInt64(Self.readUInt32(data, offset: base + 8))
                    entries.append(NodeEntry(nid: nid, dataBid: dataBid, subBid: subBid))
                }
            }
            return entries
        } else if pageType == 0x80 {
            // Internal — recurse into each child offset.
            var entries: [NodeEntry] = []
            for i in 0..<entryCount {
                let childOffset: Int
                if isUnicode {
                    let base = offset + i * 24
                    guard base + 24 <= data.count else { break }
                    childOffset = Int(Self.readUInt64(data, offset: base + 16))
                } else {
                    let base = offset + i * 12
                    guard base + 12 <= data.count else { break }
                    childOffset = Int(Self.readUInt32(data, offset: base + 8))
                }
                entries.append(contentsOf: readNodeBTreePage(at: childOffset, depth: depth + 1))
            }
            return entries
        }
        return []
    }

    private func readBlockBTree() -> [UInt64: BlockEntry] {
        let rootOffset: Int = isUnicode
            ? Int(Self.readUInt64(data, offset: 240))
            : Int(Self.readUInt32(data, offset: 196))
        guard rootOffset > 0 && rootOffset < data.count else { return [:] }
        var result: [UInt64: BlockEntry] = [:]
        for entry in readBlockBTreePage(at: rootOffset, depth: 0) {
            result[entry.bid] = entry
        }
        return result
    }

    private func readBlockBTreePage(at offset: Int, depth: Int) -> [BlockEntry] {
        guard depth < Self.maxBTreeDepth else { return [] }
        guard offset >= 0 && offset + 512 <= data.count else { return [] }

        let pageType = data[offset + 496]
        let entryCount = min(Int(data[offset + 488]), 40)

        if pageType == 0x82 {
            var entries: [BlockEntry] = []
            entries.reserveCapacity(entryCount)
            for i in 0..<entryCount {
                if isUnicode {
                    let base = offset + i * 24
                    guard base + 24 <= data.count else { break }
                    let bid = Self.readUInt64(data, offset: base)
                    let blockOffset = Self.readUInt64(data, offset: base + 8)
                    let size = Self.readUInt16(data, offset: base + 16)
                    entries.append(BlockEntry(bid: bid, offset: blockOffset, size: size))
                } else {
                    let base = offset + i * 12
                    guard base + 12 <= data.count else { break }
                    let bid = UInt64(Self.readUInt32(data, offset: base))
                    let blockOffset = UInt64(Self.readUInt32(data, offset: base + 4))
                    let size = Self.readUInt16(data, offset: base + 8)
                    entries.append(BlockEntry(bid: bid, offset: blockOffset, size: size))
                }
            }
            return entries
        } else if pageType == 0x83 {
            var entries: [BlockEntry] = []
            for i in 0..<entryCount {
                let childOffset: Int
                if isUnicode {
                    let base = offset + i * 24
                    guard base + 24 <= data.count else { break }
                    childOffset = Int(Self.readUInt64(data, offset: base + 16))
                } else {
                    let base = offset + i * 12
                    guard base + 12 <= data.count else { break }
                    childOffset = Int(Self.readUInt32(data, offset: base + 8))
                }
                entries.append(contentsOf: readBlockBTreePage(at: childOffset, depth: depth + 1))
            }
            return entries
        }
        return []
    }

    // MARK: - Message reader

    private func readMessage(node: NodeEntry, blockEntries: [UInt64: BlockEntry]) throws -> PSTMessage {
        guard let block = blockEntries[node.dataBid] else { throw PSTError.blockNotFound }
        let blockData = readBlockData(block)
        let props = parsePropertyContext(blockData)

        var msg = PSTMessage()
        msg.subject = props.strings[0x0037] ?? ""
        msg.senderName = props.strings[0x0C1A] ?? props.strings[0x0042] ?? ""
        // Outlook stores SMTP under 0x0C1F first, then 0x0065, then 0x0076.
        // The earlier 0x0042 is the legacy Exchange name, NOT an SMTP
        // address, so it stays out of the SMTP fallback list.
        msg.senderEmail = props.strings[0x0C1F] ?? props.strings[0x0065] ?? props.strings[0x0076] ?? ""
        msg.displayTo = props.strings[0x0E04] ?? ""
        msg.displayCc = props.strings[0x0E03] ?? ""
        msg.displayBcc = props.strings[0x0E02] ?? ""
        msg.replyToAddress = props.strings[0x0050]

        msg.bodyText = props.strings[0x1000] ?? ""
        if let htmlData = props.binaries[0x1013] {
            msg.bodyHTML = String(data: htmlData, encoding: .utf8)
                ?? String(data: htmlData, encoding: .ascii)
                ?? ""
        }
        if msg.bodyHTML.isEmpty, let htmlStr = props.strings[0x1013] {
            msg.bodyHTML = htmlStr
        }

        msg.internetMessageId = props.strings[0x1035]
        msg.inReplyToId = props.strings[0x1042]
        msg.references = props.strings[0x1039]
        msg.conversationTopic = props.strings[0x0070]
        msg.transportHeaders = props.strings[0x007D] ?? ""
        msg.contentType = props.strings[0x001A]

        msg.deliveryTime = props.dates[0x0E06]
        msg.creationTime = props.dates[0x3007]
        msg.lastModificationTime = props.dates[0x3008]

        msg.importance = props.ints[0x0017]
        msg.sensitivity = props.ints[0x0036]
        if let flags = props.ints[0x0E07] {
            msg.hasAttachments = (flags & 0x10) != 0
        }
        if let size = props.ints[0x0E08] {
            msg.messageSize = Int(size)
        }
        return msg
    }

    // MARK: - Block data + OST decryption

    private func readBlockData(_ block: BlockEntry) -> Data {
        let offset = Int(block.offset)
        let size = Int(block.size)
        guard offset >= 0 && size >= 0 && offset + size <= data.count else { return Data() }

        var blockData = Data(data[offset..<(offset + size)])
        if isOST {
            if encType == 0x01 {
                blockData = Data(blockData.map { Self.decodePermute($0) })
            } else if encType == 0x02 {
                blockData = Data(blockData.map { $0 ^ 0xA5 })
            }
        }
        return blockData
    }

    // MARK: - Property-context parser

    private func parsePropertyContext(_ data: Data) -> MAPIPropertySet {
        var props = MAPIPropertySet()
        guard data.count >= 8 else { return props }

        let heapType = data.count > 3 ? data[3] : 0
        // 0xBC == PC heap; 0x7C == TC heap. Anything else means this
        // block isn't a property context and we'd emit junk.
        guard heapType == 0xBC || heapType == 0x7C else { return props }

        var offset = 8
        let entrySize = 8
        while offset + entrySize <= data.count {
            let propID = Self.readUInt16(data, offset: offset)
            let propType = Self.readUInt16(data, offset: offset + 2)

            switch propType {
            case 0x001F, 0x001E:
                // String — value is an indirect offset into the same block.
                let valueRef = Self.readUInt32(data, offset: offset + 4)
                let strOffset = Int(valueRef)
                if strOffset > 0 && strOffset < data.count {
                    let remaining = data[strOffset...]
                    let maxLen = min(remaining.count, 4096)
                    let chunk = Data(remaining.prefix(maxLen))
                    if propType == 0x001F {
                        if let str = String(data: chunk, encoding: .utf16LittleEndian) {
                            props.strings[propID] = str.components(separatedBy: "\0").first ?? str
                        }
                    } else {
                        if let str = String(data: chunk, encoding: .utf8)
                            ?? String(data: chunk, encoding: .ascii) {
                            props.strings[propID] = str.components(separatedBy: "\0").first ?? str
                        }
                    }
                }
            case 0x0102:
                // Binary blob.
                let valueRef = Self.readUInt32(data, offset: offset + 4)
                let binOffset = Int(valueRef)
                if binOffset > 0 && binOffset < data.count {
                    let maxSize = min(data.count - binOffset, 10_485_760)
                    props.binaries[propID] = Data(data[binOffset...].prefix(maxSize))
                }
            case 0x0040:
                // PT_SYSTIME — Windows FILETIME inline.
                if offset + 12 <= data.count {
                    let fileTime = Self.readUInt64(data, offset: offset + 4)
                    if fileTime > 0 {
                        let seconds = Double(fileTime) / 10_000_000.0 - 11_644_473_600.0
                        // Sanity-clamp: anything before 1970 or after
                        // year ~2100 is almost certainly a corrupt
                        // value and would poison the timeline.
                        if seconds > 0 && seconds < 4_102_444_800 {
                            props.dates[propID] = Date(timeIntervalSince1970: seconds)
                        }
                    }
                }
            case 0x0003:
                // PT_LONG.
                if offset + 8 <= data.count {
                    props.ints[propID] = Self.readUInt32(data, offset: offset + 4)
                }
            default:
                break
            }
            offset += entrySize
        }
        return props
    }

    // MARK: - Static helpers (binary reads + OST permute table)

    nonisolated static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset >= 0 && offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset >= 0 && offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    nonisolated static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        guard offset >= 0 && offset + 8 <= data.count else { return 0 }
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(data[offset + i]) << (i * 8)
        }
        return result
    }

    /// Outlook's "compressible encryption" permute table — fixed
    /// 256-byte LUT documented in [MS-PST] §5.1. OST files with
    /// encType == 0x01 push every block byte through this table.
    private static func decodePermute(_ byte: UInt8) -> UInt8 {
        permuteTable[Int(byte)]
    }

    private static let permuteTable: [UInt8] = [
        65, 54, 19, 98, 168, 33, 110, 187, 244, 22, 204, 4, 127, 100, 232, 93,
        30, 242, 203, 42, 116, 197, 94, 53, 210, 149, 71, 158, 150, 45, 154, 136,
        76, 125, 132, 63, 219, 172, 49, 182, 72, 95, 246, 196, 216, 57, 139, 231,
        35, 59, 56, 142, 200, 193, 223, 37, 177, 32, 165, 70, 96, 78, 156, 251,
        170, 211, 86, 81, 69, 124, 85, 0, 7, 201, 43, 157, 133, 155, 9, 160,
        143, 173, 179, 15, 99, 171, 137, 75, 215, 167, 21, 90, 113, 102, 66, 191,
        38, 74, 107, 152, 250, 234, 119, 83, 178, 112, 5, 44, 253, 89, 58, 134,
        126, 206, 6, 235, 130, 120, 87, 199, 141, 67, 175, 180, 28, 212, 91, 205,
        62, 128, 135, 174, 52, 79, 40, 41, 20, 13, 29, 117, 28, 51, 68, 146,
        184, 82, 88, 236, 190, 164, 138, 163, 46, 73, 248, 121, 46, 115, 189, 145,
        17, 11, 60, 145, 131, 108, 159, 24, 31, 14, 230, 12, 151, 176, 227, 213,
        174, 218, 252, 153, 106, 109, 249, 105, 195, 2, 181, 198, 148, 207, 254, 166,
        247, 103, 123, 55, 48, 129, 226, 161, 144, 255, 101, 192, 36, 239, 50, 97,
        114, 162, 64, 77, 26, 10, 169, 228, 111, 104, 183, 118, 84, 8, 47, 147,
        240, 122, 233, 16, 221, 243, 237, 208, 245, 186, 25, 238, 188, 23, 220, 34,
        229, 39, 3, 140, 1, 92, 217, 209, 80, 241, 214, 61, 222, 18, 224, 27
    ]
}
