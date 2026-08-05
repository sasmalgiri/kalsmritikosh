//
//  InvestigationSubjectIdentityMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-02 / INV-03 — schema v98 adds investigation_subjects (a case→canonical-entity subject with a
//  proposed→confirmed identity decision) and investigation_identity_decisions (the append-only, reversible
//  merge decision log). Proves reach, v97→v98 preservation, self-heal, repeat + fault rollback, milestone,
//  and every integrity CHECK / FK / cascade / uniqueness. Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-02/03 — v98 subject + identity-decision migration")
struct InvestigationSubjectIdentityMigrationTests {

    @discardableResult
    private func insertWorkspace(_ db: Database, id: UUID = UUID()) async throws -> UUID {
        try await db.exec("INSERT INTO workspaces (id, title, created_at, updated_at) VALUES (?,?,?,?);",
                          [.uuid(id), .text("W"), .real(1), .real(1)])
        return id
    }
    @discardableResult
    private func insertCase(_ db: Database, id: UUID = UUID(), workspace: UUID) async throws -> UUID {
        try await db.exec("""
            INSERT INTO investigation_cases (id, workspace_id, title, status, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(workspace), .text("C"), .text("open"), .integer(1), .text("u"), .real(1), .real(1)])
        return id
    }
    private func insertSubject(_ db: Database, caseID: UUID, entity: UUID = UUID(), label: String = "S",
                               status: String = "proposed", confirmedBy: SQLValue = .null, confirmedAt: SQLValue = .null,
                               revision: Int64 = 1) async throws {
        try await db.exec("""
            INSERT INTO investigation_subjects (id, case_id, canonical_entity_id, label, identity_status,
                confirmed_by, confirmed_at, revision, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .uuid(entity), .text(label), .text(status),
                  confirmedBy, confirmedAt, .integer(revision), .text("u"), .real(1), .real(1)])
    }
    private func insertDecision(_ db: Database, caseID: UUID, seq: Int64 = 1, kind: String = "mergeProposed",
                                winner: UUID = UUID(), loser: UUID = UUID(), prior: SQLValue = .null) async throws {
        try await db.exec("""
            INSERT INTO investigation_identity_decisions (id, case_id, sequence, decision_kind, winner_entity_id,
                loser_entity_id, rationale, actor, prior_decision_id, occurred_at)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .integer(seq), .text(kind), .uuid(winner), .uuid(loser),
                  .null, .text("u"), prior, .real(1)])
    }

    @Test("A fresh database reaches v98 with both new tables")
    func freshV98() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        #expect(try await db.currentUserVersion() == 98)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_subjects"))
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_identity_decisions"))
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_subjects")
            .isSuperset(of: ["case_id", "canonical_entity_id", "label", "identity_status", "confirmed_by", "confirmed_at"]))
    }

    @Test("v97→v98 preserves an existing case and fabricates no subjects or decisions")
    func v97ToV98Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 97)
        let ws = try await insertWorkspace(db)
        _ = try await insertCase(db, workspace: ws)
        try await SchemaMigrations.migrate(db, through: 98)
        #expect(try await db.currentUserVersion() == 98)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_subjects;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_identity_decisions;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v98 tables")
    func selfHealRecognizesV98() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(95)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v98 database is a safe no-op")
    func v98Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        try await SchemaMigrations.migrate(db, through: 98)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v98 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 97)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 98, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 98)))
        }
        #expect(try await db.currentUserVersion() == 97)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_subjects';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v98 with a clean FK graph")
    func milestoneReachesV98() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 98)
        #expect(try await db.currentUserVersion() == 98)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("A subject enforces label, status vocab, confirmed⇔confirmer, revision, and uniqueness")
    func subjectChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        let e1 = UUID()
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: c, label: "  ") }                    // blank label
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: c, status: "bogus") }               // bad status
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: c, revision: 0) }                    // revision >= 1
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: c, status: "confirmed") }           // confirmed needs confirmer
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: c, status: "proposed", confirmedBy: .text("u"), confirmedAt: .real(1)) } // non-confirmed carries no confirmer
        try await insertSubject(db, caseID: c, entity: e1, status: "confirmed", confirmedBy: .text("u"), confirmedAt: .real(1))
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: c, entity: e1) }                    // dup (case, entity)
    }

    @Test("A decision enforces kind vocab, winner≠loser, sequence, and uniqueness; prior_decision_id SET NULL on delete")
    func decisionChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        let same = UUID()
        await #expect(throws: (any Error).self) { try await insertDecision(db, caseID: c, kind: "bogus") }                 // bad kind
        await #expect(throws: (any Error).self) { try await insertDecision(db, caseID: c, winner: same, loser: same) }     // winner == loser
        await #expect(throws: (any Error).self) { try await insertDecision(db, caseID: c, seq: 0) }                        // sequence >= 1
        try await insertDecision(db, caseID: c, seq: 1)
        await #expect(throws: (any Error).self) { try await insertDecision(db, caseID: c, seq: 1) }                        // dup (case, sequence)
    }

    @Test("A subject/decision requires a real case; deleting the case cascades both")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 98)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertSubject(db, caseID: UUID()) }     // no such case
        let ws = try await insertWorkspace(db)
        let c = try await insertCase(db, workspace: ws)
        try await insertSubject(db, caseID: c)
        try await insertDecision(db, caseID: c)
        try await db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_subjects;", []).first?.int(0) == 0)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_identity_decisions;", []).first?.int(0) == 0)
    }
}
