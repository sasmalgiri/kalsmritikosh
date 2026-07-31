//
//  MethodRunMigrationTests.swift
//  KalsmritikoshTests
//
//  PM-002 — schema v79 migration acceptance for the Stage 4 MethodRun aggregate:
//  fresh reach, v78→v79 preservation, indexes, repeatability, self-heal sentinel,
//  injected-fault rollback, CHECK/FK constraints and workspace CASCADE.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("PM-002 — v79 method persistence migration")
struct MethodRunMigrationTests {

    private let t0 = Date(timeIntervalSince1970: 1_753_900_000)

    private let methodTables = [
        "method_runs", "method_nodes", "method_edges", "method_evidence_links",
        "method_assumptions", "method_findings", "method_reviews", "method_validation_results"
    ]

    private func seedWorkspace(_ db: Database, _ id: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(id), .text("WS"), .text("general"), .real(0), .real(0)])
    }

    private func insertRun(_ db: Database, id: UUID, ws: UUID, status: String = "draft", revision: Int = 1) async throws {
        try await db.exec("""
            INSERT INTO method_runs (id, workspace_id, method_definition_id, method_definition_version,
                                     status, revision, created_by, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(ws), .text("com.k.method.test"), .integer(1),
                  .text(status), .integer(Int64(revision)), .text("analyst"), .real(0), .real(0)])
    }

    private func insertNode(_ db: Database, id: UUID, run: UUID, ordinal: Int = 0) async throws {
        try await db.exec("""
            INSERT INTO method_nodes (id, method_run_id, node_definition_key, node_kind, label,
                                      working_state, ordinal, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(run), .text("k"), .text("cause"), .text("L"),
                  .text("proposal"), .integer(Int64(ordinal)), .real(0), .real(0)])
    }

    // MARK: - Reach + structure

    @Test("A fresh database migrated through v79 has all eight method tables")
    func freshV79HasEightTables() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        #expect(try await db.currentUserVersion() == 79)
        for t in methodTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "missing \(t)")
        }
    }

    @Test("The v79 indexes — including the partial-unique evidence-link indexes — exist")
    func v79IndexesPresent() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        let rows = try await db.query(
            "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name LIKE 'method_%';", [])
        let names = Set(rows.compactMap { $0.string(0) })
        for idx in ["idx_method_runs_workspace", "idx_method_nodes_run", "idx_method_edges_run",
                    "idx_method_evlink_node", "idx_method_evlink_run", "idx_method_findings_run",
                    "idx_method_reviews_run", "idx_method_validation_run"] {
            #expect(names.contains(idx), "missing index \(idx)")
        }
    }

    @Test("There is no professional-method-definition table — definitions stay code-registry-backed")
    func noDefinitionTable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        for t in ["professional_method_definitions", "method_definition_registry", "method_templates"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t) == false, "\(t) must not exist")
        }
    }

    // MARK: - Preservation + repeatability

    @Test("v78→v79 preserves existing rows and adds only the method ledger")
    func v78ToV79Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 78)
        let ws = UUID()
        try await seedWorkspace(db, ws)
        try await SchemaMigrations.migrate(db, through: 79)
        let n = Int(try await db.query("SELECT COUNT(*) FROM workspaces WHERE id = ?;", [.uuid(ws)]).first?.int(0) ?? -1)
        #expect(n == 1)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "method_runs"))
    }

    @Test("Re-running migrate over a v79 database is a safe no-op")
    func v79Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        try await SchemaMigrations.migrate(db, through: 79)
        #expect(try await db.currentUserVersion() == 79)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("The self-heal sentinel recognises the v79 markers and reconciles a stale counter")
    func selfHealRecognizesV79Markers() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        // Schema is fully v79 but the counter is stale — self-heal must stamp 79
        // without re-running any DDL (which would fail "table already exists").
        try await db.setUserVersion(78)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == 79)
        for t in methodTables { #expect(try await MigrationFixtureBuilder.tableExists(db, t)) }
    }

    @Test("An injected failure inside the v79 SAVEPOINT rolls back all eight tables and the version stamp")
    func injectedFailureRollsBackV79() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 78)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(
                db, through: 79,
                fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 79)))
        }
        #expect(try await db.currentUserVersion() == 78)
        for t in methodTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t) == false, "\(t) should have rolled back")
        }
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - Constraints

    @Test("method_runs rejects an unknown status")
    func runStatusChecked() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        let ws = UUID(); try await seedWorkspace(db, ws)
        await #expect(throws: (any Error).self) {
            try await self.insertRun(db, id: UUID(), ws: ws, status: "nonsense")
        }
    }

    @Test("method_runs rejects revision < 1 and a self-referential supersession")
    func runRevisionAndSupersessionChecked() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        let ws = UUID(); try await seedWorkspace(db, ws)
        await #expect(throws: (any Error).self) {
            try await self.insertRun(db, id: UUID(), ws: ws, revision: 0)
        }
        let runID = UUID(); try await insertRun(db, id: runID, ws: ws)
        await #expect(throws: (any Error).self) {
            try await db.exec("UPDATE method_runs SET superseded_by_run_id = id WHERE id = ?;", [.uuid(runID)])
        }
    }

    @Test("method_reviews rejects a non-human actor_kind")
    func reviewHumanOnlyChecked() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        let ws = UUID(); try await seedWorkspace(db, ws)
        let runID = UUID(); try await insertRun(db, id: runID, ws: ws)
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO method_reviews (id, method_run_id, action, actor_kind, actor_identifier, reviewed_at)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(runID), .text("acceptForWorkflow"), .text("system"), .text("sys"), .real(0)])
        }
    }

    @Test("A composite ownership foreign key rejects an edge endpoint from another run")
    func compositeOwnershipRejectsForeignEndpoint() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let runA = UUID(); try await insertRun(db, id: runA, ws: ws)
        let runB = UUID(); try await insertRun(db, id: runB, ws: ws)
        let nodeA = UUID(); try await insertNode(db, id: nodeA, run: runA)
        let nodeB = UUID(); try await insertNode(db, id: nodeB, run: runB)
        // An edge in run B whose from-node belongs to run A must fail the composite FK.
        await #expect(throws: (any Error).self) {
            try await db.exec("""
                INSERT INTO method_edges (id, method_run_id, from_node_id, to_node_id, edge_kind, ordinal)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(runB), .uuid(nodeA), .uuid(nodeB), .text("leadsTo"), .integer(0)])
        }
    }

    @Test("A duplicate identical edge is rejected")
    func duplicateEdgeRejected() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        let n1 = UUID(); try await insertNode(db, id: n1, run: run, ordinal: 0)
        let n2 = UUID(); try await insertNode(db, id: n2, run: run, ordinal: 1)
        func addEdge() async throws {
            try await db.exec("""
                INSERT INTO method_edges (id, method_run_id, from_node_id, to_node_id, edge_kind, ordinal)
                VALUES (?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(run), .uuid(n1), .uuid(n2), .text("leadsTo"), .integer(0)])
        }
        try await addEdge()
        await #expect(throws: (any Error).self) { try await addEdge() }
    }

    @Test("Deleting a workspace cascades the method aggregate but not canonical evidence")
    func workspaceCascadeDeletesMethodRows() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        let node = UUID(); try await insertNode(db, id: node, run: run)
        // A canonical row that must survive the workspace deletion.
        _ = try await PJE007Fixtures.seedGap(db)
        let gapsBefore = Int(try await db.query("SELECT COUNT(*) FROM gap_nodes;", []).first?.int(0) ?? -1)

        try await db.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(ws)])
        #expect(try await db.query("SELECT COUNT(*) FROM method_runs WHERE id = ?;", [.uuid(run)]).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM method_nodes WHERE id = ?;", [.uuid(node)]).first?.int(0) == 0)
        #expect(Int(try await db.query("SELECT COUNT(*) FROM gap_nodes;", []).first?.int(0) ?? -1) == gapsBefore)
    }

    @Test("method_validation_results requires a subject id for every non-run subject kind")
    func validationSubjectCheck() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        func insertValidation(_ kind: String, subjectID: SQLValue) async throws {
            try await db.exec("""
                INSERT INTO method_validation_results (id, method_run_id, validator_id, validator_version,
                                                       severity, code, message, subject_kind, subject_id, created_at)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """, [.uuid(UUID()), .uuid(run), .text("v"), .text("1"), .text("info"), .text("C"),
                      .text("m"), .text(kind), subjectID, .real(0)])
        }
        // A non-run subject with a NULL subject_id must fail the CHECK.
        await #expect(throws: (any Error).self) { try await insertValidation("node", subjectID: .null) }
        // A run subject may omit the subject id.
        try await insertValidation("run", subjectID: .null)
    }

    @Test("Foreign-key integrity is clean after seeding a method aggregate")
    func foreignKeyIntegrityClean() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 79)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, ws)
        let run = UUID(); try await insertRun(db, id: run, ws: ws)
        try await insertNode(db, id: UUID(), run: run)
        let violations = try await db.query("PRAGMA foreign_key_check;", [])
        #expect(violations.isEmpty)
    }
}
