//
//  ProgressiveUpgradeMigrationTests.swift
//  KalsmritikoshTests
//
//  USF-M3 — schema v88 evolves enrichment_jobs into an exact-SourceVersion progressive-upgrade ledger
//  + adds enrichment_job_events. Legacy jobs are preserved verbatim as scope_kind='legacySubject' with
//  source_version_id NULL (NEVER guessed); states/attempts/errors/timestamps carry over. Proves reach,
//  v87→v88 preservation, self-heal, repeat + fault rollback, and every integrity CHECK: scope integrity,
//  closed state/action vocabularies, running-requires-lease, active-job idempotency, event sequencing.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("USF-M3 — v88 progressive upgrade ledger migration")
struct ProgressiveUpgradeMigrationTests {

    private let hex = String(repeating: "a", count: 64)

    private func insertLegacyJob(_ db: Database, subject: UUID, kind: String, state: String, attempts: Int, error: String?) async throws {
        try await db.exec("""
            INSERT INTO enrichment_jobs (id, subject_id, kind, state, attempts, last_error, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .uuid(subject), .text(kind), .text(state), .integer(Int64(attempts)),
                  error.map { SQLValue.text($0) } ?? .null, .real(100), .real(100)])
    }

    private func seedVersion(_ db: Database, id: UUID) async throws {
        try await db.exec("INSERT INTO files (id, url, source_type, availability) VALUES (?,?,?,?);",
                          [.uuid(id), .text("file:///x/\(id.uuidString)"), .text("txt"), .text("available")])
        try await db.exec("""
            INSERT INTO source_versions (id, logical_source_id, content_hash, valid_from, is_current, created_at,
                filename, detected_type, detection_basis, size_bytes, custody_mode, preservation_status, intake_recorded_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(id), .uuid(id), .text(hex), .real(100), .integer(1), .real(100),
                  .text("f.txt"), .text("txt"), .text("magicBytes"), .integer(1), .text("referenced"),
                  .text("referenceRecorded"), .real(100)])
    }

