//
//  JournaldReader.swift
//  Kalsmritikosh
//
//  Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
//  Binary Linux systemd journal files (`*.journal`, signature "LPKSHHRH"), per systemd's published
//  JOURNAL_FILE_FORMAT. Read-only, bounds-checked. Objects are walked in file order from the header
//  (8-byte aligned; 16-byte object header: type, flags, reserved, u64 size). ENTRY objects (type 3)
//  carry seqnum, realtime (µs since 1970), monotonic, boot id and a list of DATA object offsets
//  (u64 offset + u64 hash; u32 offset in "compact" files, incompatible flag 0x10). DATA objects
//  (type 1) hold "FIELD=value" at +64 (+72 compact); payload flags 1 = XZ, 2 = LZ4 (u64 size + raw
//  block), 4 = ZSTD. XZ and LZ4 are decompressed with Apple's Compression framework; ZSTD is
//  reported per field as not decoded.
//
//  Checked (2026-11-22, python prototype of this same walk) against plaso's Apache-2.0 sample
//  test_data/systemd/journal/system.journal: 2,101 entries (= the header's n_entries), first
//  2017-01-27 09:40:55.913258 UTC "Started User Manager for UID 1000." (systemd, PID 1, host
//  test-VirtualBox), last 2017-02-06 16:24:42.140470 UTC sudo "pam_unix(sudo:session): session
//  opened for user root by test(uid=0)"; two XZ-compressed DATA objects decode to MESSAGE=aaaa….
//

import Foundation
import Compression

nonisolated struct JournaldReader {
    struct Entry: Sendable {
        let seqnum: UInt64
        let realtime: Date?
        let fileOffset: Int
        /// Fields in stored order; a field that could not be decoded holds a bracketed note.
        let fields: [(name: String, value: String)]

        func value(_ name: String) -> String? { fields.first { $0.name == name }?.value }
    }

    enum ReaderError: Error, Sendable { case notJournal, truncated }

    static let signature: [UInt8] = Array("LPKSHHRH".utf8)
    static let maxEntries = 200_000
    static let maxFieldBytes = 64 * 1024

    let headEntryRealtime: Date?
    let tailEntryRealtime: Date?
    let declaredEntries: Int
    let isCompact: Bool
    private(set) var problems: [String] = []
    private let d: [UInt8]
    private let headerSize: Int
    private let tailObject: Int

    static func isJournal(_ data: Data) -> Bool { data.count >= 8 && Array(data.prefix(8)) == signature }

    init(data: Data) throws {
        guard Self.isJournal(data) else { throw ReaderError.notJournal }
        guard data.count >= 208 else { throw ReaderError.truncated }
        let bytes = [UInt8](data)
        d = bytes
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) } }
        let incompatible = UInt32(truncatingIfNeeded: u64(12) & 0xFFFF_FFFF)
        isCompact = (incompatible & 0x10) != 0
        headerSize = Int(min(u64(88), UInt64(bytes.count)))
        tailObject = Int(min(u64(136), UInt64(bytes.count)))
        declaredEntries = Int(min(u64(152), UInt64(Int32.max)))
        headEntryRealtime = Self.date(u64(184))
        tailEntryRealtime = Self.date(u64(192))
        if (incompatible & 0x08) != 0 {
            problems.append("Some fields are compressed with zstd, which is not decoded here; those fields are marked.")
        }
    }

    static func date(_ us: UInt64) -> Date? {
        guard us > 0, us < 4_102_444_800_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(us) / 1_000_000)
    }

    private func u64(_ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= d.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[o + $1]) << (8 * UInt64($1)) }
    }
    private func u32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }

    /// Every entry, in file order (which is seqnum order within one file).
    mutating func entries() -> [Entry] {
        var out: [Entry] = []
        var o = max(headerSize, 208)
        while o + 16 <= d.count, o <= tailObject {
            let type = d[o]
            guard let size64 = u64(o + 8), size64 >= 16, Int(exactly: size64).map({ o + $0 <= d.count }) == true else {
                problems.append("An object at byte \(o) has an impossible size; reading stopped there.")
                break
            }
            let size = Int(size64)
            if type == 3, let entry = entry(at: o, size: size) {
                out.append(entry)
                if out.count >= Self.maxEntries {
                    problems.append("Stopped after \(Self.maxEntries) entries.")
                    break
                }
            }
            o += (size + 7) & ~7
        }
        if declaredEntries > 0, out.count < declaredEntries, out.count < Self.maxEntries {
            problems.append("The header declares \(declaredEntries) entries; \(out.count) were readable (the file may be cut short).")
        }
        return out
    }

    private func entry(at o: Int, size: Int) -> Entry? {
        guard let seq = u64(o + 16), let real = u64(o + 24) else { return nil }
        var fields: [(String, String)] = []
        var p = o + 64
        let itemSize = isCompact ? 4 : 16
        while p + itemSize <= o + size {
            let offset = isCompact ? u32(p).map(UInt64.init) : u64(p)
            p += itemSize
            guard let off = offset, off > 0, let dataAt = Int(exactly: off), let field = dataField(at: dataAt) else { continue }
            fields.append(field)
        }
        return Entry(seqnum: seq, realtime: Self.date(real), fileOffset: o, fields: fields)
    }

    private func dataField(at o: Int) -> (String, String)? {
        guard o + 16 <= d.count, d[o] == 1, let size64 = u64(o + 8), let size = Int(exactly: size64),
              o + size <= d.count else { return nil }
        let flags = d[o + 1]
        let start = o + (isCompact ? 72 : 64)
        guard start <= o + size else { return nil }
        var payload = Array(d[start..<(o + size)])
        if flags & 0x01 != 0 {
            guard let plain = Self.decode(payload, algorithm: COMPRESSION_LZMA) else { return ("(field)", "[xz-compressed field not decoded]") }
            payload = plain
        } else if flags & 0x02 != 0 {
            guard payload.count > 8, let plain = Self.decode(Array(payload[8...]), algorithm: COMPRESSION_LZ4_RAW,
                                                             expected: Int((0..<8).reduce(UInt64(0)) { $0 | UInt64(payload[$1]) << (8 * UInt64($1)) })) else {
                return ("(field)", "[lz4-compressed field not decoded]")
            }
            payload = plain
        } else if flags & 0x04 != 0 {
            return ("(field)", "[zstd-compressed field not decoded]")
        }
        guard let eq = payload.firstIndex(of: UInt8(ascii: "=")) else { return nil }
        let name = String(decoding: payload[..<eq], as: UTF8.self)
        let value = String(decoding: payload[(eq + 1)...].prefix(Self.maxFieldBytes), as: UTF8.self)
        return (name, value)
    }

    private static func decode(_ input: [UInt8], algorithm: compression_algorithm, expected: Int? = nil) -> [UInt8]? {
        guard !input.isEmpty else { return nil }
        let capacity = min(max(expected ?? input.count * 16, 4096), maxFieldBytes * 4)
        var out = [UInt8](repeating: 0, count: capacity)
        let n = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, capacity, src.baseAddress!, input.count, nil, algorithm)
            }
        }
        guard n > 0 else { return nil }
        return Array(out.prefix(n))
    }
}

