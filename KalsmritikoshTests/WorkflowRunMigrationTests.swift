//
//  WorkflowRunMigrationTests.swift
//  KalsmritikoshTests
//
//  PJE-003 — schema v75 (persistent workflow run ledger). Locks:
//    1. All 7 new tables exist after a fresh v75 migration.
//    2. Expected indexes are present.
//    3. migration list is consistent through v75.
//    4. v74→v75 preserves all pre-v75 rows and adds no workflow run rows.
//    5. Status CHECK constraint on workflow_runs rejects invalid values.
//    6. Status CHECK constraint on workflow_step_runs rejects invalid values.
//    7. Kind CHECK constraint on workflow_decisions rejects invalid values.
//    8. actor_kind CHECK constraint on workflow_run_events rejects invalid values.
//    9. Deleting a workspace cascades to workflow_runs and all child tables.
//   10. Deleting a workflow_run cascades to all 6 child tables.
//   11. workflow_artifacts.work_product_run_id is SET NULL when the work_product_run is deleted.
//   12. workflow_artifacts.step_run_id is SET NULL when the step_run is deleted.
//   13. workflow_attention_items.step_run_id is SET NULL when the step_run is deleted.
//   14. UNIQUE(run_id, step_definition_id, attempt) constraint on workflow_step_runs.
//   15. UNIQUE(run_id, sequence) constraint on workflow_run_events.
//   16. PRAGMA integrity_check passes after migration.
//   17. v75 migration does not add or remove rows from the canonical claims table.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-003 — WorkflowRun schema (v75)")
struct WorkflowRunMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)

    // MARK: - Helpers

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

    private func insertMinimalStepRun(_ db: Database, id: String, runID: String, stepID: String = "step.a", attempt: Int = 1) async throws {
        try await db.exec("""
        INSERT INTO workflow_step_runs
            (id, run_id, step_definition_id, step_kind, attempt, sequence,
             status, input_json, state_json, state_sha256, entered_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.text(id), .text(runID), .text(stepID), .text("intake"),
              .integer(Int64(attempt)), .integer(1),
              .text("ready"), .text("{}"), .text("{}"), .text("abc"),
              .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
    }

    // MARK: - 1: All 7 tables present after fresh v75

    @Test("A fresh database reaches v75 with all 7 workflow tables")
    func freshV75HasAllSevenTables() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        #expect(try await db.currentUserVersion() == 75)

        let tables = ["workflow_runs", "workflow_step_runs", "workflow_decisions",
                      "workflow_artifacts", "workflow_checkpoints",
                      "workflow_attention_items", "workflow_run_events"]
        for table in tables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, table),
                    "\(table) missing after v75")
        }
    }

    // MARK: - 2: Expected indexes present

    @Test("All expected v75 indexes are present")
    func freshV75AllIndexesPresent() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)

        let expectedIndexes: [String] = [
            "idx_wfr_workspace", "idx_wfr_app", "idx_wfr_status", "idx_wfr_created",
            "idx_wfsr_run", "idx_wfsr_step",
            "idx_wfd_run", "idx_wfd_step",
            "idx_wfa_run", "idx_wfa_step",
            "idx_wfc_run", "idx_wfc_revision",
            "idx_wfai_run", "idx_wfai_status",
            "idx_wfre_run", "idx_wfre_sequence"
        ]
        let rows = try await db.query(
            "SELECT name FROM sqlite_master WHERE type='index';", [])
        let present = Set(rows.compactMap { $0.string(0) })
        for idx in expectedIndexes {
            #expect(present.contains(idx), "\(idx) missing")
        }
    }

    // MARK: - 3: Migration list consistency

    @Test("migrationListIsConsistent and v75 ledger included")
    func migrationListIsConsistent() async throws {
        #expect(SchemaMigrations.migrationListIsConsistent)
        // Only MigrationMatrixTests.freshDatabaseReachesLatest owns the exact
        // latest-version sentinel; here assert the v75 ledger is included.
        #expect(SchemaMigrations.latestVersion >= 75)
    }

    // MARK: - 4: v74→v75 preservation

    @Test("v74→v75 migration preserves all pre-v75 rows and adds no workflow run rows")
    func v74ToV75PreservesExistingRows() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 74)
        #expect(try await db.currentUserVersion() == 74)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 74)

        try await SchemaMigrations.migrate(db, through: 75)

        #expect(try await db.currentUserVersion() == 75)
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "Preserved rows lost after v74→v75: \(failures)")

        let runCount = try await db.query("SELECT COUNT(*) FROM workflow_runs;", [])
        #expect(Int(runCount.first?.int(0) ?? -1) == 0,
                "Expected 0 workflow_runs after a clean v75 migration (no backfill)")
    }

    // MARK: - 5: workflow_runs status CHECK

    @Test("workflow_runs status CHECK rejects invalid values")
    func workflowRunStatusCheckRejectsInvalidValue() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)

        do {
            try await db.exec("""
            INSERT INTO workflow_runs
                (id, workspace_id, application_definition_id, application_definition_version,
                 workflow_definition_id, workflow_definition_version, status,
                 contract_snapshot_json, contract_snapshot_sha256, snapshot_schema_version,
                 revision, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text(wsID),
                  .text("app"), .integer(1), .text("wf"), .integer(1),
                  .text("INVALID_STATUS"),
                  .text("{}"), .text("hash"), .integer(1), .integer(1),
                  .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
            Issue.record("Expected a constraint error for invalid status")
        } catch {
            // Expected
        }
    }

    // MARK: - 6: workflow_step_runs status CHECK

    @Test("workflow_step_runs status CHECK rejects invalid values")
    func workflowStepRunStatusCheckRejectsInvalidValue() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)

        do {
            try await insertMinimalStepRun(db, id: UUID().uuidString, runID: runID)
            // Change status to invalid
            try await db.exec(
                "UPDATE workflow_step_runs SET status = 'BADSTATUS' WHERE run_id = ?;",
                [.text(runID)])
            // SQLite doesn't re-evaluate CHECK on UPDATE by default in some versions...
            // Instead test via INSERT:
        } catch { /* ok */ }

        do {
            try await db.exec("""
            INSERT INTO workflow_step_runs
                (id, run_id, step_definition_id, step_kind, attempt, sequence,
                 status, input_json, state_json, state_sha256, entered_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text(runID), .text("step.b"), .text("intake"),
                  .integer(2), .integer(2), .text("BADSTATUS"),
                  .text("{}"), .text("{}"), .text("abc"),
                  .real(t0.timeIntervalSince1970), .real(t0.timeIntervalSince1970)])
            Issue.record("Expected constraint error for invalid status")
        } catch { /* Expected */ }
    }

    // MARK: - 7: workflow_decisions kind CHECK

    @Test("workflow_decisions kind CHECK rejects invalid values")
    func workflowDecisionKindCheckRejectsInvalidValue() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        let stepRunID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)
        try await insertMinimalStepRun(db, id: stepRunID, runID: runID)

        do {
            try await db.exec("""
            INSERT INTO workflow_decisions
                (id, run_id, step_run_id, decision_key, kind, selected_option,
                 actor_kind, metadata_json, decided_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text(runID), .text(stepRunID),
                  .text("key"), .text("BADKIND"), .text("yes"),
                  .text("system"), .text("{}"),
                  .real(t0.timeIntervalSince1970)])
            Issue.record("Expected constraint error for invalid kind")
        } catch { /* Expected */ }
    }

    // MARK: - 8: workflow_run_events actor_kind CHECK

    @Test("workflow_run_events actor_kind CHECK rejects invalid values")
    func workflowRunEventActorKindCheckRejectsInvalidValue() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)

        do {
            try await db.exec("""
            INSERT INTO workflow_run_events
                (id, run_id, sequence, run_revision, type, actor_kind, payload_json, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text(runID),
                  .integer(1), .integer(1), .text("runCreated"),
                  .text("BADACTOR"), .text("{}"),
                  .real(t0.timeIntervalSince1970)])
            Issue.record("Expected constraint error for invalid actor_kind")
        } catch { /* Expected */ }
    }

    // MARK: - 9: Workspace cascade

    @Test("Deleting a workspace cascades to workflow_runs and all child tables")
    func deleteWorkspaceCascadesToAllRunTables() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        let stepRunID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)
        try await insertMinimalStepRun(db, id: stepRunID, runID: runID)

        try await db.exec("""
        INSERT INTO workflow_run_events
            (id, run_id, sequence, run_revision, type, actor_kind, payload_json, occurred_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID), .integer(1), .integer(1),
              .text("runCreated"), .text("system"), .text("{}"),
              .real(t0.timeIntervalSince1970)])

        try await db.exec("DELETE FROM workspaces WHERE id = ?;", [.text(wsID)])

        let runCount = try await db.query("SELECT COUNT(*) FROM workflow_runs WHERE id = ?;", [.text(runID)])
        #expect(Int(runCount.first?.int(0) ?? -1) == 0, "workflow_run must be deleted via workspace cascade")

        let stepCount = try await db.query("SELECT COUNT(*) FROM workflow_step_runs WHERE run_id = ?;", [.text(runID)])
        #expect(Int(stepCount.first?.int(0) ?? -1) == 0, "workflow_step_runs must cascade")

        let evtCount = try await db.query("SELECT COUNT(*) FROM workflow_run_events WHERE run_id = ?;", [.text(runID)])
        #expect(Int(evtCount.first?.int(0) ?? -1) == 0, "workflow_run_events must cascade")
    }

    // MARK: - 10: Run cascade to all 6 children

    @Test("Deleting a workflow_run cascades to all 6 child tables")
    func deleteRunCascadesToAllChildren() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        let stepRunID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)
        try await insertMinimalStepRun(db, id: stepRunID, runID: runID)

        try await db.exec("""
        INSERT INTO workflow_decisions
            (id, run_id, step_run_id, decision_key, kind, selected_option,
             actor_kind, metadata_json, decided_at)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID), .text(stepRunID),
              .text("k"), .text("branchSelection"), .text("yes"),
              .text("system"), .text("{}"), .real(t0.timeIntervalSince1970)])

        try await db.exec("""
        INSERT INTO workflow_artifacts
            (id, run_id, artifact_definition_id, kind, label, metadata_json, created_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID),
              .text("art.1"), .text("attachment"), .text("File"),
              .text("{}"), .real(t0.timeIntervalSince1970)])

        try await db.exec("""
        INSERT INTO workflow_checkpoints
            (id, run_id, run_revision, reason, snapshot_json, snapshot_sha256, created_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID),
              .integer(1), .text("explicitSave"), .text("{}"), .text("abc"),
              .real(t0.timeIntervalSince1970)])

        try await db.exec("""
        INSERT INTO workflow_attention_items
            (id, run_id, source_kind, severity, status, title, created_at)
        VALUES (?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID),
              .text("system"), .text("advisory"), .text("open"), .text("Check me"),
              .real(t0.timeIntervalSince1970)])

        try await db.exec("""
        INSERT INTO workflow_run_events
            (id, run_id, sequence, run_revision, type, actor_kind, payload_json, occurred_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID), .integer(1), .integer(1),
              .text("runCreated"), .text("system"), .text("{}"), .real(t0.timeIntervalSince1970)])

        try await db.exec("DELETE FROM workflow_runs WHERE id = ?;", [.text(runID)])

        let childTables = ["workflow_step_runs", "workflow_decisions", "workflow_artifacts",
                           "workflow_checkpoints", "workflow_attention_items", "workflow_run_events"]
        for table in childTables {
            let count = try await db.query("SELECT COUNT(*) FROM \(table) WHERE run_id = ?;", [.text(runID)])
            #expect(Int(count.first?.int(0) ?? -1) == 0, "\(table) must be empty after run delete")
        }
    }

    // MARK: - 11: work_product_run SET NULL

    @Test("workflow_artifacts.work_product_run_id is SET NULL when work_product_run is deleted")
    func workflowArtifactWorkProductRunSetNullOnDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        let artifactID = UUID().uuidString
        let wprID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)

        // Insert a work_product_run (workspace_id + minimal required fields)
        try await db.exec("""
        INSERT INTO work_product_runs
            (id, workspace_id, template, title, subject_label,
             schema_version, app_version, composed_at, finding_count)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.text(wprID), .text(wsID), .text("chronology"), .text("WP"),
              .text("Subject"), .integer(1), .text("1.0"),
              .real(t0.timeIntervalSince1970), .integer(0)])

        try await db.exec("""
        INSERT INTO workflow_artifacts
            (id, run_id, artifact_definition_id, kind, label,
             work_product_run_id, metadata_json, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(artifactID), .text(runID),
              .text("art.wp"), .text("workProductRun"), .text("Report"),
              .text(wprID), .text("{}"), .real(t0.timeIntervalSince1970)])

        let before = try await db.query(
            "SELECT work_product_run_id FROM workflow_artifacts WHERE id = ?;",
            [.text(artifactID)])
        #expect(before.first?.string(0) == wprID, "work_product_run_id must be set before delete")

        try await db.exec("DELETE FROM work_product_runs WHERE id = ?;", [.text(wprID)])

        let after = try await db.query(
            "SELECT work_product_run_id FROM workflow_artifacts WHERE id = ?;",
            [.text(artifactID)])
        #expect(after.first?.isNull(0) == true,
                "work_product_run_id must be NULL after work_product_run delete (ON DELETE SET NULL)")

        // The artifact itself must survive
        let artCount = try await db.query(
            "SELECT COUNT(*) FROM workflow_artifacts WHERE id = ?;", [.text(artifactID)])
        #expect(Int(artCount.first?.int(0) ?? 0) == 1, "artifact must still exist")
    }

    // MARK: - 12: step_run SET NULL on artifact

    @Test("workflow_artifacts.step_run_id is SET NULL when step_run is deleted")
    func workflowArtifactStepRunSetNullOnDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        let stepRunID = UUID().uuidString
        let artifactID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)
        try await insertMinimalStepRun(db, id: stepRunID, runID: runID)

        try await db.exec("""
        INSERT INTO workflow_artifacts
            (id, run_id, step_run_id, artifact_definition_id, kind, label, metadata_json, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(artifactID), .text(runID), .text(stepRunID),
              .text("art.1"), .text("attachment"), .text("File"),
              .text("{}"), .real(t0.timeIntervalSince1970)])

        try await db.exec(
            "DELETE FROM workflow_step_runs WHERE id = ?;", [.text(stepRunID)])

        let after = try await db.query(
            "SELECT step_run_id FROM workflow_artifacts WHERE id = ?;", [.text(artifactID)])
        #expect(after.first?.isNull(0) == true,
                "artifact.step_run_id must be NULL after step_run delete (ON DELETE SET NULL)")
    }

    // MARK: - 13: attention_item.step_run_id SET NULL

    @Test("workflow_attention_items.step_run_id is SET NULL when step_run is deleted")
    func workflowAttentionItemStepRunSetNullOnDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        let stepRunID = UUID().uuidString
        let itemID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)
        try await insertMinimalStepRun(db, id: stepRunID, runID: runID)

        try await db.exec("""
        INSERT INTO workflow_attention_items
            (id, run_id, step_run_id, source_kind, severity, status, title, created_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(itemID), .text(runID), .text(stepRunID),
              .text("requirement"), .text("blocking"), .text("open"), .text("Issue"),
              .real(t0.timeIntervalSince1970)])

        try await db.exec(
            "DELETE FROM workflow_step_runs WHERE id = ?;", [.text(stepRunID)])

        let after = try await db.query(
            "SELECT step_run_id FROM workflow_attention_items WHERE id = ?;", [.text(itemID)])
        #expect(after.first?.isNull(0) == true,
                "attention_item.step_run_id must be NULL after step_run delete (ON DELETE SET NULL)")
    }

    // MARK: - 14: UNIQUE(run_id, step_definition_id, attempt)

    @Test("UNIQUE(run_id, step_definition_id, attempt) constraint is enforced")
    func uniqueStepAttemptConstraintEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)
        try await insertMinimalStepRun(db, id: UUID().uuidString, runID: runID, stepID: "step.x", attempt: 1)

        do {
            try await insertMinimalStepRun(db, id: UUID().uuidString, runID: runID, stepID: "step.x", attempt: 1)
            Issue.record("Expected UNIQUE constraint violation for duplicate (run_id, step_definition_id, attempt)")
        } catch { /* Expected */ }
    }

    // MARK: - 15: UNIQUE(run_id, sequence) in events

    @Test("UNIQUE(run_id, sequence) constraint on workflow_run_events is enforced")
    func uniqueEventSequenceConstraintEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        let wsID = UUID().uuidString
        let runID = UUID().uuidString
        try await insertWorkspace(db, id: wsID)
        try await insertMinimalRun(db, id: runID, workspaceID: wsID)

        try await db.exec("""
        INSERT INTO workflow_run_events
            (id, run_id, sequence, run_revision, type, actor_kind, payload_json, occurred_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.text(UUID().uuidString), .text(runID), .integer(1), .integer(1),
              .text("runCreated"), .text("system"), .text("{}"), .real(t0.timeIntervalSince1970)])

        do {
            try await db.exec("""
            INSERT INTO workflow_run_events
                (id, run_id, sequence, run_revision, type, actor_kind, payload_json, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.text(UUID().uuidString), .text(runID), .integer(1), .integer(2),
                  .text("runStateChanged"), .text("system"), .text("{}"), .real(t0.timeIntervalSince1970)])
            Issue.record("Expected UNIQUE constraint violation for duplicate sequence")
        } catch { /* Expected */ }
    }

    // MARK: - 16: Integrity check

    @Test("PRAGMA integrity_check passes after v75 migration")
    func integrityCheckPassesAfterMigration() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 75)
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - 17: Canonical isolation

    @Test("v75 migration does not add or remove rows from the canonical claims table")
    func v75DoesNotTouchCanonicalClaims() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 74)
        _ = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 74)
        let before = try await db.query("SELECT COUNT(*) FROM claims;", [])
        let beforeCount = Int(before.first?.int(0) ?? 0)
        #expect(beforeCount > 0, "seedPreservationRows must seed at least one claim at v74")

        try await SchemaMigrations.migrate(db, through: 75)

        let after = try await db.query("SELECT COUNT(*) FROM claims;", [])
        #expect(Int(after.first?.int(0) ?? 0) == beforeCount,
                "v75 must not add or remove canonical claims during migration")
    }

    // MARK: - PJE-006B.1: v76 step-state hash semantics column

    @Test("A fresh v76 database has state_hash_semantics defaulting to legacyCanonicalizedJSON")
    func freshV76HasSemanticsColumnWithDefault() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 76)
        #expect(try await db.currentUserVersion() == 76)
        let cols = try await MigrationFixtureBuilder.columns(db, "workflow_step_runs")
        #expect(cols.contains("state_hash_semantics"))

        // An insert that omits the column gets the legacy default.
        try await insertWorkspace(db, id: "ws-76")
        try await insertMinimalRun(db, id: "run-76", workspaceID: "ws-76")
        try await insertMinimalStepRun(db, id: "sr-76", runID: "run-76")
        let rows = try await db.query(
            "SELECT state_hash_semantics FROM workflow_step_runs WHERE id = 'sr-76';", [])
        #expect(rows.first?.string(0) == "legacyCanonicalizedJSON")
    }

    @Test("v75→v76 preserves existing step runs and labels them legacyCanonicalizedJSON")
    func v75ToV76PreservesStepRunsAsLegacy() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 75)
        try await insertWorkspace(db, id: "ws-up")
        try await insertMinimalRun(db, id: "run-up", workspaceID: "ws-up")
        try await insertMinimalStepRun(db, id: "sr-up", runID: "run-up")

        try await SchemaMigrations.migrate(db, through: 76)
        #expect(try await db.currentUserVersion() == 76)

        let rows = try await db.query("""
            SELECT state_json, state_sha256, state_hash_semantics
              FROM workflow_step_runs WHERE id = 'sr-up';
            """, [])
        #expect(rows.count == 1)
        #expect(rows.first?.string(0) == "{}")
        #expect(rows.first?.string(1) == "abc")
        #expect(rows.first?.string(2) == "legacyCanonicalizedJSON",
                "Pre-existing rows must be labelled legacy — never silently reclassified")
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }
}
