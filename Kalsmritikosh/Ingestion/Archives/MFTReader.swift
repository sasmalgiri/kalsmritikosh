//
//  MFTReader.swift
//  Kalsmritikosh
//
//  HOST-5 — reader for the NTFS Master File Table (`$MFT`). Pure Swift,
//  read-only, no dependency.
//
//  This is the single most valuable host artifact there is, because it survives
//  the files it describes. Every file and folder on an NTFS volume has an MFT
//  record holding its name, its size, its parent, and TWO independent sets of
//  created / modified / MFT-changed / accessed times. When a file is deleted the
//  record is only marked not-in-use — the name and the timestamps stay until the
//  record is reused. So `$MFT` answers "what was on this disk, and when", for
//  files that are no longer there.
//
//  Layout (each record `allocatedSize` bytes, usually 1024):
//    0x00 "FILE" (or "BAAD" for a record NTFS itself found corrupt)
//    0x04 offset of the update-sequence array, 0x06 its size in words
//    0x10 sequence number, 0x12 hard-link count
//    0x14 offset of the first attribute, 0x16 flags (0x01 in use, 0x02 directory)
//    0x18 used size, 0x1C allocated size, 0x20 base-record reference
//  then a chain of attributes, each with type + length, ending at 0xFFFFFFFF.
//
//  THE TRAP THIS READER MUST NOT FALL INTO — FIXUPS. NTFS overwrites the LAST
//  TWO BYTES OF EVERY 512-BYTE SECTOR of a record with an update-sequence
//  number, and stores the displaced originals in the update-sequence array. A
//  reader that does not put them back reads two corrupted bytes per sector, and
//  they land in the middle of timestamps and sizes for any field that straddles
//  a sector boundary. The corruption is silent: a plausible-looking wrong date.
//  `applyFixups` restores them before anything is parsed, and refuses the record
//  if the sector's placeholder does not match the expected sequence number,
//  because that means the record is a torn mix of two versions.
//
//  Read-only, deterministic, offline.
//

import Foundation

public struct MFTReader: Sendable {

    /// The four NTFS times, which exist TWICE per file: once in
    /// $STANDARD_INFORMATION and once in $FILE_NAME. Both are recorded, because
    /// the two disagreeing is itself a finding.
    public struct Timestamps: Sendable, Equatable {
        public let created: Date?
        public let modified: Date?
        /// When the MFT RECORD changed — not the file's content. Windows does
        /// not expose it, which is why it is the one an editor rarely forges.
        public let recordChanged: Date?
        public let accessed: Date?

        public var isEmpty: Bool {
            created == nil && modified == nil && recordChanged == nil && accessed == nil
        }
    }

    public struct FileName: Sendable, Equatable {
        /// 0 POSIX, 1 Win32, 2 DOS (8.3), 3 Win32 & DOS.
        public let namespace: UInt8
        public let name: String
        /// MFT record number of the containing directory.
        public let parentRecordNumber: UInt64
        /// The parent's sequence number. If the parent record's CURRENT sequence
        /// differs, that directory record has been reused and any path built
        /// through it is stale.
        public let parentSequenceNumber: UInt16
        public let timestamps: Timestamps
        public let allocatedSize: UInt64
        public let realSize: UInt64

        /// A DOS 8.3 name is a duplicate of the long name, not another file.
        public var isDOSOnly: Bool { namespace == 2 }
    }

    public struct Record: Sendable, Equatable {
        public let recordNumber: UInt64
        public let sequenceNumber: UInt16
        public let inUse: Bool
        public let isDirectory: Bool
        /// A record NTFS itself marked bad. Its contents are not trustworthy and
        /// are not reported as facts.
        public let isBAAD: Bool
        public let hardLinkCount: UInt16
        /// Set when this record extends another; its names belong to the base.
        public let baseRecordNumber: UInt64
        public let standardInformation: Timestamps?
        public let names: [FileName]
        /// Content of a RESIDENT $DATA attribute — the whole file, recovered
        /// from the MFT itself. Only small files are resident, which is exactly
        /// the case where the content is otherwise unrecoverable after deletion.
        public let residentData: Data?
        public let dataSizeBytes: UInt64?
        public let fileOffset: Int

