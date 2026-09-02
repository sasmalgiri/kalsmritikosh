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

    @Test("facts(forBlockIDs:) returns only facts whose evidence intersects the blocks")
    func blockJoin() async throws {
        let repo = GenericFactRepository(database: try await freshDB())
        let blkA = UUID(), blkB = UUID(), blkC = UUID()
        try await repo.upsert(GenericFact(subjectLabel: "doc", field: "employer", value: "Orchid",
                                          status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blkA]))
        try await repo.upsert(GenericFact(subjectLabel: "doc", field: "amount", value: "₹3,800",
                                          status: .directlyObserved, confidence: 0.9, sourceBlockIDs: [blkB]))
        // Ask for A + an unrelated block → only the A fact rides along.
        let hits = try await repo.facts(forBlockIDs: [blkA, blkC])
        #expect(hits.count == 1)
        #expect(hits.first?.value == "Orchid")
        // Both blocks → both facts, highest confidence first.
        let both = try await repo.facts(forBlockIDs: [blkA, blkB])
        #expect(both.map(\.value) == ["₹3,800", "Orchid"])
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

    // MARK: - w1: the version dialect round-trips at the SQL layer (both directions)

    /// Set fields → insert → decode intact. A v1 fact carrying producer_version,
    /// raw_match and source_count writes and reads back through the repository's
    /// own SQL INSERT and SELECT unchanged — the WRITE direction of the dialect.
    @Test("v1 fact round-trips producer_version, raw_match and source_count")
    func versionColumnsRoundTrip() async throws {
        let repo = GenericFactRepository(database: try await freshDB())
        let blk = UUID()
        let f = GenericFact(subjectLabel: "patent", field: "patentNumber", value: "555489",
                            status: .sourceAsserted, confidence: 0.8, sourceBlockIDs: [blk],
                            producerVersion: 1, rawMatch: "Patent No. 555489.", sourceCount: 6,
                            reassignedFrom: "applicationnumber")
        try await repo.upsert(f)
        let read = try await repo.facts(subjectLabel: "patent", field: "patentNumber")
        let got = try #require(read.first { $0.value == "555489" })
        #expect(got.producerVersion == 1)
        #expect(got.rawMatch == "Patent No. 555489.")
        #expect(got.sourceCount == 6)
        #expect(got.reassignedFrom == "applicationnumber")   // v122 gate-3 advisory round-trips
    }

    /// The MIRROR at the SQL read path: a row written with the three columns
    /// absent (a pre-v121 legacy row, or any producer that leaves them unset)
    /// decodes to nil ≡ v0 and would render legacy. 2a proved this at the model
    /// layer; this proves it end-to-end through the repository's SELECT/decode,
    /// so the legacy ledger's safety is not merely inferred across layers.
    @Test("NULL version columns decode to nil ≡ v0 (legacy row)")
    func nullVersionColumnsDecodeAsLegacy() async throws {
        let db = try await freshDB()
        let repo = GenericFactRepository(database: db)
        let id = UUID()
        // Raw INSERT naming only the identity/content columns — producer_version,
        // raw_match and source_count are left at their column default (NULL),
        // exactly as a row written before v121 carries them.
        try await db.exec("""
        INSERT INTO generic_facts (id, subject_label, field, value, status, confidence, source_blocks_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """, [.uuid(id), .text("patent"), .text("patentnumber"), .text("555489"),
              .text("sourceAsserted"), .real(0.8), .text("[]"), .real(0)])
        let read = try await repo.facts(subjectLabel: "patent", field: "patentNumber")
        let got = try #require(read.first { $0.value == "555489" })
        #expect(got.producerVersion == nil)   // ≡ v0 ≡ current, renders legacy
        #expect(got.rawMatch == nil)
        #expect(got.sourceCount == nil)
    }
}
