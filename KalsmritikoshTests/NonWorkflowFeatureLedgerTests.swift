//
//  NonWorkflowFeatureLedgerTests.swift
//  KalsmritikoshTests
//
//  Ledger-backed simulation for the new repository queries that power the
//  Fund Flow and Email Threads surfaces. Seeds a fully-migrated temp database
//  with representative rows and asserts the hand-written SQL executes and
//  decodes correctly — the risk that couldn't be covered by pure-logic tests.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("Non-workflow features — ledger simulation")
struct NonWorkflowFeatureLedgerTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func migratedDB() async throws -> Database {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        return db
    }

    // MARK: - Fund flow

    @Test("fundFlowEdges returns weighted payer→payee edges with resolved labels")
    func fundFlowEdges() async throws {
        let db = try await migratedDB()
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file://\(fileID)"), .text("pdf")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("pdf"), .text("ledger"), .date(t0), .date(t0)])

        let acme = UUID(), vx = UUID(), vy = UUID()
        let entities: [(UUID, String, String, String)] = [
            (acme, "organization", "Acme Corp", "acme corp"),
            (vx, "vendor", "Vendor X", "vendor x"),
            (vy, "vendor", "Vendor Y", "vendor y")
        ]
        for (id, kind, value, norm) in entities {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json)
            VALUES (?,?,?,?,?,?, '{}');
            """, [.uuid(id), .text(kind), .text(value), .text(norm), .uuid(koID), .real(0.8)])
        }
        func paid(_ from: UUID, _ to: UUID, weight: Int, evidence: String) async throws {
            try await db.exec("""
            INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                       source_object_id, confidence, attributes_json, weight, evidence_object_ids_json)
            VALUES (?, 'paid', ?, ?, NULL, ?, 0.8, '{}', ?, ?);
            """, [.uuid(UUID()), .uuid(from), .uuid(to), .uuid(koID),
                  .integer(Int64(weight)), .text(evidence)])
        }
        try await paid(acme, vx, weight: 5, evidence: #"["k1","k2"]"#)
        try await paid(acme, vy, weight: 2, evidence: #"["k1"]"#)

        let repo = RelationshipsRepository(database: db)
        let edges = try await repo.fundFlowEdges()
        #expect(edges.count == 2)
        // Ordered by weight descending.
        #expect(edges.first?.weight == 5)
        let ax = edges.first { $0.fromLabel == "Acme Corp" && $0.toLabel == "Vendor X" }
        #expect(ax != nil)
        #expect(ax?.weight == 5)
        #expect(ax?.evidenceCount == 2)
        let ay = edges.first { $0.toLabel == "Vendor Y" }
        #expect(ay?.evidenceCount == 1)
    }

    @Test("fundFlowEdges excludes merged/rejected endpoints")
    func fundFlowExcludesHidden() async throws {
        let db = try await migratedDB()
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file://\(fileID)"), .text("pdf")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?,?,?,?,?,?);
        """, [.uuid(koID), .uuid(fileID), .text("pdf"), .text("x"), .date(t0), .date(t0)])
        let a = UUID(), b = UUID()
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, review_status)
        VALUES (?, 'organization', 'Payer', 'payer', ?, 0.8, '{}', NULL);
        """, [.uuid(a), .uuid(koID)])
        // Rejected payee — must be filtered out.
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, review_status)
        VALUES (?, 'vendor', 'Rejected Payee', 'rejected payee', ?, 0.8, '{}', 'rejected');
        """, [.uuid(b), .uuid(koID)])
        try await db.exec("""
        INSERT INTO relationships (id, kind, from_entity_id, to_entity_id, via_event_id,
                                   source_object_id, confidence, attributes_json, weight, evidence_object_ids_json)
        VALUES (?, 'paid', ?, ?, NULL, ?, 0.8, '{}', 3, '[]');
        """, [.uuid(UUID()), .uuid(a), .uuid(b), .uuid(koID)])

        let edges = try await RelationshipsRepository(database: db).fundFlowEdges()
        #expect(edges.isEmpty, "edges touching a rejected entity must be excluded")
    }

    // MARK: - Email digests

    @Test("emailDigests extracts subject/from/date from metadata across key casings")
    func emailDigests() async throws {
        let db = try await migratedDB()
        func addEmail(hash: String, metadata: String) async throws {
            let f = UUID(), k = UUID()
            try await db.exec("INSERT INTO files (id, url, source_type, content_hash) VALUES (?,?,?,?);",
                              [.uuid(f), .text("file://\(f)"), .text("eml"), .text(hash)])
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, metadata_json, confidence, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(k), .uuid(f), .text("eml"), .text("body text"),
                  .text(metadata), .real(0.9), .date(t0), .date(t0)])
        }
        try await addEmail(hash: "h1", metadata: #"{"Subject":"Quarterly Update","From":"alice@x.com","Date":"Tue, 1 Nov 2022 09:30:00 +0000"}"#)
        try await addEmail(hash: "h2", metadata: #"{"subject":"Lowercase Keys","from":"bob@x.com"}"#)

        let repo = KnowledgeObjectRepository(database: db)
        let digests = try await repo.emailDigests()
        #expect(digests.count == 2)

        let q = digests.first { $0.subject == "Quarterly Update" }
        #expect(q?.from == "alice@x.com")
        #expect(q?.date != nil)
        #expect(q?.contentHash == "h1")

        let lc = digests.first { $0.subject == "Lowercase Keys" }
        #expect(lc?.from == "bob@x.com")
        #expect(lc?.date == nil)
    }

    @Test("parseEmailDate handles common header formats and rejects junk")
    func emailDateParsing() {
        #expect(KnowledgeObjectRepository.parseEmailDate("Tue, 1 Nov 2022 09:30:00 +0000") != nil)
        #expect(KnowledgeObjectRepository.parseEmailDate("2022-11-01") != nil)
        #expect(KnowledgeObjectRepository.parseEmailDate(nil) == nil)
        #expect(KnowledgeObjectRepository.parseEmailDate("") == nil)
        #expect(KnowledgeObjectRepository.parseEmailDate("not a date") == nil)
    }
}
