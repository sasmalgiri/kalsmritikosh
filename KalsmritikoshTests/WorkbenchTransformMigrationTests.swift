//
//  WorkbenchTransformMigrationTests.swift
//  KalsmritikoshTests
//
//  LAB-002 — schema v93 adds the safe transformation engine's durable lineage: workbench_transformations
//  (append-only, per-dataset sequence, closed kind vocab, engine version, spec, optional target field /
//  result) + workbench_derivations (one per derived value, optional output cell / group key / output) +
//  workbench_derivation_inputs (the EXACT input cells a derived value read). It also rebuilds
//  workbench_dataset_events to widen the action vocabulary with 'transformed', preserving existing rows.
//  Proves reach, v92→v93 preservation + vocabulary extension, self-heal, repeat + fault rollback,
//  milestone, and every integrity CHECK / FK / cascade. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-002 — v93 Workbench transformation migration")
struct WorkbenchTransformMigrationTests {

    private func seedDataset(_ db: Database, ws: UUID = UUID(), dataset d: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("W"), .real(100), .real(100)])
        try await db.exec("""
            INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(d), .uuid(ws), .text("D"), .text("advanced"), .integer(1), .real(100), .real(100)])
    }

    private func insertTransformation(_ db: Database, dataset d: UUID, id: UUID = UUID(), seq: Int64 = 1,
                                      kind: String = "calculatedColumn", engine: String = "workbench-transform-1",
                                      spec: String = "{}", actor: String = "u") async throws -> UUID {
        try await db.exec("""
            INSERT INTO workbench_transformations
              (id, dataset_id, sequence, kind, formula_text, engine_version, spec_json, target_field_id, result_json, actor, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(d), .integer(seq), .text(kind), .null, .text(engine), .text(spec), .null, .null, .text(actor), .real(100)])
        return id
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v93 with the three transformation tables")
    func freshV93() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        #expect(try await db.currentUserVersion() == 93)
        for t in ["workbench_transformations", "workbench_derivations", "workbench_derivation_inputs"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing at v93")
        }
        #expect(try await MigrationFixtureBuilder.columns(db, "workbench_transformations")
            .isSuperset(of: ["kind", "formula_text", "engine_version", "spec_json", "target_field_id", "result_json"]))
    }

    @Test("v92→v93 preserves existing dataset events and widens the action vocabulary with 'transformed'")
    func v92ToV93PreservesAndExtends() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        let ws = UUID(); let d = UUID(); try await seedDataset(db, ws: ws, dataset: d)
        try await db.exec("""
            INSERT INTO workbench_dataset_events (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(d), .integer(1), .integer(1), .text("created"), .text("u"), .null, .real(100)])
        // 'transformed' is NOT yet a permitted action at v92.
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO workbench_dataset_events (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(d), .integer(2), .integer(2), .text("transformed"), .text("u"), .null, .real(100)])
        }
        try await SchemaMigrations.migrate(db, through: 93)
        #expect(try await db.currentUserVersion() == 93)
        // The pre-existing 'created' event survived the rebuild verbatim.
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_dataset_events WHERE dataset_id = ? AND action = 'created';", [.uuid(d)]).first?.int(0) == 1)
        // 'transformed' is now permitted.
        try await db.exec("""
            INSERT INTO workbench_dataset_events (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(d), .integer(2), .integer(2), .text("transformed"), .text("u"), .null, .real(100)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_dataset_events WHERE action = 'transformed';", []).first?.int(0) == 1)
    }

    @Test("The self-heal sentinel recognises the v93 transformation tables")
    func selfHealRecognizesV93() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(90)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v93 database is a safe no-op")
    func v93Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await SchemaMigrations.migrate(db, through: 93)
        #expect(try await db.currentUserVersion() == 93)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v93 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 93, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 93)))
        }
        #expect(try await db.currentUserVersion() == 92)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='workbench_transformations';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v93 with a clean FK graph")
    func milestoneReachesV93() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 93)
        #expect(try await db.currentUserVersion() == 93)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - CHECKs

    @Test("Transformation kind is a closed vocabulary")
    func kindVocabulary() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: d, kind: "guessed") }
        for (i, k) in ["calculatedColumn", "runningTotal", "filter", "sort", "deduplicate", "aggregate", "pivot", "join", "rollingCalculation"].enumerated() {
            _ = try await insertTransformation(db, dataset: d, seq: Int64(i + 1), kind: k)
        }
        #expect(try await db.query("SELECT COUNT(DISTINCT kind) FROM workbench_transformations;", []).first?.int(0) == 9)
    }

    @Test("engine_version, spec_json and actor must be non-blank; sequence >= 1")
    func nonBlankAndSequence() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: d, engine: "  ") }
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: d, spec: "  ") }
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: d, actor: "  ") }
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: d, seq: 0) }
    }

    @Test("A per-dataset transformation sequence is unique")
    func uniqueSequence() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        _ = try await insertTransformation(db, dataset: d, seq: 1)
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: d, seq: 1) }
        _ = try await insertTransformation(db, dataset: d, seq: 2)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_transformations;", []).first?.int(0) == 2)
    }

    @Test("A derivation input ordinal is unique within a derivation and non-negative")
    func derivationInputUnique() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); let d = UUID(); try await seedDataset(db, ws: ws, dataset: d)
        let tx = try await insertTransformation(db, dataset: d)
        // A field, a row and a cell to reference as an input.
        let f = UUID(); try await db.exec("INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at) VALUES (?,?,?,?,?,?);",
                                          [.uuid(f), .uuid(d), .text("amount"), .text("number"), .integer(0), .real(100)])
        let r = UUID(); try await db.exec("INSERT INTO workbench_rows (id, dataset_id, ordinal, created_at) VALUES (?,?,?,?);",
                                          [.uuid(r), .uuid(d), .integer(0), .real(100)])
        let c = UUID(); try await db.exec("INSERT INTO workbench_cells (id, dataset_id, row_id, field_id, kind, value, status, created_at) VALUES (?,?,?,?,?,?,?,?);",
                                          [.uuid(c), .uuid(d), .uuid(r), .uuid(f), .text("sourceValue"), .text("1"), .text("DIRECTLY_OBSERVED"), .real(100)])
        let der = UUID(); try await db.exec("INSERT INTO workbench_derivations (id, transformation_id, dataset_id, output_cell_id, result_key, output_value, created_at) VALUES (?,?,?,?,?,?,?);",
                                            [.uuid(der), .uuid(tx), .uuid(d), .null, .null, .text("1"), .real(100)])
        try await db.exec("INSERT INTO workbench_derivation_inputs (id, derivation_id, input_cell_id, ordinal) VALUES (?,?,?,?);",
                          [.uuid(UUID()), .uuid(der), .uuid(c), .integer(0)])
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO workbench_derivation_inputs (id, derivation_id, input_cell_id, ordinal) VALUES (?,?,?,?);",
                              [.uuid(UUID()), .uuid(der), .uuid(c), .integer(0)])   // duplicate ordinal
        }
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO workbench_derivation_inputs (id, derivation_id, input_cell_id, ordinal) VALUES (?,?,?,?);",
                              [.uuid(UUID()), .uuid(der), .uuid(c), .integer(-1)])  // negative ordinal
        }
    }

    // MARK: - FKs + cascade

    @Test("A transformation's dataset must exist; target_field_id references a real field")
    func fkChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { _ = try await insertTransformation(db, dataset: UUID()) }
        let d = UUID(); try await seedDataset(db, dataset: d)
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO workbench_transformations (id, dataset_id, sequence, kind, formula_text, engine_version, spec_json, target_field_id, result_json, actor, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(d), .integer(1), .text("calculatedColumn"), .null, .text("e"), .text("{}"), .uuid(UUID()), .null, .text("u"), .real(100)])
        }
    }

    @Test("Deleting a transformation cascades its derivations and their inputs")
    func cascadeTransformation() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let tx = try await insertTransformation(db, dataset: d)
        let f = UUID(); try await db.exec("INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at) VALUES (?,?,?,?,?,?);",
                                          [.uuid(f), .uuid(d), .text("amount"), .text("number"), .integer(0), .real(100)])
        let r = UUID(); try await db.exec("INSERT INTO workbench_rows (id, dataset_id, ordinal, created_at) VALUES (?,?,?,?);",
                                          [.uuid(r), .uuid(d), .integer(0), .real(100)])
        let c = UUID(); try await db.exec("INSERT INTO workbench_cells (id, dataset_id, row_id, field_id, kind, value, status, created_at) VALUES (?,?,?,?,?,?,?,?);",
                                          [.uuid(c), .uuid(d), .uuid(r), .uuid(f), .text("sourceValue"), .text("1"), .text("DIRECTLY_OBSERVED"), .real(100)])
        let der = UUID(); try await db.exec("INSERT INTO workbench_derivations (id, transformation_id, dataset_id, output_cell_id, result_key, output_value, created_at) VALUES (?,?,?,?,?,?,?);",
                                            [.uuid(der), .uuid(tx), .uuid(d), .null, .null, .text("1"), .real(100)])
        try await db.exec("INSERT INTO workbench_derivation_inputs (id, derivation_id, input_cell_id, ordinal) VALUES (?,?,?,?);",
                          [.uuid(UUID()), .uuid(der), .uuid(c), .integer(0)])
        try await db.exec("DELETE FROM workbench_transformations WHERE id = ?;", [.uuid(tx)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_derivations;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_derivation_inputs;", []).first?.int(0) == 0)
    }

    @Test("Deleting the dataset cascades transformations, derivations and inputs")
    func cascadeDataset() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let tx = try await insertTransformation(db, dataset: d)
        try await db.exec("INSERT INTO workbench_derivations (id, transformation_id, dataset_id, output_cell_id, result_key, output_value, created_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(tx), .uuid(d), .null, .text("k"), .text("1"), .real(100)])
        try await db.exec("DELETE FROM workbench_datasets WHERE id = ?;", [.uuid(d)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_transformations;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_derivations;", []).first?.int(0) == 0)
    }

    @Test("Deleting a source cell cascades the derivation-input link that referenced it")
    func cascadeInputCell() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let tx = try await insertTransformation(db, dataset: d)
        let f = UUID(); try await db.exec("INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at) VALUES (?,?,?,?,?,?);",
                                          [.uuid(f), .uuid(d), .text("a"), .text("number"), .integer(0), .real(100)])
        let r = UUID(); try await db.exec("INSERT INTO workbench_rows (id, dataset_id, ordinal, created_at) VALUES (?,?,?,?);",
                                          [.uuid(r), .uuid(d), .integer(0), .real(100)])
        let c = UUID(); try await db.exec("INSERT INTO workbench_cells (id, dataset_id, row_id, field_id, kind, value, status, created_at) VALUES (?,?,?,?,?,?,?,?);",
                                          [.uuid(c), .uuid(d), .uuid(r), .uuid(f), .text("sourceValue"), .text("1"), .text("DIRECTLY_OBSERVED"), .real(100)])
        let der = UUID(); try await db.exec("INSERT INTO workbench_derivations (id, transformation_id, dataset_id, output_cell_id, result_key, output_value, created_at) VALUES (?,?,?,?,?,?,?);",
                                            [.uuid(der), .uuid(tx), .uuid(d), .null, .null, .text("1"), .real(100)])
        try await db.exec("INSERT INTO workbench_derivation_inputs (id, derivation_id, input_cell_id, ordinal) VALUES (?,?,?,?);",
                          [.uuid(UUID()), .uuid(der), .uuid(c), .integer(0)])
        try await db.exec("DELETE FROM workbench_cells WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_derivation_inputs;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_derivations;", []).first?.int(0) == 1)   // the derivation itself remains
    }
}
