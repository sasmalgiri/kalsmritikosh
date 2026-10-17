//
//  SevenZipReader.swift
//  Kalsmritikosh
//
//  W4-2 — reads .7z archives natively (format: the public 7z specification,
//  7zFormat.txt). Supported coders: Copy, LZMA, LZMA2 in single-coder folders —
//  what 7-Zip writes by default. Encrypted archives (AES), filters (BCJ/Delta)
//  and other coders (BZip2, PPMd, Deflate) are reported per member as
//  unsupported, never silently skipped. Encoded (compressed) headers are read.
//
//  Folders are decoded whole into memory, bounded by the caller's cap.
//

import Foundation

nonisolated enum SevenZipError: Error, Sendable, Equatable {
    case notSevenZip, corrupt(String), unsupportedHeader, encrypted, unsupportedCoder(String), tooLarge
}

nonisolated struct SevenZipEntry: Sendable {
    let index: Int
    let name: String
    let isDirectory: Bool
    let size: Int64
    /// Folder holding the bytes (nil for empty files and directories).
    let folder: Int?
    let offsetInFolder: Int64
}

nonisolated final class SevenZipReader {
    struct Coder { let id: [UInt8]; let inStreams: Int; let outStreams: Int; let props: [UInt8] }
    struct Folder {
        var coders: [Coder] = []
        var bindPairs: [(inIndex: Int, outIndex: Int)] = []
        var packedStreams: [Int] = []
        var unpackSizes: [Int64] = []
        var firstPackStream = 0
        var unpackSize: Int64 {
            // The final output is the out-stream not bound to any coder input.
            let bound = Set(bindPairs.map(\.outIndex))
            for i in 0..<unpackSizes.count where !bound.contains(i) { return unpackSizes[i] }
            return unpackSizes.last ?? 0
        }
    }
    struct StreamsInfo {
        var packPos: Int64 = 0
        var packSizes: [Int64] = []
        var folders: [Folder] = []
        var numUnpackStreams: [Int] = []
        var subSizes: [Int64] = []
        var folderCRCDefined: [Bool] = []
    }

    let data: [UInt8]
    let maxFolderBytes: Int
    private(set) var entries: [SevenZipEntry] = []
    private var streams = StreamsInfo()
    private var cachedFolder: (index: Int, bytes: [UInt8])?

    init(data: Data, maxFolderBytes: Int) throws {
        self.data = [UInt8](data)
        self.maxFolderBytes = maxFolderBytes
        try parse()
    }

    // MARK: - Byte reading

    private struct Cursor {
        let b: [UInt8]
        var p: Int
        var end: Int
        mutating func byte() throws -> UInt8 {
            guard p < end else { throw SevenZipError.corrupt("unexpected end of header") }
            defer { p += 1 }; return b[p]
        }
        mutating func number() throws -> Int64 {
            let first = try byte()
            var mask: UInt8 = 0x80
            var value: UInt64 = 0
            for i in 0..<8 {
                if first & mask == 0 {
                    let high = UInt64(first & (mask &- 1))
                    value |= high << (8 * UInt64(i))
                    return Int64(bitPattern: value)
                }
                value |= UInt64(try byte()) << (8 * UInt64(i))
                mask >>= 1
            }
            return Int64(bitPattern: value)
        }
        mutating func int() throws -> Int {
            let v = try number()
            guard v >= 0, v < Int64(Int32.max) else { throw SevenZipError.corrupt("number out of range") }
            return Int(v)
        }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, p + n <= end else { throw SevenZipError.corrupt("field past end") }
            defer { p += n }; return Array(b[p..<(p + n)])
        }
        mutating func uint32() throws -> UInt32 {
            let x = try bytes(4); return UInt32(x[0]) | UInt32(x[1]) << 8 | UInt32(x[2]) << 16 | UInt32(x[3]) << 24
        }
        mutating func bitVector(_ n: Int) throws -> [Bool] {
            var out: [Bool] = [], mask: UInt8 = 0, cur: UInt8 = 0
            for _ in 0..<n {
                if mask == 0 { cur = try byte(); mask = 0x80 }
                out.append(cur & mask != 0); mask >>= 1
            }
            return out
        }
        mutating func definedVector(_ n: Int) throws -> [Bool] {
            let all = try byte()
            return all != 0 ? Array(repeating: true, count: n) : try bitVector(n)
        }
    }

    private static func le64(_ b: [UInt8], _ o: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        return Int64(bitPattern: v)
    }

    // MARK: - Parsing

    private func parse() throws {
        let sig: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
        guard data.count >= 32, Array(data[0..<6]) == sig else { throw SevenZipError.notSevenZip }
        let nextOffset = Self.le64(data, 12), nextSize = Self.le64(data, 20)
        let start = 32 + Int(nextOffset)
        guard nextOffset >= 0, nextSize > 0, start + Int(nextSize) <= data.count else {
            if nextSize == 0 { return }   // empty archive
            throw SevenZipError.corrupt("next header out of range")
        }
        var header = Array(data[start..<(start + Int(nextSize))])
        var c = Cursor(b: header, p: 0, end: header.count)
        var id = try c.byte()
        // Encoded header: decode the header stream, then parse it as a plain header.
        var guardCount = 0
        while id == 0x17 {
            guardCount += 1
            guard guardCount < 4 else { throw SevenZipError.unsupportedHeader }
            let s = try readStreamsInfo(&c)
            guard let f = s.folders.first else { throw SevenZipError.corrupt("encoded header without folder") }
            header = try decodeFolder(f, index: 0, streams: s)
            c = Cursor(b: header, p: 0, end: header.count)
            id = try c.byte()
        }
        guard id == 0x01 else { throw SevenZipError.unsupportedHeader }
        try readHeader(&c)
    }

    private func skipProperty(_ c: inout Cursor) throws { let n = try c.int(); _ = try c.bytes(n) }

    private func readHeader(_ c: inout Cursor) throws {
        var t = try c.byte()
        if t == 0x02 {                                   // ArchiveProperties
            while true { let p = try c.byte(); if p == 0 { break }; try skipProperty(&c) }
            t = try c.byte()
        }
        if t == 0x03 { _ = try readStreamsInfo(&c); t = try c.byte() }   // AdditionalStreamsInfo (ignored)
        if t == 0x04 { streams = try readStreamsInfo(&c); t = try c.byte() }
        if t == 0x05 { try readFilesInfo(&c); t = try c.byte() }
        guard t == 0x00 else { throw SevenZipError.corrupt("header not terminated") }
    }

    private func readStreamsInfo(_ c: inout Cursor) throws -> StreamsInfo {
        var s = StreamsInfo()
        var t = try c.byte()
        if t == 0x06 {                                   // PackInfo
            s.packPos = try c.number()
            let n = try c.int()
            t = try c.byte()
            while t != 0x00 {
                if t == 0x09 { s.packSizes = try (0..<n).map { _ in try c.number() } }
                else if t == 0x0A { let d = try c.definedVector(n); for x in d where x { _ = try c.uint32() } }
                else { try skipProperty(&c) }
                t = try c.byte()
            }
            t = try c.byte()
        }
        if t == 0x07 {                                   // UnpackInfo
            guard try c.byte() == 0x0B else { throw SevenZipError.corrupt("expected folders") }
            let nf = try c.int()
            guard try c.byte() == 0 else { throw SevenZipError.unsupportedHeader }   // external folders
            var packIndex = 0
            for _ in 0..<nf {
                var f = try readFolder(&c)
                f.firstPackStream = packIndex
                packIndex += f.packedStreams.count
                s.folders.append(f)
            }
            guard try c.byte() == 0x0C else { throw SevenZipError.corrupt("expected unpack sizes") }
            for i in 0..<s.folders.count {
                let outs = s.folders[i].coders.reduce(0) { $0 + $1.outStreams }
                s.folders[i].unpackSizes = try (0..<outs).map { _ in try c.number() }
            }
            t = try c.byte()
            s.folderCRCDefined = Array(repeating: false, count: s.folders.count)
            while t != 0x00 {
                if t == 0x0A {
                    let d = try c.definedVector(s.folders.count)
                    s.folderCRCDefined = d
                    for x in d where x { _ = try c.uint32() }
                } else { try skipProperty(&c) }
                t = try c.byte()
            }
            t = try c.byte()
        }
        s.numUnpackStreams = Array(repeating: 1, count: s.folders.count)
        if t == 0x08 {                                   // SubStreamsInfo
            t = try c.byte()
            if t == 0x0D { s.numUnpackStreams = try (0..<s.folders.count).map { _ in try c.int() }; t = try c.byte() }
            var sizes: [Int64] = []
            for (i, f) in s.folders.enumerated() {
                let n = s.numUnpackStreams[i]
                guard n > 0 else { continue }
                var sum: Int64 = 0
                if t == 0x09 { for _ in 0..<(n - 1) { let v = try c.number(); sizes.append(v); sum += v } }
                sizes.append(f.unpackSize - sum)
            }
            if t == 0x09 { t = try c.byte() }
            s.subSizes = sizes
            while t != 0x00 {
                if t == 0x0A {
                    // CRCs listed here cover only streams whose CRC is not already known at folder level.
                    var total = 0
                    for (i, n) in s.numUnpackStreams.enumerated() {
                        let known = i < s.folderCRCDefined.count && s.folderCRCDefined[i]
                        total += (n == 1 && known) ? 0 : n
                    }
                    let d = try c.definedVector(total); for x in d where x { _ = try c.uint32() }
                } else { try skipProperty(&c) }
                t = try c.byte()
            }
            t = try c.byte()
        } else {
            s.subSizes = s.folders.map(\.unpackSize)
        }
        // Caller-level terminator: if this StreamsInfo was not already closed, `t` must be End.
        if t != 0x00 { throw SevenZipError.corrupt("streams info not terminated") }
        return s
    }

    private func readFolder(_ c: inout Cursor) throws -> Folder {
        var f = Folder()
        let nc = try c.int()
        guard nc > 0, nc <= 32 else { throw SevenZipError.corrupt("coder count") }
        var totalIn = 0, totalOut = 0
        for _ in 0..<nc {
            let flag = try c.byte()
            let id = try c.bytes(Int(flag & 0x0F))
            var ins = 1, outs = 1
            if flag & 0x10 != 0 { ins = try c.int(); outs = try c.int() }
            var props: [UInt8] = []
            if flag & 0x20 != 0 { props = try c.bytes(try c.int()) }
            guard flag & 0x80 == 0 else { throw SevenZipError.unsupportedHeader }   // alternative methods (never written)
            f.coders.append(Coder(id: id, inStreams: ins, outStreams: outs, props: props))
            totalIn += ins; totalOut += outs
        }
        for _ in 0..<(totalOut - 1) { f.bindPairs.append((try c.int(), try c.int())) }
        let packed = totalIn - f.bindPairs.count
        if packed == 1 {
            let bound = Set(f.bindPairs.map(\.inIndex))
            f.packedStreams = [(0..<totalIn).first { !bound.contains($0) } ?? 0]
        } else {
            f.packedStreams = try (0..<packed).map { _ in try c.int() }
        }
        return f
    }

    private func readFilesInfo(_ c: inout Cursor) throws {
        let n = try c.int()
        var names = Array(repeating: "", count: n)
        var emptyStream = Array(repeating: false, count: n)
        var emptyFile: [Bool] = []
        var anti: [Bool] = []
        while true {
            let t = try c.byte()
            if t == 0x00 { break }
            let size = try c.int()
            let end = c.p + size
            switch t {
            case 0x0E: emptyStream = try c.bitVector(n)
            case 0x0F: emptyFile = try c.bitVector(emptyStream.filter { $0 }.count)
            case 0x10: anti = try c.bitVector(emptyStream.filter { $0 }.count)
            case 0x11:
                guard try c.byte() == 0 else { throw SevenZipError.unsupportedHeader }
                var i = 0
                var units: [UInt16] = []
                while c.p + 1 < end, i < n {
                    let u = UInt16(try c.byte()) | UInt16(try c.byte()) << 8
                    if u == 0 { names[i] = String(decoding: units, as: UTF16.self); units = []; i += 1 } else { units.append(u) }
                }
            default: break
            }
            c.p = end
        }
        _ = anti
        // Assign streams to non-empty files in order.
        var folderIndex = 0, inFolder = 0, offset: Int64 = 0, sizeIndex = 0, emptyIndex = 0
        for i in 0..<n {
            if emptyStream[i] {
                let isFile = emptyIndex < emptyFile.count ? emptyFile[emptyIndex] : false
                emptyIndex += 1
                entries.append(SevenZipEntry(index: i, name: names[i], isDirectory: !isFile, size: 0, folder: nil, offsetInFolder: 0))
                continue
            }
            while folderIndex < streams.numUnpackStreams.count, inFolder >= streams.numUnpackStreams[folderIndex] {
                folderIndex += 1; inFolder = 0; offset = 0
            }
            guard folderIndex < streams.folders.count, sizeIndex < streams.subSizes.count else {
                throw SevenZipError.corrupt("more files than streams")
            }
            let size = streams.subSizes[sizeIndex]
            entries.append(SevenZipEntry(index: i, name: names[i], isDirectory: false, size: size, folder: folderIndex, offsetInFolder: offset))
            offset += size; sizeIndex += 1; inFolder += 1
        }
    }

    // MARK: - Decoding

    /// Why a folder cannot be decoded, or nil when it can.
    func unsupportedReason(folder index: Int) -> String? {
        guard index < streams.folders.count else { return "missing folder" }
        let f = streams.folders[index]
        if f.coders.contains(where: { $0.id == [0x06, 0xF1, 0x07, 0x01] }) { return "encrypted (AES)" }
        guard f.coders.count == 1 else { return "filter chain (\(f.coders.count) coders) not supported" }
        switch f.coders[0].id {
        case [0x00], [0x03, 0x01, 0x01], [0x21]: return nil
        default: return "compression method \(f.coders[0].id.map { String(format: "%02X", $0) }.joined()) not supported"
        }
    }

    private func decodeFolder(_ f: Folder, index: Int, streams s: StreamsInfo) throws -> [UInt8] {
        guard f.unpackSize >= 0, f.unpackSize <= Int64(maxFolderBytes) else { throw SevenZipError.tooLarge }
        guard f.coders.count == 1, let coder = f.coders.first else { throw SevenZipError.unsupportedCoder("filter chain") }
        var start = 32 + Int(s.packPos)
        for i in 0..<f.firstPackStream { start += Int(s.packSizes[i]) }
        guard f.firstPackStream < s.packSizes.count else { throw SevenZipError.corrupt("pack stream index") }
        let len = Int(s.packSizes[f.firstPackStream])
        guard start >= 32, start + len <= data.count else { throw SevenZipError.corrupt("pack stream out of range") }
        let packed = Array(data[start..<(start + len)])
        let size = Int(f.unpackSize)
        switch coder.id {
        case [0x00]: return Array(packed.prefix(size))
        case [0x03, 0x01, 0x01]: return try LZMADecoder.decodeLZMA(packed, properties: coder.props, size: size, maxOutput: maxFolderBytes)
        case [0x21]: return try LZMADecoder.decodeLZMA2(packed, size: size, maxOutput: maxFolderBytes)
        case [0x06, 0xF1, 0x07, 0x01]: throw SevenZipError.encrypted
        default: throw SevenZipError.unsupportedCoder(coder.id.map { String(format: "%02X", $0) }.joined())
        }
    }

    /// The bytes of one file entry (decodes its folder once and caches it for the next entry).
    func extract(_ entry: SevenZipEntry) throws -> Data {
        guard let fi = entry.folder else { return Data() }
        let bytes: [UInt8]
        if let cached = cachedFolder, cached.index == fi { bytes = cached.bytes }
        else {
            bytes = try decodeFolder(streams.folders[fi], index: fi, streams: streams)
            cachedFolder = (fi, bytes)
        }
        let start = Int(entry.offsetInFolder), end = start + Int(entry.size)
        guard start >= 0, end <= bytes.count else { throw SevenZipError.corrupt("entry past folder end") }
        return Data(bytes[start..<end])
    }

    func packedSize(folder index: Int) -> Int64 {
        guard index < streams.folders.count else { return 0 }
        let f = streams.folders[index]
        return f.firstPackStream < streams.packSizes.count ? streams.packSizes[f.firstPackStream] : 0
    }
}
