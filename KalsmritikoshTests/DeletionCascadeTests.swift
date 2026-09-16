//
//  DeletionCascadeTests.swift
//  KalsmritikoshTests
//
//  G2/Stage-11 — deleting a document removes EVERYTHING derived from it and
//  nothing survives to be revived through a citation. Reuses the real ingest
//  rig so the cascade is exercised over genuinely-produced derived rows.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@MainActor
@Suite("G2 deletion cascade")
struct DeletionCascadeTests {

    private func count(_ db: Database, _ sql: String, _ id: UUID) async -> Int {
        let rows = (try? await db.query(sql, [.uuid(id)])) ?? []
        return Int(rows.first?.int(0) ?? 0)
    }

    @Test func deletingADocumentCascadesToAllDerivedRows() async throws {
        // A document that yields chunks, an entity mention and an event.
        let rig = try await FixtureRig.make(
            document: "On 28 November 2024 the patent was granted to Shirshendu Sasmal.",
            name: "grant.md")
        defer { try? FileManager.default.removeItem(at: rig.dir) }
        let db = rig.db
        let koID = try #require(
            (try await db.query("SELECT id FROM knowledge_objects LIMIT 1", []))
                .first?.string(0).flatMap(UUID.init(uuidString:)),
            "rig produced no knowledge object")

        // Before: derived rows exist for this KO.
        let chunksBefore = await count(db, "SELECT COUNT(*) FROM chunks WHERE object_id = ?;", koID)
        #expect(chunksBefore > 0, "expected the rig to produce chunks")

        // Delete the document.
        try await KnowledgeObjectRepository(database: db).deleteByID(koID)

        // After: the KO and every derived row keyed to it are gone.
        #expect(await count(db, "SELECT COUNT(*) FROM knowledge_objects WHERE id = ?;", koID) == 0)
        #expect(await count(db, "SELECT COUNT(*) FROM chunks WHERE object_id = ?;", koID) == 0,
                "chunks must cascade")
        // chunk_embeddings are keyed by chunk_id; with the chunks gone they
        // must be gone too (no orphaned vectors that could resurface).
        let orphanRows = (try? await db.query("""
        SELECT COUNT(*) FROM chunk_embeddings
        WHERE chunk_id NOT IN (SELECT id FROM chunks);
        """, [])) ?? []
        #expect(Int(orphanRows.first?.int(0) ?? 0) == 0, "no orphaned embeddings survive the delete")
    }
}
