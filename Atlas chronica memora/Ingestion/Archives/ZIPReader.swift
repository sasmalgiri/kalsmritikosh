//
//  ZIPReader.swift
//  Atlas chronica memora
//
//  Minimal pure-Swift ZIP reader sufficient for the Office Open XML
//  family (DOCX / XLSX / PPTX) and other "standard" zips. Decompresses
//  STORED (method 0) and DEFLATE (method 8) entries using Apple's
//  Compression framework — no third-party dependency.
//
//  Not a full ZIP implementation. Skips: ZIP64, encryption, multi-disk
//  spanning, AES, traditional-PKWARE-encrypted, archive comments > 64KB.
//  Office files don't use any of those, so this covers our needs.
//

import Foundation
import Compression

public enum ZIPReaderError: Error, Sendable {
    case notAZIP
    case truncated
    case unsupportedCompressionMethod(UInt16)
    case decompressionFailed
    case entryNotFound(String)
}

public struct ZIPEntry: Sendable {
    public let name: String
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let compressionMethod: UInt16
    public let localHeaderOffset: Int
}

public struct ZIPReader {
    private let data: Data

    public init(data: Data) {
        self.data = data
    }

    public init(url: URL) throws {
        self.data = try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Walks the central directory and returns every entry.
    public func entries() throws -> [ZIPEntry] {
        let eocdOffset = try findEOCD()
        let cdSize = readUInt32(at: eocdOffset + 12)
        let cdOffset = readUInt32(at: eocdOffset + 16)
        let cdEnd = Int(cdOffset) + Int(cdSize)
        guard cdEnd <= data.count else { throw ZIPReaderError.truncated }

        var entries: [ZIPEntry] = []
        var cursor = Int(cdOffset)
        while cursor + 46 <= cdEnd {
            let signature = readUInt32(at: cursor)
            guard signature == 0x02014b50 else { break }   // central dir sig
            let method = readUInt16(at: cursor + 10)
            let compressed = Int(readUInt32(at: cursor + 20))
            let uncompressed = Int(readUInt32(at: cursor + 24))
            let nameLen = Int(readUInt16(at: cursor + 28))
            let extraLen = Int(readUInt16(at: cursor + 30))
            let commentLen = Int(readUInt16(at: cursor + 32))
            let localOffset = Int(readUInt32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLen <= cdEnd else { throw ZIPReaderError.truncated }
            let name = String(
                decoding: data.subdata(in: nameStart..<(nameStart + nameLen)),
                as: UTF8.self
            )
            entries.append(ZIPEntry(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                compressionMethod: method,
                localHeaderOffset: localOffset
            ))
            cursor = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Returns the raw (decompressed) bytes of a single named entry.
    public func read(_ name: String) throws -> Data {
        let all = try entries()
        guard let entry = all.first(where: { $0.name == name }) else {
            throw ZIPReaderError.entryNotFound(name)
        }
        return try extract(entry: entry)
    }

    /// Lower-level: extract a specific entry by descriptor.
    public func extract(entry: ZIPEntry) throws -> Data {
        // Re-read the local file header to skip past its variable-length
        // name + extra fields (the central directory's values are not
        // always identical to the local header's).
        let lho = entry.localHeaderOffset
        guard lho + 30 <= data.count else { throw ZIPReaderError.truncated }
        let signature = readUInt32(at: lho)
        guard signature == 0x04034b50 else { throw ZIPReaderError.notAZIP }
        let localNameLen = Int(readUInt16(at: lho + 26))
        let localExtraLen = Int(readUInt16(at: lho + 28))
        let dataStart = lho + 30 + localNameLen + localExtraLen
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= data.count else { throw ZIPReaderError.truncated }
        let payload = data.subdata(in: dataStart..<dataEnd)

        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try inflateDEFLATE(payload, expecting: entry.uncompressedSize)
        default:
            throw ZIPReaderError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    // MARK: - EOCD

    private func findEOCD() throws -> Int {
        // EOCD is at the end of the file, with an optional comment up to
        // 65535 bytes. Walk back through the trailing window for the magic.
        let magic: UInt32 = 0x06054b50
        let searchStart = max(0, data.count - 65535 - 22)
        var cursor = data.count - 22
        while cursor >= searchStart {
            if readUInt32(at: cursor) == magic { return cursor }
            cursor -= 1
        }
        throw ZIPReaderError.notAZIP
    }

    // MARK: - Little-endian readers

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - DEFLATE via Apple's Compression framework

    private func inflateDEFLATE(_ input: Data, expecting: Int) throws -> Data {
        // Apple's `compression_decode_buffer` with `COMPRESSION_ZLIB`
        // expects RAW DEFLATE bytes, which is exactly what ZIP stores.
        // Allocate a buffer the size we expect; grow if the decoder ran
        // out of room (very rare for ZIP, which records the size up front).
        var bufferSize = max(expecting, max(256, input.count * 4))
        for _ in 0..<3 {
            var out = Data(count: bufferSize)
            let written = out.withUnsafeMutableBytes { outBuf -> Int in
                input.withUnsafeBytes { inBuf -> Int in
                    guard
                        let outBase = outBuf.bindMemory(to: UInt8.self).baseAddress,
                        let inBase = inBuf.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        outBase, bufferSize,
                        inBase, input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                out.count = written
                return out
            }
            // 0 from compression_decode_buffer can mean "buffer too small"
            // OR a real failure. Grow and retry once or twice.
            bufferSize *= 2
        }
        throw ZIPReaderError.decompressionFailed
    }
}
