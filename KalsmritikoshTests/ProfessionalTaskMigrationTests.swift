//
//  ProfessionalTaskMigrationTests.swift
//  KalsmritikoshTests
//
//  OPS-002 — schema v69 (shared Task and Deadline Engine). Locks: a fresh database reaches v69
//  with all eight workflow tables; a GENUINE v68→v69 migration preserves canonical rows AND
//  existing Issue rows and adds ONLY the new tables; the truth-rule constraints are enforced at
//  the database layer (UNIQUE(source_candidate_id) — one candidate promotes at most once;
//  UNIQUE dependency triple + CHECK(no self-dependency); CHECK(confidence 0…1);
//  primary_issue_id ON DELETE SET NULL); integrity + foreign-key checks pass; and no canonical
//  table gained a task/deadline column.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("OPS-002 — professional task schema (v69)")
struct ProfessionalTaskMigrationTests {

    private let taskTables = ["professional_tasks", "professional_task_dependencies",
                              "deadline_candidates", "deadlines",
                              "professional_task_evidence_links", "professional_task_reviews",
                              "deadline_candidate_reviews", "deadline_reviews"]

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Case 1 + 27: fresh v69

    @Test("A fresh database reaches v69 with all eight Task/Deadline tables and clean integrity")
    func freshV69() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        // Pinned `through: 69` — this locks the v69 step; head coverage lives in
        // MigrationMatrixTests and the v69→v70 test below.
        try await SchemaMigrations.migrate(db, through: 69)
        #expect(try await db.currentUserVersion() == 69)
        for t in taskTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
        // The columns the truth rule depends on.
        #expect(try await MigrationFixtureBuilder.columns(db, "deadlines")
            .isSuperset(of: ["source_candidate_id", "precision", "time_zone", "confirmation_kind",
                             "confirmed_by", "rule_id", "rule_version"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "deadline_candidates")
            .isSuperset(of: ["precision", "time_zone", "origin", "confidence", "proposed_by",
                             "rule_id", "rule_version", "status"]))
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - Case 2: genuine v68→v69 preservation (canonical + Issue rows)