    private func insertSVJob(_ db: Database, sv: UUID?, kind: String = "structuralExtraction", state: String = "pending",
                             scope: String = "sourceVersion", producer: String = "usf-m3", version: String = "1",
                             lease: SQLValue = .null, leaseExp: SQLValue = .null, priority: Int = 40, maxAttempts: Int = 3,
                             subject: UUID? = nil) async throws {
        try await db.exec("""
            INSERT INTO enrichment_jobs (id, scope_kind, subject_id, source_version_id, kind, priority, origin, state,
                attempts, max_attempts, producer_id, producer_version, not_before, lease_token, lease_expires_at, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [.uuid(UUID()), .text(scope), subject.map { SQLValue.uuid($0) } ?? .null,
                  sv.map { SQLValue.uuid($0) } ?? .null, .text(kind), .integer(Int64(priority)), .text("userRequested"),
                  .text(state), .integer(0), .integer(Int64(maxAttempts)), .text(producer), .text(version), .real(0),
                  lease, leaseExp, .real(100), .real(100)])
    }

    // MARK: - Reach + preservation

    @Test("A fresh database reaches v88 with the upgrade ledger + events table")
    func freshV88() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        #expect(try await db.currentUserVersion() == 88)
        #expect(try await MigrationFixtureBuilder.columns(db, "enrichment_jobs").isSuperset(of: ["scope_kind", "source_version_id", "lease_token", "requested_goal"]))
        #expect(try await MigrationFixtureBuilder.columns(db, "enrichment_job_events").contains("action"))
    }

    @Test("v87→v88 preserves legacy jobs verbatim as legacySubject with a NULL source version")
    func v87ToV88PreservesLegacy() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        let s1 = UUID(), s2 = UUID()
        try await insertLegacyJob(db, subject: s1, kind: "embedding", state: "pending", attempts: 1, error: nil)
        try await insertLegacyJob(db, subject: s2, kind: "ocr", state: "failed", attempts: 2, error: "boom")
        try await SchemaMigrations.migrate(db, through: 88)
        #expect(try await db.currentUserVersion() == 88)
        let rows = try await db.query("SELECT scope_kind, source_version_id, state, attempts, last_error FROM enrichment_jobs WHERE subject_id = ?;", [.uuid(s2)])
        #expect(rows.first?.string(0) == "legacySubject")
        #expect(rows.first?.isNull(1) == true)                 // never guessed
        #expect(rows.first?.string(2) == "failed")
        #expect(rows.first?.int(3) == 2)
        #expect(rows.first?.string(4) == "boom")
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_jobs;", []).first?.int(0) == 2)
    }

    @Test("The self-heal sentinel recognises the v88 ledger")
    func selfHealRecognizesV88() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        try await db.setUserVersion(86)
        try await SchemaMigrations.migrate(db)
        #expect(try await db.currentUserVersion() == SchemaMigrations.latestVersion)
    }

    @Test("Re-running migrate over a v88 database is a safe no-op")
    func v88Repeatable() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await SchemaMigrations.migrate(db, through: 88)
        #expect(try await db.currentUserVersion() == 88)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("An injected failure inside the v88 SAVEPOINT rolls the whole migration back")
    func injectedFailureRollsBack() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 87)
        try await insertLegacyJob(db, subject: UUID(), kind: "embedding", state: "pending", attempts: 0, error: nil)
        await #expect(throws: (any Error).self) {
            try await SchemaMigrations.migrate(db, through: 88, fault: MigrationFaultHarness.hook(throwingAt: .afterSQLBeforeVersionStamp(version: 88)))
        }
        #expect(try await db.currentUserVersion() == 87)
        #expect(try await MigrationFixtureBuilder.columns(db, "enrichment_jobs").contains("scope_kind") == false)   // old shape intact
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_jobs;", []).first?.int(0) == 1)                 // legacy row preserved
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    @Test("Milestone migration from version 0 reaches v88 with a clean FK graph")
    func milestoneReachesV88() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)
        try await SchemaMigrations.migrate(db, through: 88)
        #expect(try await db.currentUserVersion() == 88)
        #expect(try await db.query("PRAGMA foreign_key_check;", []).isEmpty)
        #expect(try await MigrationFaultHarness.integrityOK(db))
    }

    // MARK: - CHECKs

    @Test("Scope integrity: a sourceVersion job requires a source version; a legacySubject job requires a subject")
    func scopeIntegrity() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: nil) }                          // sourceVersion + null sv
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: nil, scope: "legacySubject", subject: nil) }  // legacy + null subject
    }

    @Test("A running job must hold a lease token + expiry")
    func runningRequiresLease() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv)
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: sv, state: "running") }         // no lease
        try await insertSVJob(db, sv: sv, state: "running", lease: .text("tok"), leaseExp: .real(200))         // with lease → accepted
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_jobs WHERE state='running';", []).first?.int(0) == 1)
    }

    @Test("An out-of-vocabulary state or priority/max_attempts is rejected")
    func vocabularyAndBoundsChecks() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv)
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: sv, state: "queued") }          // bad state
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: sv, priority: -1) }             // bad priority
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: sv, maxAttempts: 0) }           // bad max_attempts
    }

    @Test("At most one ACTIVE sourceVersion job per exact work identity")
    func activeSourceVersionIdempotency() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv)
        try await insertSVJob(db, sv: sv, kind: "ocr", state: "pending")
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: sv, kind: "ocr", state: "pending") }   // duplicate active
        // A DONE job does not block a fresh pending one (re-request after completion is allowed).
        try await db.exec("UPDATE enrichment_jobs SET state='done' WHERE source_version_id = ?;", [.uuid(sv)])
        try await insertSVJob(db, sv: sv, kind: "ocr", state: "pending")
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_jobs WHERE source_version_id = ?;", [.uuid(sv)]).first?.int(0) == 2)
    }

    @Test("Legacy (subject, kind) idempotency is preserved for legacySubject jobs")
    func legacySubjectIdempotency() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        let subj = UUID()
        try await insertSVJob(db, sv: nil, kind: "embedding", scope: "legacySubject", subject: subj)
        await #expect(throws: (any Error).self) {
            try await self.insertSVJob(db, sv: nil, kind: "embedding", scope: "legacySubject", subject: subj)
        }
    }

    @Test("Job events enforce the closed action vocabulary + unique sequence, and cascade on job delete")
    func eventsVocabularyAndCascade() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await db.exec("PRAGMA foreign_keys = ON;")
        let sv = UUID(); try await seedVersion(db, id: sv)
        try await insertSVJob(db, sv: sv, kind: "indexing", state: "pending")
        let jobID = try #require(try await db.query("SELECT id FROM enrichment_jobs WHERE source_version_id = ?;", [.uuid(sv)]).first?.uuid(0))
        func event(_ seq: Int, _ action: String) async throws {
            try await db.exec("INSERT INTO enrichment_job_events (id, job_id, sequence, action, occurred_at) VALUES (?,?,?,?,?);",
                             [.uuid(UUID()), .uuid(jobID), .integer(Int64(seq)), .text(action), .real(1)])
        }
        try await event(1, "enqueue")
        await #expect(throws: (any Error).self) { try await event(1, "claim") }        // duplicate (job_id, sequence)
        await #expect(throws: (any Error).self) { try await event(2, "explode") }       // bad action
        try await event(2, "claim")
        // Deleting the job cascades its events away.
        try await db.exec("DELETE FROM enrichment_jobs WHERE id = ?;", [.uuid(jobID)])
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_job_events WHERE job_id = ?;", [.uuid(jobID)]).first?.int(0) == 0)
    }

    @Test("An admitted sourceVersion job's FK pins it to a real source version")
    func sourceVersionFK() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 88)
        try await db.exec("PRAGMA foreign_keys = ON;")
        await #expect(throws: (any Error).self) { try await insertSVJob(db, sv: UUID()) }   // no such source version
        let sv = UUID(); try await seedVersion(db, id: sv)
        try await insertSVJob(db, sv: sv)                                                   // real version → accepted
        #expect(try await db.query("SELECT COUNT(*) FROM enrichment_jobs WHERE source_version_id = ?;", [.uuid(sv)]).first?.int(0) == 1)
    }
}
