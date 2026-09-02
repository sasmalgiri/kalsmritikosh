//
//  MigrationMatrixTests.swift
//  KalsmritikoshTests
//
//  MIG-001A — inventory and verify representative schema migrations. Builds GENUINE
//  intermediate-version databases from the committed migration history and proves that migrating
//  each material milestone to the latest schema (v67) preserves seeded rows, reaches the correct
//  version, and passes integrity + foreign-key checks — including a repeated-migration stability
//  pass, the stale-user-version self-heal, and a dedicated v66→v67 (add nullable scope) check.
//
//  This suite EXTENDS the existing migration framework; it does not add a runner. It also does not
//  duplicate the existing genuine v61→v62 preservation + interrupted-rollback + retry tests
//  (SchemaMigrationRollbackTests / equivalent) — see MIGRATION_MATRIX.md. Fault injection,
//  malformed partial schemas, low-disk failure and real-archive proof are deferred to MIG-001B.
//

import Foundation
import Testing
@testable import Kalsmritikosh

@Suite("MIG-001A — migration matrix")
struct MigrationMatrixTests {

    /// Material schema boundaries (not every version — these are the migration milestones).
    /// 68 = OPS-001 Issue Engine; 69 = OPS-002 Task/Deadline Engine;
    /// 70 = OPS-002.1 confirmation-authority columns; 71 = OPS-003A SensitiveScope ledger.
    /// 72 = OPS-004 WorkProductRun persistence; 73 = OPS-005 email_participant_occurrences;
    /// 74 = OPS-006 source_reliability_assessments.
    /// TWELFTH AUDIT — the modern era is covered too: 106 (last version the
    /// old self-heal sentinel could distinguish), 107 (conformance ledger),
    /// 111 (governance events + chain recreate), 113 (case_method_runs),
    /// 115 (unbound case_phase_artifacts), 116 (public-chain reset) — the
    /// v116→latest step is the exact path the stale sentinel used to skip.
    /// THIRTEENTH AUDIT — 117 (case-bound phase artifacts) and 118 (recovery
    /// rebuild + answer origin) step to the v119 dataset-origin era.
    static let milestones = [1, 36, 54, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73,
                             106, 107, 111, 113, 115, 116, 117, 118]

    // MARK: - Assertions shared across cases

    private func userVersion(_ db: Database) async throws -> Int { try await db.currentUserVersion() }

    private func integrityOK(_ db: Database) async throws -> Bool {
        let rows = try await db.query("PRAGMA integrity_check;", [])
        return rows.first?.string(0) == "ok"
    }

    private func foreignKeyViolationCount(_ db: Database) async throws -> Int {
        try await db.query("PRAGMA foreign_key_check;", []).count
    }