// MARK: - Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet. One readable line per entry.

extension JournaldReader {
    /// The fields shown in an entry's line, in this order; the rest stay on the block's attributes only.
    static let shownFields = ["SYSLOG_IDENTIFIER", "_COMM", "_PID", "_HOSTNAME", "_SYSTEMD_UNIT", "_UID", "PRIORITY"]

    static func line(for e: Entry, iso: ISO8601DateFormatter) -> String {
        var line = "Journal entry \(e.seqnum)"
        line += e.realtime.map { " at \(iso.string(from: $0))" } ?? " (no time recorded)"
        let who = [e.value("SYSLOG_IDENTIFIER") ?? e.value("_COMM"), e.value("_PID").map { "pid \($0)" },
                   e.value("_HOSTNAME").map { "on \($0)" }].compactMap { $0 }
        if !who.isEmpty { line += " — " + who.joined(separator: ", ") }
        if let unit = e.value("_SYSTEMD_UNIT") { line += " [\(unit)]" }
        line += ": " + (e.value("MESSAGE") ?? "(no message)")
        return line
    }

    /// The whole journal as text (the loader's content). Nil when `data` is not a journal.
    static func text(from data: Data) -> String? {
        guard isJournal(data), var reader = try? JournaldReader(data: data) else { return nil }
        let iso = ISO8601DateFormatter()
        let entries = reader.entries()
        var lines = ["Linux systemd journal: \(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
                     + (reader.headEntryRealtime.map { ", from \(iso.string(from: $0))" } ?? "")
                     + (reader.tailEntryRealtime.map { " to \(iso.string(from: $0))" } ?? "")]
        lines += entries.map { line(for: $0, iso: iso) }
        lines += reader.problems
        return lines.joined(separator: "\n")
    }
}