        /// `deleted` is the forensically interesting state: the record still
        /// holds the name and the times.
        public var isDeleted: Bool { !inUse }

        /// The name to use: the long name, never the 8.3 duplicate.
        public var primaryName: String? {
            names.first(where: { !$0.isDOSOnly })?.name ?? names.first?.name
        }
    }

    public enum ReaderError: Error, Sendable {
        case notAnMFT
        case truncated
    }

    public nonisolated static let signature = Data("FILE".utf8)
    public nonisolated static let badSignature = Data("BAAD".utf8)
    public nonisolated static let sectorSize = 512
    /// Record ceiling. A real `$MFT` can hold millions; this is a citation
    /// surface, so it stops at a stated number.
    public nonisolated static let maxRecords = 250_000

    private nonisolated static let attrStandardInformation: UInt32 = 0x10
    private nonisolated static let attrFileName: UInt32 = 0x30
    private nonisolated static let attrData: UInt32 = 0x80
    private nonisolated static let attrEnd: UInt32 = 0xFFFF_FFFF

    public let recordSize: Int
    public private(set) var problems: [String] = []

    private let data: Data

    // MARK: - Init

    public init(data: Data) throws {
        guard data.count >= 4 else { throw ReaderError.truncated }
        guard data.prefix(4) == Self.signature else { throw ReaderError.notAnMFT }
        // The first record declares the size every record uses. 1024 is
        // near-universal; trusting the field rather than the constant is what
        // makes a 4096-byte-record volume readable.
        let declared = Int(Self.u32(data, 0x1C) ?? 0)
        let size = (declared >= 512 && declared <= 65_536 && declared % Self.sectorSize == 0)
            ? declared : 1024
        if declared != size {
            problems.append("The first record declares an allocated size of \(declared) bytes, "
                            + "which is not a valid record size; \(size) was assumed.")
        }
        self.recordSize = size
        self.data = data
        guard data.count >= size else { throw ReaderError.truncated }
    }

    /// Whether these bytes look like an MFT at all. Used only where the
    /// alternative is dropping the file as unknown: `$MFT` is extensionless and
    /// "FILE" is a weak signature on its own, so this also checks that the
    /// header's own offsets are self-consistent.
    public nonisolated static func looksLikeAnMFT(_ data: Data) -> Bool {
        guard data.count >= 1024, data.prefix(4) == signature else { return false }
        guard let firstAttribute = u16(data, 0x14).map(Int.init),
              let used = u32(data, 0x18).map(Int.init),
              let allocated = u32(data, 0x1C).map(Int.init),
              let usaOffset = u16(data, 0x04).map(Int.init) else { return false }
        return firstAttribute >= 0x2A && firstAttribute < allocated
            && used > firstAttribute && used <= allocated
            && allocated >= 512 && allocated % sectorSize == 0
            && usaOffset >= 0x2A && usaOffset < allocated
    }

    // MARK: - Records

    public mutating func records() -> [Record] {
        var out: [Record] = []
        var offset = 0
        var skipped = 0

        while offset + recordSize <= data.count {
            defer { offset += recordSize }
            let raw = data.subdata(in: offset..<(offset + recordSize))
            let head = raw.prefix(4)
            guard head == Self.signature || head == Self.badSignature else {
                // An all-zero slot is unused MFT space, which is normal and not
                // worth a warning. Anything else is unexpected.
                if raw.contains(where: { $0 != 0 }) { skipped += 1 }
                continue
            }
            let isBAAD = head == Self.badSignature

            guard let fixed = Self.applyFixups(raw) else {
                problems.append("The record at offset \(offset) failed its update-sequence check, "
                                + "so it is a torn mix of two versions; it was NOT read rather "
                                + "than reported with corrupted fields.")
                continue
            }
            if let record = Self.parse(fixed, fileOffset: offset, isBAAD: isBAAD) {
                out.append(record)
            }
            if out.count >= Self.maxRecords {
                problems.append("Stopped after \(Self.maxRecords) records; later records have no "
                                + "individual citation.")
                return out
            }
        }

        if skipped > 0 {
            problems.append("\(skipped) record slot(s) held data but no FILE/BAAD signature and "
                            + "were skipped.")
        }
        if data.count % recordSize != 0 {
            problems.append("A trailing partial record of \(data.count % recordSize) byte(s) was "
                            + "not read: a record is \(recordSize) bytes and this one is incomplete.")
        }
        if out.isEmpty {
            problems.append("No readable records: the file has an MFT signature but no record "
                            + "parsed.")
        }
        return out
    }

