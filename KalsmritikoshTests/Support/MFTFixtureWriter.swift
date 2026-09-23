//
//  MFTFixtureWriter.swift
//  KalsmritikoshTests
//
//  HOST-5 test support — writes real NTFS MFT records.
//
//  Built from the published record and attribute layout, and crucially it
//  APPLIES THE FIXUPS the way NTFS does: after the record is assembled, the last
//  two bytes of every 512-byte sector are moved into the update-sequence array
//  and replaced by the sequence number. A fixture that skipped that step would
//  let a reader which ignores fixups pass, and fixups are the one thing in this
//  format that corrupts data silently.
//

import Foundation
@testable import Kalsmritikosh

struct MFTFixtureWriter {

    struct Times {
        var created: Date?
        var modified: Date?
        var recordChanged: Date?
        var accessed: Date?

        static func all(_ date: Date) -> Times {
            Times(created: date, modified: date, recordChanged: date, accessed: date)
        }
    }

    struct FileRecord {
        var recordNumber: UInt32
        var sequenceNumber: UInt16 = 1
        var name: String
        /// 0 POSIX, 1 Win32, 2 DOS 8.3, 3 Win32 & DOS.
        var namespace: UInt8 = 1
        var parentRecordNumber: UInt64 = 5
        var parentSequenceNumber: UInt16 = 1
        var inUse = true
        var isDirectory = false
        var isBAAD = false
        var hardLinkCount: UInt16 = 1
        var standardTimes: Times = .init()
        /// When set, written into $FILE_NAME instead of `standardTimes` — which
        /// is how a record ends up with two disagreeing sets.
        var fileNameTimes: Times?
        var realSize: UInt64 = 0
        /// Content stored INSIDE the record, as NTFS does for small files.
        var residentData: Data?
        /// Emit a non-resident $DATA that only declares a size.
        var nonResidentSize: UInt64?
        /// Base record reference — non-zero marks this an extension record.
        var baseRecordNumber: UInt64 = 0
        /// Break the fixup check: leave a sector placeholder that does not match
        /// the sequence number, which is what a torn record looks like.
        var corruptFixup = false
    }

    var recordSize = 1024

    func build(records: [FileRecord]) -> Data {
        var out = Data()
        for record in records { out += encode(record) }
        return out
    }

    /// An empty (never-used) record slot, which real MFTs are full of.
    func emptySlot() -> Data { Data(repeating: 0, count: recordSize) }

    // MARK: - One record

    func encode(_ record: FileRecord) -> Data {
        let sectors = recordSize / MFTReader.sectorSize
        let usaOffset = 0x30
        let usaWords = sectors + 1                     // sequence number + one per sector
        let firstAttribute = usaOffset + usaWords * 2 + ((usaWords * 2) % 8 == 0 ? 0 : 8 - (usaWords * 2) % 8)

        var attributes = Data()
        attributes += standardInformation(record)
        attributes += fileNameAttribute(record)
        if let resident = record.residentData {
            attributes += residentDataAttribute(resident)
        } else if let size = record.nonResidentSize {
            attributes += nonResidentDataAttribute(size)
        }
        attributes += Self.u32(0xFFFF_FFFF)            // end-of-attributes marker
        attributes += Self.u32(0)

        let usedSize = firstAttribute + attributes.count
        precondition(usedSize <= recordSize, "fixture record overflows \(recordSize) bytes")

        var header = Data(record.isBAAD ? "BAAD".utf8 : "FILE".utf8)
        header += Self.u16(UInt16(usaOffset))          // 0x04 update-sequence offset
        header += Self.u16(UInt16(usaWords))           // 0x06 its size in words
        header += Self.u64(0)                          // 0x08 $LogFile sequence number
        header += Self.u16(record.sequenceNumber)      // 0x10
        header += Self.u16(record.hardLinkCount)       // 0x12
        header += Self.u16(UInt16(firstAttribute))     // 0x14
        var flags: UInt16 = 0
        if record.inUse { flags |= 0x0001 }
        if record.isDirectory { flags |= 0x0002 }
        header += Self.u16(flags)                      // 0x16
        header += Self.u32(UInt32(usedSize))           // 0x18
        header += Self.u32(UInt32(recordSize))         // 0x1C
        header += Self.u64(record.baseRecordNumber)    // 0x20
        header += Self.u16(0)                          // 0x28 next attribute id
        header += Self.u16(0)                          // 0x2A padding
        header += Self.u32(record.recordNumber)        // 0x2C
        precondition(header.count == 0x30)

        var bytes = [UInt8](header)
        bytes += [UInt8](repeating: 0, count: firstAttribute - bytes.count)
        bytes += [UInt8](attributes)
        bytes += [UInt8](repeating: 0, count: recordSize - bytes.count)

        // FIXUPS, exactly as NTFS applies them: the last two bytes of each
        // sector move into the update-sequence array, and the sequence number
        // takes their place.
        let usn = record.sequenceNumber
        var usa: [UInt16] = [usn]
        for sector in 1...sectors {
            let target = sector * MFTReader.sectorSize - 2
            let original = UInt16(bytes[target]) | (UInt16(bytes[target + 1]) << 8)
            usa.append(original)
            let placeholder = record.corruptFixup && sector == sectors ? usn ^ 0xFFFF : usn
            bytes[target] = UInt8(placeholder & 0xFF)
            bytes[target + 1] = UInt8(placeholder >> 8)
        }
        for (index, word) in usa.enumerated() {
            let at = usaOffset + index * 2
            bytes[at] = UInt8(word & 0xFF)
            bytes[at + 1] = UInt8(word >> 8)
        }
        return Data(bytes)
    }

