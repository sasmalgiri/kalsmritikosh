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

@Suite("Named cases — captions anchor and absent ones refuse")
struct CaptionAnchorTests {

    @Test("Caption cores are the party words around v.",
          arguments: [("When was Sweet Home Chapter of Communities for a Great Oregon v. Babbitt, 1 F.3d 1 decided?", "Oregon", "Babbitt"),
                      ("Which court decided United States v. Brewster, 1 F.3d 51?", "States", "Brewster"),
                      ("Who were the parties in Rahilly v. O'Laughlin?", "Rahilly", "O'Laughlin"),
                      ("Smith vs. Jones", "Smith", "Jones"),
                      ("What did the court decide in United States v. 27.09 Acres of Land, 1 F.3d 107?", "States", "27.09"),
                      ("When was Westnau Land Corp. v. U.S. Small Business Administration, 1 F.3d 112 decided?", "Corp", "Small"),
                      ("When was United Food Workers, Local 150-A v. NLRB decided?", "150-A", "NLRB")])
    func cores(question: String, left: String, right: String) {
        let c = AbsentSubjectGate.captionCores(in: question)
        #expect(c.first?.left == left && c.first?.right == right, "\(c)")
    }

    @Test("No caption in ordinary prose")
    func noCaption() {
        #expect(AbsentSubjectGate.captionCores(in: "What did we decide about the roof?").isEmpty)
        #expect(AbsentSubjectGate.captionCores(in: "Where did the NTSB SEA08LA057 accident happen?").isEmpty)
    }
}

@Suite("Caption anchoring prefers the decision over decisions that cite it")
struct CaptionOpeningTests {
    @Test func opensBeatsCites() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let own = UUID(), citing = UUID()
        for (i, (text, v)) in [("Sweet Home Chapter v. Babbitt\nThe Secretary appeals.", own),
                               ("Doe v. Roe\nAs held in Sweet Home Chapter v. Babbitt, the rule applies.", citing)].enumerated() {
            let fileID = UUID(), koID = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash) VALUES (?, ?, 'text', 9, 0, 0, ?);",
                              [.uuid(fileID), .text("/tmp/c\(i).txt"), .text("h\(i)")])
            try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at) VALUES (?, ?, 'text', ?, '{}', 0.9, 0, 0);",
                              [.uuid(koID), .uuid(fileID), .text(text)])
            try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id) VALUES (?, ?, 0, ?, 0, 40, 0, ?);",
                              [.uuid(UUID()), .uuid(koID), .text(text), .uuid(v)])
        }
        struct Stub: Retriever { func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { RetrievalResult() } }
        let r = IdentifierAnchoredRetriever(base: Stub(), database: db, evidence: EvidenceStore(database: db), scopedRecall: nil)
        let scope = await r.anchorScope(for: "When was Sweet Home Chapter v. Babbitt decided?")
        #expect(scope?.authorizedSourceVersionIDs == [own])
    }

    @Test("An abbreviated party keeps its period: 'Hertz Corp. v. City' anchors from 'Corp v. City'")
    func abbreviatedParty() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let v = UUID(), fileID = UUID(), koID = UUID()
        let text = "Hertz Corp. v. City of New York\nThe City appeals."
        try await db.exec("INSERT INTO files (id, url, source_type, size_bytes, modified_at, ingested_at, content_hash) VALUES (?, '/tmp/h.txt', 'text', 9, 0, 0, 'h');", [.uuid(fileID)])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at) VALUES (?, ?, 'text', ?, '{}', 0.9, 0, 0);",
                          [.uuid(koID), .uuid(fileID), .text(text)])
        try await db.exec("INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, source_version_id) VALUES (?, ?, 0, ?, 0, 40, 0, ?);",
                          [.uuid(UUID()), .uuid(koID), .text(text), .uuid(v)])
        struct Stub: Retriever { func retrieve(for intent: UserIntent, layers: [RetrievalLayer]) async throws -> RetrievalResult { RetrievalResult() } }
        let r = IdentifierAnchoredRetriever(base: Stub(), database: db, evidence: EvidenceStore(database: db), scopedRecall: nil)
        #expect(await r.anchorScope(for: "What is the docket number in Hertz Corp. v. City of New York, 1 F.3d 121?")?.authorizedSourceVersionIDs == [v])
    }
}
