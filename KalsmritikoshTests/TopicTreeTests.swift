//
//  TopicTreeTests.swift
//  KalsmritikoshTests
//
//  TT (Amendment A1) — the tree's gold: a seeded multi-topic archive yields
//  the EXPECTED tree (anchor-labeled patent node; term-labeled second node;
//  the lone leaf stays a leaf), and a second run yields the identical tree
//  (the determinism laws: total order at every clustering decision).
//  Level-0 stays the detector's; this suite seeds it raw and proves the
//  builder only ADDS level-1 — build-upon, never replace.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("TT — topic tree (expected shape, deterministic labels, rerun-stable)", .serialized)
@MainActor
struct TopicTreeTests {

    @Test("Anchor-shared communities nest under an anchor-labeled node; term-shared under terms; lone leaves stay leaves; reruns identical")
    func treeGold() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        // ── the seeded archive: 5 KOs in 3 families ─────────────────────────
        let fileID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, '/tmp/a.md', 'markdown');", [.uuid(fileID)])
        func ko(_ name: String) async throws -> UUID {
            let id = UUID()
            try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?, ?, 'markdown', ?, 0, 0);
            """, [.uuid(id), .uuid(fileID), .text(name)])
            return id
        }
        let patentA = try await ko("grant letter"), patentB = try await ko("hearing notice")
        let invA = try await ko("statement jan"), invB = try await ko("statement feb")
        let lone = try await ko("recipe")

        // entities per KO (the community members) + the shared patent anchor.
        func ent(_ v: String, ko: UUID, kind: String = "person") async throws -> UUID {
            let id = UUID()
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, ?, ?, ?, ?, 0.9);
            """, [.uuid(id), .text(kind), .text(v), .text(v.lowercased()), .uuid(ko)])
            return id
        }
        let e1 = try await ent("Alice Advocate", ko: patentA)
        let e2 = try await ent("Bob Examiner", ko: patentB)
        let e3 = try await ent("Cara Accountant", ko: invA)
        let e4 = try await ent("Dev Auditor", ko: invB)
        let e5 = try await ent("Eve Baker", ko: lone)
        // ONE anchor row per identity (the UNIQUE law); both patent documents
        // NAME the value in their text, so the corroborated identifier term is
        // the cross-document edge.
        _ = try await ent("patentnumber|555489", ko: patentA, kind: "identifierAnchor")

        // chunks for the invoice family: ≥3 shared distinctive terms.
        func chunk(_ text: String, ko: UUID, ordinal: Int) async throws {
            try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at, salience)
            VALUES (?, ?, ?, ?, 0, ?, 0, 0.8);
            """, [.uuid(UUID()), .uuid(ko), .integer(Int64(ordinal)), .text(text), .integer(Int64(text.count))])
        }
        try await chunk("The patent 555489 was granted after examination of 555489", ko: patentA, ordinal: 0)
        try await chunk("Hearing scheduled regarding patent 555489 objections", ko: patentB, ordinal: 0)
        try await chunk("Meridian ledger reconciliation payroll quarterly Meridian ledger", ko: invA, ordinal: 0)
        try await chunk("Meridian ledger reconciliation payroll quarterly totals", ko: invB, ordinal: 0)
        try await chunk("sourdough starter hydration levain", ko: lone, ordinal: 0)

        // level-0 communities, seeded raw (the detector's authorship stands).
        func community(_ cid: String, _ members: [UUID]) async throws {
            for m in members {
                try await db.exec("""
                INSERT INTO entity_communities (community_id, entity_id, level, computed_at)
                VALUES (?, ?, 0, 0);
                """, [.text(cid), .uuid(m)])
            }
        }
        try await community("c-patentA", [e1])
        try await community("c-patentB", [e2])
        try await community("c-invA", [e3])
        try await community("c-invB", [e4])
        try await community("c-lone", [e5])

        // ── term salience, then the tree ────────────────────────────────────
        let terms = try await TermSalienceComputer(database: db).run()
        #expect(terms > 0, "winner terms must compute")
        // Idempotence: a second term run finds nothing stale.
        #expect(try await TermSalienceComputer(database: db).run() == 0)

        let receipt = try await TopicTreeBuilder(database: db).run()
        print("TT: \(receipt.levelZeroNodes) leaves → \(receipt.levelOneNodes) level-1 (\(receipt.labeled) labeled)")
        #expect(receipt.levelZeroNodes == 5)
        #expect(receipt.levelOneNodes == 2, "patent pair + invoice pair; the lone leaf stays a leaf")

        // The anchor-labeled node: the patent family, named by its identifier.
        let labels = (try await db.query(
            "SELECT title FROM community_summaries WHERE level = 1 ORDER BY title;", []))
            .compactMap { $0.string(0) }
        #expect(labels.contains("Patent No. 555489"), "anchor display name labels the node, got \(labels)")
        #expect(labels.contains { $0.contains("meridian") || $0.contains("ledger") },
                "corroborated winner terms label the term node, got \(labels)")

        // The lone community appears at level 1 nowhere.
        let loneAtL1 = Int((try await db.query(
            "SELECT COUNT(*) FROM entity_communities WHERE level = 1 AND entity_id = ?;",
            [.uuid(e5)])).first?.int(0) ?? 0)
        #expect(loneAtL1 == 0, "single-document leaves are leaves")

        // ── rerun stability: the identical tree, byte for byte ─────────────
        let before = try await treeSnapshot(db)
        _ = try await TopicTreeBuilder(database: db).run()
        let after = try await treeSnapshot(db)
        #expect(before == after, "same world → same tree, always")
    }

    private func treeSnapshot(_ db: Database) async throws -> [String] {
        (try await db.query("""
        SELECT community_id || '|' || entity_id || '|' || level FROM entity_communities
        WHERE level = 1 ORDER BY community_id, entity_id;
        """, [])).compactMap { $0.string(0) }
    }
}
