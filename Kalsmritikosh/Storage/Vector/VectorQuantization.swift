//
//  VectorQuantization.swift
//  Kalsmritikosh
//
//  P9.3 step 2 — the ONE int8 symmetric-quantization + cosine-scoring kernel.
//  Extracted byte-for-byte from the two identical private copies in
//  SQLiteVectorStore and HNSWVectorIndex (both now delegate here) so the
//  third consumer (IVFDiskVectorIndex) cannot drift: a vector quantized by
//  ingest, scored by the brute-force scan, walked by HNSW, or probed by IVF
//  goes through exactly this arithmetic. scale = max|x|/127 (1.0 for the
//  all-zero vector so the blob stays well-defined); scoring expands int8 to
//  float with vDSP and computes cosine on the dequantized magnitudes.
//

import Foundation
import Accelerate

public enum VectorQuantization {

    /// Int8 symmetric quantization. Returns the raw bytes + per-vector scale.
    public nonisolated static func quantizeToBytes(_ embedding: [Float]) -> ([UInt8], Double) {
        var maxAbs: Float = 0
        for x in embedding { let a = Swift.abs(x); if a > maxAbs { maxAbs = a } }
        let scale = maxAbs == 0 ? 1.0 : Double(maxAbs) / 127.0
        var out = [UInt8](repeating: 0, count: embedding.count)
        if scale > 0 {
            for i in 0..<embedding.count {
                let v = (Double(embedding[i]) / scale).rounded()
                let clamped = Swift.max(-127.0, Swift.min(127.0, v))
                out[i] = UInt8(bitPattern: Int8(clamped))
            }
        }
        return (out, scale)
    }

    /// Data-typed convenience for repository blobs.
    public nonisolated static func quantize(_ embedding: [Float]) -> (Data, Double) {
        let (bytes, scale) = quantizeToBytes(embedding)
        return (Data(bytes), scale)
    }

    /// Expand an int8 blob to floats for vDSP scoring.
    public nonisolated static func floats(fromInt8 blob: Data) -> [Float] {
        var out = [Float](repeating: 0, count: blob.count)
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let p = raw.bindMemory(to: Int8.self).baseAddress {
                vDSP_vflt8(p, 1, &out, 1, vDSP_Length(blob.count))
            }
        }
        return out
    }

    /// A query prepared once, scored against many candidates. The query is
    /// itself int8-quantized first (matching the stored representation) so
    /// query and candidates live in the same numeric space.
    public struct PreparedQuery: Sendable {
        public let qFloat: [Float]
        public let scale: Double
        public let norm: Double
        public var dimension: Int { qFloat.count }
    }

    /// nil when the embedding is empty or has zero norm (nothing can score).
    public nonisolated static func prepareQuery(_ embedding: [Float]) -> PreparedQuery? {
        guard !embedding.isEmpty else { return nil }
        let (qBytes, queryScale) = quantizeToBytes(embedding)
        var qFloat = [Float](repeating: 0, count: qBytes.count)
        qBytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: Int8.self, capacity: qBytes.count) { p in
                vDSP_vflt8(p, 1, &qFloat, 1, vDSP_Length(qBytes.count))
            }
        }
        var queryNormSq: Float = 0
        vDSP_svesq(qFloat, 1, &queryNormSq, vDSP_Length(qFloat.count))
        let norm = Double(queryNormSq).squareRoot() * queryScale
        guard norm != 0 else { return nil }
        return PreparedQuery(qFloat: qFloat, scale: queryScale, norm: norm)
    }

    /// Cosine similarity between a prepared query and one stored int8
    /// candidate. nil on dimension mismatch or a zero-norm candidate —
    /// identical semantics to the store's row scorer.
    public nonisolated static func cosineScore(
        query: PreparedQuery, candidate blob: Data, scale: Double
    ) -> Double? {
        let dim = query.qFloat.count
        guard blob.count == dim else { return nil }
        var rowFloat = [Float](repeating: 0, count: dim)
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let p = raw.bindMemory(to: Int8.self).baseAddress {
                vDSP_vflt8(p, 1, &rowFloat, 1, vDSP_Length(dim))
            }
        }
        var dot: Float = 0
        vDSP_dotpr(query.qFloat, 1, rowFloat, 1, &dot, vDSP_Length(dim))
        var rowNormSq: Float = 0
        vDSP_svesq(rowFloat, 1, &rowNormSq, vDSP_Length(dim))
        let rowNorm = Double(rowNormSq).squareRoot() * scale
        guard rowNorm != 0 else { return nil }
        return (Double(dot) * query.scale * scale) / (query.norm * rowNorm)
    }
}
