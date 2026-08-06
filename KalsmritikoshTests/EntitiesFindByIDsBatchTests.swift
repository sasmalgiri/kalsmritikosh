//
//  EntitiesFindByIDsBatchTests.swift
//  KalsmritikoshTests
//
//  #148 hardening — proves the HybridRetriever entity global top-up refactor is behavior-preserving. That path
//  changed from a per-row `find(byID:)` loop (N+1) to a single `findByIDs(...)` batch. This test asserts the
//  batch returns exactly the same canonical entities (by id) that per-row find would have, over the same
//  `list(kind:)` rows the retriever uses — so the query reduction changes cost, not results. Synthetic only.
//

import Testing
import Foundation
@testable import Kalsmritikosh

@Suite("Entities findByIDs batch equivalence", .serialized)
struct EntitiesFindByIDsBatchTests {

    /// A repo over a fresh DB plus one real knowledge_objects row (entities reference a KO via source_object_id).
    private func makeRepo() async throws -> (repo: EntitiesRepository, sourceKO: UUID) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ent-batch-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        let fileID = UUID(), koID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at) VALUES (?,?,?,?,?,?);",
                          [.uuid(koID), .uuid(fileID), .text("txt"), .text("seed"), .real(0), .real(0)])
        return (EntitiesRepository(database: db), koID)
    }

    @Test("findByIDs over list(kind:) rows returns the same entities as per-row find(byID:)")
    func batchMatchesPerRow() async throws {
        let (repo, ko) = try await makeRepo()
        _ = try await repo.insertBatch((0..<6).map { i in
            Entity(kind: .organization, value: "Org \(i)", normalizedValue: "org \(i)", sourceObjectID: ko)
        })

        let rows = try await repo.list(kind: .organization, limit: 8)
        #expect(rows.count == 6)
        let ids = rows.map(\.id)

        // Per-row (the old path) vs batch (the new path).
        var perRow: [Entity] = []
        for id in ids { if let e = try await repo.find(byID: id) { perRow.append(e) } }
        let batched = try await repo.findByIDs(ids, limit: ids.count)

        #expect(Set(perRow.map(\.id)) == Set(ids))
        #expect(Set(batched.map(\.id)) == Set(perRow.map(\.id)), "batch resolves the same canonical entities")
        #expect(batched.count == perRow.count)
    }

    @Test("findByIDs is empty for no ids and ignores unknown ids")
    func batchEdgeCases() async throws {
        let (repo, _) = try await makeRepo()
        #expect(try await repo.findByIDs([]).isEmpty)
        #expect(try await repo.findByIDs([UUID()]).isEmpty)   // unknown id → no row, no crash
    }
}
