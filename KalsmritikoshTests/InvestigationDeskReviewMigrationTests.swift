//
//  InvestigationDeskReviewMigrationTests.swift
//  KalsmritikoshTests
//
//  INV-08 / INV-12 — schema v100 adds investigation_desk_reviews: the thin, case-scoped human disposition of
//  a shared canonical item (reliability assessment / contradiction / gap) by soft id. Proves reach, v99→v100
//  preservation, self-heal, repeat + fault rollback, milestone, and the integrity CHECKs (item_kind/decision
//  vocab, nonblank item_id/actor, one disposition per (case,kind,item), FK/cascade). Synthetic only.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("INV-08/12 — v100 desk-review migration")
struct InvestigationDeskReviewMigrationTests {

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
    private func insertReview(_ db: Database, caseID: UUID, kind: String = "contradiction", item: String = "item-1",
                              decision: String = "confirmed", actor: String = "u") async throws {
        try await db.exec("""
            INSERT INTO investigation_desk_reviews (id, case_id, item_kind, item_id, decision, note, actor, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(caseID), .text(kind), .text(item), .text(decision), .null, .text(actor), .real(1), .real(1)])
    }

    @Test("A fresh database reaches v100 with the desk-review table")
    func freshV100() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 100)
        #expect(try await db.currentUserVersion() == 100)
        #expect(try await MigrationFixtureBuilder.tableExists(db, "investigation_desk_reviews"))
        #expect(try await MigrationFixtureBuilder.columns(db, "investigation_desk_reviews")
            .isSuperset(of: ["case_id", "item_kind", "item_id", "decision", "actor"]))
    }

    @Test("v99→v100 preserves an existing case and fabricates no reviews")
    func v99ToV100Preserves() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        _ = try await insertWorkspaceAndCase(db)
        try await SchemaMigrations.migrate(db, through: 100)
        #expect(try await db.currentUserVersion() == 100)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_cases;", []).first?.int(0) == 1)
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_desk_reviews;", []).first?.int(0) == 0)
    }

    @Test("The self-heal sentinel recognises the v100 table")
    func selfHealRecognizesV100() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(97)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v100 database is a safe no-op")
    func v100Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 100)
        try await SchemaMigrations.migrate(db, through: 100)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v100 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 99)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 100, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 100)))
        }
        #expect(try await db.currentUserVersion() == 99)
        #expect(try await db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='investigation_desk_reviews';", []).isEmpty)
    }

    @Test("Milestone migration from version 0 reaches v100 with a clean FK graph")
    func milestoneReachesV100() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 100)
        #expect(try await db.currentUserVersion() == 100)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("A desk review enforces item_kind/decision vocab, nonblank item_id/actor, and one disposition per (case,kind,item)")
    func reviewChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 100)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let c = try await insertWorkspaceAndCase(db)
        await #expect(throws: (any Error).self) { try await insertReview(db, caseID: c, kind: "bogus") }
        await #expect(throws: (any Error).self) { try await insertReview(db, caseID: c, decision: "maybe") }
        await #expect(throws: (any Error).self) { try await insertReview(db, caseID: c, item: "  ") }
        await #expect(throws: (any Error).self) { try await insertReview(db, caseID: c, actor: " ") }
        try await insertReview(db, caseID: c, kind: "gap", item: "g1")
        await #expect(throws: (any Error).self) { try await insertReview(db, caseID: c, kind: "gap", item: "g1") }   // dup (case,kind,item)
        try await insertReview(db, caseID: c, kind: "reliability", item: "g1")   // same item id, different kind is fine
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_desk_reviews;", []).first?.int(0) == 2)
    }

    @Test("A desk review requires a real case; deleting the case cascades its reviews")
    func fkAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 100)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertReview(db, caseID: UUID()) }
        let c = try await insertWorkspaceAndCase(db)
        try await insertReview(db, caseID: c)
        try await db.exec("DELETE FROM investigation_cases WHERE id = ?;", [.uuid(c)])
        #expect(try await db.query("SELECT COUNT(*) FROM investigation_desk_reviews;", []).first?.int(0) == 0)
    }
}
