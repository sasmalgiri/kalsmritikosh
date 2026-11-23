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
    /// Fix PERF-28 (owner 2026-11-23): the size of every vector under this store's label (nil = not fixed: tests and
    /// harnesses that never mix embedders). When set, a vector of another size is never written under this label, never
    /// read into an index and never compared with a query.
    public nonisolated let embeddingDimension: Int?

    /// " AND dim = ?" when the size is fixed (with `dimBinds`), so every read sees one embedder's vectors only.
    private nonisolated var dimSQL: String { embeddingDimension == nil ? "" : " AND dim = ?" }
    private nonisolated var dimBinds: [SQLValue] { embeddingDimension.map { [.integer(Int64($0))] } ?? [] }

    /// A vector refused because its size is not the label's (Fix PERF-28).
    public enum LabelError: Error, CustomStringConvertible {
        case dimensionMismatch(label: String, expected: Int, got: Int)
        public var description: String {
            switch self {
            case .dimensionMismatch(let l, let e, let g): return "a \(g)-dimension vector is not written under \(l) (\(e) dimensions)"
            }
        }
    }

    /// Soft cap. Beyond this row count we still scan, but log a Gate 3
    /// reminder so latency regressions are visible. `nonisolated` so the
    /// actor's own `nearest` (running on the actor) can read it without
    /// hopping back through MainActor isolation.
    public nonisolated static let bruteForceWarnAt = 2_000_000

    public init(
        database: Database,
        ann: ANNIndexCoordinator? = nil,
        modelID: String = "apple.nl.v1",
        modelVersion: String = "1",
        dimension: Int? = nil
    ) {
        self.database = database
        self.ann = ann
        self.embeddingModelID = modelID
        self.embeddingModelVersion = modelVersion
        self.embeddingDimension = dimension
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
            "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?\(dimSQL);",
            [.text(embeddingModelID)] + dimBinds
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Speed PERF-28 (owner 2026-11-23) — not tested yet: rows up to and including `chunkID` in the
    /// keyset order; a saved partial HNSW build resumes only when this still equals what it covered.
    public func count(through chunkID: Chunk.ID) async throws -> Int {
        let rows = try await database.query(
            "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ? AND chunk_id <= ?\(dimSQL);",
            [.text(embeddingModelID), .text(chunkID.uuidString)] + dimBinds
        )
        return Int(rows.first?.int(0) ?? 0)
    }

    /// Paged enumeration of every vector row. Used by HNSW build.
    /// Speed PERF-23 (owner 2026-11-23) — not tested yet: keyset `chunk_id > ?` in the same chunk_id order (the
    /// (chunk_id, model_id) primary key serves it), not OFFSET. The page's last RAW chunk id is returned as `next`
    /// so a row that fails to decode never ends the walk early; a scale stored as an integer is accepted.
    public func listAll(after: Chunk.ID? = nil, pageSize: Int = 5_000) async throws -> (rows: [RawVector], next: Chunk.ID?, rawCount: Int) {
        let rows = try await database.query("""
        SELECT chunk_id, q, scale FROM chunk_embeddings
        WHERE model_id = ? AND chunk_id > ?\(dimSQL)
        ORDER BY chunk_id ASC
        LIMIT ?;
        """, [.text(embeddingModelID), .text(after?.uuidString ?? "")] + dimBinds + [.integer(Int64(pageSize))])
        var out: [RawVector] = []
        for row in rows {
            guard let cid = row.uuid(0),
                  let blob = row.blob(1),
                  let scale = row.double(2) ?? row.int(2).map(Double.init) else {
                KalsmritikoshLog.storage.error("SQLiteVectorStore.listAll: skipped an undecodable vector row")
                continue
            }
            var bytes = [UInt8](repeating: 0, count: blob.count)
            blob.copyBytes(to: &bytes, count: blob.count)
            out.append(RawVector(chunkID: cid, bytes: bytes, scale: scale))
        }
        return (out, rows.last?.uuid(0), rows.count)
    }

    public func upsert(chunkID: Chunk.ID, embedding: [Float]) async throws {
        guard !embedding.isEmpty else { return }
        if let d = embeddingDimension, d != embedding.count {
            KalsmritikoshLog.storage.error("SQLiteVectorStore: refused a \(embedding.count, privacy: .public)-d vector under \(self.embeddingModelID, privacy: .public) (\(d, privacy: .public)-d)")
            throw LabelError.dimensionMismatch(label: embeddingModelID, expected: d, got: embedding.count)
        }
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

    public nonisolated var embeddingModelVersionTag: String { embeddingModelVersion }

    /// Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet: one transaction per batch, multi-row
    /// INSERT … ON CONFLICT (up to 64 rows per statement), instead of one commit per vector.
    public func upsertBatch(_ items: [(chunkID: Chunk.ID, embedding: [Float])]) async throws -> [Chunk.ID] {
        let expected = embeddingDimension
        let mismatched = expected.map { d in items.filter { !$0.embedding.isEmpty && $0.embedding.count != d }.count } ?? 0
        if mismatched > 0 {
            KalsmritikoshLog.storage.error("SQLiteVectorStore: refused \(mismatched, privacy: .public) vector(s) of another size under \(self.embeddingModelID, privacy: .public) (Fix PERF-28: one embedder per label)")
        }
        let rows: [(Chunk.ID, Data, Double, Int)] = items.compactMap { item in
            guard !item.embedding.isEmpty, expected.map({ $0 == item.embedding.count }) ?? true else { return nil }
            let (q, scale) = quantize(item.embedding)
            return (item.chunkID, q, scale, item.embedding.count)
        }
        guard !rows.isEmpty else { return [] }
        let model = embeddingModelID
        let version = embeddingModelVersion
        let now = Date()
        let sendable = rows.map { SendableVectorRow(chunkID: $0.0, q: $0.1, scale: $0.2, dim: $0.3) }
        try await database.withSavepoint("vector_batch") { db in
            var start = 0
            while start < sendable.count {
                let piece = sendable[start..<min(sendable.count, start + 64)]
                let values = Array(repeating: "(?, ?, ?, ?, ?, ?, ?)", count: piece.count).joined(separator: ", ")
                var binds: [SQLValue] = []
                binds.reserveCapacity(piece.count * 7)
                for r in piece {
                    binds += [.uuid(r.chunkID), .text(model), .text(version), .integer(Int64(r.dim)), .blob(r.q), .real(r.scale), .date(now)]
                }
                try db.exec("""
                INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
                VALUES \(values)
                ON CONFLICT(chunk_id, model_id) DO UPDATE SET
                    model_version = excluded.model_version,
                    dim = excluded.dim,
                    q = excluded.q,
                    scale = excluded.scale,
                    created_at = excluded.created_at;
                """, binds)
                start += piece.count
            }
        }
        // P9.3 — the disk index follows the committed rows.
        if let ann {
            for r in sendable { await ann.noteUpsert(chunkID: r.chunkID, q: r.q, scale: r.scale) }
        }
        return sendable.map(\.chunkID)
    }

    public func nearest(
        to embedding: [Float],
        limit: Int,
        candidateChunkIDs: [Chunk.ID]?
    ) async throws -> [VectorHit] {
        guard !embedding.isEmpty, limit > 0 else { return [] }
        // Fix PERF-28 (owner 2026-11-23): a query vector from another embedder (another size) is never compared with this
        // label's vectors — the vector layer is unavailable for it and the structured layers answer.
        if let d = embeddingDimension, d != embedding.count {
            KalsmritikoshLog.storage.error("SQLiteVectorStore.nearest: a \(embedding.count, privacy: .public)-d query is not compared with \(self.embeddingModelID, privacy: .public) (\(d, privacy: .public)-d) — vector layer unavailable for this query")
            return []
        }
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
            let sql = "SELECT chunk_id, dim, q, scale FROM chunk_embeddings WHERE model_id = ?\(dimSQL) AND chunk_id IN (\(placeholders));"
            let rows = try await database.query(sql, [.text(embeddingModelID)] + dimBinds + candidates.map { SQLValue.uuid($0) })
            for row in rows {
                if let hit = score(row: row, col: 0, qFloat: qFloat, queryScale: queryScale, queryNorm: queryNorm, dimExpected: embedding.count) {
                    top.offer(hit.0, hit.1)
                }
            }
        } else {
            let totalRows = try await database.query(
                "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ?\(dimSQL);", [.text(embeddingModelID)] + dimBinds
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
                    "SELECT rowid, chunk_id, dim, q, scale FROM chunk_embeddings WHERE model_id = ?\(dimSQL) AND rowid > ? ORDER BY rowid LIMIT ?;",
                    [.text(embeddingModelID)] + dimBinds + [.integer(lastRowID), .integer(Int64(pageSize))]
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

    // MARK: - Fix PERF-28 (owner 2026-11-23): labelled writes and the mislabel repair

    public func upsertBatchLabelled(_ items: [LabelledVector]) async throws -> LabelledWrite {
        var out = LabelledWrite()
        var mine: [(chunkID: Chunk.ID, embedding: [Float])] = []
        var others: [String: (producer: EmbeddingProducer, rows: [SendableVectorRow])] = [:]
        for item in items where !item.embedding.isEmpty {
            guard let p = item.producer, p.id != embeddingModelID else {
                // This store's producer (or unlabelled): its label, after the size check.
                if let p = item.producer, p.dimension != item.embedding.count { out.refused.append(item.chunkID); continue }
                if let d = embeddingDimension, d != item.embedding.count { out.refused.append(item.chunkID); continue }
                mine.append((item.chunkID, item.embedding))
                continue
            }
            guard p.dimension == item.embedding.count else { out.refused.append(item.chunkID); continue }
            let (q, scale) = quantize(item.embedding)
            others[p.id, default: (p, [])].rows.append(SendableVectorRow(chunkID: item.chunkID, q: q, scale: scale, dim: item.embedding.count))
        }
        if !out.refused.isEmpty {
            KalsmritikoshLog.storage.error("SQLiteVectorStore: refused \(out.refused.count, privacy: .public) vector(s) whose size is not their embedder's")
        }
        out.active = try await upsertBatch(mine)
        // Another embedder's vectors: under ITS label (coexisting rows, never this store's index).
        let version = embeddingModelVersion
        let now = Date()
        for (label, group) in others.sorted(by: { $0.key < $1.key }) {
            let rows = group.rows
            try await database.withSavepoint("vector_batch_other") { db in
                for r in rows {
                    try db.exec("""
                    INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(chunk_id, model_id) DO UPDATE SET
                        model_version = excluded.model_version, dim = excluded.dim, q = excluded.q,
                        scale = excluded.scale, created_at = excluded.created_at;
                    """, [.uuid(r.chunkID), .text(label), .text(version), .integer(Int64(r.dim)), .blob(r.q), .real(r.scale), .date(now)])
                }
            }
            out.other += rows.map(\.chunkID)
        }
        return out
    }

    /// Vectors stored under this label whose size is not the label's — written by an older build that labelled the
    /// fallback's vectors with the primary's name. Counted without changing anything.
    public func mislabeledCount() async throws -> Int {
        guard let d = embeddingDimension else { return 0 }
        let rows = try await database.query(
            "SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ? AND dim <> ?;", [.text(embeddingModelID), .integer(Int64(d))])
        return Int(rows.first?.int(0) ?? 0)
    }

    /// The repair: such vectors leave this label (vectors are derived data; their chunks are never touched) together with
    /// any index posting they had, so the embedding drain re-embeds those chunks with this label's own embedder. A vector
    /// of `relabelTo`'s size (the fallback that really made it) is first kept under THAT label when the chunk has none
    /// there yet; the rest are removed. Returns how many left this label.
    public func removeMislabeledVectors(relabelTo fallback: EmbeddingProducer? = nil) async throws -> Int {
        guard let d = embeddingDimension else { return 0 }
        let label = embeddingModelID
        let removed: Int = try await database.withSavepoint("vector_mislabel_repair") { db -> Int in
            let n = try db.query("SELECT COUNT(*) FROM chunk_embeddings WHERE model_id = ? AND dim <> ?;",
                                 [.text(label), .integer(Int64(d))]).first?.int(0) ?? 0
            guard n > 0 else { return 0 }
            try db.exec("""
                DELETE FROM ann_postings WHERE model_id = ? AND chunk_id IN
                    (SELECT chunk_id FROM chunk_embeddings WHERE model_id = ? AND dim <> ?);
                """, [.text(label), .text(label), .integer(Int64(d))])
            if let fallback, fallback.id != label, fallback.dimension != d {
                try db.exec("""
                    INSERT OR IGNORE INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
                    SELECT chunk_id, ?, model_version, dim, q, scale, created_at FROM chunk_embeddings
                    WHERE model_id = ? AND dim = ?;
                    """, [.text(fallback.id), .text(label), .integer(Int64(fallback.dimension))])
            }
            try db.exec("DELETE FROM chunk_embeddings WHERE model_id = ? AND dim <> ?;", [.text(label), .integer(Int64(d))])
            return Int(n)
        }
        if removed > 0 {
            KalsmritikoshLog.storage.notice("Embedder labels: removed \(removed, privacy: .public) vector(s) under \(label, privacy: .public) whose size was not \(d, privacy: .public); their chunks are re-embedded by the drain")
        }
        return removed
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
nonisolated struct BoundedTopK {
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

    /// Number of hits currently kept (≤ limit).
    var count: Int { items.count }
}

/// One quantised vector row of a batch write (PERF-19).
nonisolated struct SendableVectorRow: Sendable {
    let chunkID: Chunk.ID
    let q: Data
    let scale: Double
    let dim: Int
}
