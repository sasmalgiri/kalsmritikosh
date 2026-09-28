//
//  EVTXReader.swift
//  Kalsmritikosh
//
//  HOST-3 — reader for the Windows Event Log format (EVTX). Pure Swift,
//  read-only, no dependency.
//
//  Layout (Microsoft's published format, widely replicated):
//    - 4096-byte file header: "ElfFile\0", first/last chunk numbers, next record
//      id, version, chunk count, flags, CRC32.
//    - 65536-byte chunks from offset 4096: "ElfChnk\0", the record-number and
//      record-id ranges the chunk covers, a string table and a template table,
//      records from chunk offset 512.
//    - each record: magic 2a 2a 00 00, size, record id, written FILETIME, then
//      BinXML, then the size repeated as a trailer.
//
//  SCOPE, STATED PLAINLY. This reads the CONTAINER exactly — every record's id
//  and written time, and the UTF-16 strings its BinXML carries. It does NOT
//  resolve BinXML TEMPLATES, so a record's structured field names (EventID,
//  Provider, Channel, the named Data elements) are not recovered; the values are
//  harvested as an unlabelled set.
//
//  That boundary is deliberate, not an oversight. BinXML templates are
//  self-referential: a fixture writer correct enough to prove a template resolver
//  requires the same understanding as the resolver, so a shared misunderstanding
//  would pass its own tests. The container layer is fixed-offset and can be
//  verified against an independently-built fixture; the template layer cannot,
//  without a real .evtx to check against. So the container ships verified and the
//  parser SAYS what it could not interpret, rather than implying a full read.
//

import Foundation

public struct EVTXReader: Sendable {

    public struct Record: Sendable, Equatable {
        public let recordID: UInt64
        /// When Windows wrote the record. The one fact every record carries.
        public let written: Date?
        /// UTF-16 strings recovered from the record's BinXML. Unlabelled by
        /// design — see the scope note above.
        public let strings: [String]
        /// Byte offset in the file, so a record is citable at its exact location.
        public let fileOffset: Int
    }

    public enum ReaderError: Error, Sendable {
        case notAnEventLog
        case truncated
    }

    public let majorVersion: UInt16
    public let minorVersion: UInt16
    /// Chunk count the header DECLARES. Compared against what is present, since
    /// a log copied from a live system is routinely short.
    public let declaredChunkCount: Int
    public let nextRecordID: UInt64
    /// Whether the header's dirty flag is set — the log was open when copied, so
    /// the last chunk may be mid-write.
    public let isDirty: Bool
    public private(set) var problems: [String] = []

    private let data: Data

    /// Record ceiling. A busy Security.evtx holds hundreds of thousands; this is
    /// a citation surface, so it stops at a stated number.
    public nonisolated static let maxRecords = 100_000

    nonisolated static let fileSignature = Data("ElfFile\0".utf8)
    nonisolated static let chunkSignature = Data("ElfChnk\0".utf8)
    nonisolated static let recordMagic: [UInt8] = [0x2A, 0x2A, 0x00, 0x00]
    nonisolated static let headerSize = 4096
    nonisolated static let chunkSize = 65536
    nonisolated static let recordsOffsetInChunk = 512

    // MARK: - Init

    public init(data: Data) throws {
        guard data.count >= 4 else { throw ReaderError.truncated }
        guard data.prefix(8) == Self.fileSignature else { throw ReaderError.notAnEventLog }
        guard data.count >= Self.headerSize else { throw ReaderError.truncated }
        self.data = data
        self.minorVersion = Self.u16(data, 0x18) ?? 0
        self.majorVersion = Self.u16(data, 0x1A) ?? 0
        self.nextRecordID = Self.u64(data, 0x18 - 0x08) ?? 0   // 0x10: next record id
        self.declaredChunkCount = Int(Self.u16(data, 0x2A) ?? 0)
        let flags = Self.u32(data, 0x78) ?? 0
        self.isDirty = (flags & 0x0001) != 0

        let presentChunks = max(0, (data.count - Self.headerSize) / Self.chunkSize)
        if declaredChunkCount > presentChunks {
            problems.append("Header declares \(declaredChunkCount) chunk(s) but only "
                            + "\(presentChunks) are present — the log is truncated.")
        }
        if isDirty {
            problems.append("The log's dirty flag is set: it was open when copied, so the "
                            + "last chunk may be mid-write and its final records incomplete.")
        }
    }

    // MARK: - Records

