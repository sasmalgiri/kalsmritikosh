//
//  WorkflowAutomationExecutionMigrationTests.swift
//  KalsmritikoshTests
//
//  PJE-010 — v78 automation execution ledger migration.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PJE-010 — v78 automation execution ledger migration")
struct WorkflowAutomationExecutionMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_700_000)

    private func insertExecution(
        _ db: Database, id: UUID = UUID(), idempotencyKey: String, workspaceID: UUID = UUID()
    ) async throws {
        try await db.exec("""
            INSERT INTO workflow_automation_executions
                (id, workspace_id, application_definition_id, automation_definition_id,
                 automation_definition_version, trigger_kind, trigger_event_key,
                 action_kind, idempotency_key, request_json, request_sha256, status, started_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .uuid(id), .uuid(workspaceID), .text("com.app"), .text("auto.1"),
                .integer(1), .text("workflowEvent"), .text("evt-1"),
                .text("createSuggestion"), .text(idempotencyKey), .text("{}"),
                .text(String(repeating: "a", count: 64)), .text("started"), .real(0)
            ])
    }

    @Test("A fresh database migrated through v78 has the automation execution ledger")
    func freshV78HasLedger() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_automation_executions"))
    }

    @Test("The v78 UNIQUE idempotency index and audit indexes exist")
    func v78IndexesPresent() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        let rows = try await db.query(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='workflow_automation_executions';", [])
        let names = Set(rows.compactMap { $0.string(0) })
        #expect(names.contains("idx_wae_idempotency"))
        #expect(names.contains("idx_wae_run"))
        #expect(names.contains("idx_wae_automation"))
    }

    @Test("The fresh v78 ledger is empty")
    func freshV78Empty() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        let n = Int(try await db.query("SELECT COUNT(*) FROM workflow_automation_executions;", []).first?.int(0) ?? -1)
        #expect(n == 0)
    }

    @Test("v77→v78 preserves existing rows and adds only the ledger")
    func v77ToV78Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        let wsID = UUID()
        try await db.exec("""
            INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);
            """, [.uuid(wsID), .text("WS"), .text("general"), .real(0), .real(0)])
        try await SchemaMigrations.migrate(db, through: 78)
        let n = Int(try await db.query("SELECT COUNT(*) FROM workspaces WHERE id = ?;", [.uuid(wsID)]).first?.int(0) ?? -1)
        #expect(n == 1)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_automation_executions"))
    }

    @Test("Re-running migrate over a v78 database is a safe no-op")
    func v78Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 78)
        try await SchemaMigrations.migrate(db, through: 78)
        #expect(try await db.currentUserVersion() == 78)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Self-heal does not FALSELY stamp v78 while the ledger is missing — the sentinel forces a re-apply")
    func selfHealRecognizesV78Marker() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 78)
        try await db.exec("DROP TABLE workflow_automation_executions;")
        try await db.setUserVersion(77)
        // Because the self-heal sentinel includes the v78 marker table, the schema
        // is NOT reported complete; migrate() re-applies v78 and the ledger returns.
        // (If the sentinel lacked the v78 marker it would false-stamp 78 and leave
        // the table missing — this test would then fail.)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 78)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_automation_executions"))
    }

    @Test("The UNIQUE idempotency key rejects a duplicate execution")
    func idempotencyUniqueEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        try await insertExecution(db, idempotencyKey: "dup-key")
        await #expect(throws: (any Error).self) {
            try await self.insertExecution(db, idempotencyKey: "dup-key")
        }
    }

    @Test("The status CHECK rejects an unknown status")
    func statusCheckEnforced() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 78)
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO workflow_automation_executions
                    (id, workspace_id, application_definition_id, automation_definition_id,
                     automation_definition_version, trigger_kind, trigger_event_key,
                     action_kind, idempotency_key, request_json, request_sha256, status, started_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .uuid(UUID()), .uuid(UUID()), .text("a"), .text("b"), .integer(1),
                    .text("manual"), .text("e"), .text("createSuggestion"), .text("k"),
                    .text("{}"), .text("h"), .text("bogusStatus"), .real(0)
                ])
        }
    }

    @Test("v78 does not add or remove rows from the canonical claims table")
    func v78DoesNotTouchClaims() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        let before = Int(try await db.query("SELECT COUNT(*) FROM claims;", []).first?.int(0) ?? -1)
        try await SchemaMigrations.migrate(db, through: 78)
        let after = Int(try await db.query("SELECT COUNT(*) FROM claims;", []).first?.int(0) ?? -2)
        #expect(after == before)
    }

    @Test("An injected failure inside the v78 SAVEPOINT rolls back the ledger and version stamp")
    func injectedFailureRollsBackV78() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 77)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 78,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 78)))
        }
        #expect(try await db.currentUserVersion() == 77)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_automation_executions") == false)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }
}