    /// The distinguishing markers of the fully-applied latest schema.
    private func assertLatestSchemaMarkers(_ db: Database) async throws {
        let claimsCols = try await MigrationFixtureBuilder.columns(db, "claims")
        #expect(claimsCols.isSuperset(of: ["scope_kind", "scope_id"]), "v67 claims scope columns missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "evidence_block_objects"), "v66 ownership table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "claim_projection_progress"), "v65 progress table missing")
        let refCols = try await MigrationFixtureBuilder.columns(db, "claim_evidence_ref")
        #expect(refCols.contains("ordinal"), "v64 ordinal evidence identity missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "professional_issues"), "v68 issue table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "professional_tasks"), "v69 task table missing")
        let reviewCols = try await MigrationFixtureBuilder.columns(db, "professional_task_reviews")
        #expect(reviewCols.isSuperset(of: ["authority_kind", "rule_id", "rule_version"]),
                "v70 confirmation-authority columns missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "sensitive_scope_assignments"),
                "v71 sensitive_scope_assignments table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "sensitive_scope_reviews"),
                "v71 sensitive_scope_reviews table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_product_runs"),
                "v72 work_product_runs table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "email_participant_occurrences"),
                "v73 email_participant_occurrences table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "source_reliability_assessments"),
                "v74 source_reliability_assessments table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_provenance_snapshots"),
                "v77 workflow_provenance_snapshots table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_attachment_bindings"),
                "v77 workflow_attachment_bindings table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "workflow_automation_executions"),
                "v78 workflow_automation_executions table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_center_documents"),
                "v105 work_center_documents table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_center_counters"),
                "v105 work_center_counters table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "work_center_record_edits"),
                "v106 work_center_record_edits table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "conformance_assessments"),
                "v107 conformance_assessments table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "protocol_registry"),
                "v108 protocol_registry table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "protocol_review_records"),
                "v108 protocol_review_records table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "governance_events"),
                "v111 governance_events table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "case_method_runs"),
                "v113 case_method_runs table missing")
        #expect(try await MigrationFixtureBuilder.tableExists(db, "case_phase_artifacts"),
                "v115/v117 case_phase_artifacts table missing")
        // v117 — the phase-artifact ledger is case-bound: revision + scope
        // fingerprint columns must exist after a full migrate.
        let cpaCols = try await db.query("PRAGMA table_info(case_phase_artifacts);", [])
            .compactMap { $0.string(1) }
        #expect(cpaCols.contains("case_revision") && cpaCols.contains("scope_fingerprint"),
                "v117 case binding columns missing")
        // v116 resets pre-rule-v2 public links: after a full migrate, no row
        // may carry a public hash computed under the v114 payload-only rule.
        let v1Links = try await db.query(
            "SELECT COUNT(*) FROM audit_chain WHERE public_hash IS NOT NULL;", [])
        #expect((v1Links.first?.int(0) ?? -1) == 0, "v116 must reset v114-rule public links")
    }

    private func assertHealthyLatest(_ db: Database) async throws {
        #expect(try await userVersion(db) == SchemaMigrations.latestVersion)
        try await assertLatestSchemaMarkers(db)
        #expect(try await integrityOK(db), "PRAGMA integrity_check not ok")
        #expect(try await foreignKeyViolationCount(db) == 0, "PRAGMA foreign_key_check reported violations")
    }

    // MARK: - Fresh database

    @Test("The migration list is gap-free and a fresh database reaches the latest schema")
    func freshDatabaseReachesLatest() async throws {
        #expect(SchemaMigrations.migrationListIsConsistent)     // 1...latestVersion, gap-free
        #expect(SchemaMigrations.latestVersion == 121)          // v120 v1.1 Stage-1 column batch · v121 V2 capture-group provenance (raw_match, source_count)
        let db = try await MigrationFixtureBuilder.database(atVersion: 0)   // unmigrated
        #expect(try await userVersion(db) == 0)
        try await SchemaMigrations.migrate(db)                  // full migrate
        try await assertHealthyLatest(db)
    }

    // MARK: - Each milestone → latest, with preservation + reopen

    @Test("Every representative milestone version migrates to latest, preserving seeded rows",
          arguments: MigrationMatrixTests.milestones)
    func milestoneMigratesToLatest(_ version: Int) async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: version, at: url)
        #expect(try await userVersion(db) == version)

        // Seed version-valid preservation rows (era-safe: only tables/columns that exist at `version`).
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: version)

        // Migrate to the latest schema.
        try await SchemaMigrations.migrate(db)
        try await assertHealthyLatest(db)

        // Every seeded row survived (counts unchanged).
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "preservation failures after migrate: \(failures)")

        // Reopen the SAME file with a fresh Database instance and re-verify (durability).
        let reopened = try MigrationFixtureBuilder.reopen(at: url)
        #expect(try await userVersion(reopened) == SchemaMigrations.latestVersion)
        let failuresAfterReopen = try await snap.failures(in: reopened)
        #expect(failuresAfterReopen.isEmpty, "preservation failures after reopen: \(failuresAfterReopen)")
    }

    /// TWELFTH AUDIT P0 — the exact defect: a real v116 database must
    /// actually RECEIVE the case-binding rebuild (the stale-counter
    /// self-heal used to stamp v117 without running it, because the
    /// sentinel had no post-v106 markers). Unbound v115-shape rows are
    /// dropped; the bound shape + constraints exist after reopening.
    @Test("A real v116 database receives the case-binding rebuild; unbound rows are dropped")
    func v116ReceivesCaseBindingRebuild() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 116, at: url)
        // v115 unbound shape at this point — seed an unbound row.
        try await db.exec("""
        INSERT INTO case_phase_artifacts (id, case_id, phase_kind, artifact_id, detail, created_at)
        VALUES (?, ?, 'ask', ?, 'question=dead', 1.0);
        """, [.uuid(UUID()), .uuid(UUID()), .uuid(UUID())])
        try await SchemaMigrations.migrate(db)
        try await assertHealthyLatest(db)
        // The unbound row is GONE and the bound shape + constraints exist.
        let reopened = try MigrationFixtureBuilder.reopen(at: url)
        #expect(try await userVersion(reopened) == SchemaMigrations.latestVersion)
        let count = try await reopened.query("SELECT COUNT(*) FROM case_phase_artifacts;", []).first?.int(0)
        #expect(count == 0, "pre-binding rows cannot be trusted retroactively — they must be dropped")
        let sql = try await reopened.query(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='case_phase_artifacts';", [])
            .first?.string(0) ?? ""
        #expect(sql.contains("UNIQUE(phase_kind, artifact_id)"))
        #expect(sql.contains("REFERENCES investigation_cases(id)"))
        #expect(sql.contains("scope_fingerprint"))
    }

    /// TWELFTH AUDIT P0 — field recovery: a database WRONGLY stamped v117
    /// by the old sentinel (schema still v116-shaped) must be repaired by
    /// v118's fail-closed rebuild, not skipped again.
    @Test("A database wrongly stamped v117 by the stale sentinel is repaired by v118")
    func wronglyStampedV117Recovers() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: 116, at: url)
        try await db.setUserVersion(117)   // the field state the old sentinel produced
        try await SchemaMigrations.migrate(db)
        try await assertHealthyLatest(db)
        let cols = try await db.query("PRAGMA table_info(case_phase_artifacts);", [])
            .compactMap { $0.string(1) }
        #expect(cols.contains("case_revision") && cols.contains("scope_fingerprint"),
                "v118 must rebuild the bound shape even when v117 was skipped")
    }

    // MARK: - Repeated migration is idempotent + non-destructive

    @Test("Migrating an already-current database repeatedly is stable (no dup / regression / loss)")
    func repeatedMigrationIsStable() async throws {
        let url = MigrationFixtureBuilder.newTemporaryURL()
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion, at: url)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: SchemaMigrations.latestVersion)

        for _ in 0..<3 {
            let d = try MigrationFixtureBuilder.reopen(at: url)
            try await SchemaMigrations.migrate(d)
            #expect(try await userVersion(d) == SchemaMigrations.latestVersion)   // never regresses
        }
        // No duplication / no loss: every seeded row is still present exactly once.
        let final = try MigrationFixtureBuilder.reopen(at: url)
        let failures = try await snap.failures(in: final)
        #expect(failures.isEmpty, "repeated migration changed row counts: \(failures)")
        try await assertHealthyLatest(final)
    }

    // MARK: - Stale user_version self-heals (non-destructive)

    @Test("A stale user_version counter self-heals to latest without destructive replay")
    func staleUserVersionSelfHeals() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: SchemaMigrations.latestVersion)
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: SchemaMigrations.latestVersion)

        // Full v67 schema present, but the counter is stuck early (the observed field condition).
        try await db.setUserVersion(2)
        #expect(try await userVersion(db) == 2)

        try await SchemaMigrations.migrate(db)                  // self-heal path

        #expect(try await userVersion(db) == SchemaMigrations.latestVersion)   // healed
        try await assertLatestSchemaMarkers(db)
        let failures = try await snap.failures(in: db)          // rows retained, not re-applied
        #expect(failures.isEmpty, "self-heal altered seeded rows: \(failures)")
    }

    // MARK: - Previous version (v66 → v67): additive nullable scope, nothing invented

    @Test("v66→v67 preserves an existing Claim + evidence/review/usage and adds NULL scope columns")
    func v66ToV67AddsNullScope() async throws {
        let db = try await MigrationFixtureBuilder.database(atVersion: 66)
        #expect(try await userVersion(db) == 66)
        // At v66 the claims table has no scope columns; the seed is a plain (conceptually entity-
        // scoped) claim + its evidence ref + review + usage.
        let snap = try await MigrationFixtureBuilder.seedPreservationRows(into: db, forVersion: 66)
        #expect(try await MigrationFixtureBuilder.columns(db, "claims").isDisjoint(with: ["scope_kind", "scope_id"]))

        try await SchemaMigrations.migrate(db)                  // 66 → 67

        try await assertHealthyLatest(db)
        // Claim + evidence + review + usage all unchanged.
        let failures = try await snap.failures(in: db)
        #expect(failures.isEmpty, "v66→v67 lost a preserved row: \(failures)")
        // Scope columns now exist AND the migrated claim's scope is NULL (migration invents nothing).
        let cols = try await MigrationFixtureBuilder.columns(db, "claims")
        #expect(cols.isSuperset(of: ["scope_kind", "scope_id"]))
        let scoped = try await db.query("SELECT COUNT(*) FROM claims WHERE scope_kind IS NOT NULL OR scope_id IS NOT NULL;", [])
        #expect(Int(scoped.first?.int(0) ?? -1) == 0, "migration invented a scope value")
    }
}
