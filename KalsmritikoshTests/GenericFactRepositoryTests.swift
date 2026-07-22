//
//  GenericFactRepositoryTests.swift
//  KalsmritikoshTests
//
//  SEM persistence — migration v57 applies; domain-pack facts persist and read back with
//  evidence lineage intact (end-to-end: extractor → repo → query).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("GenericFactRepository (v57)")
struct GenericFactRepositoryTests {

    private func freshDB() async throws -> Database {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gf-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return db
    }

    @Test("Migration reaches v57 (generic_facts exists)")
    func migration() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Extracted facts persist and read back by subject+field with lineage")
    func endToEnd() async throws {
        let repo = GenericFactRepository(database: try await freshDB())
        let blk = UUID()
        let facts = DomainFactExtractor().extract(
            fromText: "Paid to Rajesh Kumar. Amount ₹3,800 on 12/01/2024.",
            subjectLabel: "payment", blockID: blk)
        try await repo.upsert(facts)
        let amounts = try await repo.facts(subjectLabel: "payment", field: "amount")
        #expect(amounts.contains { $0.value == "₹3,800" })
        #expect(amounts.first?.sourceBlockIDs == [blk])
        #expect(try await repo.count() >= 2)
    }

    @Test("Upsert is idempotent on fact id")
    func idempotent() async throws {
        let repo = GenericFactRepository(database: try await freshDB())
        let f = GenericFact(subjectLabel: "s", field: "employer", value: "Orchid",
                            status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [UUID()])
        try await repo.upsert(f)
        try await repo.upsert(f)   // same id
        #expect(try await repo.count() == 1)
    }
}
