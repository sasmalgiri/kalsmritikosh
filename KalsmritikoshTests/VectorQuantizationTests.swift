//
//  VectorQuantizationTests.swift
//  KalsmritikoshTests
//
//  P9.3 step 2 — pins the ONE shared int8 quantization + cosine kernel that
//  SQLiteVectorStore, HNSWVectorIndex and (next) IVFDiskVectorIndex all
//  delegate to. The golden vectors reproduce the exact arithmetic of the two
//  previous private copies (max|x|/127 symmetric scale, round-half-away,
//  clamp ±127, all-zero → scale 1.0), so numeric drift in ANY consumer fails
//  here first. Pure; no DB.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("P9.3 — shared vector quantization kernel")
struct VectorQuantizationTests {

    @Test("Golden vectors: exact bytes + scale of the historical private implementations")
    func goldenParity() {
        // [1, -1, 0.5] → maxAbs 1, scale 1/127; values scale to ±127 and 63.5 → 64 (round half away).
        let (b1, s1) = VectorQuantization.quantizeToBytes([1.0, -1.0, 0.5])
        #expect(s1 == 1.0 / 127.0)
        #expect(b1 == [UInt8(bitPattern: 127), UInt8(bitPattern: -127), UInt8(bitPattern: 64)])

        // Scaling invariance of the bytes: [10, -10, 5] quantizes to the same bytes, 10× the scale.
        let (b2, s2) = VectorQuantization.quantizeToBytes([10.0, -10.0, 5.0])
        #expect(b2 == b1)
        #expect(abs(s2 - 10.0 / 127.0) < 1e-12)

        // All-zero vector: scale 1.0, zero bytes — the historical well-definedness rule.
        let (b3, s3) = VectorQuantization.quantizeToBytes([0, 0, 0, 0])
        #expect(s3 == 1.0)
        #expect(b3 == [0, 0, 0, 0])

        // Empty vector.
        let (b4, s4) = VectorQuantization.quantizeToBytes([])
        #expect(b4.isEmpty && s4 == 1.0)
    }

    @Test("Round trip: dequantized values stay within one quantization step")
    func roundTripBound() {
        let v: [Float] = (0..<384).map { i in Float(sin(Double(i) * 0.37)) * 3.5 }
        let (blob, scale) = VectorQuantization.quantize(v)
        let back = VectorQuantization.floats(fromInt8: blob)
        #expect(back.count == v.count)
        for i in 0..<v.count {
            let restored = Double(back[i]) * scale
            #expect(abs(restored - Double(v[i])) <= scale * 0.5 + 1e-9,
                    "component \(i) drifted beyond half a step")
        }
    }

    @Test("Cosine kernel: self-similarity ≈ 1, orthogonal ≈ 0, opposite ≈ -1")
    func cosineSemantics() throws {
        let a: [Float] = [1, 0, 0, 2]
        let query = try #require(VectorQuantization.prepareQuery(a))
        let (qa, sa) = VectorQuantization.quantize(a)
        #expect(abs(try #require(VectorQuantization.cosineScore(query: query, candidate: qa, scale: sa)) - 1.0) < 1e-6)

        let (qb, sb) = VectorQuantization.quantize([0, 3, -1, 0])   // orthogonal to a
        #expect(abs(try #require(VectorQuantization.cosineScore(query: query, candidate: qb, scale: sb))) < 0.02)

        let (qc, sc) = VectorQuantization.quantize([-1, 0, 0, -2])  // opposite of a
        #expect(abs(try #require(VectorQuantization.cosineScore(query: query, candidate: qc, scale: sc)) + 1.0) < 1e-6)
    }

    @Test("Kernel guards: zero-norm query is unpreparable; dimension mismatch and zero-norm candidates score nil")
    func kernelGuards() throws {
        #expect(VectorQuantization.prepareQuery([0, 0, 0]) == nil)
        #expect(VectorQuantization.prepareQuery([]) == nil)
        let query = try #require(VectorQuantization.prepareQuery([1, 2, 3]))
        #expect(VectorQuantization.cosineScore(query: query, candidate: Data([1, 2]), scale: 0.1) == nil)
        let (zeroBlob, zeroScale) = VectorQuantization.quantize([0, 0, 0])
        #expect(VectorQuantization.cosineScore(query: query, candidate: zeroBlob, scale: zeroScale) == nil)
    }

    @Test("Ranking parity: the kernel orders candidates identically to exact float cosine")
    func rankingParity() throws {
        // Deterministic pseudo-random corpus; compare kernel ranking against
        // exact float cosine on the ORIGINAL vectors. int8 quantization can
        // swap near-ties, so compare top-5 SETS with generous margins.
        var state: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> Float {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return Float(Double(state &* 0x2545_F491_4F6C_DD1D % 1_000_000) / 1_000_000.0) - 0.5
        }
        let queryVec: [Float] = (0..<64).map { _ in rand() }
        let corpus: [[Float]] = (0..<50).map { _ in (0..<64).map { _ in rand() } }

        func exactCosine(_ a: [Float], _ b: [Float]) -> Double {
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in 0..<a.count { dot += Double(a[i] * b[i]); na += Double(a[i] * a[i]); nb += Double(b[i] * b[i]) }
            return dot / (na.squareRoot() * nb.squareRoot())
        }
        let exactTop = Set(corpus.indices.sorted { exactCosine(queryVec, corpus[$0]) > exactCosine(queryVec, corpus[$1]) }.prefix(5))

        let query = try #require(VectorQuantization.prepareQuery(queryVec))
        let kernelScores = corpus.map { v -> Double in
            let (blob, scale) = VectorQuantization.quantize(v)
            return VectorQuantization.cosineScore(query: query, candidate: blob, scale: scale) ?? -2
        }
        let kernelTop = Set(corpus.indices.sorted { kernelScores[$0] > kernelScores[$1] }.prefix(5))
        #expect(exactTop.intersection(kernelTop).count >= 4,
                "quantized ranking diverged from exact cosine: \(exactTop) vs \(kernelTop)")
    }
}