    // MARK: - Fixups

    /// Restore the bytes NTFS displaced with the update-sequence number. Returns
    /// nil when a sector's placeholder does not hold the expected number, which
    /// means the record was captured mid-write and its fields cannot be trusted.
    nonisolated static func applyFixups(_ record: Data) -> Data? {
        guard let usaOffset = u16(record, 0x04).map(Int.init),
              let usaWords = u16(record, 0x06).map(Int.init),
              usaWords >= 1, usaOffset + usaWords * 2 <= record.count else { return nil }
        guard let expected = u16(record, usaOffset) else { return nil }

        var out = [UInt8](record)
        // The first word is the sequence number itself; the rest are the
        // displaced originals, one per sector.
        for sector in 1..<usaWords {
            let target = sector * sectorSize - 2
            guard target + 2 <= out.count else { break }
            let placeholder = UInt16(out[target]) | (UInt16(out[target + 1]) << 8)
            guard placeholder == expected else { return nil }
            guard let original = u16(record, usaOffset + sector * 2) else { return nil }
            out[target] = UInt8(original & 0xFF)
            out[target + 1] = UInt8(original >> 8)
        }
        return Data(out)
    }

    // MARK: - One record

    private nonisolated static func parse(_ d: Data, fileOffset: Int, isBAAD: Bool) -> Record? {
        let flags = u16(d, 0x16) ?? 0
        let recordNumber = UInt64(u32(d, 0x2C) ?? 0)
        let sequenceNumber = u16(d, 0x10) ?? 0
        let baseReference = u64(d, 0x20) ?? 0
        let usedSize = Int(u32(d, 0x18) ?? 0)
        let limit = min(usedSize > 0 ? usedSize : d.count, d.count)

        var standard: Timestamps?
        var names: [FileName] = []
        var residentData: Data?
        var dataSize: UInt64?

        var offset = Int(u16(d, 0x14) ?? 0x38)
        var guardCount = 0
        while offset + 8 <= limit, guardCount < 64 {
            guardCount += 1
            guard let type = u32(d, offset) else { break }
            if type == attrEnd { break }
            guard let length = u32(d, offset + 4).map(Int.init), length >= 24,
                  offset + length <= limit else { break }
            let nonResident = d[d.startIndex + offset + 8] != 0

            if !nonResident,
               let contentLength = u32(d, offset + 0x10).map(Int.init),
               let contentOffset = u16(d, offset + 0x14).map(Int.init),
               contentLength >= 0, offset + contentOffset + contentLength <= limit {
                let start = offset + contentOffset
                let content = d.subdata(in: start..<(start + contentLength))
                switch type {
                case attrStandardInformation:
                    standard = timestamps(content, at: 0)
                case attrFileName:
                    if let name = fileName(content) { names.append(name) }
                case attrData:
                    // A small file's entire content lives here. After deletion
                    // this is often the only copy left anywhere.
                    if !isBAAD, !content.isEmpty { residentData = content }
                    dataSize = UInt64(contentLength)
                default:
                    break
                }
            } else if nonResident, type == attrData {
                // Non-resident: the content is out on the volume, which this
                // artifact does not contain. The SIZE is still recorded here.
                dataSize = u64(d, offset + 0x30)
            }
            offset += length
        }

        return Record(
            recordNumber: recordNumber, sequenceNumber: sequenceNumber,
            inUse: (flags & 0x0001) != 0, isDirectory: (flags & 0x0002) != 0,
            isBAAD: isBAAD, hardLinkCount: u16(d, 0x12) ?? 0,
            baseRecordNumber: baseReference & 0x0000_FFFF_FFFF_FFFF,
            standardInformation: standard, names: names,
            residentData: residentData, dataSizeBytes: dataSize, fileOffset: fileOffset)
    }

