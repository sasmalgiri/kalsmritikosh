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
    /// Optional ANN accelerator. When wired AND built, `nearest()` hits
    /// the HNSW index instead of brute-forcing every row. SQL stays
    /// the durable source-of-truth; the index is rebuilt from SQL on
    /// every cold boot.
    private let annIndex: HNSWVectorIndex?

    /// Soft cap. Beyond this row count we still scan, but log a Gate 3
    /// reminder so latency regressions are visible. `nonisolated` so the
    /// actor's own `nearest` (running on the actor) can read it without
    /// hopping back through MainActor isolation.
    public nonisolated static let bruteForceWarnAt = 2_000_000

    public init(database: Database, annIndex: HNSWVectorIndex? = nil) {
        self.database = database
        self.annIndex = annIndex
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
        let rows = try await database.query("SELECT COUNT(*) FROM vectors;")
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Paged enumeration of every vector row. Used by HNSW build.
    public func listAll(offset: Int = 0, pageSize: Int = 5_000) async throws -> [RawVector] {
        let rows = try await database.query("""
        SELECT chunk_id, q, scale FROM vectors
        ORDER BY chunk_id ASC
        LIMIT ? OFFSET ?;
        """, [.integer(Int64(pageSize)), .integer(Int64(offset))])
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
        // ANN hot path: when the HNSW index is built AND no
        // pre-filter is requested (candidateChunkIDs == nil), the
        // index answers in O(log N) instead of O(N) brute-force.
        // Pre-filtered queries still take the SQL path so the
        // vector layer can honour upstream layer prefilters.
        if let ann = annIndex, candidateChunkIDs == nil {
            if await ann.isBuilt() {
                return await ann.nearest(to: embedding, limit: limit)
            }
        }
        let (qBytes, queryScale) = quantizeToBytes(embedding)
        var queryNormSquared: Double = 0
        for b in qBytes {
            let v = Double(Int8(bitPattern: b))
            queryNormSquared += v * v
        }
        let queryNorm = queryNormSquared.squareRoot() * queryScale
        if queryNorm == 0 { return [] }

        var top = BoundedTopK(limit: limit)

        if let candidates = candidateChunkIDs {
            if candidates.isEmpty { return [] }
            // Bounded by the caller's candidate set — a single query is fine.
            let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
            let sql = "SELECT chunk_id, dim, q, scale FROM vectors WHERE chunk_id IN (\(placeholders));"
            let rows = try await database.query(sql, candidates.map { SQLValue.uuid($0) })
            for row in rows {
                if let hit = score(row: row, col: 0, qBytes: qBytes, queryScale: queryScale, queryNorm: queryNorm, dimExpected: embedding.count) {
                    top.offer(hit.0, hit.1)
                }
            }
        } else {
            let totalRows = try await database.query("SELECT COUNT(*) FROM vectors;", [])
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
                    "SELECT rowid, chunk_id, dim, q, scale FROM vectors WHERE rowid > ? ORDER BY rowid LIMIT ?;",
                    [.integer(lastRowID), .integer(Int64(pageSize))]
                )
                if rows.isEmpty { break }
                for row in rows {
                    if let rid = row.int(0) { lastRowID = rid }
                    if let hit = score(row: row, col: 1, qBytes: qBytes, queryScale: queryScale, queryNorm: queryNorm, dimExpected: embedding.count) {
                        top.offer(hit.0, hit.1)
                    }
                }
                if rows.count < pageSize { break }
            }
        }
        return top.sortedDescending().map { VectorHit(chunkID: $0.0, score: $0.1) }
    }

    /// Cosine of one vectors row against the query, computed on int8 blobs. `col`
    /// is the column offset of `chunk_id` (0 for the candidate query, 1 when a
    /// leading `rowid` is selected). Returns nil for dim mismatches / zero norm.
    private func score(
        row: SQLRow, col: Int, qBytes: [UInt8], queryScale: Double, queryNorm: Double, dimExpected: Int
    ) -> (Chunk.ID, Double)? {
        guard let cid = row.uuid(col),
              let dim = row.int(col + 1).map(Int.init),
              let blob = row.blob(col + 2),
              let scale = row.double(col + 3),
              dim == dimExpected, blob.count == dim, qBytes.count == dim else { return nil }
        var dot: Double = 0
        var rowNormSquared: Double = 0
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let rowPtr = raw.bindMemory(to: Int8.self)
            qBytes.withUnsafeBufferPointer { qBuf in
                let n = min(rowPtr.count, qBuf.count, dim)
                for i in 0..<n {
                    dot += Double(Int8(bitPattern: qBuf[i])) * Double(rowPtr[i])
                    rowNormSquared += Double(rowPtr[i]) * Double(rowPtr[i])
                }
            }
        }
        let rowNorm = rowNormSquared.squareRoot() * scale
        guard rowNorm != 0 else { return nil }
        return (cid, (dot * queryScale * scale) / (queryNorm * rowNorm))
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
