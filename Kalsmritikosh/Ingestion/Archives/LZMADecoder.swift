//
//  LZMADecoder.swift
//  Kalsmritikosh
//
//  W4-2 — LZMA and LZMA2 decompression, written from the public LZMA
//  specification (the algorithm and its reference description are public
//  domain). Used by the 7z reader. The whole output is kept in memory and
//  doubles as the dictionary, so callers cap the output size first.
//

import Foundation

nonisolated enum LZMAError: Error, Sendable { case corrupt, truncated, badProperties, outputTooLarge }

nonisolated struct LZMARangeDecoder {
    let input: [UInt8]
    var pos: Int
    var range: UInt32 = 0xFFFF_FFFF
    var code: UInt32 = 0

    init(_ input: [UInt8], at start: Int) throws {
        self.input = input
        pos = start
        guard pos + 5 <= input.count, input[pos] == 0 else { throw LZMAError.corrupt }
        pos += 1
        for _ in 0..<4 { code = (code << 8) | UInt32(input[pos]); pos += 1 }
        guard code != range else { throw LZMAError.corrupt }
    }

    @inline(__always) mutating func normalize() throws {
        if range < 0x0100_0000 {
            guard pos < input.count else { throw LZMAError.truncated }
            range <<= 8
            code = (code << 8) | UInt32(input[pos]); pos += 1
        }
    }

    @inline(__always) mutating func bit(_ probs: inout [UInt16], _ i: Int) throws -> Int {
        let p = UInt32(probs[i])
        let bound = (range >> 11) &* p
        let b: Int
        if code < bound {
            probs[i] = UInt16(p + ((2048 - p) >> 5)); range = bound; b = 0
        } else {
            probs[i] = UInt16(p - (p >> 5)); code &-= bound; range &-= bound; b = 1
        }
        try normalize()
        return b
    }

    mutating func directBits(_ n: Int) throws -> UInt32 {
        var res: UInt32 = 0
        for _ in 0..<n {
            range >>= 1
            code &-= range
            let t = 0 &- (code >> 31)
            code &+= range & t
            if code == range { throw LZMAError.corrupt }
            try normalize()
            res = (res << 1) &+ (t &+ 1)
        }
        return res
    }

    mutating func tree(_ probs: inout [UInt16], base: Int, bits: Int) throws -> Int {
        var m = 1
        for _ in 0..<bits { m = (m << 1) + (try bit(&probs, base + m)) }
        return m - (1 << bits)
    }

    mutating func reverseTree(_ probs: inout [UInt16], base: Int, bits: Int) throws -> Int {
        var m = 1, sym = 0
        for i in 0..<bits { let b = try bit(&probs, base + m); m = (m << 1) + b; sym |= b << i }
        return sym
    }
}

/// LZMA decoder state that can be continued across LZMA2 chunks.
nonisolated final class LZMADecoderState {
    var lc = 3, lp = 0, pb = 2
    var probs: [UInt16] = []          // isMatch … align, one flat table
    var litProbs: [UInt16] = []
    var state = 0
    var rep0 = 0, rep1 = 0, rep2 = 0, rep3 = 0
    var out: [UInt8] = []
    let maxOutput: Int

    // Offsets into `probs`.
    static let isMatch = 0, isRep = 192, isRepG0 = 204, isRepG1 = 216, isRepG2 = 228, isRep0Long = 240
    static let posSlot = 432, posDecoders = 688, align = 803
    static let lenBase = 819, repLenBase = 1333, lenSize = 514   // choice, choice2, low[16*8], mid[16*8], high[256]
    static let total = 1847

    init(maxOutput: Int) { self.maxOutput = maxOutput }

    func setProperties(_ props: UInt8) throws {
        var d = Int(props)
        guard d < 9 * 5 * 5 else { throw LZMAError.badProperties }
        lc = d % 9; d /= 9; lp = d % 5; pb = d / 5
        guard lc + lp <= 12 else { throw LZMAError.badProperties }   // LZMA2 requires lc+lp <= 4; LZMA allows more
    }

    func resetState() {
        probs = [UInt16](repeating: 1024, count: Self.total)
        litProbs = [UInt16](repeating: 1024, count: 0x300 << (lc + lp))
        state = 0; rep0 = 0; rep1 = 0; rep2 = 0; rep3 = 0
    }

    private func len(_ rc: inout LZMARangeDecoder, base: Int, posState: Int) throws -> Int {
        if try rc.bit(&probs, base) == 0 { return try rc.tree(&probs, base: base + 2 + posState * 8, bits: 3) }
        if try rc.bit(&probs, base + 1) == 0 { return 8 + (try rc.tree(&probs, base: base + 2 + 128 + posState * 8, bits: 3)) }
        return 16 + (try rc.tree(&probs, base: base + 2 + 256, bits: 8))
    }

    /// Decode until `target` total output bytes (or an end marker when `allowEndMarker`).
    func decode(_ rc: inout LZMARangeDecoder, until target: Int, allowEndMarker: Bool) throws {
        let pbMask = (1 << pb) - 1, lpMask = (1 << lp) - 1
        while out.count < target {
            let posState = out.count & pbMask
            if try rc.bit(&probs, Self.isMatch + (state << 4) + posState) == 0 {
                let prev = out.last.map(Int.init) ?? 0
                let litState = ((out.count & lpMask) << lc) + (prev >> (8 - lc))
                let base = 0x300 * litState
                var symbol = 1
                if state >= 7 {
                    guard rep0 < out.count else { throw LZMAError.corrupt }
                    var matchByte = Int(out[out.count - rep0 - 1])
                    repeat {
                        let matchBit = (matchByte >> 7) & 1
                        matchByte <<= 1
                        let b = try rc.bit(&litProbs, base + ((1 + matchBit) << 8) + symbol)
                        symbol = (symbol << 1) | b
                        if matchBit != b { break }
                    } while symbol < 0x100
                }
                while symbol < 0x100 { symbol = (symbol << 1) | (try rc.bit(&litProbs, base + symbol)) }
                out.append(UInt8(symbol - 0x100))
                state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                continue
            }
            var length: Int
            if try rc.bit(&probs, Self.isRep + state) != 0 {
                guard !out.isEmpty else { throw LZMAError.corrupt }
                if try rc.bit(&probs, Self.isRepG0 + state) == 0 {
                    if try rc.bit(&probs, Self.isRep0Long + (state << 4) + posState) == 0 {
                        state = state < 7 ? 9 : 11
                        guard rep0 < out.count else { throw LZMAError.corrupt }
                        out.append(out[out.count - rep0 - 1])
                        continue
                    }
                } else {
                    let dist: Int
                    if try rc.bit(&probs, Self.isRepG1 + state) == 0 { dist = rep1 }
                    else {
                        if try rc.bit(&probs, Self.isRepG2 + state) == 0 { dist = rep2 } else { dist = rep3; rep3 = rep2 }
                        rep2 = rep1
                    }
                    rep1 = rep0; rep0 = dist
                }
                length = try len(&rc, base: Self.repLenBase, posState: posState)
                state = state < 7 ? 8 : 11
            } else {
                rep3 = rep2; rep2 = rep1; rep1 = rep0
                length = try len(&rc, base: Self.lenBase, posState: posState)
                state = state < 7 ? 7 : 10
                // Distance.
                let lenState = min(length, 3)
                let slot = try rc.tree(&probs, base: Self.posSlot + lenState * 64, bits: 6)
                if slot < 4 { rep0 = slot }
                else {
                    let direct = (slot >> 1) - 1
                    var dist = (2 | (slot & 1)) << direct
                    if slot < 14 {
                        dist += try rc.reverseTree(&probs, base: Self.posDecoders + dist - slot, bits: direct)
                    } else {
                        dist += Int(try rc.directBits(direct - 4)) << 4
                        dist += try rc.reverseTree(&probs, base: Self.align, bits: 4)
                    }
                    rep0 = dist
                }
                if rep0 == 0xFFFF_FFFF {
                    guard allowEndMarker else { throw LZMAError.corrupt }
                    return
                }
            }
            length += 2
            guard rep0 < out.count else { throw LZMAError.corrupt }
            guard out.count + length <= maxOutput else { throw LZMAError.outputTooLarge }
            let start = out.count - rep0 - 1
            let n = min(length, target - out.count)
            for k in 0..<n { out.append(out[start + k]) }
        }
    }
}

