//
//  EntityMergeTests.swift
//  KalsmritikoshTests
//
//  v52 soft, reversible entity merge/split. Verifies that merging folds the
//  loser under the winner (hidden from listings, mentions combined, old
//  spelling resolves via alias), that cycles and cross-kind merges are
//  rejected, and that unmerge fully restores — nothing is ever deleted.
//

import Testing
import Foundation
@testable import Kalsmritikosh

struct EntityMergeTests {

    private func makeDB() async throws -> Database {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kalsm-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try Database(url: dir.appendingPathComponent("test.sqlite"))
        try await SchemaMigrations.migrate(db)
        return db
    }

    /// Insert a canonical entity row directly (keeps the test focused on the
    /// merge path, not the full ingest/upsert machinery).
    private func insertEntity(_ db: Database, id: UUID, kind: String, value: String, normalized: String) async throws {
        try await db.exec("""
        INSERT INTO entities (id, kind, value, normalized, source_object_id, confidence, attributes_json, quality_tier)
        VALUES (?, ?, ?, ?, ?, ?, '{}', 'T2');
        """, [.uuid(id), .text(kind), .text(value), .text(normalized), .uuid(UUID()), .real(0.9)])
    }

    @Test func mergeHidesLoserAndResolvesOldSpelling() async throws {
        let db = try await makeDB()
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        let repo = EntitiesRepository(database: db)
        let winner = UUID(), loser = UUID()
        try await insertEntity(db, id: winner, kind: "person", value: "John Smith", normalized: "john smith")
        try await insertEntity(db, id: loser, kind: "person", value: "J. Smith", normalized: "j. smith")

        // Both visible before the merge.
        #expect((try await repo.list(kind: .person)).count == 2)

        try await repo.merge(loserID: loser, winnerID: winner)

        // Loser hidden from the canonical list; only the winner remains.
        let listed = try await repo.list(kind: .person)
        #expect(listed.count == 1)
        #expect(listed.first?.id == winner)
        // Loser shows in the merged set and resolves to the winner.
        #expect((try await repo.mergedInto(winner)).map(\.id) == [loser])
        #expect((try await repo.listMerged(kind: .person)).map(\.id) == [loser])
        let resolved = try await repo.resolveCanonical(loser)
        #expect(resolved == winner)
        // The old spelling still finds the winner (via the merge alias).
        let hit = try await repo.find(byValue: "j. smith")
        #expect(hit.map(\.id) == [winner])
    }

    @Test func unmergeFullyRestores() async throws {
        let db = try await makeDB()
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        let repo = EntitiesRepository(database: db)
        let winner = UUID(), loser = UUID()
        try await insertEntity(db, id: winner, kind: "person", value: "John Smith", normalized: "john smith")
        try await insertEntity(db, id: loser, kind: "person", value: "J. Smith", normalized: "j. smith")

        try await repo.merge(loserID: loser, winnerID: winner)
        try await repo.unmerge(loserID: loser)

        // Both canonical again; nothing merged; loser resolves to itself.
        #expect((try await repo.list(kind: .person)).count == 2)
        #expect((try await repo.mergedInto(winner)).isEmpty)
        #expect((try await repo.resolveCanonical(loser)) == loser)
    }

    @Test func rejectsSelfCrossKindAndCycleMerges() async throws {
        let db = try await makeDB()
        try await db.exec("PRAGMA foreign_keys=OFF;", [])
        let repo = EntitiesRepository(database: db)
        let a = UUID(), b = UUID(), org = UUID()
        try await insertEntity(db, id: a, kind: "person", value: "John Smith", normalized: "john smith")
        try await insertEntity(db, id: b, kind: "person", value: "J. Smith", normalized: "j. smith")
        try await insertEntity(db, id: org, kind: "organization", value: "Smith LLC", normalized: "smith llc")

        await #expect(throws: EntitiesRepository.MergeError.self) {
            try await repo.merge(loserID: a, winnerID: a)          // self
        }
        await #expect(throws: EntitiesRepository.MergeError.self) {
            try await repo.merge(loserID: a, winnerID: org)        // cross-kind
        }
        try await repo.merge(loserID: b, winnerID: a)              // b → a
        await #expect(throws: EntitiesRepository.MergeError.self) {
            try await repo.merge(loserID: a, winnerID: b)          // a → b would cycle
        }
    }
}
