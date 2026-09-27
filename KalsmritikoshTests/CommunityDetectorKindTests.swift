//
//  CommunityDetectorKindTests.swift
//  KalsmritikoshTests
//
//  P1.14 — attributes (dates, money, phone numbers) are never community
//  members, even when an older co-occurrence graph still carries their edges.
//  On the owner's copy 88 of ~350 level-0 members were email date headers.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P1.14 — community detection ignores attribute entities", .serialized)
struct CommunityDetectorKindTests {

    @Test("A stale date edge cannot pull a date header into a community; people still cluster")
    func datesNeverJoinCommunities() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("db.sqlite"))
        try await SchemaMigrations.migrate(db)

        let fileID = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?, ?, ?);",
                          [.uuid(fileID), .text("file:///x.eml"), .text("eml")])
        try await db.exec("""
        INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
        VALUES (?, ?, 'eml', 'body', 0, 0);
        """, [.uuid(ko), .uuid(fileID)])
        let alice = UUID(), bob = UUID(), stamp = UUID()
        for (id, kind, value) in [(alice, "person", "Alice Rao"), (bob, "person", "Bob Sen"),
                                  (stamp, "date", "Mon, 26 Jul 2021 20:02:20")] {
            try await db.exec("""
            INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence)
            VALUES (?, ?, ?, ?, ?, 0.9);
            """, [.uuid(id), .text(kind), .text(value), .text(value.lowercased()), .uuid(ko)])
        }
        // A graph built before the builder excluded dates: the date is the
        // strongest edge of all.
        for (a, b, w) in [(alice, bob, 3), (alice, stamp, 9), (bob, stamp, 9)] {
            let (x, y) = a.uuidString < b.uuidString ? (a, b) : (b, a)
            try await db.exec("""
            INSERT INTO entity_cooccurrences (entity_a, entity_b, weight, computed_at) VALUES (?, ?, ?, 0);
            """, [.uuid(x), .uuid(y), .integer(Int64(w))])
        }

        _ = await AgglomerativeCommunityDetector(database: db).runOnce()
        let members = Set(try await db.query(
            "SELECT entity_id FROM entity_communities WHERE level = 0;", []).compactMap { $0.uuid(0) })
        #expect(!members.contains(stamp), "a date header is an attribute, never a community member")
        #expect(members.isSuperset(of: [alice, bob]), "the people still form their community")
    }
}

@Suite("P1.17 — topic labels are words, not fragments")
struct TopicLabelHygieneTests {
    @Test("Encoded fragments and truncated identifiers never label a node; real words and full identifiers do")
    func labelWorthy() {
        let canons: Set<String> = ["202331019665"]
        #expect(!TopicTreeBuilder.isLabelWorthy("capuxmjoemkzvp", anchorCanons: canons))
        #expect(!TopicTreeBuilder.isLabelWorthy("2023310", anchorCanons: canons))
        #expect(TopicTreeBuilder.isLabelWorthy("202331019665", anchorCanons: canons))
        for word in ["pharmaceuticals", "strengths", "attorney", "investigation", "khurana"] {
            #expect(TopicTreeBuilder.isLabelWorthy(word, anchorCanons: canons), "\(word)")
        }
    }
}
