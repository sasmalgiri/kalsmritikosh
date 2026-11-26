//
//  VectorStore.swift
//  Kalsmritikosh
//
//  Protocol for the chunk-embedding store. T5 ships a brute-force int8
//  implementation (`SQLiteVectorStore`). When sqlite-vec / ANN lands at
//  Gate 3 it slots behind the same protocol — callers don't change.
//

import Foundation

public protocol VectorStore: Sendable {
    /// Stable identity of the embedding model this store reads and writes (v54
    /// model-aware storage). Vectors from different models coexist in
    /// `chunk_embeddings` keyed by (chunk_id, model_id); a store instance is
    /// scoped to ONE model, so a query vector is only ever compared against
    /// same-model rows. Nonisolated so the embedding drain can read it without
    /// awaiting the actor.
    nonisolated var embeddingModelID: String { get }
    func upsert(chunkID: Chunk.ID, embedding: [Float]) async throws
    /// Nearest-neighbours by cosine similarity. If `candidateChunkIDs`
    /// is non-nil, the scan is restricted to those rows (FTS / entity
    /// prefilter). nil → full scan with implementation-defined caps.
    func nearest(
        to embedding: [Float],
        limit: Int,
        candidateChunkIDs: [Chunk.ID]?
    ) async throws -> [VectorHit]
    func remove(chunkID: Chunk.ID) async throws
    /// Unified path PERF-19 (owner 2026-11-22, round 2) — not tested yet: write a whole batch of vectors in one
    /// transaction. Returns the chunk ids that were written.
    func upsertBatch(_ items: [(chunkID: Chunk.ID, embedding: [Float])]) async throws -> [Chunk.ID]
    /// The version tag stored beside each vector (a shard writes its vectors with the main store's tag).
    nonisolated var embeddingModelVersionTag: String { get }
    /// Fix PERF-28 (owner 2026-11-23): the size of every vector this store's label holds (nil = not fixed by the caller).
    nonisolated var embeddingDimension: Int? { get }
    /// Fix PERF-28 (owner 2026-11-23): write vectors under the embedder that made each one. A vector of this store's
    /// producer (or unlabelled) goes under this store's label after the size check; another producer's vector goes under
    /// THAT producer's label (rows coexist per model, never mixed); a vector whose size is not its producer's is refused.
    func upsertBatchLabelled(_ items: [LabelledVector]) async throws -> LabelledWrite
}

/// One vector with the embedder that made it (Fix PERF-28).
public nonisolated struct LabelledVector: Sendable {
    public let chunkID: Chunk.ID
    public let embedding: [Float]
    public let producer: EmbeddingProducer?
    public init(chunkID: Chunk.ID, embedding: [Float], producer: EmbeddingProducer?) {
        self.chunkID = chunkID; self.embedding = embedding; self.producer = producer
    }
}

/// What a labelled write did (Fix PERF-28): under this store's label, under another embedder's label, refused.
public nonisolated struct LabelledWrite: Sendable, Equatable {
    public var active: [Chunk.ID] = []
    public var other: [Chunk.ID] = []
    public var refused: [Chunk.ID] = []
    public init(active: [Chunk.ID] = [], other: [Chunk.ID] = [], refused: [Chunk.ID] = []) {
        self.active = active; self.other = other; self.refused = refused
    }
}

public extension VectorStore {
    /// The current Apple NLEmbedding baseline. Overridden per model when a
    /// quality (Core ML) embedder is wired.
    nonisolated var embeddingModelID: String { "apple.nl.v1" }

    nonisolated var embeddingModelVersionTag: String { "1" }

    nonisolated var embeddingDimension: Int? { nil }

    /// Default: this store's own producer only (a store without per-model writes refuses another embedder's vectors).
    func upsertBatchLabelled(_ items: [LabelledVector]) async throws -> LabelledWrite {
        var out = LabelledWrite()
        var mine: [(chunkID: Chunk.ID, embedding: [Float])] = []
        for item in items where !item.embedding.isEmpty {
            if let p = item.producer, p.id != embeddingModelID || p.dimension != item.embedding.count {
                out.refused.append(item.chunkID); continue
            }
            if let d = embeddingDimension, d != item.embedding.count { out.refused.append(item.chunkID); continue }
            mine.append((item.chunkID, item.embedding))
        }
        out.active = try await upsertBatch(mine)
        return out
    }

    /// Default: one write per vector (stores without a transactional batch path).
    func upsertBatch(_ items: [(chunkID: Chunk.ID, embedding: [Float])]) async throws -> [Chunk.ID] {
        var written: [Chunk.ID] = []
        for item in items where !item.embedding.isEmpty {
            try await upsert(chunkID: item.chunkID, embedding: item.embedding)
            written.append(item.chunkID)
        }
        return written
    }

    /// Convenience overload — full-scan nearest.
    func nearest(to embedding: [Float], limit: Int) async throws -> [VectorHit] {
        try await nearest(to: embedding, limit: limit, candidateChunkIDs: nil)
    }
}

public struct VectorHit: Sendable, Hashable {
    public let chunkID: Chunk.ID
    public let score: Double  // cosine similarity, -1...1 (typical use ≥ 0)

    public nonisolated init(chunkID: Chunk.ID, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}
