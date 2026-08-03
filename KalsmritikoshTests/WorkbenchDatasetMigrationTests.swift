//
//  WorkbenchDatasetMigrationTests.swift
//  KalsmritikoshTests
//
//  LAB-001 — schema v92 adds the canonical Workbench dataset model: workbench_datasets + _fields +
//  _rows (stable identity) + _cells (typed by kind) + _source_bindings (drill-through to canonical
//  origin) + _saved_views + _dataset_events (revision history). Proves reach, v91→v92 legacy
//  preservation (the superseded evidence_datasets/dataset_rows prototype is untouched, no fabricated
//  datasets), self-heal, repeat + fault rollback, milestone, and every integrity CHECK/FK + cascade.
//  Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-001 — v92 Workbench dataset migration")
struct WorkbenchDatasetMigrationTests {

    private func seedWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(id), .text("W"), .real(100), .real(100)])
    }

    private func insertDataset(_ db: Database, ws: UUID, id: UUID = UUID(), title: String = "Payments",
                               mode: String = "advanced", revision: Int64 = 1) async throws {
        try await db.exec("""
            INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(ws), .text(title), .text(mode), .integer(revision), .real(100), .real(100)])
    }

    @discardableResult
    private func insertField(_ db: Database, dataset: UUID, id: UUID = UUID(), name: String = "amount",
                             shape: String = "number", ordinal: Int64 = 0) async throws -> UUID {
        try await db.exec("""
            INSERT INTO workbench_fields (id, dataset_id, name, value_shape, ordinal, created_at)
            VALUES (?,?,?,?,?,?);
            """, [.uuid(id), .uuid(dataset), .text(name), .text(shape), .integer(ordinal), .real(100)])
        return id
    }

    @discardableResult
    private func insertRow(_ db: Database, dataset: UUID, id: UUID = UUID(), ordinal: Int64 = 0) async throws -> UUID {
        try await db.exec("INSERT INTO workbench_rows (id, dataset_id, ordinal, created_at) VALUES (?,?,?,?);",
                          [.uuid(id), .uuid(dataset), .integer(ordinal), .real(100)])
        return id
    }

    @discardableResult
    private func insertCell(_ db: Database, dataset: UUID, row: UUID, field: UUID, id: UUID = UUID(),
                            kind: String = "sourceValue", value: SQLValue = .text("100"),
                            status: String = "supported") async throws -> UUID {
        try await db.exec("""
            INSERT INTO workbench_cells (id, dataset_id, row_id, field_id, kind, value, status, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(dataset), .uuid(row), .uuid(field), .text(kind), value, .text(status), .real(100)])
        return id
    }

    private func insertBinding(_ db: Database, cell: UUID, kind: String = "evidenceBlock",
                               target: String = "blk-1", ordinal: Int64 = 0) async throws {
        try await db.exec("""
            INSERT INTO workbench_source_bindings (id, cell_id, target_kind, target_id, source_version_id, locator_json, ordinal, created_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(cell), .text(kind), .text(target), .null, .null, .integer(ordinal), .real(100)])
    }

    private func insertEvent(_ db: Database, dataset: UUID, seq: Int64 = 1, rev: Int64 = 1,
                             action: String = "created", actor: String = "u") async throws {
        try await db.exec("""
            INSERT INTO workbench_dataset_events (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(dataset), .integer(seq), .integer(rev), .text(action), .text(actor), .null, .real(100)])
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v92 with the seven Workbench tables")
    func freshV92() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        #expect(try await db.currentUserVersion() == 92)
        for t in ["workbench_datasets", "workbench_fields", "workbench_rows", "workbench_cells",
                  "workbench_source_bindings", "workbench_saved_views", "workbench_dataset_events"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing at v92")
        }
        #expect(try await MigrationFixtureBuilder.columns(db, "workbench_cells").isSuperset(of: ["row_id", "field_id", "kind", "value", "status"]))
    }

    @Test("v91→v92 preserves the legacy dataset prototype with no fabricated Workbench datasets")
    func v91ToV92Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        let legacy = UUID()
        try await db.exec("""
            INSERT INTO evidence_datasets (id, name, version, columns_json, created_at) VALUES (?,?,?,?,?);
            """, [.uuid(legacy), .text("legacy"), .integer(1), .text("[]"), .real(1)])
        try await SchemaMigrations.migrate(db, through: 92)
        #expect(try await db.currentUserVersion() == 92)
        #expect(try await db.query("SELECT COUNT(*) FROM evidence_datasets WHERE id = ?;", [.uuid(legacy)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_datasets;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v92 Workbench tables")
    func selfHealRecognizesV92() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(90)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v92 database is a safe no-op")
    func v92Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await SchemaMigrations.migrate(db, through: 92)
        #expect(try await db.currentUserVersion() == 92)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v92 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 92, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 92)))
        }
        #expect(try await db.currentUserVersion() == 91)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='workbench_datasets';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v92 with a clean FK graph")
    func milestoneReachesV92() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 92)
        #expect(try await db.currentUserVersion() == 92)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - CHECKs

    @Test("Dataset title / mode / revision are constrained")
    func datasetChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertDataset(db, ws: ws, title: "  ") }
        await #expect(throws: (any Error).self) { try await insertDataset(db, ws: ws, mode: "expert") }
        await #expect(throws: (any Error).self) { try await insertDataset(db, ws: ws, revision: 0) }
        try await insertDataset(db, ws: ws, mode: "simple")
        try await insertDataset(db, ws: ws, mode: "advanced")
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_datasets;", []).first?.int(0) == 2)
    }

    @Test("A cell kind must be one of the closed provenance classes")
    func cellKindVocabulary() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let d = UUID(); try await insertDataset(db, ws: ws, id: d)
        let f = try await insertField(db, dataset: d); let r = try await insertRow(db, dataset: d)
        await #expect(throws: (any Error).self) { try await insertCell(db, dataset: d, row: r, field: f, kind: "guessed") }
        for (i, kind) in ["sourceValue", "deterministicCalculation", "userEntered", "userCorrected", "modelProposal", "reviewed"].enumerated() {
            let rr = try await insertRow(db, dataset: d, ordinal: Int64(i + 1))
            try await insertCell(db, dataset: d, row: rr, field: f, kind: kind)
        }
        #expect(try await db.query("SELECT COUNT(DISTINCT kind) FROM workbench_cells;", []).first?.int(0) == 6)
    }

    @Test("One cell per (row, field)")
    func oneCellPerRowField() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let d = UUID(); try await insertDataset(db, ws: ws, id: d)
        let f = try await insertField(db, dataset: d); let r = try await insertRow(db, dataset: d)
        try await insertCell(db, dataset: d, row: r, field: f)
        await #expect(throws: (any Error).self) { try await insertCell(db, dataset: d, row: r, field: f, value: .text("x")) }
    }

    @Test("A source binding's target kind and target id are constrained")
    func bindingChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let d = UUID(); try await insertDataset(db, ws: ws, id: d)
        let f = try await insertField(db, dataset: d); let r = try await insertRow(db, dataset: d)
        let c = try await insertCell(db, dataset: d, row: r, field: f)
        await #expect(throws: (any Error).self) { try await insertBinding(db, cell: c, kind: "spreadsheet") }
        await #expect(throws: (any Error).self) { try await insertBinding(db, cell: c, target: "  ") }
        try await insertBinding(db, cell: c, kind: "sourceVersion", target: "sv-1")
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_source_bindings;", []).first?.int(0) == 1)
    }

    @Test("Dataset event action is a closed vocabulary with a unique per-dataset sequence")
    func eventChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let d = UUID(); try await insertDataset(db, ws: ws, id: d)
        await #expect(throws: (any Error).self) { try await insertEvent(db, dataset: d, action: "guessed") }
        try await insertEvent(db, dataset: d, seq: 1, action: "created")
        await #expect(throws: (any Error).self) { try await insertEvent(db, dataset: d, seq: 1, action: "rowAdded") }
        try await insertEvent(db, dataset: d, seq: 2, action: "rowAdded")
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_dataset_events;", []).first?.int(0) == 2)
    }

    // MARK: - FKs + cascade

    @Test("A dataset's workspace_id must reference a real workspace")
    func workspaceFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertDataset(db, ws: UUID()) }
    }

    @Test("Deleting a dataset cascades fields, rows, cells, bindings, views and events")
    func cascadeOnDatasetDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let d = UUID(); try await insertDataset(db, ws: ws, id: d)
        let f = try await insertField(db, dataset: d); let r = try await insertRow(db, dataset: d)
        let c = try await insertCell(db, dataset: d, row: r, field: f)
        try await insertBinding(db, cell: c)
        try await db.exec("INSERT INTO workbench_saved_views (id, dataset_id, name, projection_json, created_at) VALUES (?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(d), .text("v"), .text("{}"), .real(100)])
        try await insertEvent(db, dataset: d)
        try await db.exec("DELETE FROM workbench_datasets WHERE id = ?;", [.uuid(d)])
        for t in ["workbench_fields", "workbench_rows", "workbench_cells", "workbench_source_bindings",
                  "workbench_saved_views", "workbench_dataset_events"] {
            #expect(try await db.query("SELECT COUNT(*) FROM \(t);", []).first?.int(0) == 0, "\(t) not cascaded")
        }
    }

    @Test("Deleting a row cascades its cells; deleting a cell cascades its source bindings")
    func cascadeRowAndCell() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 92)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let d = UUID(); try await insertDataset(db, ws: ws, id: d)
        let f = try await insertField(db, dataset: d)
        let r = try await insertRow(db, dataset: d)
        let c = try await insertCell(db, dataset: d, row: r, field: f)
        try await insertBinding(db, cell: c)
        try await db.exec("DELETE FROM workbench_cells WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_source_bindings;", []).first?.int(0) == 0)
        // A second row+cell, then delete the row → its cell cascades.
        let r2 = try await insertRow(db, dataset: d, ordinal: 1)
        _ = try await insertCell(db, dataset: d, row: r2, field: f)
        try await db.exec("DELETE FROM workbench_rows WHERE id = ?;", [.uuid(r2)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_cells WHERE row_id = ?;", [.uuid(r2)]).first?.int(0) == 0)
    }
}
