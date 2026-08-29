//
//  SlotAwareRetrievalTests.swift
//  KalsmritikoshTests
//
//  Owner acceptance defect (2026-08-29): "what is the patent no" answered a
//  false "none of the N documents carries a patent number" while Patent No.
//  555489 sat in the ledger — because the fact's chunk ranked #99 of 338
//  "patent" FTS hits, past the metadata layer's 25-hit window, so the fact
//  never rode retrieval. Slot-aware retrieval pulls the block that CARRIES a
//  requested fact field into the candidate set regardless of bm25 rank.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Slot-aware retrieval (patent-number acceptance defect)", .serialized)
struct SlotAwareRetrievalTests {

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slotret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("t.sqlite"))
        try await SchemaMigrations.migrate(db)
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        return db
    }

    private func addKO(_ db: Database, koText: String, chunkText: String, blockID: UUID) async throws -> UUID {
        let fileID = UUID(), koID = UUID(), chunkID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text(koText), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, evidence_block_id)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(chunkID), .uuid(koID), .integer(0), .text(chunkText),
                  .integer(0), .integer(Int64(chunkText.count)), .real(1), .uuid(blockID)])
        return koID
    }

    private func retriever(_ db: Database, withFacts: Bool) -> HybridRetriever {
        HybridRetriever(
            memory: MemoryRepository(database: db),
            events: EventsRepository(database: db),
            entities: EntitiesRepository(database: db),
            chunks: ChunksRepository(database: db),
            summaries: SummariesRepository(database: db),
            graph: GraphStore(relationships: RelationshipsRepository(database: db)),
            vectors: SQLiteVectorStore(database: db, modelID: "apple.nl.v1"),
            embedder: NLEmbedder(),
            objects: KnowledgeObjectRepository(database: db),
            genericFacts: withFacts ? GenericFactRepository(database: db) : nil)
    }

    @Test("A slot fact whose chunk FTS never ranks is still surfaced by slot-aware retrieval")
    func slotFactSurfacedRegardlessOfRank() async throws {
        let db = try await makeDB()
        // The fact-bearing chunk deliberately contains NEITHER "patent" nor
        // "number" — pure FTS on the question would never return it.
        let certBlock = UUID()
        _ = try await addKO(db, koText: "Registry extract sheet.", chunkText: "Registry extract sheet, entry 7.", blockID: certBlock)
        // Decoys that DO match "patent" so a bm25 window fills with them.
        for i in 0..<30 {
            _ = try await addKO(db, koText: "patent discussion \(i)", chunkText: "We discussed the patent status in meeting \(i).", blockID: UUID())
        }
        // The real granted-number fact, bound to the cert block.
        try await GenericFactRepository(database: db).upsert(
            GenericFact(subjectLabel: "Grant letter", field: "patentNumber", value: "Patent No. 555489",
                        status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [certBlock]))

        let intent = (try? await RuleIntentDetector().detect(question: "what is the patent number"))
            ?? UserIntent(kind: .factualLookup, scope: .global, rawQuestion: "what is the patent number")

        // WITH facts wired → slot-aware retrieval surfaces the 555489 fact.
        let withFacts = try await retriever(db, withFacts: true).retrieve(for: intent, layers: [])
        #expect(withFacts.genericFacts.contains { $0.field == "patentnumber" && $0.value.contains("555489") },
                "slot-aware retrieval did not surface the patent-number fact")

        // Control: the fact's chunk is NOT among plain FTS hits for the question
        // (proving the slot layer, not FTS, is what surfaced it).
        let ftsOnly = try await ChunksRepository(database: db).searchFTS("patent number", limit: 25)
        #expect(!ftsOnly.contains { $0.evidenceBlockID == certBlock },
                "the cert chunk should be invisible to plain FTS — test corpus drifted")
    }

    @Test("sourceBlocks(forFields:) returns the fact's blocks; chunksForEvidenceBlocks hydrates them")
    func repoHelpers() async throws {
        let db = try await makeDB()
        let block = UUID()
        _ = try await addKO(db, koText: "x", chunkText: "opaque body", blockID: block)
        try await GenericFactRepository(database: db).upsert(
            GenericFact(subjectLabel: "s", field: "patentNumber", value: "Patent No. 555489",
                        status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [block]))
        let blocks = try await GenericFactRepository(database: db).sourceBlocks(forFields: ["patentnumber"])
        #expect(blocks.contains(block))
        let hydrated = try await ChunksRepository(database: db).chunksForEvidenceBlocks(blocks)
        #expect(hydrated.contains { $0.evidenceBlockID == block })
        // A field nobody carries returns nothing.
        #expect(try await GenericFactRepository(database: db).sourceBlocks(forFields: ["nosuchfield"]).isEmpty)
    }
}
