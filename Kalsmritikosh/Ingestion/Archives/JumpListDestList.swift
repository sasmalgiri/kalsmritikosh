//
//  JumpListDestList.swift
//  Kalsmritikosh
//
//  Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
//  The `DestList` stream of an automatic jump list: the most-recently-used ORDER (entries are stored
//  most recent first), each entry's last access time, pin state, and the stream it describes.
//  Layout (community-documented; checked against plaso's Apache-2.0 samples):
//    header 32 bytes: u32 version (1 = Windows 7/8, 3/4 = Windows 10/11), u32 entry count,
//                     i32 pinned count, …, u32 last entry number at 0x10
//    entry: +0x48 NetBIOS host name (16 bytes ASCII), +0x58 u32 entry number (= the stream name in
//           hex), +0x60 float32 access weight, +0x64 FILETIME last access, +0x6C i32 pin slot
//           (-1 = not pinned); v1: +0x70 u16 path length, +0x72 UTF-16 path (entry = 0x72 + 2n bytes);
//           v3/v4: +0x74 u32 access count, +0x80 u16 path length, +0x82 path, 4 trailing bytes.
//  Samples: 1b4dd67f29cb1962 (v1, 7 entries, streams 7,5,2,1,6,4,3 in that order, host student-pc1,
//  newest 2015-08-29 15:32:44 UTC "C:\Users\bperry\Downloads"); 9d1f905ce5044aee (v3, 2 entries,
//  streams 2,1, access count 1 each, newest 2016-01-17 13:08:08 UTC). Every entry number named a
//  stream present in the file.
//

import Foundation

nonisolated enum JumpListDestList {
    struct Entry: Sendable, Equatable {
        /// 1 = most recently used.
        let rank: Int
        /// The shell-link stream this entry describes (entry number in lower-case hex).
        let streamName: String
        let lastAccess: Date?
        let pinned: Bool
        let accessCount: Int?
        let hostName: String?
        let path: String
    }

    struct Decoded: Sendable {
        let version: Int
        let entries: [Entry]
        /// Set when the stream ended before the declared entry count.
        let stoppedEarly: String?
    }

    static func decode(_ data: Data) -> Decoded? {
        let d = [UInt8](data)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> UInt32? {
            o >= 0 && o + 4 <= d.count ? UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 : nil
        }
        func filetime(_ o: Int) -> Date? {
            guard let lo = u32(o), let hi = u32(o + 4) else { return nil }
            let ticks = UInt64(hi) << 32 | UInt64(lo)
            guard ticks > 0 else { return nil }
            let seconds = Double(ticks) / 10_000_000 - 11_644_473_600
            guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let versionRaw = u32(0), let countRaw = u32(4) else { return nil }
        let version = Int(versionRaw)
        guard version == 1 || version == 3 || version == 4 else { return nil }
        let count = Int(min(countRaw, 10_000))
        var entries: [Entry] = []
        var o = 32
        var stopped: String?
        for i in 0..<count {
            let lengthAt = version == 1 ? o + 0x70 : o + 0x80
            let pathAt = lengthAt + 2
            guard let chars = u16(lengthAt), pathAt + 2 * chars <= d.count, let number = u32(o + 0x58) else {
                stopped = "the DestList ended after \(i) of \(count) entries"
                break
            }
            var units: [UInt16] = []
            for k in 0..<chars { units.append(UInt16(d[pathAt + 2 * k]) | UInt16(d[pathAt + 2 * k + 1]) << 8) }
            let host = String(decoding: d[(o + 0x48)..<min(o + 0x58, d.count)].prefix { $0 != 0 }, as: UTF8.self)
            let pin = u32(o + 0x6C).map { Int32(bitPattern: $0) } ?? -1
            entries.append(Entry(rank: i + 1, streamName: String(number, radix: 16),
                                 lastAccess: filetime(o + 0x64), pinned: pin >= 0,
                                 accessCount: version == 1 ? nil : u32(o + 0x74).map(Int.init),
                                 hostName: host.isEmpty ? nil : host,
                                 path: String(decoding: units, as: UTF16.self)))
            o = pathAt + 2 * chars + (version == 1 ? 0 : 4)
        }
        return Decoded(version: version, entries: entries, stoppedEarly: stopped)
    }
}
