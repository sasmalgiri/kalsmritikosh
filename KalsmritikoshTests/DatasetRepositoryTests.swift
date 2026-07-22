//
//  DatasetRepositoryTests.swift
//  KalsmritikoshTests
//
//  LAB-002 — migration v55 applies cleanly and the EvidenceDataset round-trips durably with
//  lineage preserved; rows are paged (rowCount without loading them).
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 DatasetRepository")
struct DatasetRepositoryTests {

    private func freshDB() async throws -> Database {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lab002-\(UUID().uuidString).sqlite")
        let db = try Database(url: tmp)
        try await SchemaMigrations.migrate(db)
        return db
    }

    @Test("Migration reaches the latest version")
    func migrationApplies() async throws {
        let db = try await freshDB()
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Dataset round-trips with lineage preserved")
    func roundTrip() async throws {
        let repo = DatasetRepository(database: try await freshDB())
        let blk = UUID()
        let ds = EvidenceDataset(name: "payments",
            columns: [DatasetColumn(name: "amount", shape: .money)],
            rows: [DatasetRow(cells: [DatasetCell(value: "₹3,800", sourceBlockIDs: [blk], status: .sourceAsserted)]),
                   DatasetRow(cells: [DatasetCell(value: "₹1,200", sourceBlockIDs: [blk], status: .sourceAsserted)])])
        try await repo.save(ds)
        let loaded = try await repo.load(id: ds.id)
        #expect(loaded?.name == "payments")
        #expect(loaded?.rows.count == 2)
        #expect(loaded?.rows.first?.cells.first?.value == "₹3,800")
        #expect(loaded?.rows.first?.cells.first?.sourceBlockIDs == [blk])
        #expect(try await repo.rowCount(id: ds.id) == 2)
    }

    @Test("Delete removes the dataset and cascades its rows")
    func delete() async throws {
        let repo = DatasetRepository(database: try await freshDB())
        let ds = EvidenceDataset(name: "x", columns: [DatasetColumn(name: "c", shape: .text)],
                                 rows: [DatasetRow(cells: [DatasetCell(value: "v", sourceBlockIDs: [UUID()], status: .sourceAsserted)])])
        try await repo.save(ds)
        try await repo.delete(id: ds.id)
        #expect(try await repo.load(id: ds.id) == nil)
        #expect(try await repo.rowCount(id: ds.id) == 0)
    }
}
