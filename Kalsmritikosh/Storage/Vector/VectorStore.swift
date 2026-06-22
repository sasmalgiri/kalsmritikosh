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
