//
//  ScopedRecallTests.swift
//  KalsmritikoshTests
//
//  F08 — a small case whose evidence sits behind higher-ranked chunks from OUTSIDE the case must
//  still be retrieved: the scope predicate goes inside the candidate query, before LIMIT.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F08 — case evidence is not crowded out by the global corpus")
struct ScopedRecallTests {

    /// Stands in for the shared retriever: global keyword search truncated to its top 25 BEFORE any
    /// case filtering — exactly the ordering that starved small cases.
    private struct GlobalTopK: Retriever {
        let chunks: ChunksRepository
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult {
            let hits = try await chunks.searchFTS(intent.rawQuestion, limit: 25)
            return RetrievalResult(chunks: hits.map { RetrievedChunk(chunk: $0, score: 1, viaLayer: .metadata) })
        }
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer], access: SensitiveAccessContext) async throws -> AuthorizedRetrievalResult {
            AuthorizedRetrievalResult(result: try await retrieve(for: intent, layers: layers), accessContext: access)
        }
    }

    private func seed() async throws -> (Database, ChunksRepository, authorized: UUID, caseChunk: UUID) {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let repo = ChunksRepository(database: db)
        func object() async throws -> UUID {
            let file = UUID(), ko = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                              [.uuid(file), .text("file://sr-\(file)"), .text("txt")])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
            return ko
        }
        // 30 outside chunks that mention the term MANY times (they outrank the case chunk).
        let outsideVersion = UUID(), outsideKO = try await object()
        try await repo.insertBatch((0..<30).map { i in
            Chunk(objectID: outsideKO, ordinal: i, text: "zanthorite zanthorite zanthorite ledger copy \(i)",
                  characterRange: 0..<40, sourceVersionID: outsideVersion)
        })
        // ONE case chunk that mentions it once.
        let caseVersion = UUID(), caseKO = try await object()
        let caseChunk = Chunk(objectID: caseKO, ordinal: 0, text: "The zanthorite invoice was signed by the vendor.",
                              characterRange: 0..<48, sourceVersionID: caseVersion)
        try await repo.insertBatch([caseChunk])
        return (db, repo, caseVersion, caseChunk.id)
    }

    @Test("Without scoped recall the case chunk is starved; with it, it is retrieved")
    func caseChunkRecovered() async throws {
        let (db, repo, authorized, caseChunk) = try await seed()
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "zanthorite invoice")
        let access = SensitiveAccessContext.testUnrestricted()
        let evidence = EvidenceStore(database: db)

        let starved = SourceScopedRetriever(base: GlobalTopK(chunks: repo), evidence: evidence, scope: .authorizing([authorized]))
        let before = try await starved.retrieve(for: intent, layers: [.metadata], access: access)
        #expect(before.result.chunks.isEmpty, "precondition: the global top-25 held no case chunk")

        let recalled = SourceScopedRetriever(base: GlobalTopK(chunks: repo), evidence: evidence, scope: .authorizing([authorized]),
                                             scopedRecall: .init(chunks: repo, sensitivePolicy: nil))
        let after = try await recalled.retrieve(for: intent, layers: [.metadata], access: access)
        #expect(after.result.chunks.map(\.chunk.id) == [caseChunk])
        #expect(after.result.chunks.allSatisfy { $0.chunk.sourceVersionID == authorized })   // never widens the scope
    }

    @Test("An empty authorized set still yields nothing (recall never widens the boundary)")
    func emptyScopeStaysEmpty() async throws {
        let (db, repo, _, _) = try await seed()
        let intent = UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "zanthorite")
        let d = SourceScopedRetriever(base: GlobalTopK(chunks: repo), evidence: EvidenceStore(database: db),
                                      scope: .authorizing([]), scopedRecall: .init(chunks: repo, sensitivePolicy: nil))
        #expect(try await d.retrieve(for: intent, layers: [.metadata], access: .testUnrestricted()).result.chunks.isEmpty)
    }
}
