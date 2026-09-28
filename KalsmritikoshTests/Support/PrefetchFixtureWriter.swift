//
//  PrefetchFixtureWriter.swift
//  KalsmritikoshTests
//
//  HOST-6d test support — writes real Windows prefetch files.
//
//  Built by placing each field at its documented offset for the three
//  UNCOMPRESSED generations, independently of how PrefetchReader walks them.
//  It can also emit a Windows 10 MAM container, so the reader's refusal to
//  half-read a compressed file is tested rather than assumed.
//

import Foundation
@testable import Kalsmritikosh

struct PrefetchFixtureWriter {

    var version: PrefetchReader.Version = .win8
    var executableName = "POWERSHELL.EXE"
    var pathHash: UInt32 = 0x1A2B_3C4D
    var runCount: UInt32 = 1
    /// Newest first, as the format stores them. Fewer than the format's
    /// capacity leaves the remaining slots zero — padding, not 1601 runs.
    var runTimes: [Date] = []

    func build() -> Data {
        // Large enough for every version's information block.
        var bytes = [UInt8](repeating: 0, count: 0x100)

        func put32(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        }
        func put64(_ value: UInt64, at offset: Int) {
            for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * UInt64(i))) & 0xFF) }
        }
        func filetime(_ date: Date) -> UInt64 {
            UInt64((date.timeIntervalSince1970 + 11_644_473_600.0) * 10_000_000.0)
        }

        put32(version.rawValue, at: 0x00)
        for (i, b) in Array("SCCA".utf8).enumerated() { bytes[4 + i] = b }
        put32(UInt32(bytes.count), at: 0x0C)

        for (i, unit) in Array(executableName.utf16).prefix(59).enumerated() {
            bytes[0x10 + i * 2] = UInt8(unit & 0xFF)
            bytes[0x10 + i * 2 + 1] = UInt8(unit >> 8)
        }
        put32(pathHash, at: 0x4C)

        // Version-specific information block.
        let timeOffset: Int
        let countOffset: Int
        let capacity: Int
        switch version {
        case .winXP:      timeOffset = 0x78; countOffset = 0x90; capacity = 1
        case .winVista7:  timeOffset = 0x80; countOffset = 0x98; capacity = 1
        case .win8:       timeOffset = 0x80; countOffset = 0xD0; capacity = 8
        case .win10:      timeOffset = 0x80; countOffset = 0xD0; capacity = 8
        }
        for (index, date) in runTimes.prefix(capacity).enumerated() {
            put64(filetime(date), at: timeOffset + index * 8)
        }
        put32(runCount, at: countOffset)
        return Data(bytes)
    }

    /// A Windows 10+ compressed container: "MAM\x04" then the declared
    /// uncompressed size, then LZXPRESS-Huffman bytes this reader refuses to
    /// interpret.
    static func compressed(uncompressedSize: UInt32 = 12_345) -> Data {
        var out = Data([0x4D, 0x41, 0x4D, 0x04])
        for i in 0..<4 { out.append(UInt8((uncompressedSize >> (8 * UInt32(i))) & 0xFF)) }
        out += Data((0..<64).map { UInt8(($0 * 7 + 11) % 251) })
        return out
    }
}