    // MARK: - Attributes

    private func standardInformation(_ record: FileRecord) -> Data {
        var content = Data()
        content += Self.filetime(record.standardTimes.created)
        content += Self.filetime(record.standardTimes.modified)
        content += Self.filetime(record.standardTimes.recordChanged)
        content += Self.filetime(record.standardTimes.accessed)
        content += Self.u32(0)                          // DOS permissions
        content += Data(repeating: 0, count: 0x30 - content.count)
        return residentAttribute(type: 0x10, content: content)
    }

    private func fileNameAttribute(_ record: FileRecord) -> Data {
        let times = record.fileNameTimes ?? record.standardTimes
        var content = Data()
        let parentReference = (record.parentRecordNumber & 0x0000_FFFF_FFFF_FFFF)
            | (UInt64(record.parentSequenceNumber) << 48)
        content += Self.u64(parentReference)            // 0x00
        content += Self.filetime(times.created)         // 0x08
        content += Self.filetime(times.modified)        // 0x10
        content += Self.filetime(times.recordChanged)   // 0x18
        content += Self.filetime(times.accessed)        // 0x20
        content += Self.u64(record.realSize)            // 0x28 allocated
        content += Self.u64(record.realSize)            // 0x30 real
        content += Self.u32(0)                          // 0x38 flags
        content += Self.u32(0)                          // 0x3C reparse
        let units = Array(record.name.utf16)
        content += Data([UInt8(units.count), record.namespace])   // 0x40, 0x41
        for unit in units { content += Self.u16(unit) }
        return residentAttribute(type: 0x30, content: content)
    }

    private func residentDataAttribute(_ content: Data) -> Data {
        residentAttribute(type: 0x80, content: content)
    }

    private func residentAttribute(type: UInt32, content: Data) -> Data {
        let contentOffset = 0x18
        var padded = contentOffset + content.count
        if padded % 8 != 0 { padded += 8 - padded % 8 }

        var out = Data()
        out += Self.u32(type)                           // 0x00
        out += Self.u32(UInt32(padded))                 // 0x04 length
        out += Data([0, 0])                             // 0x08 resident, no name
        out += Self.u16(0)                              // 0x0A name offset
        out += Self.u16(0)                              // 0x0C flags
        out += Self.u16(0)                              // 0x0E attribute id
        out += Self.u32(UInt32(content.count))          // 0x10 content length
        out += Self.u16(UInt16(contentOffset))          // 0x14 content offset
        out += Self.u16(0)                              // 0x16 indexed flag
        precondition(out.count == contentOffset)
        out += content
        out += Data(repeating: 0, count: padded - out.count)
        return out
    }

    private func nonResidentDataAttribute(_ realSize: UInt64) -> Data {
        var out = Data()
        out += Self.u32(0x80)                           // type
        out += Self.u32(0x48)                           // length
        out += Data([1, 0])                             // non-resident
        out += Self.u16(0)                              // name offset
        out += Self.u16(0)                              // flags
        out += Self.u16(0)                              // attribute id
        out += Self.u64(0)                              // 0x10 start VCN
        out += Self.u64(0)                              // 0x18 last VCN
        out += Self.u16(0x40)                           // 0x20 data-run offset
        out += Self.u16(0)                              // 0x22 compression unit
        out += Self.u32(0)                              // 0x24 padding
        out += Self.u64(realSize)                       // 0x28 allocated size
        out += Self.u64(realSize)                       // 0x30 real size
        out += Self.u64(realSize)                       // 0x38 initialized size
        out += Data(repeating: 0, count: 0x48 - out.count)
        return out
    }

    // MARK: - Primitives

    private static func u16(_ v: UInt16) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u32(_ v: UInt32) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func u64(_ v: UInt64) -> Data {
        var le = v.littleEndian; return withUnsafeBytes(of: &le) { Data($0) }
    }
    private static func filetime(_ date: Date?) -> Data {
        guard let date else { return Data(repeating: 0, count: 8) }
        let ticks = UInt64((date.timeIntervalSince1970 + 11_644_473_600.0) * 10_000_000.0)
        return u64(ticks)
    }
}
