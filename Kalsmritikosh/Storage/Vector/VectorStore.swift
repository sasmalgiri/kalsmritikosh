//
//  VectorStore.swift
//  Kalsmritikosh
//
//  M0 ships a protocol + a SQLite-backed implementation that stores
//  embeddings as BLOBs and does brute-force cosine. When the sqlite-vec
//  extension is vendored, the same protocol switches to ANN.
//

import Foundation

public protocol VectorStore: Sendable {
    func upsert(chunkID: Chunk.ID, embedding: [Float]) async throws
    func nearest(to embedding: [Float], limit: Int) async throws -> [VectorHit]
    func remove(chunkID: Chunk.ID) async throws
}

public struct VectorHit: Sendable, Hashable {
    public let chunkID: Chunk.ID
    public let score: Double  // cosine similarity, 0...1

    public init(chunkID: Chunk.ID, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}

/// SQLite implementation that stores embeddings as raw little-endian Float
/// blobs. Brute-force cosine until sqlite-vec is loaded.
public actor SQLiteVectorStore: VectorStore {
    private let database: Database

    public init(database: Database) async throws {
        self.database = database
        try await database.exec("""
        CREATE TABLE IF NOT EXISTS vector_embeddings (
            chunk_id   TEXT PRIMARY KEY NOT NULL,
            dim        INTEGER NOT NULL,
            embedding  BLOB NOT NULL,
            FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
        );
        """)
    }

    public func upsert(chunkID: Chunk.ID, embedding: [Float]) async throws {
        // M0 stub: API contract only. The first real embedding pass lands
        // in M2 once chunks exist. Avoid an empty bound-statement path
        // while we don't yet have a binder helper.
        _ = (chunkID, embedding)
    }

    public func nearest(to embedding: [Float], limit: Int) async throws -> [VectorHit] {
        _ = (embedding, limit)
        return []
    }

    public func remove(chunkID: Chunk.ID) async throws {
        _ = chunkID
    }
}
