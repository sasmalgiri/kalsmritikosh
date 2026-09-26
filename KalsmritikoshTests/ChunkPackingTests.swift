//
//  ChunkPackingTests.swift
//  KalsmritikoshTests
//
//  L1 — "data cut by chunk must be handled". The owner's ledger had one chunk
//  per LINE (36% under 40 chars). These pin the packing rules: adjacent small
//  blocks join up to the budget; a heading opens its section; email messages,
//  sheets and tables never share a chunk; rows and prose never mix; boilerplate
//  stands alone; an oversized block still splits by sentence; and every chunk
//  names every block it came from.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("L1 — chunk packing")
struct ChunkPackingTests {

    private func block(_ kind: EvidenceBlockKind, _ text: String, ordinal: Int,
                       message: Int? = nil, sheet: String? = nil) -> EvidenceBlock {
        EvidenceBlock(documentID: UUID(), ordinal: ordinal, kind: kind, rawText: text,
                      locator: SourceLocator(sheet: sheet),
                      attributes: message.map { ["messageIndex": AnyCodable(.int(Int64($0)))] } ?? [:])
    }

    @Test("Per-line résumé blocks pack into one coherent chunk with full lineage")
    func linesPack() {
        let lines = ["Shirshendu Sasmal", "Cell : 9960270472 : sasmalgiri@gmail.com",
                     "Experience : 24th dec – 2004 to till date", "Audit Faced : USFDA, MHRA",
                     "Nationality : Indian", "Marital status : Married"]
        let blocks = lines.enumerated().map { block(.paragraph, $0.element, ordinal: $0.offset) }
        let out = Chunker(targetCharacterCount: 1_200).chunkWithLineage(objectID: UUID(), blocks: blocks)
        #expect(out.chunks.count == 1, "six short lines are one retrieval unit, got \(out.chunks.count)")
        let chunk = try! #require(out.chunks.first)
        #expect(chunk.text.contains("Cell : 9960270472") && chunk.text.contains("Marital status : Married"))
        #expect(chunk.evidenceBlockID == blocks[0].id, "the primary block is the first")
        #expect(out.blockIDs[chunk.id] == blocks.map(\.id), "every block is named, in order")
    }

    @Test("The budget is respected: packing stops before overflow, never mid-block")
    func budgetRespected() {
        let blocks = (0..<10).map { block(.paragraph, String(repeating: "word ", count: 40), ordinal: $0) } // ~200 chars each
        let out = Chunker(targetCharacterCount: 500).chunk(objectID: UUID(), blocks: blocks)
        #expect(out.count == 5, "two 200-char blocks per 500-char budget, got \(out.count)")
        #expect(out.allSatisfy { $0.text.count <= 500 })
    }

    @Test("A heading opens a chunk and its body packs under it; the next heading starts a new one")
    func headingsOpenSections() {
        let blocks = [
            block(.sectionHeading, "Experience", ordinal: 0),
            block(.paragraph, "Auro Laboratories Ltd — Executive", ordinal: 1),
            block(.paragraph, "Movers Limited — Dy. Manager", ordinal: 2),
            block(.sectionHeading, "Education", ordinal: 3),
            block(.paragraph, "M.Sc Organic Chemistry", ordinal: 4),
        ]
        let out = Chunker().chunk(objectID: UUID(), blocks: blocks)
        #expect(out.count == 2)
        #expect(out[0].text.hasPrefix("Experience") && out[0].text.contains("Movers Limited"))
        #expect(out[0].blockKind == "paragraph", "the kind describes the content, not the heading")
        #expect(out[1].text.hasPrefix("Education"))
    }

    @Test("Different email messages never share a chunk, even when small")
    func messagesStayApart() {
        let blocks = [
            block(.emailBody, "Please find the fee structure.", ordinal: 0, message: 3),
            block(.emailBody, "Thanks, will pay tomorrow.", ordinal: 1, message: 3),
            block(.emailBody, "Payment has been made.", ordinal: 2, message: 4),
        ]
        let out = Chunker().chunk(objectID: UUID(), blocks: blocks)
        #expect(out.count == 2)
        #expect(out[0].text.contains("fee structure") && out[0].text.contains("pay tomorrow"))
        #expect(out[1].text == "Payment has been made.")
    }

