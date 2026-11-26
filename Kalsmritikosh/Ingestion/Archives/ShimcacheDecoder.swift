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
//  Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. Windows 7 (0xBADC0FEE, 32- and
//  64-bit entry layouts), Vista (0xBADC0FFE) and XP (0xDEADBEEF, 552-byte entries) are now decoded.
//  The Windows 7 32-bit layout was checked against plaso's Apache-2.0 SYSTEM hive (ControlSet001:
//  330 entries, first "\??\C:\Program Files\McAfee\VirusScan Enterprise\mfeann.exe", file last
//  modified 2011-01-12 12:08:00 UTC; 238 entries carry insert flag 0x2). Vista, XP and the Windows 7
//  64-bit layout are decoded from the public descriptions without a sample; Windows 8/10/11 likewise.
//

import Foundation

public nonisolated enum ShimcacheDecoder {

    public struct Entry: Sendable, Hashable {
        public let ordinal: Int
        public let path: String
        public let fileLastModified: Date?
        /// Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. Windows 7/Vista insert flag 0x2,
        /// commonly read as "the program ran" — a sign, not proof. nil where the layout has no such flag.
        public var insertFlagSet: Bool? = nil
        /// Which layout decoded it ("win10", "win8", "win7-x86", "win7-x64", "vista-x86", "vista-x64", "xp").
        public var layout: String = "win10"
    }

    /// Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. The caveat that travels with each entry.
    public static func note(forLayout layout: String) -> String {
        layout == "win7-x86"
            ? "Shimcache read in the Windows 7 layout, checked against a public sample hive."
            : limitationNote
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
        if header == 0xBADC0FEE || header == 0xBADC0FFE {   // Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
            return decodeWin7Vista(data, isVista: header == 0xBADC0FFE)
        }
        if header == 0xDEADBEEF { return decodeXP(data) }
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

    // MARK: - Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. Older layouts.

    /// Windows 7 (header 0x80 bytes) / Vista (header 8 bytes). Entries: u16 length, u16 max length,
    /// [x64: 4 pad] path offset (u32 x86 / u64 x64, from the value start), FILETIME last modified,
    /// u32 insert flags, u32 shim flags, then (Win7 only) data size + data offset (u32 x86 / u64 x64).
    static func decodeWin7Vista(_ data: Data, isVista: Bool) -> Outcome {
        guard let declared = u32(data, 4).map(Int.init) else { return .notDecoded("unreadable entry count") }
        let start = isVista ? 8 : 0x80
        // x64 when the padding after the two lengths is zero and the 64-bit path offset lands inside the value.
        let pad = u32(data, start + 4) ?? 1
        let off64 = (u32(data, start + 8).map(UInt64.init) ?? 0) | ((u32(data, start + 12).map(UInt64.init) ?? 0) << 32)
        let x64 = pad == 0 && off64 > 0 && off64 < UInt64(data.count)
        let size: Int = isVista ? (x64 ? 32 : 24) : (x64 ? 48 : 32)
        let layout = (isVista ? "vista-" : "win7-") + (x64 ? "x64" : "x86")
        var entries: [Entry] = []
        var stopped: String?
        for i in 0..<min(declared, maxEntries) {
            let o = start + i * size
            guard o + size <= data.count, let length = u16(data, o).map(Int.init) else {
                stopped = "the value ended after \(i) of \(declared) entries"; break
            }
            let pathOffset: Int
            let timeAt: Int
            let flagsAt: Int
            if x64 {
                pathOffset = Int(u32(data, o + 8) ?? 0); timeAt = o + 16; flagsAt = o + 24
            } else {
                pathOffset = Int(u32(data, o + 4) ?? 0); timeAt = o + 8; flagsAt = o + 16
            }
            guard pathOffset > 0, pathOffset + length <= data.count else {
                stopped = "entry \(i + 1)'s path lies outside the value; decoding stopped there"; break
            }
            let path = utf16(data.subdata(in: (data.startIndex + pathOffset)..<(data.startIndex + pathOffset + length)))
            var e = Entry(ordinal: i + 1, path: path, fileLastModified: filetime(data, timeAt))
            e.insertFlagSet = ((u32(data, flagsAt) ?? 0) & 0x2) != 0
            e.layout = layout
            entries.append(e)
        }
        if declared > maxEntries { stopped = "stopped at \(maxEntries) entries" }
        return .decoded(entries, stoppedEarly: stopped)
    }

    /// Windows XP: 400-byte header, u32 entry count at 4; 552-byte entries: UTF-16 path (520 bytes,
    /// NUL-terminated), FILETIME last modified at 528, u64 file size at 536, FILETIME last update at 544.
    static func decodeXP(_ data: Data) -> Outcome {
        guard let declared = u32(data, 4).map(Int.init) else { return .notDecoded("unreadable entry count") }
        var entries: [Entry] = []
        var stopped: String?
        for i in 0..<min(declared, maxEntries) {
            let o = 400 + i * 552
            guard o + 552 <= data.count else { stopped = "the value ended after \(i) of \(declared) entries"; break }
            let raw = data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + 520))
            let path = utf16(raw).split(separator: "\u{0}").first.map(String.init) ?? ""
            guard !path.isEmpty else { continue }
            var e = Entry(ordinal: i + 1, path: path, fileLastModified: filetime(data, o + 528))
            e.layout = "xp"
            entries.append(e)
        }
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
