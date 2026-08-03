//
//  WorkbenchScenarioMigrationTests.swift
//  KalsmritikoshTests
//
//  LAB-003 — schema v94 adds the scenario overlay tables: workbench_scenarios (base revision + undo/redo
//  pointer + status) + workbench_scenario_operations (append-only log, closed op/target/status vocab,
//  cell-op-requires-field) + workbench_scenario_reviews (reviewed promotion routing) +
//  workbench_scenario_events (audit). Proves reach, v93→v94 preservation, self-heal, repeat + fault
//  rollback, milestone, every integrity CHECK / FK / cascade. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("LAB-003 — v94 scenario migration")
struct WorkbenchScenarioMigrationTests {

    private func seedDataset(_ db: Database, ws: UUID = UUID(), dataset d: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(ws), .text("W"), .real(100), .real(100)])
        try await db.exec("""
            INSERT INTO workbench_datasets (id, workspace_id, title, mode, revision, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?);
            """, [.uuid(d), .uuid(ws), .text("D"), .text("advanced"), .integer(1), .real(100), .real(100)])
    }

    @discardableResult
    private func insertScenario(_ db: Database, dataset d: UUID, id: UUID = UUID(), status: String = "active",
                                ptr: Int64 = 0, baseRev: Int64 = 1, rev: Int64 = 1, actor: String = "u") async throws -> UUID {
        try await db.exec("""
            INSERT INTO workbench_scenarios (id, dataset_id, base_dataset_revision, title, status, current_op_seq, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(d), .integer(baseRev), .text("S"), .text(status), .integer(ptr), .integer(rev), .text(actor), .real(100), .real(100)])
        return id
    }

    @discardableResult
    private func insertOp(_ db: Database, scenario s: UUID, id: UUID = UUID(), seq: Int64 = 1, kind: String = "valueOverride",
                          targetKind: String = "cell", row: UUID = UUID(), field: UUID? = UUID(),
                          status: String = "live", actor: String = "u") async throws -> UUID {
        try await db.exec("""
            INSERT INTO workbench_scenario_operations (id, scenario_id, sequence, kind, target_kind, row_id, field_id, before_value, after_value, reason, status, actor, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(s), .integer(seq), .text(kind), .text(targetKind), .uuid(row),
                  field.map { SQLValue.uuid($0) } ?? .null, .null, .text("x"), .null, .text(status), .text(actor), .real(100)])
        return id
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v94 with the four scenario tables")
    func freshV94() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        #expect(try await db.currentUserVersion() == 94)
        for t in ["workbench_scenarios", "workbench_scenario_operations", "workbench_scenario_reviews", "workbench_scenario_events"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing at v94")
        }
        #expect(try await MigrationFixtureBuilder.columns(db, "workbench_scenarios").isSuperset(of: ["base_dataset_revision", "current_op_seq", "status"]))
    }

    @Test("v93→v94 preserves existing transformation lineage with no fabricated scenarios")
    func v93ToV94Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        let ws = UUID(); let d = UUID(); try await seedDataset(db, ws: ws, dataset: d)
        try await db.exec("""
            INSERT INTO workbench_transformations (id, dataset_id, sequence, kind, formula_text, engine_version, spec_json, target_field_id, result_json, actor, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(d), .integer(1), .text("filter"), .null, .text("e"), .text("{}"), .null, .null, .text("u"), .real(1)])
        try await SchemaMigrations.migrate(db, through: 94)
        #expect(try await db.currentUserVersion() == 94)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_transformations;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenarios;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v94 scenario tables")
    func selfHealRecognizesV94() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(91)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v94 database is a safe no-op")
    func v94Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await SchemaMigrations.migrate(db, through: 94)
        #expect(try await db.currentUserVersion() == 94)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v94 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 93)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 94, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 94)))
        }
        #expect(try await db.currentUserVersion() == 93)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='workbench_scenarios';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v94 with a clean FK graph")
    func milestoneReachesV94() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 94)
        #expect(try await db.currentUserVersion() == 94)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - CHECKs

    @Test("Scenario status, pointer and base revision are constrained")
    func scenarioChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        await #expect(throws: (any Error).self) { _ = try await insertScenario(db, dataset: d, status: "paused") }
        await #expect(throws: (any Error).self) { _ = try await insertScenario(db, dataset: d, ptr: -1) }
        await #expect(throws: (any Error).self) { _ = try await insertScenario(db, dataset: d, baseRev: 0) }
        _ = try await insertScenario(db, dataset: d, status: "active")
        _ = try await insertScenario(db, dataset: d, status: "discarded")
        _ = try await insertScenario(db, dataset: d, status: "promoted")
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenarios;", []).first?.int(0) == 3)
    }

    @Test("Operation kind / target-kind / status are closed vocabularies; a cell op requires a field")
    func operationChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let s = try await insertScenario(db, dataset: d)
        await #expect(throws: (any Error).self) { _ = try await insertOp(db, scenario: s, kind: "magic") }
        await #expect(throws: (any Error).self) { _ = try await insertOp(db, scenario: s, targetKind: "table") }
        await #expect(throws: (any Error).self) { _ = try await insertOp(db, scenario: s, status: "pending") }
        // A cell op with a NULL field is rejected by the target-kind/field CHECK.
        await #expect(throws: (any Error).self) { _ = try await insertOp(db, scenario: s, targetKind: "cell", field: nil) }
        // A row op with a NULL field is fine.
        _ = try await insertOp(db, scenario: s, seq: 1, kind: "rowExclusion", targetKind: "row", field: nil)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenario_operations;", []).first?.int(0) == 1)
    }

    @Test("A per-scenario operation sequence is unique")
    func uniqueOpSequence() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let s = try await insertScenario(db, dataset: d)
        _ = try await insertOp(db, scenario: s, seq: 1)
        await #expect(throws: (any Error).self) { _ = try await insertOp(db, scenario: s, seq: 1) }
        _ = try await insertOp(db, scenario: s, seq: 2)
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenario_operations;", []).first?.int(0) == 2)
    }

    @Test("Review destination and decision are closed vocabularies with a non-blank reviewer")
    func reviewChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let s = try await insertScenario(db, dataset: d)
        let op = try await insertOp(db, scenario: s)
        func review(dest: String, decision: String, reviewer: String) async throws {
            try await db.exec("""
                INSERT INTO workbench_scenario_reviews (id, scenario_id, operation_id, destination, decision, reviewer, reason, resulting_reference, decided_at)
                VALUES (?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(s), .uuid(op), .text(dest), .text(decision), .text(reviewer), .null, .null, .real(1)])
        }
        await #expect(throws: (any Error).self) { try await review(dest: "database", decision: "accepted", reviewer: "r") }
        await #expect(throws: (any Error).self) { try await review(dest: "claimReview", decision: "maybe", reviewer: "r") }
        await #expect(throws: (any Error).self) { try await review(dest: "claimReview", decision: "accepted", reviewer: "  ") }
        try await review(dest: "userCorrection", decision: "rejected", reviewer: "r")
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenario_reviews;", []).first?.int(0) == 1)
    }

    @Test("Event action is a closed vocabulary with a unique per-scenario sequence")
    func eventChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let s = try await insertScenario(db, dataset: d)
        func event(seq: Int64, action: String) async throws {
            try await db.exec("""
                INSERT INTO workbench_scenario_events (id, scenario_id, sequence, scenario_revision, action, actor, detail, occurred_at)
                VALUES (?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(s), .integer(seq), .integer(1), .text(action), .text("u"), .null, .real(1)])
        }
        await #expect(throws: (any Error).self) { try await event(seq: 1, action: "teleported") }
        try await event(seq: 1, action: "created")
        await #expect(throws: (any Error).self) { try await event(seq: 1, action: "undone") }
        try await event(seq: 2, action: "undone")
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenario_events;", []).first?.int(0) == 2)
    }

    // MARK: - FKs + cascade

    @Test("A scenario's dataset must exist")
    func datasetFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { _ = try await insertScenario(db, dataset: UUID()) }
    }

    @Test("Deleting a scenario cascades its operations, reviews and events")
    func cascadeScenario() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let s = try await insertScenario(db, dataset: d)
        let op = try await insertOp(db, scenario: s)
        try await db.exec("""
            INSERT INTO workbench_scenario_reviews (id, scenario_id, operation_id, destination, decision, reviewer, reason, resulting_reference, decided_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(s), .uuid(op), .text("claimReview"), .text("accepted"), .text("r"), .null, .null, .real(1)])
        try await db.exec("""
            INSERT INTO workbench_scenario_events (id, scenario_id, sequence, scenario_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(s), .integer(1), .integer(1), .text("created"), .text("u"), .null, .real(1)])
        try await db.exec("DELETE FROM workbench_scenarios WHERE id = ?;", [.uuid(s)])
        for t in ["workbench_scenario_operations", "workbench_scenario_reviews", "workbench_scenario_events"] {
            #expect(try await db.query("SELECT COUNT(*) FROM \(t);", []).first?.int(0) == 0, "\(t) not cascaded")
        }
    }

    @Test("Deleting an operation cascades the reviews that referenced it")
    func cascadeOperationReview() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 94)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let d = UUID(); try await seedDataset(db, dataset: d)
        let s = try await insertScenario(db, dataset: d)
        let op = try await insertOp(db, scenario: s)
        try await db.exec("""
            INSERT INTO workbench_scenario_reviews (id, scenario_id, operation_id, destination, decision, reviewer, reason, resulting_reference, decided_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(s), .uuid(op), .text("claimReview"), .text("accepted"), .text("r"), .null, .null, .real(1)])
        try await db.exec("DELETE FROM workbench_scenario_operations WHERE id = ?;", [.uuid(op)])
        #expect(try await db.query("SELECT COUNT(*) FROM workbench_scenario_reviews;", []).first?.int(0) == 0)
    }
}
