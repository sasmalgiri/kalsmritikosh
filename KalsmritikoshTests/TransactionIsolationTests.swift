//
//  TransactionIsolationTests.swift
//  KalsmritikoshTests
//
//  F28 (residual, 2026-09-29 review) — `beginTransaction()` held a SQLite transaction open across
//  awaits. Only callers of that gate waited for it; an ordinary write or `withSavepoint` from any
//  other repository ran INSIDE the open transaction, reported success, and vanished when the
//  graph batch later rolled back. Every transaction is now one synchronous isolated unit.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("F28 — no await-spanning transaction can swallow another caller's write", .serialized)
struct TransactionIsolationTests {

    private struct Rig { let db: Database; let ko: UUID; let entities: [UUID] }

    private func rig(entities n: Int = 6) async throws -> Rig {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let file = UUID(), ko = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(file), .text("file:///tx-\(file)"), .text("txt")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);
            """, [.uuid(ko), .uuid(file), .text("txt"), .text("c"), .real(0), .real(0)])
        var ids: [UUID] = []
        for i in 0..<n {
            let id = UUID()
            try await db.exec("INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence) VALUES (?,?,?,?,?,?);",
                              [.uuid(id), .text("person"), .text("P\(i)"), .text("p\(i)"), .uuid(ko), .real(0.9)])
            ids.append(id)
        }
        return Rig(db: db, ko: ko, entities: ids)
    }

    private func review(_ i: Int) -> FactReview {
        FactReview(subjectKind: .entity, subjectID: UUID(), action: .reject, reviewer: "unrelated.\(i)", reason: "r\(i)")
    }

    private func count(_ db: Database, _ sql: String) async throws -> Int {
        Int(try await db.query(sql, []).first?.int(0) ?? 0)
    }

    @Test("A failing edge batch rolls back alone: every unrelated write that succeeded persists")
    func failedEdgeBatchKeepsUnrelatedWrites() async throws {
        let r = try await rig()
        let rel = RelationshipsRepository(database: r.db)
        let reviews = FactReviewsRepository(database: r.db)
        let e = r.entities
        // Five valid edges, then one whose endpoint does not exist (foreign-key failure).
        var batch = (0..<5).map { RelationshipsRepository.EdgeUpsert(kind: .coOccurs, from: e[$0], to: e[$0 + 1]) }
        batch.append(.init(kind: .coOccurs, from: UUID(), to: e[0]))
        let rounds = 12, writesPerRound = 8
        var reported = 0
        for round in 0..<rounds {
            reported += try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    _ = try? await rel.upsertEdges(batch, sourceObjectID: r.ko)
                    return 0
                }
                for w in 0..<writesPerRound {
                    group.addTask {
                        _ = try await reviews.record(review(round * writesPerRound + w))
                        return 1
                    }
                }
                var n = 0
                for try await x in group { n += x }
                return n
            }
        }
        #expect(reported == rounds * writesPerRound)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM fact_reviews;") == reported,
                "an unrelated write reported success and then disappeared")
        #expect(try await count(r.db, "SELECT COUNT(*) FROM relationships;") == 0, "a failed batch left partial edges")
    }

    @Test("A failing bond batch rolls back alone: every unrelated write that succeeded persists")
    func failedBondBatchKeepsUnrelatedWrites() async throws {
        let r = try await rig()
        let bonds = FactBondsRepository(database: r.db)
        let reviews = FactReviewsRepository(database: r.db)
        let existing = (0..<5).map { _ in
            FactBondsRepository.BondUpsert(bondName: "b", fromKind: .event, fromID: UUID(), toKind: .event, toID: UUID())
        }
        try await bonds.upsertBonds(existing, sourceObjectID: r.ko)
        // The five existing bonds take the UPDATE path; the new one's insert fails its foreign key.
        let batch = existing + [.init(bondName: "b", fromKind: .event, fromID: UUID(), toKind: .event, toID: UUID())]
        let rounds = 12, writesPerRound = 8
        var reported = 0
        for round in 0..<rounds {
            reported += try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    _ = try? await bonds.upsertBonds(batch, sourceObjectID: UUID())
                    return 0
                }
                for w in 0..<writesPerRound {
                    group.addTask {
                        _ = try await reviews.record(review(round * writesPerRound + w))
                        return 1
                    }
                }
                var n = 0
                for try await x in group { n += x }
                return n
            }
        }
        #expect(try await count(r.db, "SELECT COUNT(*) FROM fact_reviews;") == reported,
                "an unrelated write reported success and then disappeared")
        // Failed batches changed nothing: the seeded bonds still have weight 1.
        #expect(try await count(r.db, "SELECT COUNT(*) FROM fact_bonds WHERE weight != 1;") == 0)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM fact_bonds;") == 5)
    }

    @Test("Concurrent successful upserts keep exact weights, evidence and one row per identity")
    func concurrentUpsertsExact() async throws {
        let r = try await rig()
        let rel = RelationshipsRepository(database: r.db)
        let bonds = FactBondsRepository(database: r.db)
        let e = r.entities
        let bond = FactBondsRepository.BondUpsert(bondName: "b", fromKind: .event, fromID: UUID(), toKind: .event, toID: UUID())
        let newBondCounts = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<20 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        try await rel.upsertEdges([.init(kind: .coOccurs, from: e[0], to: e[1])], sourceObjectID: r.ko)
                    } else {
                        try await rel.upsertEdge(kind: .coOccurs, from: e[0], to: e[1], sourceObjectID: r.ko)
                    }
                    return try await bonds.upsertBonds([bond], sourceObjectID: r.ko).count
                }
            }
            var out: [Int] = []
            for try await n in group { out.append(n) }
            return out
        }
        #expect(try await count(r.db, "SELECT COUNT(*) FROM relationships;") == 1)
        #expect(try await count(r.db, "SELECT weight FROM relationships;") == 20)
        #expect(try await count(r.db, "SELECT COUNT(*) FROM fact_bonds;") == 1)
        #expect(try await count(r.db, "SELECT weight FROM fact_bonds;") == 20)
        #expect(newBondCounts.reduce(0, +) == 1, "exactly one caller reports the bond as newly inserted")
        let evidence = try await r.db.query("SELECT evidence_object_ids_json FROM relationships;", []).first?.string(0)
        #expect(evidence == "[\"\(r.ko.uuidString)\"]", "evidence de-duplicated")
    }
}
