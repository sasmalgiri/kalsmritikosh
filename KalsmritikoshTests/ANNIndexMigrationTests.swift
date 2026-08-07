//
//  ANNIndexMigrationTests.swift
//  KalsmritikoshTests
//
//  P9.3 (GOV-005) — schema v103 adds the disk-backed ANN state (ann_index_meta /
//  ann_cells / ann_postings) to the SINGLE ledger. Proves reach, v102→v103
//  preservation, self-heal, repeat + fault rollback, milestone, the integrity
//  CHECKs (strategy/state vocab, geometry bounds), FK cascades (meta→cells,
//  chunks→postings), the one-cell-per-(chunk, model) uniqueness, and the
//  ANNIndexRepository round trip. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("P9.3 — v103 disk-backed ANN migration + repository")
struct ANNIndexMigrationTests {

    private let model = "bge-small.v1"

    private func insertMeta(_ db: Database, model: String = "bge-small.v1",
                            strategy: String = "inMemoryHNSW", state: String = "empty",
                            dimension: Int64 = 384) async throws {
        try await db.exec("""
            INSERT INTO ann_index_meta (model_id, strategy, state, dimension, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.text(model), .text(strategy), .text(state), .integer(dimension), .real(1), .real(1)])
    }

    /// A real chunk row (with its owning file + knowledge object) so posting FKs hold.
    @discardableResult
    private func insertChunk(_ db: Database) async throws -> UUID {
        let fileID = UUID(), koID = UUID(), chunkID = UUID()
        try await db.exec("INSERT INTO files (id, url, source_type) VALUES (?,?,?);",
                          [.uuid(fileID), .text("file:///\(fileID).txt"), .text("text")])
        try await db.exec("""
            INSERT INTO knowledge_objects (id, file_id, source_type, content, created_at, updated_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(koID), .uuid(fileID), .text("txt"), .text("body"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO chunks (id, object_id, ordinal, text, char_start, char_end, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(chunkID), .uuid(koID), .integer(0), .text("body"), .integer(0), .integer(4), .real(1)])
        return chunkID
    }

    private func insertPosting(_ db: Database, chunkID: UUID, model: String = "bge-small.v1",
                               cell: Int64 = 0) async throws {
        try await db.exec("""
            INSERT INTO ann_postings (model_id, cell_id, chunk_id, q, scale) VALUES (?,?,?,?,?);
            """, [.text(model), .integer(cell), .uuid(chunkID),
                  .blob(Data(repeating: 1, count: 384)), .real(0.01)])
    }

    // MARK: - Migration proofs

    @Test("A fresh database reaches v103 with all three ANN tables")
    func freshV103() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        #expect(try await db.currentUserVersion() == 103)
        for table in ["ann_index_meta", "ann_cells", "ann_postings"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, table), "\(table) missing")
        }
        #expect(try await MigrationFixtureBuilder.columns(db, "ann_index_meta")
            .isSuperset(of: ["model_id", "strategy", "state", "dimension", "cell_count",
                             "trained_vector_count", "train_seed"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "ann_postings")
            .isSuperset(of: ["model_id", "cell_id", "chunk_id", "q", "scale"]))
    }

    @Test("v102→v103 preserves existing chunks and fabricates no ANN rows")
    func v102ToV103Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 102)
        _ = try await insertChunk(db)
        try await SchemaMigrations.migrate(db, through: 103)
        #expect(try await db.currentUserVersion() == 103)
        #expect(try await db.query("SELECT COUNT(*) FROM chunks;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM ann_index_meta;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM ann_postings;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v103 tables")
    func selfHealRecognizesV103() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(99)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v103 database is a safe no-op")
    func v103Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        try await SchemaMigrations.migrate(db, through: 103)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v103 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 102)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 103, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 103)))
        }
        #expect(try await db.currentUserVersion() == 102)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='ann_index_meta';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v103 with a clean FK graph")
    func milestoneReachesV103() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 103)
        #expect(try await db.currentUserVersion() == 103)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - Integrity CHECKs + cascades

    @Test("Meta enforces the strategy/state vocabularies and geometry bounds")
    func metaChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        await #expect(throws: (any Error).self) { try await insertMeta(db, strategy: "bogus") }
        await #expect(throws: (any Error).self) { try await insertMeta(db, state: "bogus") }
        await #expect(throws: (any Error).self) { try await insertMeta(db, dimension: 0) }
        try await insertMeta(db)                                            // valid defaults
        await #expect(throws: (any Error).self) { try await insertMeta(db) } // PK duplicate
    }

    @Test("Cells require their meta row and cascade when it is deleted")
    func cellsCascadeFromMeta() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO ann_cells (model_id, cell_id, centroid, updated_at) VALUES (?,?,?,?);",
                              [.text("no-meta"), .integer(0), .blob(Data(count: 4)), .real(1)])
        }
        try await insertMeta(db)
        try await db.exec("INSERT INTO ann_cells (model_id, cell_id, centroid, updated_at) VALUES (?,?,?,?);",
                          [.text(model), .integer(0), .blob(Data(count: 4)), .real(1)])
        try await db.exec("DELETE FROM ann_index_meta WHERE model_id = ?;", [.text(model)])
        #expect(try await db.query("SELECT COUNT(*) FROM ann_cells;", []).first?.int(0) == 0)
    }

    @Test("A posting requires a real chunk, cascades on chunk deletion, and one chunk holds one cell per model")
    func postingFKCascadeAndUniqueness() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertPosting(db, chunkID: UUID()) }
        let chunk = try await insertChunk(db)
        try await insertPosting(db, chunkID: chunk, cell: 3)
        // Same chunk+model in a DIFFERENT cell violates the unique (chunk, model) index.
        await #expect(throws: (any Error).self) { try await insertPosting(db, chunkID: chunk, cell: 7) }
        // A different model may hold the same chunk.
        try await insertPosting(db, chunkID: chunk, model: "apple.nl.v1", cell: 1)
        try await db.exec("DELETE FROM chunks WHERE id = ?;", [.uuid(chunk)])
        #expect(try await db.query("SELECT COUNT(*) FROM ann_postings;", []).first?.int(0) == 0)
    }

    // MARK: - Repository round trip

    @Test("The repository round-trips meta, cells and postings, and honours the retrain contract")
    func repositoryRoundTrip() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 103)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let repo = ANNIndexRepository(database: db)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        try await repo.ensureMeta(modelID: model, dimension: 384, at: t0)
        try await repo.ensureMeta(modelID: model, dimension: 384, at: t0)   // idempotent
        var meta = try #require(try await repo.meta(for: model))
        #expect(meta.strategy == .inMemoryHNSW && meta.state == .empty && meta.dimension == 384)

        try await repo.setState(.building, for: model, at: t0)
        try await repo.recordTraining(cellCount: 2, trainedVectorCount: 150, seed: 0xDEADBEEF, for: model, at: t0)
        try await repo.replaceCells([
            ANNCell(cellID: 0, centroid: Data(repeating: 0, count: 1536), vectorCount: 0),
            ANNCell(cellID: 1, centroid: Data(repeating: 1, count: 1536), vectorCount: 0),
        ], for: model, at: t0)

        let chunkA = try await insertChunk(db), chunkB = try await insertChunk(db)
        try await repo.insertPostings([
            ANNPosting(cellID: 0, chunkID: chunkA, q: Data(repeating: 2, count: 384), scale: 0.02),
            ANNPosting(cellID: 1, chunkID: chunkB, q: Data(repeating: 3, count: 384), scale: 0.03),
        ], for: model)
        try await repo.adjustCellCount(cellID: 0, by: 1, for: model, at: t0)
        try await repo.setState(.ready, for: model, at: t0)
        try await repo.setStrategy(.diskIVF, for: model, at: t0)

        meta = try #require(try await repo.meta(for: model))
        #expect(meta.strategy == .diskIVF && meta.state == .ready)
        #expect(meta.cellCount == 2 && meta.trainedVectorCount == 150 && meta.trainSeed == 0xDEADBEEF)
        #expect(try await repo.cells(for: model).count == 2)
        #expect(try await repo.cells(for: model).first?.vectorCount == 1)
        #expect(try await repo.postingCount(for: model) == 2)
        #expect(try await repo.postings(inCell: 0, for: model).map(\.chunkID) == [chunkA])

        // Removal + retrain contract.
        try await repo.removePosting(chunkID: chunkA, for: model)
        #expect(try await repo.postingCount(for: model) == 1)
        try await repo.deleteAllPostings(for: model)
        try await repo.replaceCells([], for: model, at: t0)
        #expect(try await repo.postingCount(for: model) == 0)
        #expect(try await repo.cells(for: model).isEmpty)
    }
}
