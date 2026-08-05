//
//  InvestigationAnalysisMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-04..07 — schema v99 adds the analytical spine: investigation_hypotheses (leads/hypotheses) +
//  investigation_hypothesis_evidence (for/against links) + investigation_evidence_requests +
//  investigation_worksheet_cells (5W1H). Proves reach, v98→v99 preservation, self-heal, repeat + fault
//  rollback, milestone, and the integrity CHECKs (kind/status/stance/dimension vocab, answered<->evidence
//  pairing, uniqueness, FK/cascade/set-null). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-04..07 — v99 analytical-spine migration")
struct InvestigationAnalysisMigrationTests {

    @discardableResult
    private func insertWorkspaceAndCase(_ db: Database) async throws -> UUID {
        let ws = UUID(), c = UUID()
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);", [.uuid(ws), .text("W"), .real(1), .real(1)])
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(c), .uuid(ws), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        return c
    }
    private func insertHypothesis(_ db: Database, caseID: UUID, id: UUID = UUID(), kind: String = "lead",
                                  statement: String = "idea", status: String = "proposed", revision: Int64 = 1) async throws {
        try await db.exec("""
            INSERT INTO investigation_hypotheses (id, case_id, kind, statement, status, origin_hypothesis_id, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(caseID), .text(kind), .text(statement), .text(status), .null, .integer(revision), .text("u"), .real(1), .real(1)])
    }
    private func insertCell(_ db: Database, caseID: UUID, dimension: String = "who", status: String = "unknown",
                            answer: SQLValue = .null, sv: SQLValue = .null, ko: SQLValue = .null) async throws {
        try await db.exec("""
            INSERT INTO investigation_worksheet_cells (id, case_id, dimension, status, answer_text, source_version_id, knowledge_object_id, revision, actor, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text(dimension), .text(status), answer, sv, ko, .integer(1), .text("u"), .real(1)])
    }

    @Test("A fresh database reaches v99 with all four analytical tables")
    func freshV99() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        #expect(try await db.currentUserVersion() == 99)
        for t in ["investigation_hypotheses", "investigation_hypothesis_evidence", "investigation_evidence_requests", "investigation_worksheet_cells"] {
            #expect(try await MigrationFixtureBuilder.tableExists(db, t), "\(t) missing")
        }
    }

    @Test("v98→v99 preserves an existing case and fabricates no analytical rows")
    func v98ToV99Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        _ = try await insertWorkspaceAndCase(db)
        try await SchemaMigrations.migrate(db, through: 99)
        #expect(try await db.currentUserVersion() == 99)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_hypotheses;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v99 tables")
    func selfHealRecognizesV99() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(96)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v99 database is a safe no-op")
    func v99Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        try await SchemaMigrations.migrate(db, through: 99)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v99 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 99, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 99)))
        }
        #expect(try await db.currentUserVersion() == 98)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_hypotheses';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v99 with a clean FK graph")
    func milestoneReachesV99() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 99)
        #expect(try await db.currentUserVersion() == 99)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Hypotheses enforce kind/status vocab, nonblank statement, revision")
    func hypothesisChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let c = try await insertWorkspaceAndCase(db)
        await #expect(throws: (any Error).self) { try await insertHypothesis(db, caseID: c, kind: "bogus") }
        await #expect(throws: (any Error).self) { try await insertHypothesis(db, caseID: c, statement: "  ") }
        await #expect(throws: (any Error).self) { try await insertHypothesis(db, caseID: c, status: "won") }
        await #expect(throws: (any Error).self) { try await insertHypothesis(db, caseID: c, revision: 0) }
        try await insertHypothesis(db, caseID: c)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_hypotheses;", []).first?.int(0) == 1)
    }

    @Test("A 5W1H cell enforces the answered<->evidence pairing, the dimension vocab, and one cell per (case,dimension)")
    func worksheetCellChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let c = try await insertWorkspaceAndCase(db)
        await #expect(throws: (any Error).self) { try await insertCell(db, caseID: c, dimension: "wat") }                              // bad dimension
        await #expect(throws: (any Error).self) { try await insertCell(db, caseID: c, status: "answered") }                           // answered needs answer+evidence
        await #expect(throws: (any Error).self) { try await insertCell(db, caseID: c, status: "unknown", answer: .text("x")) }        // unknown carries nothing
        try await insertCell(db, caseID: c, dimension: "who", status: "answered", answer: .text("Alice"), sv: .uuid(UUID()), ko: .uuid(UUID()))
        await #expect(throws: (any Error).self) { try await insertCell(db, caseID: c, dimension: "who") }                             // dup (case, dimension)
        try await insertCell(db, caseID: c, dimension: "what")                                                                        // another dimension is fine
    }

    @Test("Evidence links enforce stance vocab; deleting a hypothesis cascades its links and nulls request/origin references")
    func evidenceStanceAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let c = try await insertWorkspaceAndCase(db)
        let hyp = UUID()
        try await insertHypothesis(db, caseID: c, id: hyp, kind: "hypothesis")
        await #expect(throws: (any Error).self) {
            try await db.exec("INSERT INTO investigation_hypothesis_evidence (id, hypothesis_id, stance, source_version_id, knowledge_object_id, added_by, created_at) VALUES (?,?,?,?,?,?,?);",
                              [.uuid(UUID()), .uuid(hyp), .text("maybe"), .uuid(UUID()), .uuid(UUID()), .text("u"), .real(1)])
        }
        try await db.exec("INSERT INTO investigation_hypothesis_evidence (id, hypothesis_id, stance, source_version_id, knowledge_object_id, added_by, created_at) VALUES (?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(hyp), .text("for"), .uuid(UUID()), .uuid(UUID()), .text("u"), .real(1)])
        try await db.exec("INSERT INTO investigation_evidence_requests (id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?);",
                          [.uuid(UUID()), .uuid(c), .uuid(hyp), .text("gather X"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        try await db.exec("DELETE FROM investigation_hypotheses WHERE id = ?;", [.uuid(hyp)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_hypothesis_evidence;", []).first?.int(0) == 0)   // cascade
        #expect(try await db.query("SELECT hypothesis_id FROM investigation_evidence_requests LIMIT 1;", []).first?.uuid(0) == nil)  // set null
    }
}
