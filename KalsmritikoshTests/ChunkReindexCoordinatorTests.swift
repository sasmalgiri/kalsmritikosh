//
//  ChunkReindexCoordinatorTests.swift
//  KalsmritikoshTests
//
//  S2-U3 — the shared reindex, proven on a real ledger before the live one:
//  oversized chunks split on paragraph boundaries with block lineage intact
//  (citations anchor to blocks), salience and template prefixes backfill,
//  markup stops embedding, and a second run finds nothing to do.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("S2-U3 — chunk reindex (split, backfill, gate, idempotent)", .serialized)
@MainActor
struct ChunkReindexCoordinatorTests {

    @Test("Oversized splits with lineage; salience + prefixes backfill; markup gates; second run is a no-op")
    func reindexEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(); let koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/g.pdf', 'pdf');", [.uuid(fileID)])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at, document_class)
        VALUES (?, ?, 'pdf', 'seed', 0, 0, 'legalDocument');
        """, [.uuid(koID), .uuid(fileID)])

        let repo = ChunksRepository(database: db)
        let blockID = UUID()
        // The oversized chunk: 3 paragraphs × ~1,200 chars — must split, and
        // every child must carry the SAME evidence block.
        let para = String(repeating: "The patent was granted after examination. ", count: 29) // ~1,218 chars
        let bigText = [para, para, para].joined(separator: "\n\n")
        let oversized = Chunk(objectID: koID, ordinal: 0, text: bigText,
                              characterRange: 0..<bigText.count,
                              evidenceBlockID: blockID, blockKind: "paragraph")
        // A normal default-salience chunk with known structure → backfill target.
        let plain = Chunk(objectID: koID, ordinal: 1, text: "LETTER OF GRANT",
                          characterRange: 0..<15, blockKind: "documentTitle")
        // An SVG markup chunk, currently admitted → must gate.
        let svg = Chunk(objectID: koID, ordinal: 2, text: "<?xml version=\"1.0\"?><svg><path d=\"M0 0\"/></svg>",
                        characterRange: 0..<48, blockKind: "image")
        try await repo.insertBatch([oversized, plain, svg])

        let receipt = try await ChunkReindexCoordinator(database: db).run()
        print(receipt.renderLines())

        #expect(receipt.oversizedFound == 1)
        #expect(receipt.oversizedSplit == 1)
        #expect(receipt.childrenWritten >= 2, "the 3-paragraph giant must split")
        #expect(receipt.markupGated == 1)
        #expect(receipt.citationsBlocksPreserved, "block anchoring is the citation lifeline")

        // Children: same block, sized inside the line, version 2, template-prefixed.
        let children = try await db.query("""
        SELECT length(text), evidence_block_id, chunk_version, context_template_version, salience
        FROM chunks WHERE object_id = ? AND ordinal > 2 ORDER BY ordinal;
        """, [.uuid(koID)])
        #expect(children.count == receipt.childrenWritten)
        for c in children {
            #expect(Int(c.int(0) ?? 0) <= ChunkReindexCoordinator.oversizeChars, "no child may itself be oversized")
            #expect(c.uuid(1) == blockID, "lineage: every child anchors the parent's block")
            #expect(Int(c.int(2) ?? 0) == 2, "the chunk era advances")
            #expect(Int(c.int(3) ?? 0) == ContextPrefixTemplate.currentVersion)
        }
        // The parent is gone; nothing oversized remains.
        let over = Int((try await db.query(
            "SELECT COUNT(*) FROM chunks WHERE length(text) > 2000;", [])).first?.int(0) ?? 0)
        #expect(over == 0)

        // Salience backfill reached the title row (legalDocument title = 1.0).
        let title = (try await db.query(
            "SELECT salience, context_template_version FROM chunks WHERE block_kind = 'documentTitle';", [])).first
        #expect(title?.double(0) == 1.0, "documentTitle in a legal document backfills to 1.0")
        #expect(title?.int(1).map(Int.init) == ContextPrefixTemplate.currentVersion)

        // The SVG row: stored, FTS-searchable, never embedded.
        let gated = (try await db.query(
            "SELECT admit_embedding FROM chunks WHERE block_kind = 'image';", [])).first
        #expect(Int(gated?.int(0) ?? 1) == 0)

        // Idempotence.
        let second = try await ChunkReindexCoordinator(database: db).run()
        #expect(second.oversizedFound == 0 && second.salienceBackfilled == 0
                && second.prefixesStamped == 0 && second.markupGated == 0,
                "a second run must find nothing to do")
    }

    @Test("The splitter is deterministic and respects paragraph boundaries")
    func splitterLaws() {
        let para = String(repeating: "word ", count: 200) // 1,000 chars
        let text = [para, para, para, para].joined(separator: "\n\n")
        let a = ChunkReindexCoordinator.split(text, target: 1_600)
        let b = ChunkReindexCoordinator.split(text, target: 1_600)
        #expect(a == b, "identical input, identical split")
        #expect(a.count >= 2)
        #expect(a.allSatisfy { $0.count <= 2_000 })
        // Small text passes through untouched.
        #expect(ChunkReindexCoordinator.split("short", target: 1_600) == ["short"])
        // THE LIVE-RUN LESSON: a single paragraph of 2,000–3,200 chars (no
        // \n\n anywhere) must still split — 136 of 141 live chunks were this
        // shape and the old splitter passed them through whole.
        let single = String(repeating: "The examiner raised an objection. ", count: 75) // ~2,550 chars, one paragraph
        let split = ChunkReindexCoordinator.split(single, target: 1_600)
        #expect(split.count >= 2, "a 2,550-char single paragraph must split, got \(split.count) piece(s)")
        #expect(split.allSatisfy { $0.count <= ChunkReindexCoordinator.oversizeChars })
        #expect(split.joined() == single, "no text may be lost in the split")
        // Live run 2's stragglers: text over the line in SCALARS (SQL's unit)
        // but under it in graphemes — Devanagari with combining marks.
        let hindi = String(repeating: "परीक्षण रिपोर्ट आवेदन संख्या जांच का परिणाम। ", count: 60)
        let hSplit = ChunkReindexCoordinator.split(hindi, target: 1_600)
        #expect(hSplit.allSatisfy { $0.unicodeScalars.count <= 2_000 },
                "every piece must be inside the line in SQL's own unit")
        #expect(hSplit.joined() == hindi)
    }
}