nonisolated enum LZMADecoder {
    /// Raw LZMA (7z coder 03 01 01): 5-byte properties, then the stream; `size` bytes of output.
    static func decodeLZMA(_ data: [UInt8], properties: [UInt8], size: Int, maxOutput: Int) throws -> [UInt8] {
        guard properties.count >= 5 else { throw LZMAError.badProperties }
        guard size <= maxOutput else { throw LZMAError.outputTooLarge }
        let d = LZMADecoderState(maxOutput: maxOutput)
        try d.setProperties(properties[0])
        d.resetState()
        d.out.reserveCapacity(size)
        var rc = try LZMARangeDecoder(data, at: 0)
        try d.decode(&rc, until: size, allowEndMarker: true)
        return d.out
    }

    /// LZMA2 (7z coder 21): chunked LZMA with resets; dictionary-size property only.
    static func decodeLZMA2(_ data: [UInt8], size: Int, maxOutput: Int) throws -> [UInt8] {
        guard size <= maxOutput else { throw LZMAError.outputTooLarge }
        let d = LZMADecoderState(maxOutput: maxOutput)
        d.out.reserveCapacity(size)
        var i = 0
        var needProps = true
        while i < data.count {
            let control = Int(data[i]); i += 1
            if control == 0 { break }
            if control == 1 || control == 2 {                         // uncompressed chunk
                guard i + 2 <= data.count else { throw LZMAError.truncated }
                let n = (Int(data[i]) << 8 | Int(data[i + 1])) + 1; i += 2
                guard i + n <= data.count, d.out.count + n <= maxOutput else { throw LZMAError.truncated }
                d.out.append(contentsOf: data[i..<(i + n)]); i += n
                continue
            }
            guard control >= 0x80, i + 4 <= data.count else { throw LZMAError.corrupt }
            let unpacked = ((control & 0x1F) << 16 | Int(data[i]) << 8 | Int(data[i + 1])) + 1
            let packed = (Int(data[i + 2]) << 8 | Int(data[i + 3])) + 1
            i += 4
            let mode = (control >> 5) & 3
            if mode >= 2 {
                guard i < data.count else { throw LZMAError.truncated }
                try d.setProperties(data[i]); i += 1
                guard d.lc + d.lp <= 4 else { throw LZMAError.badProperties }
                needProps = false
            } else if needProps { throw LZMAError.badProperties }
            if mode >= 1 { d.resetState() }
            guard i + packed <= data.count else { throw LZMAError.truncated }
            var rc = try LZMARangeDecoder(Array(data[i..<(i + packed)]), at: 0)
            try d.decode(&rc, until: d.out.count + unpacked, allowEndMarker: false)
            i += packed
        }
        guard d.out.count >= size else { throw LZMAError.truncated }
        return Array(d.out.prefix(size))
    }
}
