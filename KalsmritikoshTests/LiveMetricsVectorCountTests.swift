//
//  LiveMetricsVectorCountTests.swift
//  KalsmritikoshTests
//
//  v1.0-rc8 owner-witness finding — the Live dashboard's "Chunks → Vectors"
//  bar counted the LEGACY `vectors` table, which an early migration folded
//  into `chunk_embeddings` (the per-model store every real component reads:
//  SQLiteVectorStore, ANNIndexRepository, DataHealthCheck). New data never
//  touches `vectors`, so the bar sat at 0% while 9,635 of 10,458 chunks were
//  in fact embedded. The metric must count DISTINCT embedded chunks from
//  chunk_embeddings.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LiveMetrics vector coverage (rc8 witness)")
struct LiveMetricsVectorCountTests {

    /// file → KO → chunk (+ optional embedding rows) so every FK holds.
    @discardableResult
    private func insertChunk(_ db: Database, embedModels: [String]) async throws -> UUID {
        let fileID = UUID(), koID = UUID(), chunkID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("body"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(chunkID), .uuid(koID), .integer(0), .text("body"), .integer(0), .integer(4), .real(1)])
        for model in embedModels {
            let (q, scale) = VectorQuantization.quantize([0.1, 0.2, 0.3, 0.4])
            try await db.exec("""
                INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
                VALUES (?,?,?,?,?,?,?);
                """, [.uuid(chunkID), .text(model), .text("test"),
                      .integer(4), .blob(q), .real(scale), .real(1)])
        }
        return chunkID
    }

    @Test("Counts DISTINCT embedded chunks from chunk_embeddings, not the legacy vectors table")
    func countsFromChunkEmbeddings() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")

        #expect(await LiveMetrics.embeddedChunkCount(database: db) == 0)

        try await insertChunk(db, embedModels: ["bge-small.v1"])
        // A chunk embedded under TWO models still counts once (DISTINCT).
        try await insertChunk(db, embedModels: ["bge-small.v1", "apple.nl.v1"])
        // An unembedded chunk (the ~8-char fragments the embedder skips)
        // contributes nothing.
        try await insertChunk(db, embedModels: [])

        #expect(await LiveMetrics.embeddedChunkCount(database: db) == 2)
    }

    @Test("The legacy vectors table plays no part in the metric")
    func legacyVectorsTableIgnored() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        try await insertChunk(db, embedModels: ["bge-small.v1"])

        // Whether or not the legacy table exists (older DBs still carry it),
        // the metric must reflect chunk_embeddings alone.
        let legacyRows = (try? await db.query("SELECT COUNT(*) FROM vectors;", []))?
            .first?.int(0) ?? 0
        #expect(legacyRows == 0)
        #expect(await LiveMetrics.embeddedChunkCount(database: db) == 1)
    }
}
