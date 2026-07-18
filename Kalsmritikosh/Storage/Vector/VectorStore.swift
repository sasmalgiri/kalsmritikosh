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
}

public extension VectorStore {
    /// The current Apple NLEmbedding baseline. Overridden per model when a
    /// quality (Core ML) embedder is wired.
    nonisolated var embeddingModelID: String { "apple.nl.v1" }

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