    @Test("A genuine v68→v69 migration preserves canonical and Issue rows, adding only new tables")
    func v68ToV69Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 68)
        #expect(try await db.currentUserVersion() == 68)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 68)
        // A live Issue row seeded at v68 must also survive (v68 tables are untouched by v69).
        let wsID = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(wsID), .text("WS-68"), .text("general"), .real(0), .real(0)])
        let issueRepo = ProfessionalIssueRepository(database: db)
        let issue = try await issueRepo.create(workspaceID: wsID, title: "Pre-existing", detail: nil,
                                               type: .question, priority: .normal, reviewer: "u", at: t0)
        for t in taskTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t) == false, "\(t) already present at v68")
        }

        try await SchemaMigrations.migrate(db, through: 69)      // 68 → 69 (pinned step)

        #expect(try await db.currentUserVersion() == 69)
        for t in taskTables {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing after v69")
        }
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "v68→v69 lost rows: \(failures)")
        // The Issue row, its review ledger and its status are intact.
        let survived = try #require(try await issueRepo.issue(id: issue.id))
        #expect(survived == issue)
        #expect(try await issueRepo.reviews(issueID: issue.id).map(\.action) == [.created])
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)

        // v69 must not have touched canonical tables — no task/deadline columns anywhere canonical.
        for (table, forbidden) in [("claims", "task"), ("claims", "deadline"),
                                   ("events", "task"), ("events", "deadline"),
                                   ("contradictions", "task"), ("gap_nodes", "task"),
                                   ("source_versions", "deadline"), ("knowledge_objects", "task")] {
            let cols = try await MigrationFixtureBuilder.columns(db, table)
            #expect(!cols.contains { $0.lowercased().contains(forbidden) },
                    "\(table) gained a \(forbidden) column")
        }
    }

    // MARK: - OPS-002.1: genuine v69→v70 (additive authority columns; nothing invented)

    @Test("A genuine v69→v70 migration preserves Task/Deadline/Issue/canonical rows and adds NULL authority")
    func v69ToV70Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 69)
        #expect(try await db.currentUserVersion() == 69)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 69)
        // Live v69-era workflow rows seeded with the v69 column set (NO authority columns —
        // the repository can't be used here; it now writes v70 columns).
        let ws = UUID(), issue = UUID(), task = UUID(), candidate = UUID(), deadline = UUID(), review = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS-69"), .text("general"), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO professional_issues (id, workspace_id, title, issue_type, status, priority, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(issue), .uuid(ws), .text("I"), .text("question"), .text("open"), .text("normal"), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO professional_tasks (id, workspace_id, primary_issue_id, title, task_type, status, priority, origin, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(task), .uuid(ws), .uuid(issue), .text("T"), .text("action"), .text("open"),
              .text("normal"), .text("userCreated"), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO professional_task_reviews (id, task_id, action, prior_status, new_status, reviewer, reason, reviewed_at)
        VALUES (?,?,?,?,?,?,?,?);
        """, [.uuid(review), .uuid(task), .text("created"), .null, .text("open"), .text("u"), .null, .real(0)])
        try await db.exec("""
        INSERT INTO deadline_candidates (id, task_id, due_date, precision, time_zone, deadline_kind,
                                         origin, proposed_by, status, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(candidate), .uuid(task), .real(0), .integer(5), .text("UTC"), .text("due"),
              .text("sourceExtraction"), .text("x"), .text("promoted"), .real(0)])
        try await db.exec("""
        INSERT INTO deadlines (id, task_id, source_candidate_id, due_date, precision, time_zone,
                               deadline_kind, status, confirmation_kind, confirmed_by, confirmed_at,
                               created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(deadline), .uuid(task), .uuid(candidate), .real(0), .integer(5), .text("UTC"),
              .text("due"), .text("active"), .text("user"), .text("u"), .real(0), .real(0), .real(0)])
        #expect(try await MigrationFixtureBuilder.columns(db, "professional_task_reviews")
            .isDisjoint(with: ["authority_kind", "rule_id", "rule_version"]))

        try await SchemaMigrations.migrate(db, through: 70)      // 69 → 70 only

        #expect(try await db.currentUserVersion() == 70)
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "v69→v70 lost canonical rows: \(failures)")
        for (table, id) in [("professional_issues", issue), ("professional_tasks", task),
                            ("deadline_candidates", candidate), ("deadlines", deadline),
                            ("professional_task_reviews", review)] {
            let n = Int(try await db.query("SELECT COUNT(*) FROM \(table) WHERE id = ?;", [.uuid(id)]).first?.int(0) ?? 0)
            #expect(n == 1, "\(table) row lost in v69→v70")
        }
        // New columns exist AND the pre-v70 review's authority is NULL — the migration invents
        // no provenance for rows whose structured authority was never recorded.
        #expect(try await MigrationFixtureBuilder.columns(db, "professional_task_reviews")
            .isSuperset(of: ["authority_kind", "rule_id", "rule_version"]))
        let invented = try await db.query("""
        SELECT COUNT(*) FROM professional_task_reviews
        WHERE authority_kind IS NOT NULL OR rule_id IS NOT NULL OR rule_version IS NOT NULL;
        """, [])
        #expect(Int(invented.first?.int(0) ?? -1) == 0, "migration invented authority provenance")
        #expect(try await MigrationFaultHarness.integrityOK(db))
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }

    // MARK: - Truth-rule constraints at the DATABASE layer

    /// v69 DB + workspace + one open task, for raw-SQL constraint probes.
    private func constraintRig() async throws -> (db: Database, ws: UUID, task: UUID) {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db)
        let ws = UUID(), task = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, template_type, created_at, updated_at) VALUES (?,?,?,?,?);",
                          [.uuid(ws), .text("WS"), .text("general"), .real(0), .real(0)])
        try await db.exec("""
        INSERT INTO professional_tasks (id, workspace_id, title, task_type, status, priority, origin, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(task), .uuid(ws), .text("T"), .text("action"), .text("open"), .text("normal"),
              .text("userCreated"), .real(0), .real(0)])
        return (db, ws, task)
    }

    private func insertCandidate(_ db: Database, id: UUID, task: UUID, confidence: SQLValue) async throws {
        try await db.exec("""
        INSERT INTO deadline_candidates (id, task_id, due_date, precision, time_zone, deadline_kind,
                                         origin, confidence, proposed_by, status, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(id), .uuid(task), .real(0), .integer(5), .text("UTC"), .text("due"),
              .text("sourceExtraction"), confidence, .text("x"), .text("pending"), .real(0)])
    }

    private func insertDeadline(_ db: Database, id: UUID, task: UUID, candidate: UUID?) async throws {
        try await db.exec("""
        INSERT INTO deadlines (id, task_id, source_candidate_id, due_date, precision, time_zone,
                               deadline_kind, status, confirmation_kind, confirmed_by, confirmed_at,
                               created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
        """, [.uuid(id), .uuid(task), candidate.map { SQLValue.uuid($0) } ?? .null, .real(0),
              .integer(5), .text("UTC"), .text("due"), .text("active"), .text("user"), .text("u"),
              .real(0), .real(0), .real(0)])
    }

    @Test("UNIQUE(source_candidate_id): one candidate can never yield two Deadline rows")
    func oneCandidateOneDeadline() async throws {
        let (db, _, task) = try await constraintRig()
        let candidate = UUID()
        try await insertCandidate(db, id: candidate, task: task, confidence: .null)
        try await insertDeadline(db, id: UUID(), task: task, candidate: candidate)
        await #expect(throws: (any Error).self, "second promotion of the same candidate must fail") {
            try await self.insertDeadline(db, id: UUID(), task: task, candidate: candidate)
        }
        // Direct user-created deadlines (NULL source) are not limited by the unique index.
        try await insertDeadline(db, id: UUID(), task: task, candidate: nil)
        try await insertDeadline(db, id: UUID(), task: task, candidate: nil)
    }

    @Test("Dependency CHECK + UNIQUE: self-links and duplicate triples are rejected in SQL")
    func dependencyConstraints() async throws {
        let (db, ws, task) = try await constraintRig()
        let other = UUID()
        try await db.exec("""
        INSERT INTO professional_tasks (id, workspace_id, title, task_type, status, priority, origin, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?);
        """, [.uuid(other), .uuid(ws), .text("O"), .text("action"), .text("open"), .text("normal"),
              .text("userCreated"), .real(0), .real(0)])
        func addDep(_ a: UUID, _ b: UUID) async throws {
            try await db.exec("""
            INSERT INTO professional_task_dependencies (id, task_id, depends_on_task_id, dependency_kind, created_at)
            VALUES (?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(a), .uuid(b), .text("blocking"), .real(0)])
        }
        await #expect(throws: (any Error).self, "self-dependency must violate the CHECK") {
            try await addDep(task, task)
        }
        try await addDep(task, other)
        await #expect(throws: (any Error).self, "duplicate dependency triple must violate UNIQUE") {
            try await addDep(task, other)
        }
    }

    @Test("Candidate confidence outside 0…1 violates the CHECK; NULL and bounds are accepted")
    func confidenceCheck() async throws {
        let (db, _, task) = try await constraintRig()
        try await insertCandidate(db, id: UUID(), task: task, confidence: .null)
        try await insertCandidate(db, id: UUID(), task: task, confidence: .real(0))
        try await insertCandidate(db, id: UUID(), task: task, confidence: .real(1))
        await #expect(throws: (any Error).self) {
            try await self.insertCandidate(db, id: UUID(), task: task, confidence: .real(1.5))
        }
        await #expect(throws: (any Error).self) {
            try await self.insertCandidate(db, id: UUID(), task: task, confidence: .real(-0.1))
        }
    }

    @Test("Deleting the primary Issue nulls the task pointer without deleting the task")
    func primaryIssueSetNull() async throws {
        let (db, ws, _) = try await constraintRig()
        let issueRepo = ProfessionalIssueRepository(database: db)
        let issue = try await issueRepo.create(workspaceID: ws, title: "I", detail: nil,
                                               type: .question, priority: .normal, reviewer: "u", at: t0)
        let taskRepo = ProfessionalTaskRepository(database: db)
        let task = try await taskRepo.createConfirmed(workspaceID: ws, primaryIssueID: issue.id,
                                                      title: "Linked", detail: nil, type: .action,
                                                      priority: .normal, owner: nil,
                                                      authority: .user(actor: "u"), at: t0)
        try await db.exec("DELETE FROM professional_issues WHERE id = ?;", [.uuid(issue.id)])
        let survived = try #require(try await taskRepo.task(id: task.id))
        #expect(survived.primaryIssueID == nil, "primary_issue_id was not set NULL")
        #expect(survived.title == "Linked")
        #expect(try await MigrationFaultHarness.foreignKeyViolationCount(db) == 0)
    }
}
