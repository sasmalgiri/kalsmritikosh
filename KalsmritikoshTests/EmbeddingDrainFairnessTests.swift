//
//  EmbeddingDrainFairnessTests.swift
//  KalsmritikoshTests
//
//  F10 — a full page of chunks the embedder cannot vectorize, sitting in front of an older
//  valid chunk, must not stop the drain from reaching that chunk. Exercised through the real
//  keyset query on a real ledger with a small page.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F10 — embedding drain fairness")
struct EmbeddingDrainFairnessTests {

    private let model = "test.model"

    /// Inserts `junk` unembeddable chunks AFTER one valid chunk, so the junk is newest.
    private func seed(junk: Int) async throws -> (ChunksRepository, valid: Chunk.ID) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ChunksRepository(database: db)
        let object = UUID(), file = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(file), .text("file://drain-\(file)"), .text("txt")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
        """, [.uuid(object), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        let valid = Chunk(objectID: object, ordinal: 0, text: "valid prose chunk", characterRange: 0..<17)
        try await repo.insertBatch([valid])
        let junkChunks = (1...junk).map { i in
            Chunk(objectID: object, ordinal: i, text: "\u{1}\u{2}junk\(i)", characterRange: 0..<6)
        }
        try await repo.insertBatch(junkChunks)
        return (repo, valid.id)
    }

    /// The embedder can vectorize only the valid chunk.
    private func embed(_ batch: [Chunk], into reached: inout [Chunk.ID]) -> (stored: Int, unembeddable: [Chunk.ID]) {
        var stored = 0, failed: [Chunk.ID] = []
        for c in batch {
            if c.text.hasPrefix("\u{1}") { failed.append(c.id) } else { stored += 1; reached.append(c.id) }
        }
        return (stored, failed)
    }

    @Test("A front page of unembeddable chunks is stepped past; the older valid chunk is embedded")
    func frontPageDoesNotStarveOlderWork() async throws {
        let (repo, valid) = try await seed(junk: 12)
        var reached: [Chunk.ID] = []
        let pass = await EmbeddingDrain.pass(
            fetch: { try await repo.findChunksMissingVectorPage(limit: 4, modelID: model, beforeRowID: $0) },
            skip: [],
            embed: { embed($0, into: &reached) })
        #expect(reached == [valid])
        #expect(pass.embedded == 1)
        #expect(pass.newlyFailed.count == 12)
        #expect(pass.pages == 4)                    // 13 rows / page of 4 → every row visited once
    }

    @Test("A second pass never re-sends known-unembeddable chunks to the embedder")
    func knownFailuresAreNotResent() async throws {
        let (repo, _) = try await seed(junk: 6)
        var reached: [Chunk.ID] = []
        let first = await EmbeddingDrain.pass(
            fetch: { try await repo.findChunksMissingVectorPage(limit: 4, modelID: model, beforeRowID: $0) },
            skip: [], embed: { embed($0, into: &reached) })
        var resent = 0
        _ = await EmbeddingDrain.pass(
            fetch: { try await repo.findChunksMissingVectorPage(limit: 4, modelID: model, beforeRowID: $0) },
            skip: first.newlyFailed,
            embed: { batch in resent += batch.filter { first.newlyFailed.contains($0.id) }.count; return (0, []) })
        #expect(resent == 0)
    }

    @Test("The keyset page walks strictly older rows and ends with a nil cursor")
    func keysetPaging() async throws {
        let (repo, _) = try await seed(junk: 5)
        var seen = Set<Chunk.ID>(), cursor: Int64? = nil, pages = 0
        while true {
            let page = try await repo.findChunksMissingVectorPage(limit: 2, modelID: model, beforeRowID: cursor)
            guard let next = page.lastRowID else { break }
            for c in page.chunks { #expect(seen.insert(c.id).inserted) }
            cursor = next; pages += 1
        }
        #expect(seen.count == 6)
        #expect(pages == 3)
    }
}
