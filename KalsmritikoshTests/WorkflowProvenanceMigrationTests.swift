//
//  WorkflowProvenanceMigrationTests.swift
//  KalsmritikoshTests
//
//  PJE-007 Part L — the v77 provenance-bridge migration: three new tables,
//  three provenance_semantics columns defaulting 'legacyUntracked', new
//  indexes, preservation of every existing workflow row, repeatability,
//  SAVEPOINT rollback under injected failure, and self-heal refusing to stamp
//  v77 without the newest physical marker.
//
//  Historical setup uses migrate(db, through: 76) — pinned, never latest.
//  Only MigrationMatrixTests asserts the exact global latest version.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-007 — v77 provenance bridge migration")
struct WorkflowProvenanceMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_900_000)

    // MARK: - Minimal v75-shape seeding helpers

    private func insertWorkspace(_ db: Database, id: String) async throws {
        try await db.exec("""
        INSERT INTO workspaces (id, title, template_type, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?);
        """, [.text(id), .text("WS"), .text("general"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func insertMinimalRun(_ db: Database, id: String, workspaceID: String) async throws {
        try await db.exec("""
        INSERT INTO workflow_runs
            (id, workspace_id, application_definition_id, application_definition_version,
             workflow_definition_id, workflow_definition_version, status,
             contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
             revision, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(id), .text(workspaceID),
              .text("com.test.app"), .integer(1),
              .text("com.test.wf"), .integer(1),
              .text("draft"),
              .text("{}"), .text("abc"), .integer(1),
              .integer(1),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func insertMinimalStepRun(_ db: Database, id: String, runID: String) async throws {
        try await db.exec("""
        INSERT INTO workflow_step_runs
            (id, run_id, step_definition_id, step_kind, attempt, sequence,
             status, input_json, state_json, state_sha256, entered_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(id), .text(runID), .text("step.a"), .text("intake"),
              .integer(1), .integer(1),
              .text("ready"), .text("{}"), .text("{}"), .text("abc"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    private func insertMinimalArtifact(_ db: Database, id: String, runID: String) async throws {
        try await db.exec("""
        INSERT INTO workflow_artifacts
            (id, run_id, artifact_definition_id, kind, label, created_at)
        VALUES (?,?,?,?,?,?);
        """, [.text(id), .text(runID), .text("artifact.x"), .text("attachment"),
              .text("A"), .real(t0.timeIntervalSince1970)])
    }

    private func insertMinimalDecision(_ db: Database, id: String, runID: String, stepRunID: String) async throws {
        try await db.exec("""
        INSERT INTO workflow_decisions
            (id, run_id, step_run_id, decision_key, kind, selected_option,
             actor_kind, decided_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(id), .text(runID), .text(stepRunID), .text("k"),
              .text("humanDecision"), .text("yes"), .text("human"),
              .real(t0.timeIntervalSince1970)])
    }

    /// A fully seeded v76 database: workspace + run + step + artifact + decision.
    private func seededV76(_ db: Database) async throws {
        try await SchemaMigrations.migrate(db, through: 76)
        try await insertWorkspace(db, id: "ws-1")
        try await insertMinimalRun(db, id: "run-1", workspaceID: "ws-1")
        try await insertMinimalStepRun(db, id: "sr-1", runID: "run-1")
        try await insertMinimalArtifact(db, id: "art-1", runID: "run-1")
        try await insertMinimalDecision(db, id: "dec-1", runID: "run-1", stepRunID: "sr-1")
    }

    // MARK: - 1–2: Fresh v77 has all three tables

    @Test("A fresh database migrated through v77 has all three provenance tables")
    func freshV77HasAllProvenanceTables() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        #expect(try await db.currentUserVersion() == 77)
        for table in ["workflow_provenance_snapshots",
                      "workflow_provenance_references",
                      "workflow_attachment_bindings"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, table),
                    "\(table) missing after v77")
        }
    }

    // MARK: - 3: All three semantics columns exist with the legacy default

    @Test("All three provenance_semantics columns exist and default to legacyUntracked")
    func semanticsColumnsExistWithLegacyDefault() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        for table in ["workflow_step_runs", "workflow_artifacts", "workflow_decisions"] {
            let cols = try await MigrationFixtureBuilder.columns(db, table)
            #expect(cols.contains("provenance_semantics"), "\(table) missing provenance_semantics")
        }
        // An insert omitting the column receives the legacy default.
        try await insertWorkspace(db, id: "ws-d")
        try await insertMinimalRun(db, id: "run-d", workspaceID: "ws-d")
        try await insertMinimalStepRun(db, id: "sr-d", runID: "run-d")
        let rows = try await db.query(
            "SELECT provenance_semantics FROM workflow_step_runs WHERE id = 'sr-d';", [])
        #expect(rows.first?.string(0) == "legacyUntracked")
    }

    // MARK: - 4: New indexes exist

    @Test("The v77 indexes exist, including the partial UNIQUE owner indexes")
    func v77IndexesPresent() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        let rows = try await db.query(
            "SELECT name FROM sqlite_master WHERE type = 'index';", [])
        let names = Set(rows.compactMap { $0.string(0) })
        for index in ["idx_wfps_step_revision", "idx_wfps_artifact", "idx_wfps_decision",
                      "idx_wfps_run", "idx_wfps_step", "idx_wfps_artifact2",
                      "idx_wfps_decision2", "idx_wfps_revision",
                      "idx_wfpr_snapshot",
                      "idx_wfab_source_version", "idx_wfab_logical_source"] {
            #expect(names.contains(index), "\(index) missing after v77")
        }
    }

    // MARK: - 5: Fresh tables are empty

    @Test("The fresh v77 provenance tables are empty")
    func freshV77TablesEmpty() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        for table in ["workflow_provenance_snapshots",
                      "workflow_provenance_references",
                      "workflow_attachment_bindings"] {
            let rows = try await db.query("SELECT COUNT(*) FROM \(table);", [])
            #expect(Int(rows.first?.int(0) ?? -1) == 0, "\(table) not empty after fresh v77")
        }
    }

    // MARK: - 6–7 & 11: v76→v77 preserves rows and labels them legacyUntracked

    @Test("v76→v77 preserves every workflow row and labels step/artifact/decision rows legacyUntracked")
    func v76ToV77PreservesRowsAsLegacy() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await seededV76(db)

        try await SchemaMigrations.migrate(db, through: 77)
        #expect(try await db.currentUserVersion() == 77)

        let checks: [(String, String)] = [
            ("workflow_runs", "run-1"),
            ("workflow_step_runs", "sr-1"),
            ("workflow_artifacts", "art-1"),
            ("workflow_decisions", "dec-1")
        ]
        for (table, id) in checks {
            let rows = try await db.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.text(id)])
            #expect(Int(rows.first?.int(0) ?? 0) == 1, "\(table) row \(id) lost in v77")
        }
        for table in ["workflow_step_runs", "workflow_artifacts", "workflow_decisions"] {
            let rows = try await db.query("SELECT provenance_semantics FROM \(table);", [])
            #expect(rows.allSatisfy { $0.string(0) == "legacyUntracked" },
                    "Pre-existing \(table) rows must be labelled legacyUntracked — never guessed")
        }
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - 8: Repeatable

    @Test("Re-running migrate over an already-migrated v77 database is a safe no-op")
    func v77MigrationIsRepeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        try await SchemaMigrations.migrate(db, through: 77)   // no-op — no error, no change
        #expect(try await db.currentUserVersion() == 77)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - 9: Injected failure rolls back ALL v77 changes

    @Test("An injected failure inside the v77 SAVEPOINT rolls back tables, columns, and the version stamp")
    func injectedFailureRollsBackV77() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await seededV76(db)

        // migrate() wraps any injected fault as DatabaseError.migrationFailed
        // (SchemaMigrations.applyOne catch), so assert the general error — the
        // same convention MigrationFaultInjectionTests uses.
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 77,
                fault: MigrationFaultHarness.hook(
                    throwingAt: .afterSQLBeforeVersionStamp(version: 77)))
        }
        #expect(try await db.currentUserVersion() == 76, "version stamp must not survive the fault")
        for table in ["workflow_provenance_snapshots",
                      "workflow_provenance_references",
                      "workflow_attachment_bindings"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, table) == false,
                    "\(table) survived the rolled-back v77")
        }
        let cols = try await MigrationFixtureBuilder.columns(db, "workflow_step_runs")
        #expect(!cols.contains("provenance_semantics"), "ALTER survived the rolled-back v77")
        // Seeded rows untouched.
        let rows = try await db.query("SELECT COUNT(*) FROM workflow_step_runs WHERE id = 'sr-1';", [])
        #expect(Int(rows.first?.int(0) ?? 0) == 1)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - 10: Self-heal requires the newest v77 marker

    @Test("Self-heal does not stamp v77 when a v77 physical marker is missing")
    func selfHealRequiresV77Marker() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        // Remove one v77 marker and rewind the counter: the schema is now a
        // PARTIAL v77 (ALTERed columns present, one table missing).
        try await db.exec("""
            DROP INDEX IF EXISTS idx_wfab_source_version;
            DROP INDEX IF EXISTS idx_wfab_logical_source;
            DROP TABLE workflow_attachment_bindings;
            """)
        try await db.setUserVersion(76)

        // isSchemaFullyApplied must return false → no self-heal stamp → the
        // pending v77 migration fails closed (duplicate provenance columns).
        await #expect(throws: (any Error).self) { try await SchemaMigrations.migrate(db) }
        #expect(try await db.currentUserVersion() == 76,
                "self-heal falsely stamped a partial v77 schema")
    }

    // MARK: - Schema constraints introduced by v77

    @Test("The snapshot owner-exclusivity CHECK rejects a row claiming two owners")
    func ownerExclusivityCheckEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await seededV76(db)
        try await SchemaMigrations.migrate(db, through: 77)

        await #expect(throws: (any Error).self) {
            try await db.exec("""
            INSERT INTO workflow_provenance_snapshots
                (id, workflow_run_id, owner_kind, step_run_id, artifact_id, decision_id,
                 workflow_run_revision, producer_id, producer_version,
                 source_state_sha256, snapshot_json, snapshot_sha256, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text("run-1"), .text("stepState"),
                  .text("sr-1"), .text("art-1"), .null,
                  .integer(1), .text("p"), .text("1"),
                  .text("abc"), .text("{}"), .text("h"),
                  .real(self.t0.timeIntervalSince1970)])
        }
    }

    @Test("UNIQUE(snapshot_id, ordinal) rejects a duplicate reference ordinal")
    func referenceOrdinalUniquenessEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await seededV76(db)
        try await SchemaMigrations.migrate(db, through: 77)

        let snapshotID = UUID().uuidString
        try await db.exec("""
        INSERT INTO workflow_provenance_snapshots
            (id, workflow_run_id, owner_kind, step_run_id, artifact_id, decision_id,
             workflow_run_revision, producer_id, producer_version,
             source_state_sha256, snapshot_json, snapshot_sha256, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(snapshotID), .text("run-1"), .text("stepState"),
              .text("sr-1"), .null, .null,
              .integer(1), .text("p"), .text("1"),
              .text("abc"), .text("{}"), .text("h"),
              .real(t0.timeIntervalSince1970)])
        let insertRef = """
        INSERT INTO workflow_provenance_references
            (id, snapshot_id, ordinal, reference_kind, canonical_object_id,
             role, disposition, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """
        try await db.exec(insertRef, [
            .text(UUID().uuidString), .text(snapshotID), .integer(0),
            .text("claim"), .text(UUID().uuidString),
            .text("selected"), .text("active"), .real(t0.timeIntervalSince1970)])
        await #expect(throws: (any Error).self) {
            try await db.exec(insertRef, [
                .text(UUID().uuidString), .text(snapshotID), .integer(0),
                .text("claim"), .text(UUID().uuidString),
                .text("selected"), .text("active"), .real(self.t0.timeIntervalSince1970)])
        }
    }

    @Test("Deleting a workflow run cascades to its provenance snapshots and references")
    func deleteRunCascadesToProvenance() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await seededV76(db)
        try await SchemaMigrations.migrate(db, through: 77)

        let snapshotID = UUID().uuidString
        try await db.exec("""
        INSERT INTO workflow_provenance_snapshots
            (id, workflow_run_id, owner_kind, step_run_id, artifact_id, decision_id,
             workflow_run_revision, producer_id, producer_version,
             source_state_sha256, snapshot_json, snapshot_sha256, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(snapshotID), .text("run-1"), .text("stepState"),
              .text("sr-1"), .null, .null,
              .integer(1), .text("p"), .text("1"),
              .text("abc"), .text("{}"), .text("h"),
              .real(t0.timeIntervalSince1970)])
        try await db.exec("""
        INSERT INTO workflow_provenance_references
            (id, snapshot_id, ordinal, reference_kind, canonical_object_id,
             role, disposition, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(snapshotID), .integer(0),
              .text("claim"), .text(UUID().uuidString),
              .text("selected"), .text("active"), .real(t0.timeIntervalSince1970)])

        try await db.exec("DELETE FROM workflow_runs WHERE id = 'run-1';", [])
        let snapCount = try await db.query("SELECT COUNT(*) FROM workflow_provenance_snapshots;", [])
        let refCount = try await db.query("SELECT COUNT(*) FROM workflow_provenance_references;", [])
        #expect(Int(snapCount.first?.int(0) ?? -1) == 0)
        #expect(Int(refCount.first?.int(0) ?? -1) == 0)
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - Canonical isolation

    @Test("v77 does not add or remove rows from the canonical claims table")
    func v77DoesNotTouchCanonicalClaims() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 76)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 76)
        let before = try await db.query("SELECT COUNT(*) FROM claims;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)
        #expect(beforeCount > 0, "seedPreservationRows must seed at least one claim at v76")

        try await SchemaMigrations.migrate(db, through: 77)

        let after = try await db.query("SELECT COUNT(*) FROM claims;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount,
                "v77 must not add or remove canonical claims during migration")
    }
}
