//
//  IdentifierAnchoredRetrieverTests.swift
//  KalsmritikoshTests
//
//  Case bench 2026-10-18: a question naming a reference that is in the archive draws its evidence
//  from the documents carrying it; without a reference, or with one too common to single anything
//  out, retrieval is untouched.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Identifier-anchored retrieval")
struct IdentifierAnchoredRetrieverTests {

    private func ledger(_ docs: [(text: String, version: UUID)]) async throws -> Database {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        for (i, d) in docs.enumerated() {
            let fileID = UUID(), koID = UUID()
            try await db.exec("""
            INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash)
            VALUES (?, ?, 'text', 9, 0, 0, ?);
            """, [.uuid(fileID), .text("/tmp/case\(i).txt"), .text("h\(i)")])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at)
            VALUES (?, ?, 'text', ?, '{}', 0.9, 0, 0);
            """, [.uuid(koID), .uuid(fileID), .text(d.text)])
            try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id)
            VALUES (?, ?, 0, ?, 0, 40, 0, ?);
            """, [.uuid(UUID()), .uuid(koID), .text(d.text), .uuid(d.version)])
        }
        return db
    }

    private struct Stub: Retriever {
        func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { RetrievalResult() }
    }

    @Test("A present reference anchors to the documents that carry it")
    func anchorsToCarriers() async throws {
        let a = UUID(), b = UUID()
        let db = try await ledger([("NTSB SEA08LA057 — the Piper collided at Sonoma.", a),
                                   ("NTSB MIA08MA051 — the Cessna struck terrain.", b)])
        let r = IdentifierAnchoredRetriever(base: Stub(), database: db, evidence: EvidenceStore(database: db), scopedRecall: nil)
        let scope = await r.anchorScope(for: "Where did the NTSB SEA08LA057 accident happen?")
        #expect(scope?.isActive == true)
        #expect(scope?.authorizedSourceVersionIDs == [a])
    }

    @Test("No reference, or an absent one, leaves retrieval unanchored")
    func silentOtherwise() async throws {
        let db = try await ledger([("NTSB SEA08LA057 — the Piper collided at Sonoma.", UUID())])
        let r = IdentifierAnchoredRetriever(base: Stub(), database: db, evidence: EvidenceStore(database: db), scopedRecall: nil)
        #expect(await r.anchorScope(for: "Where did the accident happen?") == nil)
        #expect(await r.anchorScope(for: "What happened in 2008?") == nil)
        #expect(await r.anchorScope(for: "What about NTSB ZZZ99ZZ999?") == nil)
    }
}