    private nonisolated static func fileName(_ content: Data) -> FileName? {
        guard content.count >= 0x42 else { return nil }
        let parentReference = u64(content, 0) ?? 0
        let characters = Int(content[content.startIndex + 0x40])
        let namespace = content[content.startIndex + 0x41]
        let byteCount = characters * 2
        guard characters > 0, 0x42 + byteCount <= content.count else { return nil }
        var units: [UInt16] = []
        for index in 0..<characters {
            let i = content.startIndex + 0x42 + index * 2
            units.append(UInt16(content[i]) | (UInt16(content[i + 1]) << 8))
        }
        let name = String(decoding: units, as: UTF16.self)
        guard !name.isEmpty else { return nil }
        return FileName(
            namespace: namespace, name: name,
            parentRecordNumber: parentReference & 0x0000_FFFF_FFFF_FFFF,
            parentSequenceNumber: UInt16(truncatingIfNeeded: parentReference >> 48),
            timestamps: timestamps(content, at: 0x08),
            allocatedSize: u64(content, 0x28) ?? 0,
            realSize: u64(content, 0x30) ?? 0)
    }

    private nonisolated static func timestamps(_ d: Data, at base: Int) -> Timestamps {
        Timestamps(created: filetime(d, base),
                   modified: filetime(d, base + 8),
                   recordChanged: filetime(d, base + 16),
                   accessed: filetime(d, base + 24))
    }

    // MARK: - Path reconstruction

    /// Full paths, built by walking parent references. DELIBERATELY reports
    /// uncertainty: a parent whose sequence number no longer matches has had its
    /// record REUSED by a different directory, so the path built through it is
    /// stale — a real and common state for deleted files, and one that would
    /// otherwise produce a confident wrong path.
    public nonisolated static func paths(for records: [Record]) -> [UInt64: PathResult] {
        var byNumber: [UInt64: Record] = [:]
        for record in records where record.baseRecordNumber == 0 {
            byNumber[record.recordNumber] = record
        }
        var resolved: [UInt64: PathResult] = [:]

        func resolve(_ number: UInt64, _ visiting: inout Set<UInt64>) -> PathResult {
            if let cached = resolved[number] { return cached }
            guard let record = byNumber[number], let name = record.primaryName else {
                return PathResult(path: nil, certainty: .parentMissing)
            }
            // Record 5 is the volume root, named ".".
            if number == 5 { return PathResult(path: "", certainty: .certain) }
            guard let nameEntry = record.names.first(where: { !$0.isDOSOnly }) ?? record.names.first
            else { return PathResult(path: nil, certainty: .parentMissing) }

            guard visiting.insert(number).inserted else {
                return PathResult(path: nil, certainty: .cycle)
            }
            defer { visiting.remove(number) }

            let parentNumber = nameEntry.parentRecordNumber
            var certainty: PathCertainty = .certain
            var prefix = ""
            if parentNumber == number {
                certainty = .cycle
            } else if let parent = byNumber[parentNumber] {
                if parent.sequenceNumber != nameEntry.parentSequenceNumber {
                    // The parent slot now belongs to something else.
                    certainty = .parentReused
                }
                let parentResult = resolve(parentNumber, &visiting)
                if let parentPath = parentResult.path {
                    prefix = parentPath
                    if parentResult.certainty != .certain { certainty = parentResult.certainty }
                } else {
                    certainty = parentResult.certainty
                }
            } else {
                certainty = .parentMissing
            }
            let path = prefix.isEmpty ? "\\" + name : prefix + "\\" + name
            let result = PathResult(path: path, certainty: certainty)
            resolved[number] = result
            return result
        }

        for number in byNumber.keys {
            var visiting = Set<UInt64>()
            resolved[number] = resolve(number, &visiting)
        }
        return resolved
    }

    public enum PathCertainty: String, Sendable {
        case certain
        /// A directory in the chain has been reused by another directory, so the
        /// path is what the record SAYS but no longer where the file was.
        case parentReused
        /// The parent's record is not in this extraction at all.
        case parentMissing
        case cycle
    }

    public struct PathResult: Sendable, Equatable {
        public let path: String?
        public let certainty: PathCertainty
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

    /// FILETIME → Date. Zero means "not recorded", which is a real state and
    /// must never become 1601.
    private nonisolated static func filetime(_ d: Data, _ at: Int) -> Date? {
        guard let ticks = u64(d, at), ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
