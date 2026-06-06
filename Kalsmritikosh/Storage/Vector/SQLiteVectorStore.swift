//
//  SQLiteVectorStore.swift
//  Kalsmritikosh
//
//  Brute-force vector store with int8 symmetric quantization. Each row
//  in `vectors` stores `dim`, the quantized blob `q` (Int8 little-endian),
//  and the per-vector `scale` (max|x|/127). Cosine similarity is computed
//  directly on int8 values without dequantization — see `nearest`.
//
//  When sqlite-vec / ANN lands at Gate 3 this is replaced behind the
//  VectorStore protocol — no caller changes.
//

import Foundation
import OSLog

public actor SQLiteVectorStore: VectorStore {
    private let database: Database

    /// Soft cap. Beyond this row count we still scan, but log a Gate 3
    /// reminder so latency regressions are visible.
    public static let bruteForceWarnAt = 2_000_000

    public init(database: Database) {
        self.database = database
    }

    public func upsert(chunkID: Chunk.ID, embedding: [Float]) async throws {
        guard !embedding.isEmpty else { return }
        let (qBlob, scale) = quantize(embedding)
        try await database.exec("""
        INSERT INTO vectors (chunk_id, dim, q, scale)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(chunk_id) DO UPDATE SET
            dim = excluded.dim,
            q = excluded.q,
            scale = excluded.scale;
        """, [
            .uuid(chunkID),
            .integer(Int64(embedding.count)),
            .blob(qBlob),
            .real(scale)
        ])
    }

    public func nearest(
        to embedding: [Float],
        limit: Int,
        candidateChunkIDs: [Chunk.ID]?
    ) async throws -> [VectorHit] {
        guard !embedding.isEmpty, limit > 0 else { return [] }
        let (qBytes, queryScale) = quantizeToBytes(embedding)
        var queryNormSquared: Double = 0
        for b in qBytes {
            let v = Double(Int8(bitPattern: b))
            queryNormSquared += v * v
        }
        let queryNorm = queryNormSquared.squareRoot() * queryScale
        if queryNorm == 0 { return [] }

        let rows: [SQLRow]
        if let candidates = candidateChunkIDs {
            if candidates.isEmpty { return [] }
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
            let sql = "SELECT chunk_id, dim, q, scale FROM vectors WHERE chunk_id IN (\(placeholders));"
            let bindings = candidates.map { SQLValue.uuid($0) }
            rows = try await database.query(sql, bindings)
        } else {
            let totalRows = try await database.query("SELECT COUNT(*) FROM vectors;", [])
            let total = Int(totalRows.first?.int(0) ?? 0)
            if total > Self.bruteForceWarnAt {
                AtlasLog.storage.warning("ANN required — Gate 3 (vector corpus = \(total, privacy: .public))")
            }
            rows = try await database.query("SELECT chunk_id, dim, q, scale FROM vectors;", [])
        }

        var hits: [(Chunk.ID, Double)] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            guard let cid = row.uuid(0),
                  let dim = row.int(1).map(Int.init),
                  let blob = row.blob(2),
                  let scale = row.double(3),
                  dim == embedding.count,
                  blob.count == dim,
                  qBytes.count == dim else { continue }
            var dot: Double = 0
            var rowNormSquared: Double = 0
            blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let rowPtr = raw.bindMemory(to: Int8.self)
                qBytes.withUnsafeBufferPointer { qBuf in
                    let n = min(rowPtr.count, qBuf.count, dim)
                    for i in 0..<n {
                        let a = Double(Int8(bitPattern: qBuf[i]))
                        let b = Double(rowPtr[i])
                        dot += a * b
                        rowNormSquared += b * b
                    }
                }
            }
            let rowNorm = rowNormSquared.squareRoot() * scale
            if rowNorm == 0 { continue }
            let cosine = (dot * queryScale * scale) / (queryNorm * rowNorm)
            hits.append((cid, cosine))
        }
        hits.sort { $0.1 > $1.1 }
        return hits.prefix(limit).map { VectorHit(chunkID: $0.0, score: $0.1) }
    }

    public func remove(chunkID: Chunk.ID) async throws {
        try await database.exec("DELETE FROM vectors WHERE chunk_id = ?;", [.uuid(chunkID)])
    }

    // MARK: - Quantization

    /// Returns the int8 blob + scale. scale = max|x|/127, falling back to
    /// 1.0 when the vector is all zeros so the blob stays well-defined.
    private func quantize(_ embedding: [Float]) -> (Data, Double) {
        let (bytes, scale) = quantizeToBytes(embedding)
        return (Data(bytes), scale)
    }

    /// Returns the int8 quantization as `[UInt8]` so callers can scan the
    /// values without an extra Data → buffer round trip.
    private func quantizeToBytes(_ embedding: [Float]) -> ([UInt8], Double) {
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
}
