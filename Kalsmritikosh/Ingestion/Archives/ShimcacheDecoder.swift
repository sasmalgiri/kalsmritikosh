//
//  ShimcacheDecoder.swift
//  Kalsmritikosh
//
//  Unified path SRC-11 (owner 2026-11-22) — not tested yet.
//
//  Shimcache (AppCompatCache) — the SYSTEM hive value
//  `ControlSet00n\Control\Session Manager\AppCompatCache\AppCompatCache`. Windows records executables
//  it SAW (path + the file's last-modified time). Like Amcache, an entry is evidence of PRESENCE, not of
//  execution: Windows 10/11 Shimcache carries no reliable "ran" flag, so nothing here says a program ran.
//  The listed time is the FILE's last-modified time, not when Windows saw it.
//
//  Formats decoded: Windows 10/11 and 8.x entries (signature "10ts" / "00ts"). Older layouts
//  (Windows 7 / XP, header 0xBADC0FEE / 0xDEADBEEF) are recognised and reported as not decoded.
//  Written from the public format descriptions WITHOUT a real hive to check against — so every decoded
//  entry is shown with that limitation, and anything that does not fit the layout stops the decode.
//  Pure, bounds-checked (nothing here can trap).
//

import Foundation

public nonisolated enum ShimcacheDecoder {

    public struct Entry: Sendable, Hashable {
        public let ordinal: Int
        public let path: String
        public let fileLastModified: Date?
    }

    public enum Outcome: Sendable {
        case decoded([Entry], stoppedEarly: String?)
        case notDecoded(String)
    }

    public static let maxEntries = 4_096
    public static let limitationNote =
        "Shimcache read from the published format description; not yet checked against a real Windows hive."

    public static func isShimcacheValue(path: String, name: String) -> Bool {
        name.caseInsensitiveCompare("AppCompatCache") == .orderedSame
            && path.lowercased().hasSuffix("session manager\\appcompatcache")
    }

    public static func decode(_ data: Data) -> Outcome {
        guard data.count >= 0x34 else { return .notDecoded("the value is too short to be a Shimcache") }
        guard let header = u32(data, 0) else { return .notDecoded("unreadable header") }
        if header == 0xBADC0FEE || header == 0xDEADBEEF || header == 0xBADC0FFE {
            return .notDecoded("an older Windows (7 / XP / Vista) Shimcache layout — present but not decoded")
        }
        // Windows 10/11: the first DWORD is the header length (0x30 or 0x34). Windows 8.x: header 0x80.
        let start: Int
        if header == 0x30 || header == 0x34 { start = Int(header) }
        else if header == 0x80 { start = 0x80 }
        else { return .notDecoded("unrecognised Shimcache header (0x\(String(header, radix: 16)))") }

        var entries: [Entry] = []
        var at = start
        var stopped: String?
        while at + 12 <= data.count, entries.count < maxEntries {
            let sig = String(decoding: data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + 4)), as: UTF8.self)
            guard sig == "10ts" || sig == "00ts" else {
                stopped = "an entry did not start with the expected signature at byte \(at); decoding stopped there"
                break
            }
            guard let entrySize = u32(data, at + 8).map(Int.init), entrySize > 0, at + 12 + entrySize <= data.count else {
                stopped = "an entry's size runs past the end of the value; decoding stopped there"
                break
            }
            let body = at + 12
            guard let pathLen = u16(data, body).map(Int.init), body + 2 + pathLen <= at + 12 + entrySize else {
                stopped = "an entry's path length does not fit; decoding stopped there"
                break
            }
            let pathData = data.subdata(in: (data.startIndex + body + 2)..<(data.startIndex + body + 2 + pathLen))
            let path = utf16(pathData)
            let timeAt = body + 2 + pathLen
            let modified = timeAt + 8 <= at + 12 + entrySize ? filetime(data, timeAt) : nil
            entries.append(Entry(ordinal: entries.count + 1, path: path, fileLastModified: modified))
            at = body + entrySize
        }
        if entries.count >= maxEntries { stopped = "stopped at \(maxEntries) entries" }
        return .decoded(entries, stoppedEarly: stopped)
    }

    // MARK: - Primitives

    static func u16(_ d: Data, _ at: Int) -> UInt16? {
        let i = d.startIndex + at
        guard at >= 0, i + 2 <= d.endIndex else { return nil }
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    static func u32(_ d: Data, _ at: Int) -> UInt32? {
        let i = d.startIndex + at
        guard at >= 0, i + 4 <= d.endIndex else { return nil }
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }

    static func filetime(_ d: Data, _ at: Int) -> Date? {
        guard let lo = u32(d, at), let hi = u32(d, at + 4) else { return nil }
        let ticks = (UInt64(hi) << 32) | UInt64(lo)
        guard ticks > 0 else { return nil }
        let seconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_208_988_800, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func utf16(_ d: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(d.count / 2)
        var i = d.startIndex
        while i + 1 < d.endIndex {
            units.append(UInt16(d[i]) | (UInt16(d[i + 1]) << 8))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
