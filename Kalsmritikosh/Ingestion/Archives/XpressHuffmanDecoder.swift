//
//  XpressHuffmanDecoder.swift
//  Kalsmritikosh
//
//  Unified path SRC-12 (owner 2026-11-22, round 2) — not tested yet.
//  LZXPRESS Huffman ("LZ77 + Huffman", [MS-XCA] §2.1–2.2) decompression, written natively
//  (Apple's Compression framework has no Xpress). Used for Windows 10/11 compressed Prefetch
//  ("MAM\x04" container). Each 64 KiB of output starts with a 256-byte table of 512 four-bit
//  code lengths (canonical Huffman, at most 15 bits); symbols 0–255 are literals, 256–511 are
//  matches (low nibble = length, high nibble = offset bit count).
//
//  Checked (2026-11-22, python prototype of this same algorithm) against plaso's Apache-2.0
//  samples: AM_DELTA_PATCH (v31, 11,888 bytes), NOTEPAD.EXE (v30, 34,286 bytes) and
//  ONEDRIVE.EXE (v30, 71,240 bytes — crosses a 64 KiB block) each decompress to exactly the
//  declared size with a valid "SCCA" header whose own file-size field matches.
//

import Foundation

nonisolated enum XpressHuffmanDecoder {
    enum DecodeError: Error, Sendable, Equatable {
        case truncated, badCode, badMatch, tooLarge
    }

    /// Refuse to build anything bigger than this (a Prefetch file is well under 1 MiB).
    static let maxOutput = 64 * 1024 * 1024

    static func decompress(_ input: [UInt8], outputSize: Int) throws -> [UInt8] {
        guard outputSize >= 0, outputSize <= maxOutput else { throw DecodeError.tooLarge }
        var out = [UInt8]()
        out.reserveCapacity(outputSize)
        let n = input.count
        var ip = 0
        func r16(_ p: Int) -> UInt32 { p + 1 < n ? UInt32(input[p]) | UInt32(input[p + 1]) << 8 : 0 }

        while out.count < outputSize {
            guard ip + 256 <= n else { throw DecodeError.truncated }
            // Code lengths: low nibble = symbol 2i, high nibble = symbol 2i+1.
            var lengths = [Int](repeating: 0, count: 512)
            for i in 0..<256 {
                let b = Int(input[ip + i])
                lengths[2 * i] = b & 0x0F
                lengths[2 * i + 1] = b >> 4
            }
            ip += 256
            // Canonical decoding table indexed by the next 15 bits: (symbol << 4) | length; 0xFFFF = empty.
            var table = [UInt16](repeating: 0xFFFF, count: 1 << 15)
            var code = 0
            var previousLength = 0
            for length in 1...15 {
                for symbol in 0..<512 where lengths[symbol] == length {
                    code <<= (length - previousLength)
                    previousLength = length
                    let start = code << (15 - length)
                    let span = 1 << (15 - length)
                    guard start + span <= table.count else { throw DecodeError.badCode }
                    let entry = UInt16(symbol << 4 | length)
                    for j in start..<(start + span) { table[j] = entry }
                    code += 1
                }
            }

            var bits: UInt32 = (r16(ip) << 16) | r16(ip + 2)
            ip += 4
            var extra = 16
            let blockEnd = min(out.count + 65_536, outputSize)
            func refill() {
                if extra < 0 {
                    bits |= r16(ip) << UInt32(-extra)
                    extra += 16
                    ip += 2
                }
            }
            while out.count < blockEnd {
                let entry = table[Int(bits >> 17)]
                guard entry != 0xFFFF else { throw DecodeError.badCode }
                var symbol = Int(entry >> 4)
                let length = Int(entry & 0x0F)
                bits = length == 32 ? 0 : bits << UInt32(length)
                extra -= length
                refill()
                if symbol < 256 { out.append(UInt8(symbol)); continue }
                if symbol == 256 && ip >= n { return out }   // end of stream
                symbol -= 256
                var matchLength = symbol & 0x0F
                let offsetBits = symbol >> 4
                if matchLength == 15 {
                    guard ip < n else { throw DecodeError.truncated }
                    matchLength = Int(input[ip]); ip += 1
                    if matchLength == 255 {
                        guard ip + 1 < n else { throw DecodeError.truncated }
                        matchLength = Int(r16(ip)); ip += 2
                        if matchLength == 0 {
                            guard ip + 3 < n else { throw DecodeError.truncated }
                            matchLength = Int(r16(ip)) | Int(r16(ip + 2)) << 16; ip += 4
                        }
                        guard matchLength >= 15 else { throw DecodeError.badMatch }
                        matchLength -= 15
                    }
                    matchLength += 15
                }
                matchLength += 3
                let offsetTail = offsetBits > 0 ? Int(bits >> UInt32(32 - offsetBits)) : 0
                let offset = offsetTail + (1 << offsetBits)
                bits = offsetBits > 0 ? bits << UInt32(offsetBits) : bits
                extra -= offsetBits
                refill()
                let source = out.count - offset
                guard source >= 0, out.count + matchLength <= outputSize + 65_536 else { throw DecodeError.badMatch }
                for k in 0..<matchLength { out.append(out[source + k]) }
            }
        }
        if out.count > outputSize { out.removeLast(out.count - outputSize) }
        return out
    }
}
