//
//  JobObjectiveMigrationTests.swift
//  KalsmritikoshTests
//
//  TBJ-FINAL — schema v91 adds the time-bounded job planning envelope: job_objectives +
//  job_plan_references + job_events. A Job REFERENCES existing task/deadline/workflow authorities;
//  it is NOT a second task or deadline system. Proves reach, v90→v91 legacy preservation (no
//  fabricated jobs), self-heal, repeat + fault rollback, milestone, and every integrity CHECK/FK:
//  title/actor nonblank, budget-basis exclusivity (only the matching column populated), lifecycle
//  vs closed_at, revision/sequence bounds, plan-reference vocab + COALESCE-unique dedup, and
//  cascade on workspace / job delete. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("TBJ-FINAL — v91 job planning migration")
struct JobObjectiveMigrationTests {

    private func seedWorkspace(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(id), .text("W"), .real(100), .real(100)])
    }

    private func insertJob(_ db: Database, ws: UUID, id: UUID = UUID(),
                           title: String = "Prepare filing",
                           basis: String = "none", seconds: SQLValue = .null,
                           deadlineID: SQLValue = .null, workflowRunID: SQLValue = .null,
                           lifecycle: String = "active", closedAt: SQLValue = .null,
                           revision: Int64 = 1) async throws {
        try await db.exec("""
            INSERT INTO job_objectives (id, workspace_id, title, objective_detail, budget_basis,
                budget_seconds, budget_deadline_id, budget_workflow_run_id, primary_workflow_run_id,
                lifecycle, revision, created_at, updated_at, closed_at, closure_reason)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(ws), .text(title), .null, .text(basis),
                  seconds, deadlineID, workflowRunID, .null,
                  .text(lifecycle), .integer(revision), .real(100), .real(100), closedAt, .null])
    }

    @discardableResult
    private func insertRef(_ db: Database, job: UUID, id: UUID = UUID(),
                           kind: String = "professionalTask", refID: String = "task-1",
                           runID: SQLValue = .null, role: String = "required",
                           mad: Int64 = 0, ordinal: Int64 = 0) async throws -> UUID {
        try await db.exec("""
            INSERT INTO job_plan_references (id, job_id, reference_kind, reference_id, workflow_run_id,
                role, is_minimum_deliverable, ordinal, note, created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(job), .text(kind), .text(refID), runID,
                  .text(role), .integer(mad), .integer(ordinal), .null, .real(100)])
        return id
    }

    private func insertEvent(_ db: Database, job: UUID, seq: Int64 = 1, rev: Int64 = 1,
                             action: String = "created", actor: String = "user") async throws {
        try await db.exec("""
            INSERT INTO job_events (id, job_id, sequence, job_revision, action, actor, detail, occurred_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(job), .integer(seq), .integer(rev), .text(action), .text(actor), .null, .real(100)])
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v91 with all three job tables")
    func freshV91() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        #expect(try await db.currentUserVersion() == 91)
        #expect(try await MigrationFixtureBuilder.columns(db, "job_objectives").isSuperset(of: ["workspace_id", "title", "budget_basis", "budget_deadline_id", "lifecycle", "revision", "closed_at"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "job_plan_references").isSuperset(of: ["job_id", "reference_kind", "reference_id", "is_minimum_deliverable", "ordinal"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "job_events").isSuperset(of: ["job_id", "sequence", "job_revision", "action", "actor"]))
    }

    @Test("v90→v91 preserves legacy data with no fabricated jobs")
    func v90ToV91Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        let a = UUID()
        try await db.exec("INSERT INTO answers (id, question, answer_state, body, confidence, created_at) VALUES (?,?,?,?,?,?);",
                         [.uuid(a), .text("q"), .text("supported"), .text("body"), .real(0.5), .real(1)])
        try await SchemaMigrations.migrate(db, through: 91)
        #expect(try await db.currentUserVersion() == 91)
        #expect(try await db.query("SELECT COUNT(*) FROM answers WHERE id = ?;", [.uuid(a)]).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM job_plan_references;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v91 job tables")
    func selfHealRecognizesV91() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(89)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v91 database is a safe no-op")
    func v91Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await SchemaMigrations.migrate(db, through: 91)
        #expect(try await db.currentUserVersion() == 91)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v91 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 90)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 91, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 91)))
        }
        #expect(try await db.currentUserVersion() == 90)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='job_objectives';", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v91 with a clean FK graph")
    func milestoneReachesV91() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 91)
        #expect(try await db.currentUserVersion() == 91)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - job_objectives CHECKs + FK

    @Test("A job title must be nonblank")
    func titleNonblank() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, title: "   ") }
        try await insertJob(db, ws: ws, title: "Real")
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 1)
    }

    @Test("explicitDuration requires a positive budget_seconds and no other budget column")
    func explicitDurationBasis() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        // basis says explicitDuration but seconds is null -> reject
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "explicitDuration") }
        // seconds must be positive
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "explicitDuration", seconds: .real(0)) }
        // seconds AND a deadline id together -> reject
        await #expect(throws: (any Error).self) {
            try await insertJob(db, ws: ws, basis: "explicitDuration", seconds: .real(3600), deadlineID: .text("d-1"))
        }
        try await insertJob(db, ws: ws, basis: "explicitDuration", seconds: .real(3600))
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 1)
    }

    @Test("confirmedDeadline requires the deadline column and nothing else")
    func confirmedDeadlineBasis() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        // basis says confirmedDeadline but no deadline id -> reject
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "confirmedDeadline") }
        // deadline id present but seconds also set -> reject (exclusivity)
        await #expect(throws: (any Error).self) {
            try await insertJob(db, ws: ws, basis: "confirmedDeadline", seconds: .real(1), deadlineID: .text("d-1"))
        }
        try await insertJob(db, ws: ws, basis: "confirmedDeadline", deadlineID: .text("d-1"))
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 1)
    }

    @Test("workflowConstraint requires the workflow column and nothing else")
    func workflowConstraintBasis() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "workflowConstraint") }
        try await insertJob(db, ws: ws, basis: "workflowConstraint", workflowRunID: .text("r-1"))
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 1)
    }

    @Test("basis 'none' forbids every budget column")
    func noneBasis() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "none", seconds: .real(10)) }
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "none", deadlineID: .text("d-1")) }
        try await insertJob(db, ws: ws, basis: "none")
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 1)
    }

    @Test("An unknown budget_basis or lifecycle is rejected")
    func closedVocabularies() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, basis: "guessed") }
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, lifecycle: "paused") }  // not a job lifecycle
    }

    @Test("active forbids closed_at; closed/abandoned require it")
    func lifecycleClosedAtConsistency() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, lifecycle: "active", closedAt: .real(200)) }
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, lifecycle: "closed", closedAt: .null) }
        try await insertJob(db, ws: ws, lifecycle: "closed", closedAt: .real(200))
        try await insertJob(db, ws: ws, lifecycle: "abandoned", closedAt: .real(200))
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 2)
    }

    @Test("revision must be >= 1")
    func revisionPositive() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: ws, revision: 0) }
    }

    @Test("A job's workspace_id must reference a real workspace")
    func workspaceFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertJob(db, ws: UUID()) }   // no such workspace
    }

    @Test("Deleting a workspace cascades its jobs, references and events away")
    func cascadeOnWorkspaceDelete() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let job = UUID(); try await insertJob(db, ws: ws, id: job)
        try await insertRef(db, job: job)
        try await insertEvent(db, job: job)
        try await db.exec("DELETE FROM workspaces WHERE id = ?;", [.uuid(ws)])
        #expect(try await db.query("SELECT COUNT(*) FROM job_objectives;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM job_plan_references;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM job_events;", []).first?.int(0) == 0)
    }

    // MARK: - job_plan_references CHECKs + dedup

    @Test("A plan reference's job_id must reference a real job")
    func planRefJobFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertRef(db, job: UUID()) }
    }

    @Test("Plan reference kind, role and MAD flag are closed vocabularies")
    func planRefVocab() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let job = UUID(); try await insertJob(db, ws: ws, id: job)
        await #expect(throws: (any Error).self) { try await insertRef(db, job: job, kind: "sourceVersion") }   // not a plan-ref kind
        await #expect(throws: (any Error).self) { try await insertRef(db, job: job, role: "maybe") }
        await #expect(throws: (any Error).self) { try await insertRef(db, job: job, refID: "  ") }              // nonblank
        try await insertRef(db, job: job, kind: "workflowRequirement", refID: "req-evidence", role: "optional", mad: 1, ordinal: 3)
        #expect(try await db.query("SELECT COUNT(*) FROM job_plan_references;", []).first?.int(0) == 1)
    }

    @Test("The same reference cannot be added twice to one job (NULL context run folded via COALESCE)")
    func planRefDedup() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let job = UUID(); try await insertJob(db, ws: ws, id: job)
        try await insertRef(db, job: job, kind: "professionalTask", refID: "task-X")
        // exact duplicate with a NULL context run -> rejected (COALESCE folds NULLs together)
        await #expect(throws: (any Error).self) { try await insertRef(db, job: job, kind: "professionalTask", refID: "task-X") }
        // same target but a distinct context run -> allowed
        try await insertRef(db, job: job, kind: "professionalTask", refID: "task-X", runID: .text("run-1"))
        #expect(try await db.query("SELECT COUNT(*) FROM job_plan_references;", []).first?.int(0) == 2)
    }

    // MARK: - job_events

    @Test("Event action is a closed vocabulary and actor must be nonblank")
    func eventVocab() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let job = UUID(); try await insertJob(db, ws: ws, id: job)
        await #expect(throws: (any Error).self) { try await insertEvent(db, job: job, action: "guessed") }
        await #expect(throws: (any Error).self) { try await insertEvent(db, job: job, actor: " ") }
        try await insertEvent(db, job: job, seq: 1, action: "created")
        #expect(try await db.query("SELECT COUNT(*) FROM job_events;", []).first?.int(0) == 1)
    }

    @Test("Event sequence is unique per job")
    func eventSequenceUnique() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 91)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = UUID(); try await seedWorkspace(db, id: ws)
        let job = UUID(); try await insertJob(db, ws: ws, id: job)
        try await insertEvent(db, job: job, seq: 1)
        await #expect(throws: (any Error).self) { try await insertEvent(db, job: job, seq: 1, action: "budgetSet") }
        try await insertEvent(db, job: job, seq: 2, action: "budgetSet")
        #expect(try await db.query("SELECT COUNT(*) FROM job_events;", []).first?.int(0) == 2)
    }
}