    /// Every record the file's chunks contain, in file order. Chunks are walked
    /// by their fixed stride rather than by following the header's count, so a
    /// truncated or over-declared file still yields everything that is really there.
    public mutating func records() -> [Record] {
        var out: [Record] = []
        var chunkStart = Self.headerSize
        var chunkIndex = 0

        while chunkStart + Self.chunkSize <= data.count {
            defer { chunkStart += Self.chunkSize; chunkIndex += 1 }
            guard data.subdata(in: chunkStart..<(chunkStart + 8)) == Self.chunkSignature else {
                problems.append("Chunk \(chunkIndex) has no ElfChnk signature; skipped.")
                continue
            }
            // Records stop at the chunk's free-space offset. Reading past it would
            // read whatever the previous log left behind — stale bytes presented
            // as current records.
            let freeSpace = Int(Self.u32(data, chunkStart + 0x30) ?? 0)
            let limit = freeSpace > Self.recordsOffsetInChunk && freeSpace <= Self.chunkSize
                ? chunkStart + freeSpace
                : chunkStart + Self.chunkSize

            var offset = chunkStart + Self.recordsOffsetInChunk
            while offset + 24 <= limit {
                guard Array(data.subdata(in: offset..<(offset + 4))) == Self.recordMagic else { break }
                guard let size = Self.u32(data, offset + 4).map(Int.init),
                      size >= 24, offset + size <= limit else {
                    problems.append("Chunk \(chunkIndex) has a record with an impossible size "
                                    + "at offset \(offset); stopped reading this chunk.")
                    break
                }
                guard let recordID = Self.u64(data, offset + 8) else { break }
                let written = Self.filetime(data, offset + 16)

                // BinXML payload: after the 24-byte record header, before the
                // 4-byte size trailer.
                let payloadStart = offset + 24
                let payloadEnd = max(payloadStart, offset + size - 4)
                let strings = Self.utf16Strings(in: data, from: payloadStart, to: payloadEnd)

                out.append(Record(recordID: recordID, written: written,
                                  strings: strings, fileOffset: offset))
                if out.count >= Self.maxRecords {
                    problems.append("Stopped after \(Self.maxRecords) records; later records "
                                    + "have no individual citation.")
                    return out
                }
                offset += size
            }
        }

        if chunkStart < data.count, data.count - chunkStart > 0 {
            problems.append("A trailing partial chunk of \(data.count - chunkStart) byte(s) was "
                            + "not read: a chunk is \(Self.chunkSize) bytes and this one is "
                            + "incomplete.")
        }
        if out.isEmpty {
            problems.append("No records found. The file has a valid header but no readable "
                            + "record in any chunk.")
        }
        return out
    }

    // MARK: - UTF-16 harvest

    /// Recovers UTF-16LE strings from a byte range. BinXML stores element names
    /// and string values as length-prefixed UTF-16, and without template
    /// resolution the honest recovery is the set of strings themselves.
    ///
    /// A run must be at least `minimumCharacters` printable characters to count,
    /// which is what keeps binary GUIDs and integers from arriving as mojibake
    /// that looks like text.
    nonisolated static func utf16Strings(in data: Data, from start: Int, to end: Int,
                                         minimumCharacters: Int = 3) -> [String] {
        guard start >= 0, end <= data.count, start < end else { return [] }
        var results: [String] = []
        var seen = Set<String>()
        var units: [UInt16] = []

        func flush() {
            defer { units.removeAll(keepingCapacity: true) }
            guard units.count >= minimumCharacters else { return }
            let text = String(decoding: units, as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= minimumCharacters, seen.insert(text).inserted else { return }
            results.append(text)
        }

        var i = start
        while i + 1 < end {
            let unit = UInt16(data[data.startIndex + i]) | (UInt16(data[data.startIndex + i + 1]) << 8)
            // Printable BMP characters only; anything else ends the run.
            let scalar = UnicodeScalar(unit)
            let isPrintable = unit >= 0x20 && unit != 0x7F
                && scalar.map { !$0.properties.isDefaultIgnorableCodePoint } ?? false
                && unit < 0xD800   // never split a surrogate pair mid-run
            if isPrintable {
                units.append(unit)
            } else {
                flush()
            }
            i += 2
        }
        flush()
        return results
    }

    // MARK: - Primitives (all bounds-checked)

    private nonisolated static func u16(_ d: Data, _ at: Int) -> UInt16? {
        let i = d.startIndex + at
        guard at >= 0, i + 2 <= d.endIndex else { return nil }
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }
    private nonisolated static func u32(_ d: Data, _ at: Int) -> UInt32? {
        let i = d.startIndex + at
        guard at >= 0, i + 4 <= d.endIndex else { return nil }
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }
    private nonisolated static func u64(_ d: Data, _ at: Int) -> UInt64? {
        guard let lo = u32(d, at), let hi = u32(d, at + 4) else { return nil }
        return UInt64(lo) | (UInt64(hi) << 32)
    }

    /// FILETIME → Date. 100-nanosecond intervals since 1601-01-01 UTC. Zero means
    /// "not set", which is a real state and must not become 1601.
    private nonisolated static func filetime(_ d: Data, _ at: Int) -> Date? {
        guard let ticks = u64(d, at), ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }  // 1900…2100
        return Date(timeIntervalSince1970: seconds)
    }
}
