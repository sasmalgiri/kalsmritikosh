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
import Accelerate

public actor SQLiteVectorStore: VectorStore {
    private let database: Database
    /// Optional ANN accelerator (P9.3): the coordinator owns BOTH the
    /// in-memory HNSW and the disk-backed IVF index plus the persisted
    /// strategy decision. When it can serve, `nearest()` takes the index
    /// path; SQL stays the durable source-of-truth and the brute-force scan
    /// remains the always-correct fallback.
    private let ann: ANNIndexCoordinator?

    /// v54 — the model whose rows in `chunk_embeddings` this store owns. All
    /// reads/writes are scoped `WHERE model_id = <this>` so an Apple index and
    /// a quality index coexist without overwriting each other.
    public nonisolated let embeddingModelID: String
    private nonisolated let embeddingModelVersion: String

    /// Soft cap. Beyond this row count we still scan, but log a Gate 3
    /// reminder so latency regressions are visible. `nonisolated` so the
    /// actor's own `nearest` (running on the actor) can read it without
    /// hopping back through MainActor isolation.
    public nonisolated static let bruteForceWarnAt = 2_000_000

    public init(
        database: Database,
        ann: ANNIndexCoordinator? = nil,
        modelID: String = "apple.nl.v1",
        modelVersion: String = "1"
    ) {
        self.database = database
        self.ann = ann
        self.embeddingModelID = modelID
        self.embeddingModelVersion = modelVersion
    }

    /// Public so HNSWVectorIndex.build can page through. Each row carries
    /// the chunk id + int8 quantized bytes + per-vector scale.
    public struct RawVector: Sendable {
        public let chunkID: Chunk.ID
        public let bytes: [UInt8]
        public let scale: Double
    }

    /// Row count for the `vectors` table. Cheap; used by HNSW's
    /// load-from-disk validation to decide whether a persisted index
    /// is still in sync with the ledger.
    public func count() async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?;",
            [.text(embeddingModelID)]
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Paged enumeration of every vector row. Used by HNSW build.
    public func listAll(offset: Int = 0, pageSize: Int = 5_000) async throws -> [RawVector] {
        let rows = try await database.query("""
        SELECT chunk_id, q, scale FROM chunk_embeddings
        WHERE model_id = ?
        ORDER BY chunk_id ASC
        LIMIT ? OFFSET ?;
        """, [.text(embeddingModelID), .integer(Int64(pageSize)), .integer(Int64(offset))])
        var out: [RawVector] = []
        for row in rows {
            guard let cid = row.uuid(0),
                  let blob = row.blob(1),
                  let scale = row.double(2) else { continue }
            var bytes = [UInt8](repeating: 0, count: blob.count)
            blob.copyBytes(to: &bytes, count: blob.count)
            out.append(RawVector(chunkID: cid, bytes: bytes, scale: scale))
        }
        return out
    }

    public func upsert(chunkID: Chunk.ID, embedding: [Float]) async throws {
        guard !embedding.isEmpty else { return }
        let (qBlob, scale) = quantize(embedding)
        try await database.exec("""
        INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(chunk_id, model_id) DO UPDATE SET
            model_version = excluded.model_version,
            dim = excluded.dim,
            q = excluded.q,
            scale = excluded.scale,
            created_at = excluded.created_at;
        """, [
            .uuid(chunkID),
            .text(embeddingModelID),
            .text(embeddingModelVersion),
            .integer(Int64(embedding.count)),
            .blob(qBlob),
            .real(scale),
            .date(Date())
        ])
        // P9.3 — keep the disk index durably fresh in the SAME call chain as
        // the ledger write (staleness structurally impossible on this path).
        await ann?.noteUpsert(chunkID: chunkID, q: qBlob, scale: scale)
    }

    public func nearest(
        to embedding: [Float],
        limit: Int,
        candidateChunkIDs: [Chunk.ID]?
    ) async throws -> [VectorHit] {
        guard !embedding.isEmpty, limit > 0 else { return [] }
        // ANN hot path (P9.3): the coordinator serves via the PERSISTED
        // strategy — in-memory HNSW (with its historical size >= stored
        // in-sync guard, the fix for the stale-index recall-0.07 incident)
        // or the disk-backed IVF (transactionally in sync by construction).
        // Pre-filtered queries still take the SQL path so the vector layer
        // honours upstream prefilters; a nil answer falls through to the
        // always-correct brute-force scan.
        if let ann, candidateChunkIDs == nil {
            let stored = (try? await self.count()) ?? 0
            if let hits = await ann.nearest(to: embedding, limit: limit, storedCount: stored) {
                return hits
            }
        }
        let (qBytes, queryScale) = quantizeToBytes(embedding)
        // Accelerate/vDSP: convert the int8 query to Float ONCE (per query, not
        // per row) and reuse it for every row's SIMD dot-product + norm below.
        var qFloat = [Float](repeating: 0, count: qBytes.count)
        qBytes.withUnsafeBytes { raw in
            if let p = raw.bindMemory(to: Int8.self).baseAddress {
                vDSP_vflt8(p, 1, &qFloat, 1, vDSP_Length(qBytes.count))
            }
        }
        var queryNormSq: Float = 0
        vDSP_svesq(qFloat, 1, &queryNormSq, vDSP_Length(qFloat.count))
        let queryNorm = Double(queryNormSq).squareRoot() * queryScale
        if queryNorm == 0 { return [] }

        var top = BoundedTopK(limit: limit)

        if let candidates = candidateChunkIDs {
            if candidates.isEmpty { return [] }
            // Bounded by the caller's candidate set — a single query is fine.
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
            let sql = "SELECT chunk_id, dim, q, scale FROM chunk_embeddings WHERE model_id = ? AND chunk_id IN (\(placeholders));"
            let rows = try await database.query(sql, [.text(embeddingModelID)] + candidates.map { SQLValue.uuid($0) })
            for row in rows {
                if let hit = score(row: row, col: 0, qFloat: qFloat, queryScale: queryScale, queryNorm: queryNorm, dimExpected: embedding.count) {
                    top.offer(hit.0, hit.1)
                }
            }
        } else {
            let totalRows = try await database.query(
                "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?;", [.text(embeddingModelID)]
            )
            let total = Int(totalRows.first?.int(0) ?? 0)
            if total > Self.bruteForceWarnAt {
                KalsmritikoshLog.storage.warning("ANN required — Gate 3 (vector corpus = \(total, privacy: .public))")
            }
            // MEMORY-BOUNDED full scan (P9.3): page by rowid so peak memory is one
            // page + K, never the whole table — the fallback that must survive a
            // corpus too big for the in-memory HNSW.
            let pageSize = 10_000
            var lastRowID: Int64 = 0
            while true {
                let rows = try await database.query(
                    "SELECT rowid, chunk_id, dim, q, scale FROM chunk_embeddings WHERE model_id = ? AND rowid > ? ORDER BY rowid LIMIT ?;",
                    [.text(embeddingModelID), .integer(lastRowID), .integer(Int64(pageSize))]
                )
                if rows.isEmpty { break }
                for row in rows {
                    if let rid = row.int(0) { lastRowID = rid }
                    if let hit = score(row: row, col: 1, qFloat: qFloat, queryScale: queryScale, queryNorm: queryNorm, dimExpected: embedding.count) {
                        top.offer(hit.0, hit.1)
                    }
                }
                if rows.count < pageSize { break }
            }
        }
        return top.sortedDescending().map { VectorHit(chunkID: $0.0, score: $0.1) }
    }

    /// Cosine of one vectors row against the query, computed on int8 blobs via
    /// Accelerate/vDSP (SIMD dot-product + sum-of-squares). `col` is the column
    /// offset of `chunk_id` (0 for the candidate query, 1 when a leading `rowid`
    /// is selected). Returns nil for dim mismatches / zero norm. `qFloat` is the
    /// query pre-converted to Float once by the caller.
    private func score(
        row: SQLRow, col: Int, qFloat: [Float], queryScale: Double, queryNorm: Double, dimExpected: Int
    ) -> (Chunk.ID, Double)? {
        guard let cid = row.uuid(col),
              let dim = row.int(col + 1).map(Int.init),
              let blob = row.blob(col + 2),
              let scale = row.double(col + 3),
              dim == dimExpected, blob.count == dim, qFloat.count == dim else { return nil }
        var rowFloat = [Float](repeating: 0, count: dim)
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let p = raw.bindMemory(to: Int8.self).baseAddress {
                vDSP_vflt8(p, 1, &rowFloat, 1, vDSP_Length(dim))
            }
        }
        var dot: Float = 0
        vDSP_dotpr(qFloat, 1, rowFloat, 1, &dot, vDSP_Length(dim))
        var rowNormSq: Float = 0
        vDSP_svesq(rowFloat, 1, &rowNormSq, vDSP_Length(dim))
        let rowNorm = Double(rowNormSq).squareRoot() * scale
        guard rowNorm != 0 else { return nil }
        return (cid, (Double(dot) * queryScale * scale) / (queryNorm * rowNorm))
    }

    public func remove(chunkID: Chunk.ID) async throws {
        // Remove this model's embedding for the chunk. (Chunk deletion itself
        // cascades all models via the FK, ann_postings included.)
        try await database.exec(
            "DELETE FROM chunk_embeddings WHERE chunk_id = ? AND model_id = ?;",
            [.uuid(chunkID), .text(embeddingModelID)]
        )
        await ann?.noteRemove(chunkID: chunkID)
    }

    // MARK: - Quantization

    // P9.3 step 2 — quantization delegates to the ONE shared kernel
    // (VectorQuantization) so ingest, brute force, HNSW and IVF can never
    // drift numerically. Parity with the previous private copy is pinned by
    // VectorQuantizationTests.

    /// Returns the int8 blob + scale. scale = max|x|/127, falling back to
    /// 1.0 when the vector is all zeros so the blob stays well-defined.
    private func quantize(_ embedding: [Float]) -> (Data, Double) {
        VectorQuantization.quantize(embedding)
    }

    /// Returns the int8 quantization as `[UInt8]` so callers can scan the
    /// values without an extra Data → buffer round trip.
    private func quantizeToBytes(_ embedding: [Float]) -> ([UInt8], Double) {
        VectorQuantization.quantizeToBytes(embedding)
    }
}

/// A fixed-size best-K collector: keeps only the top `limit` (chunkID, score)
/// pairs seen, so a full scan of any-size corpus uses O(limit) memory. `limit`
/// is tiny (≤ ~50), so the kept list stays sorted ascending by insertion.
struct BoundedTopK {
    private let limit: Int
    /// Ascending by score — the weakest kept hit is at index 0.
    private var items: [(Chunk.ID, Double)] = []

    init(limit: Int) { self.limit = max(0, limit) }

    mutating func offer(_ id: Chunk.ID, _ score: Double) {
        guard limit > 0 else { return }
        if items.count < limit {
            insert((id, score))
        } else if score > items[0].1 {
            items.removeFirst()
            insert((id, score))
        }
    }

    private mutating func insert(_ hit: (Chunk.ID, Double)) {
        var i = 0
        while i < items.count && items[i].1 < hit.1 { i += 1 }
        items.insert(hit, at: i)
    }

    /// Best-first (descending score).
    func sortedDescending() -> [(Chunk.ID, Double)] { items.reversed() }
}