    @Test("Rows pack with rows, prose with prose, sheets stay apart, boilerplate packs only with boilerplate")
    func shapesAndBoilerplate() {
        let blocks = [
            block(.paragraph, "Shift plan for July.", ordinal: 0),
            block(.spreadsheetRow, "Mon | Ravi | A", ordinal: 1, sheet: "S1"),
            block(.spreadsheetRow, "Tue | Mina | B", ordinal: 2, sheet: "S1"),
            block(.spreadsheetRow, "Wed | Ravi | C", ordinal: 3, sheet: "S2"),
            block(.pageFooter, "Page 1 of 1", ordinal: 4),
            block(.pageHeader, "Confidential", ordinal: 5),
            block(.paragraph, "Approved by HR.", ordinal: 6),
        ]
        let out = Chunker().chunk(objectID: UUID(), blocks: blocks)
        #expect(out.map(\.text) == ["Shift plan for July.", "Mon | Ravi | A\nTue | Mina | B", "Wed | Ravi | C",
                                    "Page 1 of 1\nConfidential", "Approved by HR."], "got \(out.map(\.text))")
    }

    @Test("An oversized block still splits by sentence, each piece tied to that one block")
    func oversizedSplits() {
        let big = String(repeating: "The patent was granted after examination. ", count: 40) // ~1,720 chars
        let blocks = [block(.paragraph, "Intro.", ordinal: 0), block(.paragraph, big, ordinal: 1)]
        let out = Chunker(targetCharacterCount: 600).chunkWithLineage(objectID: UUID(), blocks: blocks)
        #expect(out.chunks.count >= 4)
        #expect(out.chunks.first?.text == "Intro.")
        for c in out.chunks.dropFirst() {
            #expect(c.evidenceBlockID == blocks[1].id)
            #expect(out.blockIDs[c.id] == [blocks[1].id])
            #expect(c.text.count <= 600 + 200, "sentence packing stays near the budget")
        }
    }
}

@Suite("L1 — chunk packing over a real ledger (reindex pass 0)", .serialized)
@MainActor
struct ChunkPackingReindexTests {

    @Test("Per-line chunks are rebuilt into packed units with lineage; embeddings drop; a second run is a no-op")
    func packUndersized() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(), koID = UUID(), docID = UUID(), versionID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/cv.pdf', 'pdf');", [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, document_class)
        VALUES (?, ?, 'pdf', 'seed', 0, 0, 'resume');
        """, [.uuid(koID), .uuid(fileID)])
        let lines = ["Shirshendu Sasmal", "Cell : 9960270472", "Experience : 2004 to date",
                     "Audit Faced : USFDA", "Nationality : Indian", "Marital status : Married"]
        var blockIDs: [UUID] = []
        let repo = ChunksRepository(database: db)
        for (i, line) in lines.enumerated() {
            let bid = UUID(); blockIDs.append(bid)
            try await db.exec("""
            INSERT INTO evidence_blocks (id, document_id, source_version_id, ordinal, kind, raw_text, normalized_text, locator, extraction_method, extraction_confidence)
            VALUES (?, ?, ?, ?, 'paragraph', ?, ?, '{}', 'native', 1.0);
            """, [.uuid(bid), .uuid(docID), .uuid(versionID), .integer(Int64(i)), .text(line), .text(line)])
            try await db.exec("INSERT INTO evidence_block_objects (evidence_block_id, knowledge_object_id, linked_at) VALUES (?, ?, 0);",
                              [.uuid(bid), .uuid(koID)])
            let c = Chunk(objectID: koID, ordinal: i, text: line, characterRange: 0..<line.count,
                          evidenceBlockID: bid, blockKind: "paragraph", sourceVersionID: versionID)
            try await repo.insertBatch([c])
            try await db.exec("""
            INSERT INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
            VALUES (?, 'm', 'v', 2, X'0000', 1.0, 0);
            """, [.uuid(c.id)])
        }

        let receipt = try await ChunkReindexCoordinator(database: db).run()
        print(receipt.renderLines())
        #expect(receipt.packedObjects == 1)
        #expect(receipt.packedChunksBefore == 6)
        #expect(receipt.packedChunksAfter == 1)
        #expect(receipt.embeddingsDropped == 6, "stale vectors of replaced rows are dropped for re-embedding")

        let rows = try await db.query("SELECT id, text, evidence_block_id, chunk_version, source_version_id FROM chunks WHERE object_id = ?;", [.uuid(koID)])
        #expect(rows.count == 1)
        let chunkID = try #require(rows.first?.uuid(0))
        #expect(rows.first?.string(1)?.contains("Marital status : Married") == true)
        #expect(rows.first?.uuid(2) == blockIDs[0], "primary block = first block")
        #expect(Int(rows.first?.int(3) ?? 0) == ChunkReindexCoordinator.packedChunkVersion)
        #expect(rows.first?.uuid(4) == versionID, "the exact source version survives the rewrite")
        #expect(try await repo.blockIDs(forChunk: chunkID) == blockIDs, "chunk_blocks names every line")
        let fts = Int((try await db.query("SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH '9960270472';", [])).first?.int(0) ?? 0)
        #expect(fts == 1, "FTS follows the rewrite via triggers")

        let second = try await ChunkReindexCoordinator(database: db).run()
        #expect(second.packedObjects == 0, "idempotent")
    }
}
