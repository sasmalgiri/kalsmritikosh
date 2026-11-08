//
//  SchemaMigrations.swift
//  Kalsmritikosh
//
//  Versioned DDL for the 11 SQLite tables. Each migration bumps
//  PRAGMA user_version and is applied exactly once. Adding a new
//  migration is a pure append — never edit an existing one.
//

import Foundation
import os

/// A test-only injection point inside the migration transaction. Production migration ALWAYS
/// passes a nil hook, so these points have no effect on shipping behaviour; the migration
/// semantics (SAVEPOINT → SQL → stamp → RELEASE, rollback on failure) are identical whether or not
/// a hook is present. A test supplies a hook via the internal `fault:` overloads to prove
/// atomicity at each boundary (MIG-001B).
enum MigrationFaultPoint: Sendable, Equatable {
    case beforeSavepoint(version: Int)
    case afterSavepoint(version: Int)
    case afterSQLBeforeVersionStamp(version: Int)
    case afterVersionStampBeforeRelease(version: Int)
}

/// Injected per-migration hook. INTERNAL (not shipping API) — tests reach it via `@testable
/// import`. Passed explicitly (never a global/static), so concurrent tests cannot affect one
/// another. Production passes `nil`.
typealias MigrationFaultHook = @Sendable (MigrationFaultPoint) async throws -> Void

public enum SchemaMigrations {

    public static let latestVersion = 183

    /// True when the registered migration list is internally consistent: a
    /// gap-free `1...latestVersion` sequence whose head equals `latestVersion`.
    /// This is the real integrity invariant — it verifies the migrations match
    /// the declared latest WITHOUT a hardcoded "expected version" constant that
    /// has to be bumped by hand on every schema change (that constant is what
    /// caused the ReleaseReadiness "schema desynced" false alarm).
    public static var migrationListIsConsistent: Bool {
        all.map(\.0) == Array(1...latestVersion)
    }

    /// Apply every migration newer than the current `user_version`. Each
    /// migration runs inside a SAVEPOINT so a partial DDL failure leaves
    /// the schema at the previous version instead of half-applied.
    public static func migrate(_ database: Database) async throws {
        try await migrate(database, through: latestVersion)
    }

    /// Apply every migration in `(current, targetVersion]`. The public `migrate` calls
    /// this with `latestVersion`; tests use a smaller target to build a genuine
    /// intermediate-version database (e.g. a real v61 DB) and then step to the next.
    /// Only a full migration to `latestVersion` performs the stale-counter self-heal /
    /// final stamp — a targeted partial migration leaves the counter exactly where its
    /// last applied migration put it.
    static func migrate(_ database: Database, through targetVersion: Int,
                        fault: MigrationFaultHook? = nil) async throws {
        let current = try await database.currentUserVersion()
        // T2 — a ledger written by a newer version of the app is never opened by this one: its tables
        // and rules are not ones this build knows, and writing to it could break them. Nothing is changed.
        if targetVersion == latestVersion, current > latestVersion {
            throw DatabaseError.migrationFailed(version: current, message:
                "This ledger was written by a newer version of the app (schema \(current); this version reads up to \(latestVersion)). Update the app to open it. The ledger was not changed.")
        }
        // Self-heal a stale counter. Observed in the field: some databases carry
        // a fully-applied latest schema while `user_version` is stuck at an early
        // value. Blindly re-running the pending migrations would fail (bare CREATE
        // TABLE would raise "table already exists"). So: if the counter looks stale
        // BUT the full latest schema is already present, reconcile and return. Only
        // when migrating all the way to latest (not a targeted partial migration).
        if targetVersion == latestVersion, current < latestVersion,
           try await isSchemaFullyApplied(database) {
            try await database.setUserVersion(latestVersion)
            try await repairIdempotentMigrations(database)
            return
        }
        let pending = all.filter { $0.0 > current && $0.0 <= targetVersion }
        if !pending.isEmpty {
            // Disable foreign-key enforcement for the whole migration pass — the
            // SQLite-recommended pattern for table rebuilds (a `DROP TABLE` on a
            // parent otherwise fires ON DELETE CASCADE on its children, and FK
            // enforcement cannot be toggled inside the per-migration SAVEPOINT).
            // A single OUTER savepoint wraps EVERY pending migration AND the final
            // PRAGMA foreign_key_check, so the whole pass is atomic: a post-pass FK
            // violation (or any migration failure) rolls back all applied DDL *and*
            // every user_version stamp together — the database is never left committed
            // at a newer version while the operation reports failure. Enforcement is
            // always restored, including on the failure path. (PM-004.1 hardening: the
            // check formerly ran AFTER each migration had already released its own
            // savepoint, so a failing check could not undo the committed migrations.)
            try await database.exec("PRAGMA foreign_keys=OFF;")
            let pass = "kalsmritikosh_mig_pass"
            do {
                try await database.exec("SAVEPOINT \(pass);")
                for (version, sql) in pending {
                    try await applyOne(database, version: version, sql: sql, fault: fault)
                }
                let violations = try await database.query("PRAGMA foreign_key_check;", [])
                if !violations.isEmpty {
                    throw DatabaseError.migrationFailed(
                        version: targetVersion,
                        message: "foreign_key_check reported \(violations.count) violation(s) after migration")
                }
                try await database.exec("RELEASE SAVEPOINT \(pass);")
            } catch {
                try? await database.exec("ROLLBACK TO SAVEPOINT \(pass);")
                try? await database.exec("RELEASE SAVEPOINT \(pass);")
                try? await database.exec("PRAGMA foreign_keys=ON;")
                throw error
            }
            try await database.exec("PRAGMA foreign_keys=ON;")
        }
        // Belt-and-suspenders: after a fully-successful migration pass, stamp the
        // final version ONCE outside any SAVEPOINT (some WAL configs were observed
        // NOT to persist a PRAGMA user_version issued inside a SAVEPOINT). Only when
        // targeting latest; never downgrades a newer DB opened by an older build.
        if targetVersion == latestVersion,
           try await database.currentUserVersion() < Self.latestVersion {
            try await database.setUserVersion(Self.latestVersion)
        }
        if targetVersion == latestVersion { try await repairIdempotentMigrations(database) }
    }

    /// Names of the tables a migration creates (`CREATE TABLE [IF NOT EXISTS] name`).
    static func createdTables(inMigration version: Int) -> [String] {
        guard let sql = migrationSQL(for: version),
              let re = try? NSRegularExpression(pattern: #"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_][A-Za-z0-9_]*)"#,
                                                options: [.caseInsensitive]) else { return [] }
        let ns = sql as NSString
        return re.matches(in: sql, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { !$0.hasSuffix("__new") && !$0.contains("__v") }
    }

    /// The (table, column) pairs a migration adds with `ALTER TABLE … ADD COLUMN …` — so a migration that
    /// only adds columns still gives the self-heal sentinel something to check (v162, 2026-10-28).
    static func addedColumns(inMigration version: Int) -> [(table: String, column: String)] {
        guard let sql = migrationSQL(for: version),
              let re = try? NSRegularExpression(pattern: #"ALTER\s+TABLE\s+"?([A-Za-z_][A-Za-z0-9_]*)"?\s+ADD\s+COLUMN\s+"?([A-Za-z_][A-Za-z0-9_]*)"?"#,
                                                options: [.caseInsensitive]) else { return [] }
        let ns = sql as NSString
        return re.matches(in: sql, range: NSRange(location: 0, length: ns.length))
            .map { (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2))) }
            .filter { !$0.0.hasSuffix("__new") && !$0.0.contains("__v") }
    }

    /// A migration is safe to re-run when every top-level statement is a `CREATE … IF NOT EXISTS`
    /// (tables, indexes, triggers) — no ALTER, DROP, rename or data change outside a trigger body.
    static func isIdempotent(_ sql: String) -> Bool {
        // Remove trigger bodies: their INSERT/UPDATE only run on future writes.
        let withoutBodies = sql.replacingOccurrences(of: #"(?is)\bBEGIN\b.*?\bEND\s*;"#, with: "END;",
                                                     options: .regularExpression)
        let statements = withoutBodies.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "END" && !$0.hasPrefix("--") }
        guard !statements.isEmpty else { return false }
        return statements.allSatisfy { st in
            let lines = st.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("--") }
            let head = lines.joined(separator: " ").uppercased()
            return head.range(of: #"^CREATE\s+(UNIQUE\s+)?(TABLE|INDEX|TRIGGER|VIEW)\s+IF\s+NOT\s+EXISTS\b"#, options: .regularExpression) != nil
        }
    }

    /// Repair pass (2026-10-23): ledgers stamped past a migration by the old self-heal check may be
    /// missing that migration's tables. Re-running every IDEMPOTENT migration from v119 on is a
    /// no-op on a correct ledger and creates whatever is missing on a mis-stamped one. Nothing is
    /// altered or dropped. Non-idempotent migrations are not touched (they can't be re-run safely).
    static func repairIdempotentMigrations(_ database: Database) async throws {
        for (version, sql) in all where version >= 119 && isIdempotent(sql) {
            let sp = "kalsmritikosh_repair_v\(version)"
            do {
                try await database.exec("SAVEPOINT \(sp);")
                try await database.exec(sql)
                try await database.exec("RELEASE SAVEPOINT \(sp);")
            } catch {
                try? await database.exec("ROLLBACK TO SAVEPOINT \(sp);")
                try? await database.exec("RELEASE SAVEPOINT \(sp);")
                KalsmritikoshLog.storage.error("Schema repair v\(version) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Apply one migration inside its own SAVEPOINT so a partial DDL failure rolls the
    /// whole statement batch back (SQLite DDL is transactional) and leaves the schema +
    /// `user_version` at the previous version. Internal so a test can drive a
    /// deliberately-failing migration and assert clean rollback.
    static func applyOne(_ database: Database, version: Int, sql: String,
                         fault: MigrationFaultHook? = nil) async throws {
        let savepoint = "kalsmritikosh_mig_v\(version)"
        // `beforeSavepoint`: nothing has been opened yet, so a fault here just fails the migration
        // with no schema/data change and nothing to roll back. Production hook is nil (no-op).
        if let fault {
            do { try await fault(.beforeSavepoint(version: version)) }
            catch { throw DatabaseError.migrationFailed(version: version, message: "\(error)") }
        }
        do {
            try await database.exec("SAVEPOINT \(savepoint);")
            if let fault { try await fault(.afterSavepoint(version: version)) }
            try await database.exec(sql)
            if let fault { try await fault(.afterSQLBeforeVersionStamp(version: version)) }
            try await database.setUserVersion(version)
            // `afterVersionStampBeforeRelease`: proves the version stamp shares the SAVEPOINT with
            // the DDL — a fault here must roll BOTH back, leaving the previous version.
            if let fault { try await fault(.afterVersionStampBeforeRelease(version: version)) }
            try await database.exec("RELEASE SAVEPOINT \(savepoint);")
        } catch {
            try? await database.exec("ROLLBACK TO SAVEPOINT \(savepoint);")
            try? await database.exec("RELEASE SAVEPOINT \(savepoint);")
            throw DatabaseError.migrationFailed(version: version, message: "\(error)")
        }
    }

    /// The DDL for a given migration version (internal — used by migration tests to
    /// drive a real v62 batch with an injected failure).
    static func migrationSQL(for version: Int) -> String? {
        all.first { $0.0 == version }?.1
    }

    /// True when the LATEST migration's marker already exists — i.e. the schema
    /// is fully applied even if `user_version` disagrees. Because migrations are
    /// ordered and append-only, the newest marker's presence implies every
    /// earlier object exists too. UPDATE THIS SENTINEL whenever a new migration
    /// is added, to the newest object it creates (a table or, as here, a column).
    /// True only when the FULL v62 shape is present. v62 adds columns to three tables,
    /// so probe the complete required set — a single column is NOT sufficient proof that
    /// every v62 statement completed. Under normal SAVEPOINT rollback the migration is
    /// atomic; this stricter check protects the self-heal path from stamping the counter
    /// to 62 over a schema that only partially matches. UPDATE when a new migration adds
    /// objects, to the newest complete shape.
    private static func isSchemaFullyApplied(_ database: Database) async throws -> Bool {
        let required: [String: Set<String>] = [
            "generic_facts":   ["evidence_basis", "review_disposition", "proposal_origin",
                                 "availability_status", "conflict_status", "legacy_status"],
            "temporal_claims": ["evidence_basis", "review_disposition", "proposal_origin",
                                 "availability_status", "conflict_status", "legacy_status"],
            "history_items":   ["evidence_basis", "review_disposition", "proposal_origin",
                                 "availability_status", "legacy_status"],
            // v63 — the shared Claim engine's canonical table (+ v67 explicit scope columns).
            "claims":          ["id", "subject_id", "statement", "evidence_basis",
                                 "review_disposition", "proposal_origin", "availability_status",
                                 "conflict_status", "legacy_status", "created_at",
                                 "scope_kind", "scope_id"],
            // v64 — evidence-ref rebuilt with an ordinal identity.
            "claim_evidence_ref": ["claim_id", "ordinal", "knowledge_object_id", "evidence_role"],
            // v65 — durable claim-projection progress.
            "claim_projection_progress": ["producer_version", "source_kind", "last_source_id", "complete"],
            // v66 — canonical EvidenceBlock → KnowledgeObject ownership.
            "evidence_block_objects": ["evidence_block_id", "knowledge_object_id", "linked_at"],
            // v68 — shared professional Issue Engine (OPS-001).
            "professional_issues": ["id", "workspace_id", "title", "issue_type", "status",
                                     "priority", "created_at", "updated_at"],
            "professional_issue_links": ["id", "issue_id", "target_kind", "target_id", "link_role"],
            "professional_issue_reviews": ["id", "issue_id", "action", "reviewer", "reviewed_at"],
            // v69 — shared Task and Deadline Engine (OPS-002).
            "professional_tasks": ["id", "workspace_id", "title", "task_type", "status",
                                    "priority", "origin", "created_at", "updated_at"],
            "deadline_candidates": ["id", "task_id", "due_date", "precision", "time_zone",
                                     "deadline_kind", "origin", "status", "created_at"],
            "deadlines": ["id", "task_id", "due_date", "precision", "time_zone", "deadline_kind",
                           "status", "confirmation_kind", "confirmed_by", "confirmed_at", "created_at"],
            // v70 — structured confirmation authority on the task review ledger (OPS-002.1).
            "professional_task_reviews": ["id", "task_id", "action", "reviewer", "reviewed_at",
                                           "authority_kind", "rule_id", "rule_version"],
            // v71 — shared SensitiveScope protection ledger (OPS-003A).
            "sensitive_scope_assignments": ["id", "target_kind", "target_id", "sensitivity",
                                             "privileged", "origin", "assigned_by", "created_at"],
            // v72 — WorkProductRun persistence (OPS-004).
            "work_product_runs": ["id", "workspace_id", "template", "title",
                                   "subject_label", "schema_version", "app_version", "composed_at"],
            // v73 — email participant occurrence ledger (OPS-005).
            "email_participant_occurrences": ["id", "source_ko_id", "entity_id", "role", "raw_address"],
            // v74 — shared source reliability assessment ledger (OPS-006).
            "source_reliability_assessments": ["id", "source_version_id", "reliability", "independence",
                                                "assessed_at", "created_at"],
            // v75 — persistent workflow run ledger (PJE-003). Check all 7 new tables.
            "workflow_runs": ["id", "workspace_id", "application_definition_id", "workflow_definition_id",
                               "status", "contract_snapshot_json", "contract_snapshot_sha256",
                               "snapshot_schema_version", "revision", "created_at", "updated_at"],
            // v76 — state_hash_semantics (PJE-006B.1); v77 — provenance_semantics (PJE-007).
            // Every migration MUST add its newest physical marker here, or the self-heal
            // path can stamp user_version over a schema missing that migration's shape.
            "workflow_step_runs": ["id", "run_id", "step_definition_id", "step_kind",
                                    "attempt", "sequence", "status", "state_sha256",
                                    "state_hash_semantics", "provenance_semantics", "entered_at"],
            // v77 — provenance bridge tables (PJE-007): the NEWEST markers.
            "workflow_provenance_snapshots": ["id", "workflow_run_id", "owner_kind",
                                               "step_run_id", "artifact_id", "decision_id",
                                               "workflow_run_revision", "producer_id",
                                               "producer_version", "snapshot_json",
                                               "snapshot_sha256", "created_at"],
            "workflow_provenance_references": ["id", "snapshot_id", "ordinal", "reference_kind",
                                                "canonical_object_id", "role", "disposition",
                                                "created_at"],
            "workflow_attachment_bindings": ["artifact_id", "logical_source_id",
                                              "source_version_id", "display_name",
                                              "source_content_sha256", "created_at"],
            "workflow_decisions": ["id", "run_id", "step_run_id", "decision_key",
                                    "kind", "selected_option", "actor_kind", "decided_at"],
            "workflow_artifacts": ["id", "run_id", "artifact_definition_id", "kind", "label", "created_at"],
            "workflow_checkpoints": ["id", "run_id", "run_revision", "reason",
                                      "snapshot_json", "snapshot_sha256", "created_at"],
            "workflow_attention_items": ["id", "run_id", "source_kind", "severity", "status",
                                          "title", "created_at"],
            "workflow_run_events": ["id", "run_id", "sequence", "run_revision", "type",
                                     "actor_kind", "payload_json", "occurred_at"],
            // v78 — automation execution ledger (PJE-010).
            "workflow_automation_executions": ["id", "workspace_id", "application_definition_id",
                                                "automation_definition_id", "automation_definition_version",
                                                "trigger_kind", "trigger_event_key", "action_kind",
                                                "idempotency_key", "request_sha256", "status", "started_at"],
            // v79 — professional method run-state ledger (PM-002).
            "method_nodes": ["id", "method_run_id", "node_definition_key", "node_kind", "label",
                              "working_state", "ordinal", "parent_node_id", "created_at", "updated_at"],
            "method_edges": ["id", "method_run_id", "from_node_id", "to_node_id", "edge_kind", "ordinal"],
            "method_assumptions": ["id", "method_run_id", "node_id", "statement", "status",
                                    "created_by", "reviewed_by", "reviewed_at"],
            "method_findings": ["id", "method_run_id", "node_id", "statement", "finding_kind",
                                 "support_status", "review_status", "related_claim_id", "created_at"],
            // v80 — method lifecycle (PM-004): the NEWEST markers (content_revision,
            // input_role, review_key/reviewed_content_revision, validation batch, events).
            // Every migration MUST add its newest physical marker here, or the self-heal
            // path can stamp user_version over a schema missing that migration's shape.
            "method_runs": ["id", "workspace_id", "method_definition_id", "method_definition_version",
                             "workflow_run_id", "workflow_step_run_id", "status", "revision",
                             "content_revision", "created_by", "created_at", "updated_at", "superseded_by_run_id"],
            "method_evidence_links": ["id", "method_run_id", "node_id", "target_kind", "target_id",
                                       "role", "input_role", "ordinal", "added_by", "added_at"],
            "method_reviews": ["id", "method_run_id", "node_id", "finding_id", "review_key",
                                "reviewed_content_revision", "action", "actor_kind", "actor_identifier", "reviewed_at"],
            "method_validation_results": ["id", "method_run_id", "validator_id", "validator_version",
                                           "severity", "code", "message", "subject_kind", "subject_id",
                                           "validation_batch_id", "evaluated_content_revision", "created_at"],
            "method_run_events": ["id", "method_run_id", "sequence", "run_revision", "content_revision",
                                   "action", "from_status", "to_status", "actor_kind", "occurred_at"],
            // v82 — universal safe intake (USF-001): source_versions gains intake custody
            // metadata (NEW columns, so the column probe distinguishes v82 from v81), plus
            // two new tables and the version-linked ingest-attempt columns. These are the
            // NEWEST markers — every future migration MUST add its newest physical marker.
            "source_versions": ["id", "logical_source_id", "document_id", "content_hash", "supersedes",
                                 "valid_from", "valid_to", "is_current", "original_url", "created_at",
                                 "filename", "declared_extension", "detected_type", "mime_type",
                                 "detection_basis", "size_bytes", "modified_at", "custody_mode",
                                 "preservation_status", "vault_address", "intake_recorded_at"],
            "source_intake_receipts": ["id", "occurrence_file_id", "logical_source_id", "source_version_id",
                                        "outcome", "original_url", "content_hash", "custody_mode",
                                        "preservation_status", "detail", "recorded_at"],
            "source_version_relations": ["id", "parent_source_version_id", "child_source_version_id",
                                          "relation", "ordinal", "created_at"],
            "ingest_file_attempts": ["id", "url", "content_hash", "status", "stage", "detail",
                                      "attempted_at", "logical_source_id", "source_version_id"],
            // v85 — USF-002 independent source readiness dimensions (NEW tables, so the column
            // probe distinguishes v85 from v84). These are the NEWEST markers — every future
            // migration MUST add its newest physical marker here.
            "source_readiness_aggregates": ["source_version_id", "revision", "event_sequence",
                                             "created_at", "updated_at"],
            "source_readiness_dimensions": ["source_version_id", "dimension", "state", "applicability",
                                            "condition", "completed_units", "total_units", "producer_id",
                                            "producer_version", "basis_kind", "basis_identifier", "revision"],
            "source_readiness_events": ["id", "source_version_id", "sequence", "aggregate_revision",
                                        "dimension", "action", "from_state", "to_state", "occurred_at"],
            // v86 — USF-002.1 exact-version chunk ownership (NEW column on chunks, so the column
            // probe distinguishes v86 from v85).
            "chunks": ["id", "object_id", "ordinal", "text", "evidence_block_id", "source_version_id"],
            // v87 — USF-M2 container coverage projection (NEW tables, so the column probe
            // distinguishes v87 from v86). These are the NEWEST markers — every future migration
            // MUST add its newest physical marker here.
            "container_manifests": ["source_version_id", "revision", "container_type", "inspector_id",
                                     "inspector_version", "policy_version", "status", "total_entries",
                                     "regular_file_entries", "admitted_members", "blocked_members",
                                     "unsupported_members", "failed_members", "declared_uncompressed_bytes",
                                     "created_at", "updated_at"],
            "container_members": ["id", "parent_source_version_id", "ordinal", "member_path",
                                   "normalized_member_path", "entry_kind", "compressed_size",
                                   "uncompressed_size", "detected_type", "disposition",
                                   "child_source_version_id", "content_hash", "detail",
                                   "created_at", "updated_at"],
            // v88 — USF-M3 progressive upgrade ledger (enrichment_jobs REBUILT with new columns, so the
            // column probe distinguishes v88 from v87; enrichment_job_events is a NEW table). NEWEST markers.
            "enrichment_jobs": ["id", "scope_kind", "subject_id", "source_version_id", "kind",
                                 "target_dimension", "requested_goal", "priority", "origin", "state",
                                 "attempts", "max_attempts", "producer_id", "producer_version",
                                 "not_before", "lease_token", "lease_expires_at", "completed_at"],
            "enrichment_job_events": ["id", "job_id", "sequence", "action", "from_state", "to_state",
                                       "detail", "occurred_at"],
            // v89 — AEE-M2 progressive answer revision ledger (NEW tables + NEW columns on the
            // existing answers/answer_claims, so the column probe distinguishes v89 from v88).
            // These are the NEWEST markers — every future migration MUST add its newest here.
            "answer_revisions": ["id", "answer_id", "revision_number", "body", "answer_state",
                                  "confidence", "source", "content_hash", "correction_of_revision_id",
                                  "correction_reason", "correction_reason_kind", "created_at"],
            "answer_revision_events": ["id", "answer_id", "sequence", "revision_id", "state",
                                        "detail", "created_at"],
            "answer_claims": ["id", "answer_id", "claim_text", "support_status", "confidence",
                               "ordinal", "created_at", "revision_id"],
            "answers": ["id", "question", "answer_state", "corpus_snapshot_id", "body", "confidence",
                         "source", "created_at", "request_id", "mission_lane", "mission_objective",
                         "mission_deliverable", "is_terminal", "updated_at",
                         // v118 — the producing request's bounded scope (answer ORIGIN).
                         "origin_scope_id"],
            // v90 — MMI typed identity/document fields (NEW table, so the column probe distinguishes
            // v90 from v89).
            "typed_fields": ["id", "source_version_id", "evidence_block_id", "field_type", "raw_value",
                              "normalized_value", "confidence", "extraction_method", "locator",
                              "ocr_confidence", "bounding_box", "producer_id", "producer_version", "created_at"],
            // v91 — TBJ-FINAL time-bounded job planning envelope (three NEW tables, so the column probe
            // distinguishes v91 from v90). A Job REFERENCES existing task/deadline/workflow authorities —
            // it is NOT a second task or deadline system. These are the NEWEST markers — every future
            // migration MUST add its newest physical marker here.
            "job_objectives": ["id", "workspace_id", "title", "objective_detail", "budget_basis",
                                "budget_seconds", "budget_deadline_id", "budget_workflow_run_id",
                                "primary_workflow_run_id", "lifecycle", "revision", "created_at",
                                "updated_at", "closed_at", "closure_reason"],
            "job_plan_references": ["id", "job_id", "reference_kind", "reference_id", "workflow_run_id",
                                     "role", "is_minimum_deliverable", "ordinal", "note", "created_at"],
            "job_events": ["id", "job_id", "sequence", "job_revision", "action", "actor", "detail", "occurred_at"],
            // v92 — LAB-001 canonical Workbench dataset model (seven NEW tables, so the column probe
            // distinguishes v92 from v91). The ONE canonical DataLab dataset authority; the legacy
            // evidence_datasets/dataset_rows prototype is superseded (kept decode-only for compat).
            // These are the NEWEST markers — every future migration MUST add its newest physical marker.
            // (+ v119 origin_case_id — the immutable case origin of a case-produced dataset,
            // thirteenth audit; its presence distinguishes v119 from v118.)
            "workbench_datasets": ["id", "workspace_id", "title", "mode", "revision", "created_at",
                                   "updated_at", "origin_case_id"],
            "workbench_fields": ["id", "dataset_id", "name", "value_shape", "ordinal", "created_at"],
            "workbench_rows": ["id", "dataset_id", "ordinal", "created_at"],
            "workbench_cells": ["id", "dataset_id", "row_id", "field_id", "kind", "value", "status", "created_at"],
            "workbench_source_bindings": ["id", "cell_id", "target_kind", "target_id", "source_version_id",
                                           "locator_json", "ordinal", "created_at"],
            "workbench_saved_views": ["id", "dataset_id", "name", "projection_json", "created_at"],
            "workbench_dataset_events": ["id", "dataset_id", "sequence", "dataset_revision", "action",
                                          "actor", "detail", "occurred_at"],
            // v93 — LAB-002 safe transformation engine (three NEW tables, so their presence
            // distinguishes v93 from v92 by the column probe alone — no stored-SQL sentinel needed
            // for the co-migrated workbench_dataset_events CHECK rebuild that adds 'transformed').
            // These are the NEWEST markers — every future migration MUST add its newest physical marker.
            "workbench_transformations": ["id", "dataset_id", "sequence", "kind", "formula_text",
                                           "engine_version", "spec_json", "target_field_id", "result_json",
                                           "actor", "created_at"],
            "workbench_derivations": ["id", "transformation_id", "dataset_id", "output_cell_id",
                                       "result_key", "output_value", "created_at"],
            "workbench_derivation_inputs": ["id", "derivation_id", "input_cell_id", "ordinal"],
            // v94 — LAB-003 scenario overlays (four NEW tables, so their presence distinguishes v94 from
            // v93 by the column probe alone). A scenario is a non-destructive overlay: an append-only
            // operation log + undo/redo pointer + reviewed-promotion ledger, never a canonical mutation.
            // These are the NEWEST markers — every future migration MUST add its newest physical marker.
            "workbench_scenarios": ["id", "dataset_id", "base_dataset_revision", "title", "status",
                                     "current_op_seq", "revision", "actor", "created_at", "updated_at"],
            "workbench_scenario_operations": ["id", "scenario_id", "sequence", "kind", "target_kind",
                                               "row_id", "field_id", "before_value", "after_value",
                                               "reason", "status", "actor", "created_at"],
            "workbench_scenario_reviews": ["id", "scenario_id", "operation_id", "destination", "decision",
                                            "reviewer", "reason", "resulting_reference", "decided_at"],
            "workbench_scenario_events": ["id", "scenario_id", "sequence", "scenario_revision", "action",
                                           "actor", "detail", "occurred_at"],
            // v95 — SHELL-001 shared-shell navigation session (two NEW tables, so their presence
            // distinguishes v95 from v94). Browser-style Back/Forward location history + autosave/resume.
            // These are the NEWEST markers — every future migration MUST add its newest physical marker.
            "app_navigation_sessions": ["id", "scope_key", "current_index", "revision", "updated_at"],
            "app_navigation_entries": ["id", "session_id", "ordinal", "destination", "context_kind", "context_id"],
            // v96 — INV-01-A Investigator case + scope authority (three NEW tables, so their presence
            // distinguishes v96 from v95). A persona lens over the canonical engine: the case REFERENCES
            // canonical sources (never copies), and its in-scope set is the hard evidence boundary.
            // These are the NEWEST markers — every future migration MUST add its newest physical marker.
            "investigation_cases": ["id", "workspace_id", "title", "purpose", "scope_statement",
                                     "out_of_scope_statement", "time_window_start", "time_window_end",
                                     "status", "confirmed_deadline_id", "possible_deadline_note", "revision",
                                     "actor", "created_at", "updated_at"],
            "investigation_case_sources": ["id", "case_id", "source_ref", "source_kind", "in_scope", "note", "created_at"],
            "investigation_case_events": ["id", "case_id", "sequence", "case_revision", "action", "actor", "detail", "occurred_at"],
            // v97 — INV-01-C4 canonical case-scope fingerprint / staleness ledger.
            "investigation_scope_artifacts": ["id", "case_id", "artifact_kind", "artifact_id", "scope_fingerprint", "case_revision", "created_at"],
            // v98 — INV-02 Subject dossier + INV-03 Identity resolution (two NEW tables, so their presence
            // distinguishes v98 from v97). A subject anchors to a canonical entity id (proposed→confirmed
            // human decision); the identity-decision log records proposed/confirmed/rejected/reversed merges
            // over the SHARED reversible entity merge. These are the NEWEST markers — every future migration
            // MUST add its newest physical marker.
            "investigation_subjects": ["id", "case_id", "canonical_entity_id", "label", "identity_status",
                                        "confirmed_by", "confirmed_at", "revision", "actor", "created_at", "updated_at"],
            "investigation_identity_decisions": ["id", "case_id", "sequence", "decision_kind", "winner_entity_id",
                                                  "loser_entity_id", "rationale", "actor", "prior_decision_id", "occurred_at"],
            // v99 — INV-04..07 analytical spine (four NEW tables, so their presence distinguishes v99 from
            // v98). Leads/hypotheses (proposal→hypothesis promotion, human confirm, never auto-won) + their
            // for/against evidence links (cite exact in-scope evidence) + evidence requests (describe MISSING
            // evidence, never assert it exists) + the 5W1H worksheet (each cell cites evidence or is marked
            // unknown). These are the NEWEST markers — every future migration MUST add its newest marker.
            "investigation_hypotheses": ["id", "case_id", "kind", "statement", "status", "origin_hypothesis_id",
                                          "revision", "actor", "created_at", "updated_at"],
            "investigation_hypothesis_evidence": ["id", "hypothesis_id", "stance", "source_version_id",
                                                   "knowledge_object_id", "note", "added_by", "created_at"],
            "investigation_evidence_requests": ["id", "case_id", "hypothesis_id", "description", "status",
                                                 "revision", "actor", "created_at", "updated_at"],
            "investigation_worksheet_cells": ["id", "case_id", "dimension", "status", "answer_text",
                                               "source_version_id", "knowledge_object_id", "revision", "actor", "updated_at"],
            // v100 — INV-08 + INV-12 case-scoped review desk (one NEW table, so its presence distinguishes
            // v100 from v99). A thin, case-scoped human confirm/dismiss decision that REFERENCES a shared
            // canonical item (a source-reliability assessment / contradiction / gap) by id — it never forks
            // those authorities. This is the NEWEST marker.
            "investigation_desk_reviews": ["id", "case_id", "item_kind", "item_id", "decision", "note",
                                            "actor", "created_at", "updated_at"],
            // v101 — INV-20 Closure & export: the durable, append-only human closure/reopen decision log (one
            // NEW table, so its presence distinguishes v101 from v100). A case is CLOSED only by a recorded
            // human decision; unresolved items remain visible; a reopen never erases a prior closure. This is
            // the NEWEST marker.
            "investigation_case_closures": ["id", "case_id", "sequence", "decision", "rationale",
                                             "work_product_run_id", "scope_fingerprint", "unresolved_json",
                                             "receipt_seal", "actor", "created_at"],
            // v102 — INV-19 Findings & export: the durable, append-only human approval/withdrawal decision log
            // for a case's findings work product (one NEW table, so its presence distinguishes v102 from v101).
            // The findings work product itself is the SHARED WorkProductRun; this records only the explicit
            // human approval that authorizes it as the case's findings — never inferred from build, workflow /
            // method completion, confidence, or absence of contradiction. This is the NEWEST marker.
            "investigation_findings_approvals": ["id", "case_id", "sequence", "decision", "work_product_run_id",
                                                  "receipt_seal", "scope_fingerprint", "rationale", "actor",
                                                  "created_at"],
            // v103 — P9.3/GOV-005 disk-backed ANN: IVF meta/cells/postings in the single ledger (three NEW
            // tables; ann_index_meta's presence distinguishes v103 from v102). Population is background
            // build work, never migration work.
            "ann_index_meta": ["model_id", "strategy", "state", "dimension", "cell_count",
                               "trained_vector_count", "train_seed", "created_at", "updated_at"],
            "ann_cells": ["model_id", "cell_id", "centroid", "vector_count", "updated_at"],
            "ann_postings": ["model_id", "cell_id", "chunk_id", "q", "scale"],
            // v104 — AUD-CHAIN tamper-evident audit hash chain (+ v114 PUBLIC keyless
            // links: their presence distinguishes v114+ from v104).
            "audit_chain": ["seq", "source", "event_id", "occurred_at", "payload_hash",
                            "prev_hash", "entry_hash", "sealed_at", "public_prev", "public_hash"],
            // v105 — WORK-CENTER numbered documents + number-range counters (two NEW tables;
            // work_center_documents' presence distinguishes v105 from v104). NEWEST marker.
            "work_center_documents": ["id", "doc_number", "doc_type", "run_id", "def_id", "step_seq",
                                      "title", "status", "fields_json", "confirmed_seqs", "actor",
                                      "created_at", "updated_at"],
            "work_center_counters": ["doc_type", "year", "next_seq"],
            // v106 — REGISTERS: append-only edit log making captured documents editable
            // WITH HISTORY (one NEW table; its presence distinguishes v106 from v105).
            "work_center_record_edits": ["id", "doc_id", "field_key", "old_value", "new_value",
                                         "editor", "note", "edited_at"],
            // TWELFTH AUDIT P0 — the sentinel had NOT been extended past v106,
            // so the self-heal path stamped real v107+-era databases to latest
            // without running the pending migrations. Markers for every
            // migration since:
            // v107 conformance ledger (+ v112 approval_state column).
            "conformance_assessments": ["id", "case_id", "run_revision", "sutra_citation",
                                        "sutra_sha256", "status", "approval_state"],
            // v108 protocol registry + governance review records.
            "protocol_registry": ["id", "sutra_id", "version", "sutra_sha256", "pack_json",
                                  "publisher", "assurance", "signer_key_id"],
            // v111 governance acts ledger.
            "governance_events": ["id", "kind", "case_id", "actor", "detail", "occurred_at"],
            // v113 case ↔ method-run phase linkage.
            "case_method_runs": ["case_id", "method_run_id", "phase_kind", "created_at"],
            // v117/v118 case-bound phase artifacts (rebuilt shape).
            "case_phase_artifacts": ["id", "case_id", "case_revision", "scope_fingerprint",
                                     "phase_kind", "artifact_id", "detail", "created_at"],
            // v152 A-6 ACH in the ledger — the NEWEST marker. Without it a v151 ledger would be
            // self-healed straight to 152 and the ACH tables would never be created.
            "ach_analyses": ["id", "case_id", "workspace_id", "title", "origin", "created_by", "updated_by", "retracted_at"],
            "ach_cells": ["analysis_id", "evidence_id", "hypothesis_id", "consistency", "updated_by", "updated_at"],
            "ach_legacy_imports": ["source_key", "analysis_count", "imported_by", "imported_at"],
            // v153 — case-action log made append-only and sealed into the audit chain.
            "case_action_seal_boundaries": ["id", "sealed_from_at", "legacy_action_count", "created_at"],
            // v154 — hypothesis decisions carry their reasons; evidence links carry reliability + relevance.
            "investigation_hypothesis_decisions": ["id", "hypothesis_id", "decision", "rationale", "contrary_evidence",
                                                    "alternatives", "for_lineages", "against_lineages", "actor", "decided_at"],
            "investigation_hypothesis_evidence_assessments": ["link_id", "reliability", "diagnostic_relevance", "assessed_by", "assessed_at"],
            // v155 — schema-conformance verification recorded in the ledger it verified.
            "schema_conformance_marks": ["schema_version", "schema_fingerprint", "status", "added", "could_not_add", "checked_at"],
            // v156 — corrections to a confirmed statement are linked addenda, never edits.
            "case_statement_addenda": ["id", "interview_id", "case_id", "text", "reason", "sha256", "recorded_by", "recorded_at", "confirmed_by", "confirmed_at"],
            // v157 — when sealing of the rest of a case's history began.
            "audit_seal_boundaries": ["history", "sealed_from_at", "legacy_count", "created_at"],
            // v158 — professional studio work in the ledger, bound to its case (final brief §3.1).
            "studio_records": ["id", "studio", "persona", "job_id", "case_id", "workspace_id", "title", "model_version", "revision",
                               "payload_json", "payload_sha256", "review_state", "origin", "created_by", "created_at",
                               "updated_by", "updated_at", "retracted_at", "retracted_by",
                               "approved_payload_sha256", "erased_at"]
        ]
        // Derived, never hand-maintained: every table the NEWEST migration creates must exist. The
        // hand-kept list above stopped tracking new migrations after v118, which let a ledger at
        // v150 be stamped v151 without running v151 (2026-10-23). This keeps the sentinel current.
        for table in createdTables(inMigration: latestVersion) {
            let rows = try await database.query("PRAGMA table_info(\(table));", [])
            guard !rows.isEmpty else { return false }
        }
        // …and every column it adds (a column-only newest migration has no table to check).
        for (table, column) in addedColumns(inMigration: latestVersion) {
            let rows = try await database.query("PRAGMA table_info(\(table));", [])
            guard rows.contains(where: { $0.string(1) == column }) else { return false }
        }
        for (table, expected) in required {
            let rows = try await database.query("PRAGMA table_info(\(table));", [])
            let actual = Set(rows.compactMap { $0.string(1) })
            guard actual.isSuperset(of: expected) else { return false }
        }
        // v81 (PM-004.1) adds CHECK constraints but NO new column, so the column probe
        // above cannot distinguish a v81 schema from v80. Confirm the newest v81 markers
        // directly from each rebuilt table's stored CREATE SQL — without this, the
        // self-heal path could stamp user_version=81 over a v80 schema that lacks the
        // hardened CHECKs (the PJE-006B.1 self-heal hazard). Each substring appears ONLY
        // in the v81 form of its table.
        let v81Markers: [String: String] = [
            "method_runs":               "status = 'superseded'",              // reverse supersession CHECK
            "method_reviews":            "length(trim(review_key)) > 0",       // non-blank review key CHECK
            "method_validation_results": "length(trim(validation_batch_id)) > 0", // non-blank batch id CHECK
            // v83 (USF-001.1) hardens the intake ledger with CHECKs / composite FKs / unique
            // keys but adds NO new column, so the column probe cannot distinguish v83 from v82.
            // v84 (USF-001.2) adds hexadecimal enforcement (`content_hash NOT GLOB '*[^0-9a-f]*'`),
            // also CHECK-only — this GLOB marker appears ONLY in the v84 form and implies the
            // v83 SHA-256 shape it supersedes.
            "source_versions":           "content_hash NOT GLOB '*[^0-9a-f]*'", // v84 hexadecimal SHA-256 CHECK
            "source_intake_receipts":    "source_versions(id, content_hash)",  // receipt-hash composite FK
            "ingest_file_attempts":      "(logical_source_id IS NULL) = (source_version_id IS NULL)"
        ]
        // v117/v118 constraints (twelfth audit): the column probe above cannot
        // see the one-artifact-one-case UNIQUE or the case FK — probe the
        // stored CREATE SQL directly, like the v81 markers.
        let v118Markers: [(String, String)] = [
            ("case_phase_artifacts", "UNIQUE(phase_kind, artifact_id)"),
            ("case_phase_artifacts", "REFERENCES investigation_cases(id)")
        ]
        for (table, marker) in v118Markers {
            let sql = try await database.query(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name=?;", [.text(table)])
                .first?.string(0) ?? ""
            guard sql.contains(marker) else { return false }
        }
        for (table, marker) in v81Markers {
            let sql = try await database.query(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name=?;", [.text(table)])
                .first?.string(0) ?? ""
            guard sql.contains(marker) else { return false }
        }
        return true
    }

    /// Migrations indexed by their `user_version` number. Append-only.
    private static let all: [(Int, String)] = [
        (1, v1),
        (2, v2),
        (3, v3),
        (4, v4),
        (5, v5),
        (6, v6),
        (7, v7),
        (8, v8),
        (9, v9),
        (10, v10),
        (11, v11),
        (12, v12),
        (13, v13),
        (14, v14),
        (15, v15),
        (16, v16),
        (17, v17),
        (18, v18),
        (19, v19),
        (20, v20),
        (21, v21),
        (22, v22),
        (23, v23),
        (24, v24),
        (25, v25),
        (26, v26),
        (27, v27),
        (28, v28),
        (29, v29),
        (30, v30),
        (31, v31),
        (32, v32),
        (33, v33),
        (34, v34),
        (35, v35),
        (36, v36),
        (37, v37),
        (38, v38),
        (39, v39),
        (40, v40),
        (41, v41),
        (42, v42),
        (43, v43),
        (44, v44),
        (45, v45),
        (46, v46),
        (47, v47),
        (48, v48),
        (49, v49),
        (50, v50),
        (51, v51),
        (52, v52),
        (53, v53),
        (54, v54),
        (55, v55),
        (56, v56),
        (57, v57),
        (58, v58),
        (59, v59),
        (60, v60),
        (61, v61),
        (62, v62),
        (63, v63),
        (64, v64),
        (65, v65),
        (66, v66),
        (67, v67),
        (68, v68),
        (69, v69),
        (70, v70),
        (71, v71),
        (72, v72),
        (73, v73),
        (74, v74),
        (75, v75),
        (76, v76),
        (77, v77),
        (78, v78),
        (79, v79),
        (80, v80),
        (81, v81),
        (82, v82),
        (83, v83),
        (84, v84),
        (85, v85),
        (86, v86),
        (87, v87),
        (88, v88),
        (89, v89),
        (90, v90),
        (91, v91),
        (92, v92),
        (93, v93),
        (94, v94),
        (95, v95),
        (96, v96),
        (97, v97),
        (98, v98),
        (99, v99),
        (100, v100),
        (101, v101),
        (102, v102),
        (103, v103),
        (104, v104),
        (105, v105),
        (106, v106),
        (107, v107),
        (108, v108),
        (109, v109),
        (110, v110),
        (111, v111),
        (112, v112),
        (113, v113),
        (114, v114),
        (115, v115),
        (116, v116),
        (117, v117),
        (118, v118),
        (119, v119),
        (120, v120),
        (121, v121),
        (122, v122),
        (123, v123),
        (124, v124),
        (125, v125),
        (126, v126),
        (127, v127),
        (128, v128),
        (129, v129),
        (130, v130),
        (131, v131),
        (132, v132),
        (133, v133),
        (134, v134),
        (135, v135),
        (136, v136),
        (137, v137),
        (138, v138),
        (139, v139),
        (140, v140),
        (141, v141),
        (142, v142),
        (143, v143),
        (144, v144),
        (145, v145),
        (146, v146),
        (147, v147),
        (148, v148),
        (149, v149),
        (150, v150),
        (151, v151),
        (152, v152),
        (153, v153),
        (154, v154),
        (155, v155),
        (156, v156),
        (157, v157),
        (158, v158),
        (159, v159),
        (160, v160),
        (161, v161),
        (162, v162),
        (163, v163),
        (164, v164),
        (165, v165),
        (166, v166),
        (167, v167),
        (168, v168),
        (169, v169),
        (170, v170),
        (171, v171),
        (172, v172),
        (173, v173),
        (174, v174),
        (175, v175),
        (176, v176),
        (177, v177),
        (178, v178),
        (179, v179),
        (180, v180),
        (181, v181),
        (182, v182),
        (183, v183)
    ]

    // MARK: - v1 — initial 11-table schema + FTS5

    private static let v1: String = """
    -- Files: raw file rows discovered on disk.
    CREATE TABLE IF NOT EXISTS files (
        id              TEXT PRIMARY KEY NOT NULL,
        url             TEXT NOT NULL,
        source_type     TEXT NOT NULL,
        size_bytes      INTEGER NOT NULL DEFAULT 0,
        modified_at     REAL NOT NULL DEFAULT 0,
        ingested_at     REAL,
        content_hash    TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_files_url ON files(url);
    CREATE INDEX IF NOT EXISTS idx_files_type ON files(source_type);

    -- Knowledge Objects: normalized unit every downstream system works with.
    CREATE TABLE IF NOT EXISTS knowledge_objects (
        id              TEXT PRIMARY KEY NOT NULL,
        file_id         TEXT NOT NULL,
        source_type     TEXT NOT NULL,
        content         TEXT NOT NULL,
        metadata_json   TEXT NOT NULL DEFAULT '{}',
        confidence      REAL NOT NULL DEFAULT 1.0,
        created_at      REAL NOT NULL,
        updated_at      REAL NOT NULL,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_ko_file ON knowledge_objects(file_id);

    -- Chunks: bounded slice of KO content, granularity for embeddings + citations.
    CREATE TABLE IF NOT EXISTS chunks (
        id              TEXT PRIMARY KEY NOT NULL,
        object_id       TEXT NOT NULL,
        ordinal         INTEGER NOT NULL,
        text            TEXT NOT NULL,
        char_start      INTEGER NOT NULL,
        char_end        INTEGER NOT NULL,
        page_number     INTEGER,
        created_at      REAL NOT NULL,
        FOREIGN KEY (object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_chunks_object ON chunks(object_id);

    -- Entities.
    CREATE TABLE IF NOT EXISTS entities (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        value           TEXT NOT NULL,
        normalized      TEXT,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
    CREATE INDEX IF NOT EXISTS idx_entities_norm ON entities(normalized);

    -- Events.
    CREATE TABLE IF NOT EXISTS events (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        date            REAL NOT NULL,
        end_date        REAL,
        title           TEXT NOT NULL,
        summary         TEXT,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind);
    CREATE INDEX IF NOT EXISTS idx_events_date ON events(date);

    -- Event<->Entity join (an event has many entity participants).
    CREATE TABLE IF NOT EXISTS event_entities (
        event_id        TEXT NOT NULL,
        entity_id       TEXT NOT NULL,
        PRIMARY KEY (event_id, entity_id),
        FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );

    -- Timelines (named views over events; the engine builds these on read).
    CREATE TABLE IF NOT EXISTS timelines (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,           -- global/project/person/company/financial
        scope_id        TEXT,                    -- nullable for global
        title           TEXT NOT NULL,
        created_at      REAL NOT NULL
    );

    -- Relationships (graph edges).
    CREATE TABLE IF NOT EXISTS relationships (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        from_entity_id  TEXT NOT NULL,
        to_entity_id    TEXT NOT NULL,
        via_event_id    TEXT,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (from_entity_id) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (to_entity_id) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (via_event_id) REFERENCES events(id) ON DELETE SET NULL,
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_entity_id);
    CREATE INDEX IF NOT EXISTS idx_rel_to ON relationships(to_entity_id);

    -- Summaries (hierarchical: 6 levels).
    CREATE TABLE IF NOT EXISTS summaries (
        id              TEXT PRIMARY KEY NOT NULL,
        level           TEXT NOT NULL,
        length          TEXT NOT NULL,
        scope_json      TEXT NOT NULL,
        body            TEXT NOT NULL,
        produced_at     REAL NOT NULL,
        model_id        TEXT,
        confidence      REAL NOT NULL DEFAULT 0.5
    );
    CREATE INDEX IF NOT EXISTS idx_summaries_level ON summaries(level);

    -- Conversations (Ask transcripts).
    CREATE TABLE IF NOT EXISTS conversations (
        id              TEXT PRIMARY KEY NOT NULL,
        started_at      REAL NOT NULL,
        title           TEXT
    );

    CREATE TABLE IF NOT EXISTS conversation_turns (
        id              TEXT PRIMARY KEY NOT NULL,
        conversation_id TEXT NOT NULL,
        ordinal         INTEGER NOT NULL,
        role            TEXT NOT NULL,           -- user / assistant
        body            TEXT NOT NULL,
        created_at      REAL NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
    );

    -- Projects / Companies / People are first-class for UI navigation;
    -- entities still drive truth.
    CREATE TABLE IF NOT EXISTS projects (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        started_at      REAL,
        ended_at        REAL,
        notes           TEXT
    );

    CREATE TABLE IF NOT EXISTS companies (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        kind            TEXT,                    -- vendor / client / other
        notes           TEXT
    );

    CREATE TABLE IF NOT EXISTS people (
        id              TEXT PRIMARY KEY NOT NULL,
        name            TEXT NOT NULL,
        email           TEXT,
        phone           TEXT,
        notes           TEXT
    );

    -- FTS5 virtual table over knowledge_objects.content + chunks.text.
    CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_objects_fts USING fts5(
        content,
        content='knowledge_objects',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );

    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text,
        content='chunks',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );
    """

    // MARK: - v2 — Knowledge Memory layer (MemoryObject + change log)

    private static let v2: String = """
    -- Latest distilled state per subject (project / org / person / etc.).
    -- Decisions, risks, source IDs are JSON-encoded blobs since SQLite
    -- doesn't have arrays.
    CREATE TABLE IF NOT EXISTS memory_objects (
        id                          TEXT PRIMARY KEY NOT NULL,
        subject_kind                TEXT NOT NULL,
        subject_identifier          TEXT NOT NULL,
        key_decisions_json          TEXT NOT NULL DEFAULT '[]',
        key_event_ids_json          TEXT NOT NULL DEFAULT '[]',
        important_relationship_ids_json TEXT NOT NULL DEFAULT '[]',
        risks_json                  TEXT NOT NULL DEFAULT '[]',
        status                      TEXT NOT NULL DEFAULT 'active',
        narrative                   TEXT NOT NULL DEFAULT '',
        source_object_ids_json      TEXT NOT NULL DEFAULT '[]',
        confidence                  REAL NOT NULL DEFAULT 0.5,
        version                     INTEGER NOT NULL DEFAULT 1,
        created_at                  REAL NOT NULL,
        updated_at                  REAL NOT NULL,
        UNIQUE(subject_kind, subject_identifier)
    );
    CREATE INDEX IF NOT EXISTS idx_memory_subject
        ON memory_objects(subject_kind, subject_identifier);

    -- Append-only change log per memory object.
    CREATE TABLE IF NOT EXISTS memory_changes (
        id                     TEXT PRIMARY KEY NOT NULL,
        memory_object_id       TEXT NOT NULL,
        subject_kind           TEXT NOT NULL,
        subject_identifier     TEXT NOT NULL,
        prior_version          INTEGER NOT NULL,
        new_version            INTEGER NOT NULL,
        delta_json             TEXT NOT NULL,
        triggering_object_id   TEXT,
        occurred_at            REAL NOT NULL,
        FOREIGN KEY (memory_object_id) REFERENCES memory_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_memory_changes_subject
        ON memory_changes(subject_kind, subject_identifier, occurred_at DESC);
    """

    // MARK: - v3 — canonical entities + per-mention rows + alias table

    private static let v3: String = """
    -- T3 — Promote `entities` to a canonical table (UNIQUE on kind+normalized),
    -- preserve per-document occurrences as entity_mentions, and add an
    -- aliases table so domain stems and other synonyms can map onto orgs.
    -- Run with deferred FK checks so we can table-swap inside the savepoint.
    PRAGMA defer_foreign_keys = ON;

    -- Per-document mentions. One row per (entity, source_object) occurrence,
    -- with the surface span for future highlighting.
    CREATE TABLE entity_mentions (
        id              TEXT PRIMARY KEY NOT NULL,
        entity_id       TEXT NOT NULL,
        kind            TEXT NOT NULL,
        surface         TEXT NOT NULL,
        normalized      TEXT NOT NULL,
        source_object_id TEXT NOT NULL,
        span_start      INTEGER,
        span_end        INTEGER,
        confidence      REAL NOT NULL DEFAULT 0.5,
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_mentions_entity ON entity_mentions(entity_id);
    CREATE INDEX idx_mentions_source ON entity_mentions(source_object_id);
    CREATE INDEX idx_mentions_normalized ON entity_mentions(normalized);

    -- New canonical entities table (UNIQUE on kind+normalized).
    CREATE TABLE entities_new (
        id              TEXT PRIMARY KEY NOT NULL,
        kind            TEXT NOT NULL,
        value           TEXT NOT NULL,
        normalized      TEXT NOT NULL,
        source_object_id TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        attributes_json TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE,
        UNIQUE(kind, normalized)
    );

    -- Pick a representative row per (kind, normalized) and copy to entities_new.
    INSERT INTO entities_new (id, kind, value, normalized, source_object_id, confidence, attributes_json)
    SELECT id, kind, value, norm, source_object_id, confidence, attributes_json
    FROM (
        SELECT e.id, e.kind, e.value, e.source_object_id, e.confidence, e.attributes_json,
               COALESCE(NULLIF(e.normalized, ''), lower(e.value)) AS norm,
               ROW_NUMBER() OVER (
                   PARTITION BY e.kind, COALESCE(NULLIF(e.normalized, ''), lower(e.value))
                   ORDER BY e.confidence DESC, e.id ASC
               ) AS rn
        FROM entities e
    ) ranked
    WHERE rn = 1;

    -- Backfill mentions for every OLD entity row, pointing at the canonical.
    INSERT INTO entity_mentions (id, entity_id, kind, surface, normalized, source_object_id, span_start, span_end, confidence)
    SELECT
        lower(hex(randomblob(16))),
        canon.id,
        e.kind,
        e.value,
        COALESCE(NULLIF(e.normalized, ''), lower(e.value)),
        e.source_object_id,
        NULL,
        NULL,
        e.confidence
    FROM entities e
    JOIN entities_new canon
        ON e.kind = canon.kind
       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized;

    -- Retarget event_entities and relationships to the canonical ids.
    UPDATE event_entities
    SET entity_id = (
        SELECT canon.id
        FROM entities_new canon
        JOIN entities e ON e.kind = canon.kind
                       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized
        WHERE e.id = event_entities.entity_id
        LIMIT 1
    )
    WHERE entity_id NOT IN (SELECT id FROM entities_new);

    UPDATE relationships
    SET from_entity_id = (
        SELECT canon.id
        FROM entities_new canon
        JOIN entities e ON e.kind = canon.kind
                       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized
        WHERE e.id = relationships.from_entity_id
        LIMIT 1
    )
    WHERE from_entity_id NOT IN (SELECT id FROM entities_new);

    UPDATE relationships
    SET to_entity_id = (
        SELECT canon.id
        FROM entities_new canon
        JOIN entities e ON e.kind = canon.kind
                       AND COALESCE(NULLIF(e.normalized, ''), lower(e.value)) = canon.normalized
        WHERE e.id = relationships.to_entity_id
        LIMIT 1
    )
    WHERE to_entity_id NOT IN (SELECT id FROM entities_new);

    -- Swap old for new.
    DROP TABLE entities;
    ALTER TABLE entities_new RENAME TO entities;
    CREATE INDEX IF NOT EXISTS idx_entities_kind ON entities(kind);
    CREATE INDEX IF NOT EXISTS idx_entities_norm ON entities(normalized);

    -- Aliases — normalized synonyms (e.g. an email domain stem → an org).
    CREATE TABLE entity_aliases (
        entity_id        TEXT NOT NULL,
        alias_normalized TEXT NOT NULL,
        source           TEXT NOT NULL,
        UNIQUE(entity_id, alias_normalized),
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_aliases_norm ON entity_aliases(alias_normalized);
    """

    // MARK: - v4 — relationships gain weight + evidence list (T4)

    private static let v4: String = """
    -- T4 — Relationship edges accumulate weight and an evidence list of
    -- source KO ids (capped in code at 20). A UNIQUE index on
    -- (kind, from_entity_id, to_entity_id) lets ingest upsert idempotently
    -- via ON CONFLICT.
    ALTER TABLE relationships ADD COLUMN weight INTEGER NOT NULL DEFAULT 1;
    ALTER TABLE relationships ADD COLUMN evidence_object_ids_json TEXT NOT NULL DEFAULT '[]';
    CREATE UNIQUE INDEX idx_rel_canonical ON relationships(kind, from_entity_id, to_entity_id);
    """

    // MARK: - v5 — int8-quantized vectors table (T5)

    private static let v5: String = """
    -- T5 — Real vector store. One row per chunk: int8 symmetric blob +
    -- per-vector scale. Brute force at scan time until ANN (Gate 3).
    CREATE TABLE vectors (
        chunk_id    TEXT PRIMARY KEY NOT NULL,
        dim         INTEGER NOT NULL,
        q           BLOB NOT NULL,
        scale       REAL NOT NULL,
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
    );
    """

    // MARK: - v6 — files.alias_of for hash-based attachment dedup (T7)

    private static let v6: String = """
    -- T7 — A file whose contentHash matches an already-ingested file is
    -- stored as an alias row. Its alias_of points at the canonical file's
    -- id; no new knowledge_objects row is created. SET NULL on the FK so
    -- deleting the canonical doesn't cascade through alias bookkeeping.
    ALTER TABLE files ADD COLUMN alias_of TEXT NULL REFERENCES files(id) ON DELETE SET NULL;
    CREATE INDEX idx_files_content_hash ON files(content_hash);
    CREATE INDEX idx_files_alias_of ON files(alias_of);
    """

    // MARK: - v7 — files.availability for move/delete/revoke reconciliation (T8)

    private static let v7: String = """
    -- T8 — Files can be available, offline (their root is unreachable),
    -- or missing (gone from a still-reachable root). Reconciliation
    -- sweeps NEVER cascade-delete knowledge — they only flip this flag.
    ALTER TABLE files ADD COLUMN availability TEXT NOT NULL DEFAULT 'available';
    CREATE INDEX idx_files_availability ON files(availability);
    """

    // MARK: - v8 — event date confidence (T9)

    private static let v8: String = """
    -- T9 — Confidence in the event's date as a fact: 0.95 (parsed from
    -- an email header), 0.7 (extracted from content), 0.3 (file mtime
    -- fallback). 0.5 is the safe default for backfilled rows.
    ALTER TABLE events ADD COLUMN date_confidence REAL NOT NULL DEFAULT 0.5;
    """

    // MARK: - v9 — G2-SYNTHETIC-QUESTIONS + G2-QA-PAIRS storage

    private static let v9: String = """
    -- G2-SYNTHETIC-QUESTIONS — hypothetical questions per chunk.
    -- Each chunk can carry many generated questions; FTS5 indexes the
    -- text so question-shaped queries match by surface form, and the
    -- separate `vectors` table can host their embeddings under the
    -- `kind='synthetic_question'` discriminator (added below) so
    -- HybridRetriever's vector layer can fuse them at query time
    -- without changing the chunk text path.
    CREATE TABLE IF NOT EXISTS synthetic_questions (
        id              TEXT PRIMARY KEY NOT NULL,
        chunk_id        TEXT NOT NULL,
        object_id       TEXT NOT NULL,
        text            TEXT NOT NULL,
        confidence      REAL NOT NULL DEFAULT 0.5,
        produced_by     TEXT NOT NULL DEFAULT 'synthq.heuristic',
        created_at      REAL NOT NULL,
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE,
        FOREIGN KEY (object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_synthq_chunk ON synthetic_questions(chunk_id);
    CREATE INDEX IF NOT EXISTS idx_synthq_object ON synthetic_questions(object_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS synthetic_questions_fts USING fts5(
        text,
        content='synthetic_questions',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );

    -- G2-QA-PAIRS — mined Q-A turns from threads / conversations.
    -- Sidecar table so the chunk path stays clean; retrieval can
    -- vector-search the answer summaries (held in `answer_text`) and
    -- RRF-fuse the hits with chunk + synthetic-question signals.
    CREATE TABLE IF NOT EXISTS qa_pairs (
        id                      TEXT PRIMARY KEY NOT NULL,
        question_text           TEXT NOT NULL,
        answer_text             TEXT NOT NULL,
        question_object_id      TEXT NOT NULL,
        answer_object_id        TEXT NOT NULL,
        confidence              REAL NOT NULL DEFAULT 0.5,
        produced_by             TEXT NOT NULL DEFAULT 'qa.email.thread',
        created_at              REAL NOT NULL,
        FOREIGN KEY (question_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE,
        FOREIGN KEY (answer_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_qa_q_object ON qa_pairs(question_object_id);
    CREATE INDEX IF NOT EXISTS idx_qa_a_object ON qa_pairs(answer_object_id);
    """

    // MARK: - v10 — G2-QA-PAIRS FTS view + thread_id on KO metadata index

    private static let v10: String = """
    -- G2-QA-PAIRS — FTS5 over the answer_text. The question shape comes
    -- from the user; the corpus side stores the answer's summary, so
    -- matching question-to-answer-summary on bm25 gives the retrieval
    -- layer a question-shaped second surface alongside chunk text and
    -- synthetic_questions_fts.
    CREATE VIRTUAL TABLE IF NOT EXISTS qa_pairs_fts USING fts5(
        question_text,
        answer_text,
        content='qa_pairs',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );
    """

    // MARK: - v11 — G3 Phase 2: fact_type column on canonical rows (G3.5)

    private static let v11: String = """
    -- G3.5 — Promote every entity / event / memory_object row to a
    -- typed fact. The column is nullable; NULL = "not yet classified"
    -- (the FactTypeClassifier backfill in G3.8 fills it in).
    -- Schema version stays small: just one TEXT column per table.
    ALTER TABLE entities         ADD COLUMN fact_type TEXT NULL;
    ALTER TABLE events           ADD COLUMN fact_type TEXT NULL;
    ALTER TABLE memory_objects   ADD COLUMN fact_type TEXT NULL;

    CREATE INDEX IF NOT EXISTS idx_entities_fact_type      ON entities(fact_type);
    CREATE INDEX IF NOT EXISTS idx_events_fact_type        ON events(fact_type);
    CREATE INDEX IF NOT EXISTS idx_memory_objects_fact_type ON memory_objects(fact_type);
    """

    // MARK: - v12 — G3 Phase 2: slot_values_json column (G3.6)

    private static let v12: String = """
    -- G3.6 — JSON-encoded typed slot values per row. The schema for
    -- each FactType lives in Ontology.swift; OntologyValidator (G3.9)
    -- checks the JSON against the type's expected slots before write.
    -- Defaults to "{}" so existing rows decode cleanly.
    ALTER TABLE entities       ADD COLUMN slot_values_json TEXT NOT NULL DEFAULT '{}';
    ALTER TABLE events         ADD COLUMN slot_values_json TEXT NOT NULL DEFAULT '{}';
    ALTER TABLE memory_objects ADD COLUMN slot_values_json TEXT NOT NULL DEFAULT '{}';
    """

    // MARK: - v13 — G3 Phase 3: fact_bonds (polymorphic typed graph edges)

    private static let v13: String = """
    -- G3.10 — Typed bonds between facts. Unlike `relationships`
    -- (entity↔entity only), bonds are polymorphic over fact kind:
    -- an Email-event can be bonded to a Person-entity via `sent_by`,
    -- a Decision-memory to a Project-entity via `concerns`, etc.
    -- Bond names come from Ontology.rules; this table has no FK to
    -- the fact rows themselves (different tables per kind) but the
    -- source_object_id FK gives us KO-cascade delete for free.
    CREATE TABLE fact_bonds (
        id                      TEXT PRIMARY KEY NOT NULL,
        bond_name               TEXT NOT NULL,
        from_fact_kind          TEXT NOT NULL,
        from_fact_id            TEXT NOT NULL,
        to_fact_kind            TEXT NOT NULL,
        to_fact_id              TEXT NOT NULL,
        source_object_id        TEXT NOT NULL,
        confidence              REAL NOT NULL DEFAULT 0.5,
        weight                  INTEGER NOT NULL DEFAULT 1,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        created_at              REAL NOT NULL,
        FOREIGN KEY (source_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE UNIQUE INDEX idx_fact_bonds_unique
        ON fact_bonds(bond_name, from_fact_id, to_fact_id);
    CREATE INDEX idx_fact_bonds_from ON fact_bonds(from_fact_id, bond_name);
    CREATE INDEX idx_fact_bonds_to   ON fact_bonds(to_fact_id, bond_name);
    CREATE INDEX idx_fact_bonds_name ON fact_bonds(bond_name);
    """

    // MARK: - v14 — FTS5 population triggers + index rebuild
    //
    // CRITICAL FIX: chunks_fts / knowledge_objects_fts were created in
    // v1 as external-content FTS5 tables (content='chunks' / 'knowledge_objects')
    // but no triggers were ever added to populate the FTS index. Result:
    // 42K+ chunks in chunks but `chunks_fts MATCH 'patent'` returns 0
    // rows — the entire FTS retrieval tier in HybridRetriever has been
    // silently dead since launch. Every topic question silently fell
    // through to vector + entity-frequency, which is why "patents"
    // returned Google instead of IIPRD/Khurana.
    //
    // This migration:
    //   1. Adds INSERT/UPDATE/DELETE triggers so future writes stay in sync.
    //   2. Rebuilds the existing index for the rows already in chunks
    //      and knowledge_objects.

    private static let v14: String = """
    -- Triggers: keep chunks_fts in sync with chunks.
    CREATE TRIGGER IF NOT EXISTS chunks_fts_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_fts_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_fts_au AFTER UPDATE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
    END;

    -- Triggers: keep knowledge_objects_fts in sync with knowledge_objects.
    CREATE TRIGGER IF NOT EXISTS ko_fts_ai AFTER INSERT ON knowledge_objects BEGIN
        INSERT INTO knowledge_objects_fts(rowid, content) VALUES (new.rowid, new.content);
    END;
    CREATE TRIGGER IF NOT EXISTS ko_fts_ad AFTER DELETE ON knowledge_objects BEGIN
        INSERT INTO knowledge_objects_fts(knowledge_objects_fts, rowid, content) VALUES('delete', old.rowid, old.content);
    END;
    CREATE TRIGGER IF NOT EXISTS ko_fts_au AFTER UPDATE ON knowledge_objects BEGIN
        INSERT INTO knowledge_objects_fts(knowledge_objects_fts, rowid, content) VALUES('delete', old.rowid, old.content);
        INSERT INTO knowledge_objects_fts(rowid, content) VALUES (new.rowid, new.content);
    END;

    -- Rebuild the indexes from existing rows. Idempotent — running
    -- this twice produces the same final index.
    INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild');
    INSERT INTO knowledge_objects_fts(knowledge_objects_fts) VALUES('rebuild');
    """

    // MARK: - v15 — Boilerplate registry (Move B)
    //
    // Long repeated substrings (email signatures, legal disclaimers,
    // unsubscribe footers) are extracted ONCE into boilerplate_templates
    // and replaced in KO content with a `[[BOILERPLATE:<id>]]` token.
    // The boilerplate_uses join records every KO that referenced each
    // template so display / search can re-inject the text on demand.
    //
    // No data is destroyed: raw mbox/eml/pdf files on disk stay
    // untouched, and the templates table preserves the literal bytes
    // verbatim. Re-assembling the original KO body is one JOIN.

    private static let v15: String = """
    CREATE TABLE IF NOT EXISTS boilerplate_templates (
        id TEXT PRIMARY KEY,
        body TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'unknown',
        first_seen_at REAL NOT NULL,
        byte_size INTEGER NOT NULL,
        match_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_boilerplate_kind
        ON boilerplate_templates(kind);

    CREATE TABLE IF NOT EXISTS boilerplate_uses (
        template_id TEXT NOT NULL,
        ko_id TEXT NOT NULL,
        PRIMARY KEY (template_id, ko_id),
        FOREIGN KEY (template_id) REFERENCES boilerplate_templates(id) ON DELETE CASCADE,
        FOREIGN KEY (ko_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_boilerplate_uses_ko
        ON boilerplate_uses(ko_id);
    """

    // MARK: - v16 — G2-3 contextual retrieval (per-chunk context prefix)
    //
    // Anthropic-style contextual retrieval. Each chunk carries a one-
    // sentence summary of its role inside the parent document. The
    // prefix is prepended ONLY at embed time so display, FTS, and
    // citation snippets are unaffected — the stored `chunk.text` and
    // `chunks_fts.text` keep their original bytes. The column is
    // nullable so chunks ingested before this migration (and small-
    // doc chunks whose whole doc fits in one chunk) carry NULL.

    private static let v16: String = """
    ALTER TABLE chunks ADD COLUMN context_prefix TEXT;
    """

    // MARK: - v17 — G2-3 provenance: which generator produced the prefix
    //
    // Tracks whether each chunk's context_prefix came from the LLM
    // path or a fallback. Values written by IngestCoordinator:
    //   - "llm"                 — LLM provider produced the prefix
    //   - "heuristic"           — heuristic generator wired directly
    //   - "heuristic-fallback"  — LLM tried, timed out / failed / empty;
    //                             heuristic supplied the bytes instead
    //   - NULL                  — no prefix on this row (single-chunk
    //                             KOs, pre-v16 rows, generator disabled)
    //
    // Lets the user query "SELECT context_prefix_source, COUNT(*) FROM
    // chunks GROUP BY context_prefix_source" to see how often the
    // fallback path fired during ingest — useful for diagnosing a
    // misconfigured / unreachable LLM provider.

    private static let v17: String = """
    ALTER TABLE chunks ADD COLUMN context_prefix_source TEXT;
    """

    // MARK: - v18 — HISTORY Phase A: quality_tier on extracted facts
    //
    // Every extracted entity / event / memory_object / fact_bond
    // carries a `quality_tier` ('T1' / 'T2' / 'T3') so the brain can
    // demote noise at query time without ever deleting it. Direct
    // response to the "preserve all data, arrange don't filter"
    // directive.
    //
    // T1 — structured header-derived (EmailLoader's From / To / Cc /
    //      Date fields; calendar event ICS attendees; vCard rows).
    //      Highest trust.
    // T2 — body-text extraction via NER / NLTagger (the historical
    //      default). Mid trust.
    // T3 — shape-flagged noise (hostname-looking, vowel-less, mid-cap
    //      run, base64-ish). Preserved on disk; demoted at retrieval.
    //
    // Existing rows default to 'T2' since that's the historical
    // extraction path. A future backfill pass can re-classify
    // pre-v18 rows; not required for forward correctness.

    private static let v18: String = """
    ALTER TABLE entities       ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';
    ALTER TABLE events         ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';
    ALTER TABLE memory_objects ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';
    ALTER TABLE fact_bonds     ADD COLUMN quality_tier TEXT NOT NULL DEFAULT 'T2';

    CREATE INDEX IF NOT EXISTS idx_entities_quality_tier       ON entities(quality_tier);
    CREATE INDEX IF NOT EXISTS idx_events_quality_tier         ON events(quality_tier);
    CREATE INDEX IF NOT EXISTS idx_memory_objects_quality_tier ON memory_objects(quality_tier);
    CREATE INDEX IF NOT EXISTS idx_fact_bonds_quality_tier     ON fact_bonds(quality_tier);
    """

    // MARK: - v19 — HISTORY Phase B.1: entity co-occurrence graph
    //
    // An edge in this graph means two entities appear in at least
    // one shared KnowledgeObject. weight = number of shared KOs. The
    // Phase B community detector (Leiden / agglomerative) walks this
    // graph; the Phase D narrative composer uses the resolved
    // communities as the "topic" of a chapter.
    //
    // Schema:
    //   entity_a / entity_b — ordered lexicographically so each pair
    //     appears once (avoids both (A,B) and (B,A) edges)
    //   weight              — shared-KO count
    //   computed_at         — when this row was last rebuilt
    //
    // Index on (entity_a, entity_b) is the PK; reverse-direction
    // queries hit idx_cooc_b_a.

    private static let v19: String = """
    CREATE TABLE entity_cooccurrences (
        entity_a    TEXT NOT NULL,
        entity_b    TEXT NOT NULL,
        weight      INTEGER NOT NULL DEFAULT 1,
        computed_at REAL NOT NULL,
        PRIMARY KEY (entity_a, entity_b),
        FOREIGN KEY (entity_a) REFERENCES entities(id) ON DELETE CASCADE,
        FOREIGN KEY (entity_b) REFERENCES entities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_cooc_b_a   ON entity_cooccurrences(entity_b, entity_a);
    CREATE INDEX IF NOT EXISTS idx_cooc_weight ON entity_cooccurrences(weight DESC);
    """

    // MARK: - v20 — HISTORY Phase B.2: community detection results
    //
    // Two tables:
    //   entity_communities   — membership (which entity in which community)
    //   community_summaries  — LLM-generated per-community summary
    //
    // Why two: the detector (B.2) writes membership; the summarizer
    // (B.3) writes the LLM-derived narrative without needing to
    // rewrite memberships.
    //
    // A `level` column on entity_communities is reserved for the
    // hierarchical detector (Leiden produces a tree); the
    // agglomerative MVP shipped here uses level=0 only.

    private static let v20: String = """
    CREATE TABLE entity_communities (
        community_id TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        level        INTEGER NOT NULL DEFAULT 0,
        computed_at  REAL NOT NULL,
        PRIMARY KEY (community_id, entity_id, level),
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_communities_entity ON entity_communities(entity_id);
    CREATE INDEX IF NOT EXISTS idx_communities_level  ON entity_communities(level);

    CREATE TABLE community_summaries (
        community_id TEXT NOT NULL,
        level        INTEGER NOT NULL DEFAULT 0,
        title        TEXT NOT NULL,
        summary      TEXT NOT NULL,
        member_count INTEGER NOT NULL,
        top_entity_ids_json TEXT NOT NULL DEFAULT '[]',
        computed_at  REAL NOT NULL,
        PRIMARY KEY (community_id, level)
    );
    """

    // MARK: - v21 — HISTORY Phase C.1: per-event 5W+H narrative slots
    //
    // Adds `narrative_slots_json` to events. The column carries the
    // JSON encoding of an `EventNarrativeSlots` struct (six lists of
    // values keyed by who/what/when/where/why/how) with per-slot
    // provenance — source KO + chunk IDs and an extractor tag.
    //
    // This column is COMPLEMENTARY to v12's `slot_values_json` (the
    // FactSchema typed slot bag). FactSchema slots are typed and
    // bond-walkable; narrative_slots_json is the surface-form 5W+H
    // shape the Phase D composer reads to write chapter prose.
    //
    // Defaults to '{}' so existing rows decode as EventNarrativeSlots.empty.

    private static let v21: String = """
    ALTER TABLE events ADD COLUMN narrative_slots_json TEXT NOT NULL DEFAULT '{}';
    """

    // MARK: - v22 — HISTORY Phase G.1: temporal precision column
    //
    // Wikidata-style integer precision (0=unknown, 5=day, 7=instant,
    // see DatePrecision.swift). Default 5 = .day, which matches the
    // safest assumption for legacy rows: we know the date but not the
    // time. The G.2 composer reads this to render precision-aware
    // phrases ("in March 2025" vs "On Mar 14 at 09:00 UTC") instead
    // of falsely claiming midnight when the source was month-only.
    //
    // The G.2 backfill pass re-infers precision from each existing
    // event's dateConfidence (>=0.95 → instant, 0.85-0.94 → day,
    // 0.40-0.69 → month, <0.40 → unknown). New ingests will stamp
    // precision explicitly via the extractor.

    private static let v22: String = """
    ALTER TABLE events ADD COLUMN date_precision INTEGER NOT NULL DEFAULT 5;
    CREATE INDEX IF NOT EXISTS idx_events_precision ON events(date_precision);
    """

    // MARK: - v23 — HISTORY Phase G.3: typed causal links between events
    //
    // ONE table for all 5 relations (CAUSED / CONTRIBUTED_TO / ENABLED
    // / PREVENTED / FOLLOWED), append-only. Counterfactuals (hypothetical
    // "what-if" links) live in a SEPARATE table so they never UNION
    // into the verified history view — this honors the design research's
    // hard separation between verified-history and what-if reasoning.
    //
    // evidence_object_ids_json carries the source KOs that justify the
    // link (the composer cites these inline when rendering the
    // relation in prose). reason is an optional free-text snippet —
    // either the lexical trigger phrase that fired ("because of") or
    // a one-line heuristic description.
    //
    // superseded_by lets the Phase G.4 discoverer replace a link
    // without deleting its history; the link chain follows the same
    // append-only pattern as event_communities.

    private static let v23: String = """
    CREATE TABLE event_links (
        id                   TEXT PRIMARY KEY NOT NULL,
        source_event_id      TEXT NOT NULL,
        target_event_id      TEXT NOT NULL,
        relation             TEXT NOT NULL,
        confidence           REAL NOT NULL DEFAULT 0.5,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        allen                TEXT,
        source               TEXT NOT NULL DEFAULT 'heuristic',
        reason               TEXT,
        created_at           REAL NOT NULL,
        superseded_by        TEXT,
        FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (target_event_id) REFERENCES events(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_event_links_source ON event_links(source_event_id, relation);
    CREATE INDEX IF NOT EXISTS idx_event_links_target ON event_links(target_event_id, relation);
    CREATE INDEX IF NOT EXISTS idx_event_links_current ON event_links(superseded_by) WHERE superseded_by IS NULL;

    -- Parallel hypothetical-link table for Phase G future-work
    -- counterfactual reasoning. Never UNIONed into the verified-history
    -- timeline view. Same shape as event_links + a hypothesis note.
    CREATE TABLE event_links_hypothetical (
        id                   TEXT PRIMARY KEY NOT NULL,
        source_event_id      TEXT NOT NULL,
        target_event_id      TEXT NOT NULL,
        relation             TEXT NOT NULL,
        confidence           REAL NOT NULL DEFAULT 0.5,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        allen                TEXT,
        source               TEXT NOT NULL DEFAULT 'user',
        reason               TEXT,
        hypothesis_note      TEXT,
        created_at           REAL NOT NULL,
        FOREIGN KEY (source_event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (target_event_id) REFERENCES events(id) ON DELETE CASCADE
    );
    """

    // MARK: - v24 — HISTORY Phase I.A: event versioning (SCD2 + PROV-O)
    //
    // Slowly Changing Dimension Type 2: when an event's payload changes
    // (user correction, LLM re-enrichment refining a date, ontology
    // backfill flipping a kind), the existing row's `valid_to` is
    // closed and a new row is appended carrying the same `event_id`
    // and an incremented `version`. The current view is
    // `valid_to IS NULL`. Queries that want history walk the version
    // chain ordered by `version`.
    //
    // PROV-O light: every version carries (agent, activity) — who/what
    // proposed the change ("system.eventExtractor", "system.llmRefiner",
    // "user.correction", "ontology.backfill") and why. The compact form
    // here is deliberate — the full W3C PROV-O ontology is overkill for
    // a personal archive; the four fields cover the audit needs without
    // exploding the schema.
    //
    // No cascade on events(id) — the canonical row in `events` is the
    // current snapshot; version rows are an audit log that can outlive
    // a future events-table redesign.

    private static let v24: String = """
    CREATE TABLE event_versions (
        id              TEXT PRIMARY KEY NOT NULL,
        event_id        TEXT NOT NULL,
        version         INTEGER NOT NULL,
        valid_from      REAL NOT NULL,
        valid_to        REAL,
        payload_json    TEXT NOT NULL,
        agent           TEXT NOT NULL DEFAULT 'system',
        activity        TEXT,
        reason          TEXT,
        recorded_at     REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_event_versions_event ON event_versions(event_id, version);
    CREATE INDEX IF NOT EXISTS idx_event_versions_current ON event_versions(event_id) WHERE valid_to IS NULL;
    CREATE INDEX IF NOT EXISTS idx_event_versions_recorded ON event_versions(recorded_at);
    """

    // MARK: - v25 — HISTORY Phase I.B: investigation notebook
    //
    // Persisted Plan-and-Solve investigations. Each investigation row
    // is the user's original question + the runner's final synthesis;
    // the steps live in a separate child table to keep updates cheap
    // when the runner streams.
    //
    // FK cascade so deleting an investigation also drops its steps —
    // the user-facing "delete from notebook" action is a single row
    // delete from `investigations` and SQLite handles the rest.
    //
    // answer_body / answer_confidence / answer_citations_json store
    // the per-step VerifiedAnswer in a compact denormalized form so
    // the notebook detail view doesn't need to re-run anything. The
    // citations array is just the object-id list (the file resolution
    // happens at render time).

    private static let v25: String = """
    CREATE TABLE investigations (
        id              TEXT PRIMARY KEY NOT NULL,
        question        TEXT NOT NULL,
        synthesis       TEXT,
        created_at      REAL NOT NULL,
        finished_at     REAL
    );

    CREATE INDEX IF NOT EXISTS idx_investigations_created ON investigations(created_at DESC);

    CREATE TABLE investigation_steps (
        id                   TEXT PRIMARY KEY NOT NULL,
        investigation_id     TEXT NOT NULL,
        ordinal              INTEGER NOT NULL,
        question             TEXT NOT NULL,
        answer_body          TEXT,
        answer_confidence    REAL,
        answer_citations_json TEXT NOT NULL DEFAULT '[]',
        created_at           REAL NOT NULL,
        FOREIGN KEY (investigation_id) REFERENCES investigations(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_investigation_steps_inv
        ON investigation_steps(investigation_id, ordinal);
    """

    // MARK: - v26 — Saved queries (Vol 28 §Core Workspace)
    //
    // Lightweight bookmarking: the user marks a question (with
    // optional notes) so they can re-run it later without retyping.
    // No retrieval-result snapshot stored — re-running the question
    // re-walks the live ledger, which is the right semantic on a
    // continuously-ingesting personal archive (yesterday's "what
    // did supplier X send me" gains new evidence today).

    private static let v26: String = """
    CREATE TABLE saved_queries (
        id              TEXT PRIMARY KEY NOT NULL,
        question        TEXT NOT NULL,
        title           TEXT,
        notes           TEXT,
        category        TEXT,
        created_at      REAL NOT NULL,
        last_run_at     REAL
    );

    CREATE INDEX IF NOT EXISTS idx_saved_queries_created
        ON saved_queries(created_at DESC);
    """

    // MARK: - v27 — Assertion substrate (Vol 17 §A3)
    //
    // Subject-predicate-object triple that sits between extraction
    // and events. The full V17 §A3 refactor would derive events
    // from assertions, but the substrate ships first as an additive
    // table so user-asserted claims + future LLM extractions can
    // start landing without disturbing the existing event pipeline.
    //
    // Polymorphic object: an assertion can target another entity
    // (subject relates to entity X), an event (subject did event Y),
    // or a literal value (subject has property Z). Exactly one of
    // object_entity_id / object_event_id / object_value is set.
    //
    // Evidence + agent + recorded_at + retracted_at mirror the
    // PROV-O fields already on event_versions, so future tooling
    // can query both stores with one shape.

    private static let v27: String = """
    CREATE TABLE assertions (
        id                   TEXT PRIMARY KEY NOT NULL,
        subject_kind         TEXT NOT NULL,
        subject_id           TEXT NOT NULL,
        predicate            TEXT NOT NULL,
        object_kind          TEXT NOT NULL,
        object_value         TEXT,
        object_entity_id     TEXT,
        object_event_id      TEXT,
        confidence           REAL NOT NULL DEFAULT 0.5,
        evidence_object_ids_json TEXT NOT NULL DEFAULT '[]',
        agent                TEXT NOT NULL DEFAULT 'user',
        reason               TEXT,
        recorded_at          REAL NOT NULL,
        retracted_at         REAL
    );

    CREATE INDEX IF NOT EXISTS idx_assertions_subject
        ON assertions(subject_kind, subject_id);
    CREATE INDEX IF NOT EXISTS idx_assertions_predicate
        ON assertions(predicate);
    CREATE INDEX IF NOT EXISTS idx_assertions_recorded
        ON assertions(recorded_at DESC);
    CREATE INDEX IF NOT EXISTS idx_assertions_current
        ON assertions(retracted_at) WHERE retracted_at IS NULL;
    """

    // MARK: - v28 — Closed-corpus answer contract
    //
    // Kalsmritikosh is a ledger-based historical intelligence system,
    // not a chat-with-files RAG app. This migration adds the substrate
    // for "no citation, no factual claim":
    //
    //   corpus_snapshots  — a point-in-time census of the archive
    //       (files registered / parsed / searchable / ledgered /
    //       pending / failed) plus a content-manifest hash. Every
    //       answer is tied to the snapshot it was produced against, so
    //       the UI can say "answered from a corpus that was 87%
    //       ledgered, 1,204 files pending OCR".
    //
    //   answers           — the persisted answer object. The LLM prose
    //       is NOT the truth object; it's the human-facing rendering of
    //       a set of claims. Each answer carries an answer_state
    //       (SUPPORTED / PARTIALLY_SUPPORTED / CONTRADICTED /
    //       NOT_FOUND / INSUFFICIENTLY_INDEXED) and a confidence.
    //
    //   answer_claims     — one row per atomic claim inside an answer,
    //       each with its own support_status + confidence.
    //
    //   claim_evidence    — the claim→evidence contract, persisted.
    //       Polymorphic: a claim can be supported by a KO, a chunk, an
    //       event, or an entity. evidence_role distinguishes supports
    //       vs. contradicts vs. context.
    //
    // All four are additive; no existing table is touched. The brain
    // wires into these in a later change (answerability gate + persist
    // on answer) — the substrate ships first so the schema is stable.

    private static let v28: String = """
    CREATE TABLE corpus_snapshots (
        id                       TEXT PRIMARY KEY NOT NULL,
        created_at               REAL NOT NULL,
        schema_version           INTEGER NOT NULL,
        file_count               INTEGER NOT NULL DEFAULT 0,
        parsed_count             INTEGER NOT NULL DEFAULT 0,
        indexed_count            INTEGER NOT NULL DEFAULT 0,
        ledgered_count           INTEGER NOT NULL DEFAULT 0,
        failed_count             INTEGER NOT NULL DEFAULT 0,
        pending_ocr_count        INTEGER NOT NULL DEFAULT 0,
        pending_enrichment_count INTEGER NOT NULL DEFAULT 0,
        content_manifest_hash    TEXT NOT NULL DEFAULT ''
    );

    CREATE INDEX IF NOT EXISTS idx_corpus_snapshots_created
        ON corpus_snapshots(created_at DESC);

    CREATE TABLE answers (
        id                 TEXT PRIMARY KEY NOT NULL,
        question           TEXT NOT NULL,
        answer_state       TEXT NOT NULL,
        corpus_snapshot_id TEXT,
        body               TEXT NOT NULL,
        confidence         REAL NOT NULL DEFAULT 0.0,
        source             TEXT,
        created_at         REAL NOT NULL,
        FOREIGN KEY(corpus_snapshot_id) REFERENCES corpus_snapshots(id) ON DELETE SET NULL
    );

    CREATE INDEX IF NOT EXISTS idx_answers_created
        ON answers(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_answers_state
        ON answers(answer_state);

    CREATE TABLE answer_claims (
        id             TEXT PRIMARY KEY NOT NULL,
        answer_id      TEXT NOT NULL,
        claim_text     TEXT NOT NULL,
        support_status TEXT NOT NULL,
        confidence     REAL NOT NULL DEFAULT 0.0,
        ordinal        INTEGER NOT NULL DEFAULT 0,
        created_at     REAL NOT NULL,
        FOREIGN KEY(answer_id) REFERENCES answers(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_answer_claims_answer
        ON answer_claims(answer_id);

    CREATE TABLE claim_evidence (
        claim_id      TEXT NOT NULL,
        object_id     TEXT,
        chunk_id      TEXT,
        event_id      TEXT,
        entity_id     TEXT,
        evidence_role TEXT NOT NULL DEFAULT 'supports',
        PRIMARY KEY(claim_id, object_id, chunk_id, event_id, entity_id),
        FOREIGN KEY(claim_id) REFERENCES answer_claims(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_claim_evidence_claim
        ON claim_evidence(claim_id);
    """

    // MARK: - v29 — Persistent embedding cache
    //
    // An L2 behind the in-memory LRU: identical text (email signatures,
    // legal disclaimers, quoted footers, and re-ingested files) doesn't
    // pay the embedding cost again across launches. Keyed by
    // (model_id, text_hash) so switching embedders (e.g. NL → BGE-M3)
    // never returns a stale vector — a different model_id is a cache
    // miss. Vector is stored as a raw Float32 BLOB (full fidelity; the
    // quantized copy still lives in `vectors` for the ANN index).
    //
    // This is a cache, not ledger data — safe to DELETE wholesale; it
    // rebuilds on demand. No foreign keys.

    private static let v29: String = """
    CREATE TABLE embedding_cache (
        model_id   TEXT NOT NULL,
        text_hash  TEXT NOT NULL,
        dimension  INTEGER NOT NULL,
        vector     BLOB NOT NULL,
        created_at REAL NOT NULL,
        PRIMARY KEY (model_id, text_hash)
    );

    CREATE INDEX IF NOT EXISTS idx_embedding_cache_created
        ON embedding_cache(created_at DESC);
    """

    // MARK: - v30 — Enrichment tiers (System 2: Hot / Warm / Cold)
    //
    // Per-document importance + tier. The TierPromoter recomputes
    // importance from cheap signals (citations, query hits, pins,
    // recency) and assigns a tier; in Hot/Warm/Cold mode only HOT
    // documents get deep LLM enrichment, cold stays rule-only. Additive
    // + cache-like: safe to clear (it rebuilds from signals).

    private static let v30: String = """
    CREATE TABLE enrichment_status (
        object_id      TEXT PRIMARY KEY NOT NULL,
        tier           TEXT NOT NULL DEFAULT 'cold',   -- cold | warm | hot
        importance     REAL NOT NULL DEFAULT 0,
        query_hits     INTEGER NOT NULL DEFAULT 0,
        citation_count INTEGER NOT NULL DEFAULT 0,
        pinned         INTEGER NOT NULL DEFAULT 0,
        enriched       INTEGER NOT NULL DEFAULT 0,      -- deep pass done?
        updated_at     REAL NOT NULL,
        FOREIGN KEY(object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );

    CREATE INDEX IF NOT EXISTS idx_enrichment_tier
        ON enrichment_status(tier);
    CREATE INDEX IF NOT EXISTS idx_enrichment_importance
        ON enrichment_status(importance DESC);
    """

    // MARK: - v31 — Gap nodes + persisted contradictions (System 3)
    //
    // `gap_nodes` — INFERRED expected-but-missing evidence (a reply with
    // no ingested parent, a hole in a numbered/dated sequence, a
    // reference to an absent document). Never asserted as fact; low
    // confidence, always shown as "likely missing" with a reason. This
    // is the historiographical "silence" discipline: a gap is not a
    // negation.
    //
    // `contradictions` — persist conflicts the ContradictionFinder
    // detects so they accumulate in the ledger instead of being
    // recomputed per query.

    private static let v31: String = """
    CREATE TABLE gap_nodes (
        id            TEXT PRIMARY KEY NOT NULL,
        kind          TEXT NOT NULL,          -- threadParent | sequenceHole | danglingReference | cadenceBreak
        description   TEXT NOT NULL,
        reason        TEXT NOT NULL,
        confidence    REAL NOT NULL DEFAULT 0.3,
        near_entity   TEXT,
        before_event  TEXT,
        after_event   TEXT,
        evidence_object_id TEXT,
        detected_at   REAL NOT NULL,
        dismissed     INTEGER NOT NULL DEFAULT 0
    );

    CREATE INDEX IF NOT EXISTS idx_gap_nodes_kind ON gap_nodes(kind);
    CREATE INDEX IF NOT EXISTS idx_gap_nodes_entity ON gap_nodes(near_entity);

    CREATE TABLE contradictions (
        id           TEXT PRIMARY KEY NOT NULL,
        description  TEXT NOT NULL,
        claim_a      TEXT NOT NULL,
        claim_b      TEXT NOT NULL,
        evidence_a   TEXT,
        evidence_b   TEXT,
        severity     TEXT NOT NULL DEFAULT 'medium',
        status       TEXT NOT NULL DEFAULT 'open',
        detected_at  REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_contradictions_status
        ON contradictions(status);
    """

    // T16 — persist an evidentiary status per event (§13 vocabulary).
    // Backfill from each row's own signals so an existing corpus gets a
    // realistic spread instead of all-one-value. Idempotent: the guards are
    // mutually exclusive (observed/derived need confidence >= 0.60/0.75, so
    // an unsupported row can never match them), so re-running yields the same
    // result. CONTRADICTED/REVIEWED/REJECTED are never set here.
    private static let v32: String = """
    ALTER TABLE events ADD COLUMN status TEXT NOT NULL DEFAULT 'inferred';

    UPDATE events SET status = 'observed'
        WHERE quality_tier = 'T1' AND confidence >= 0.75 AND date_confidence >= 0.60;

    UPDATE events SET status = 'derived'
        WHERE quality_tier != 'T1' AND date_confidence < 0.60 AND confidence >= 0.60;

    UPDATE events SET status = 'unsupported'
        WHERE confidence < 0.33;

    CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
    """

    // T17 — append-only human-review ledger. Every accept/reject/correct is
    // a new row; prior_value preserves what it superseded. Nothing is ever
    // UPDATEd/DELETEd (§12.9 / §11 rule 11).
    private static let v33: String = """
    CREATE TABLE fact_reviews (
        id            TEXT PRIMARY KEY NOT NULL,
        subject_kind  TEXT NOT NULL,          -- event | assertion | contradiction | gap
        subject_id    TEXT NOT NULL,          -- the reviewed ledger item's id
        action        TEXT NOT NULL,          -- accept | reject | correct
        prior_value   TEXT,
        new_value     TEXT,
        reviewer      TEXT NOT NULL DEFAULT 'user',
        reason        TEXT,
        reviewed_at   REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_fact_reviews_subject ON fact_reviews(subject_id);
    CREATE INDEX IF NOT EXISTS idx_fact_reviews_at ON fact_reviews(reviewed_at);
    """

    // T18 — chain-of-custody ledger + privileged flags (§21). custody_events
    // is append-only. `privileged` marks material that must be filtered out of
    // answers by default (enforced like PrivacyGate filters cloud providers).
    private static let v34: String = """
    CREATE TABLE custody_events (
        id       TEXT PRIMARY KEY NOT NULL,
        file_id  TEXT NOT NULL,
        kind     TEXT NOT NULL,        -- acquired | hash_computed | hash_verified | hash_mismatch | exported | disclosed
        actor    TEXT NOT NULL DEFAULT 'system',
        at       REAL NOT NULL,
        detail   TEXT,
        hash     TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_custody_file ON custody_events(file_id);
    CREATE INDEX IF NOT EXISTS idx_custody_kind ON custody_events(kind);

    ALTER TABLE files ADD COLUMN privileged INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE knowledge_objects ADD COLUMN privileged INTEGER NOT NULL DEFAULT 0;
    """

    // §16 — derived-objects ledger. Append-only record of every USEFUL
    // query-time LLM extraction (claim / event / relationship / contradiction
    // / memory / timeline interpretation) with full provenance, so
    // minimum-LLM work compounds instead of repeating: a later request with an
    // unchanged source_hash + extractor_version can REUSE the stored result
    // rather than paying for the model again. Never overwritten — a correction
    // inserts a new row and points the old row's superseded_by at it.
    private static let v35: String = """
    CREATE TABLE derived_objects (
        id                TEXT PRIMARY KEY NOT NULL,
        kind              TEXT NOT NULL,
        content           TEXT NOT NULL,
        source_evidence   TEXT,
        source_hash       TEXT NOT NULL,
        model_id          TEXT,
        provider_id       TEXT,
        prompt_version    TEXT,
        extractor_version TEXT NOT NULL,
        confidence        REAL NOT NULL DEFAULT 0,
        review_status     TEXT NOT NULL DEFAULT 'unreviewed',
        superseded_by     TEXT,
        created_at        REAL NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_derived_source_hash ON derived_objects(source_hash);
    CREATE INDEX IF NOT EXISTS idx_derived_kind ON derived_objects(kind);
    CREATE INDEX IF NOT EXISTS idx_derived_extractor ON derived_objects(extractor_version);
    """

    // P5.5 — contradiction taxonomy. Adds a `kind` column so a conflict is
    // classified (date/amount/identity/payment/…) rather than untyped. Additive
    // with a default so existing rows remain valid.
    private static let v36: String = """
    ALTER TABLE contradictions ADD COLUMN kind TEXT NOT NULL DEFAULT 'other';
    """

    // A1 (§6.3 / P3.0g) — canonical structural evidence layer. Additive: a file
    // becomes a source_version whose ParsedDocument is stored as ordered, typed
    // evidence_blocks with exact locators, plus a deterministic document_profile
    // and a parser_run record. Legacy knowledge_objects/chunks remain; these
    // tables become the authority as subsystems migrate. Nothing is dropped.
    private static let v37: String = """
    CREATE TABLE source_documents (
        id                 TEXT PRIMARY KEY NOT NULL,
        logical_source_id  TEXT NOT NULL,
        filename           TEXT NOT NULL,
        detected_type      TEXT NOT NULL,
        mime_type          TEXT,
        content_hash       TEXT NOT NULL,
        extraction_status  TEXT NOT NULL,
        metadata           TEXT,
        created_at         REAL NOT NULL
    );

    CREATE TABLE source_versions (
        id                 TEXT PRIMARY KEY NOT NULL,
        logical_source_id  TEXT NOT NULL,
        document_id        TEXT,
        content_hash       TEXT NOT NULL,
        supersedes         TEXT,
        valid_from         REAL NOT NULL,
        valid_to           REAL,
        is_current         INTEGER NOT NULL DEFAULT 1,
        original_url       TEXT,
        created_at         REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_source_versions_logical ON source_versions(logical_source_id);
    CREATE INDEX IF NOT EXISTS idx_source_versions_current ON source_versions(logical_source_id, is_current);

    CREATE TABLE evidence_blocks (
        id                    TEXT PRIMARY KEY NOT NULL,
        document_id           TEXT NOT NULL,
        source_version_id     TEXT,
        parent_block_id       TEXT,
        ordinal               INTEGER NOT NULL,
        kind                  TEXT NOT NULL,
        raw_text              TEXT NOT NULL,
        normalized_text       TEXT NOT NULL,
        locator               TEXT,
        extraction_method     TEXT NOT NULL,
        extraction_confidence REAL NOT NULL,
        language              TEXT,
        attributes            TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_blocks_version ON evidence_blocks(source_version_id);
    CREATE INDEX IF NOT EXISTS idx_blocks_document ON evidence_blocks(document_id, ordinal);
    CREATE INDEX IF NOT EXISTS idx_blocks_kind ON evidence_blocks(kind);
    CREATE INDEX IF NOT EXISTS idx_blocks_parent ON evidence_blocks(parent_block_id);

    -- P2.6 · DEFERRED-KEPT (owner ruling 2026-09-24: "keep all").
    -- Verified 2026-09-24: this table has NO producer and NO consumer anywhere
    -- in non-test source. It is block-to-block graph scaffolding — reply-to,
    -- continuation, and containment edges between evidence blocks — designed
    -- and never populated.
    -- KEPT rather than dropped: the schema costs nothing empty, and the owner
    -- ruled that nothing is removed. EXEMPT from the coverage guard for the
    -- same reason: an unbuilt feature with reserved schema is not a wiring gap,
    -- and counting it as one would hide the real ones.
    -- To build it, the producer belongs next to persistStructuralDoc, where
    -- block order and parent/child relations are already known.
    CREATE TABLE evidence_block_edges (
        id            TEXT PRIMARY KEY NOT NULL,
        from_block_id TEXT NOT NULL,
        to_block_id   TEXT NOT NULL,
        relation      TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_block_edges_from ON evidence_block_edges(from_block_id);

    CREATE TABLE document_profiles (
        source_version_id      TEXT PRIMARY KEY NOT NULL,
        filename               TEXT NOT NULL,
        detected_type          TEXT NOT NULL,
        mime_type              TEXT,
        content_hash           TEXT NOT NULL,
        size_bytes             INTEGER NOT NULL DEFAULT 0,
        parser                 TEXT NOT NULL,
        parser_version         TEXT NOT NULL,
        language               TEXT,
        section_outline        TEXT,
        first_meaningful_block TEXT,
        block_count            INTEGER NOT NULL,
        page_count             INTEGER,
        sheet_count            INTEGER,
        slide_count            INTEGER,
        message_count          INTEGER,
        attachment_count       INTEGER,
        child_count            INTEGER,
        extraction_status      TEXT NOT NULL,
        warning_count          INTEGER NOT NULL DEFAULT 0,
        extraction_confidence  REAL NOT NULL DEFAULT 1.0,
        is_queryable           INTEGER NOT NULL DEFAULT 1,
        created_at             REAL NOT NULL
    );

    CREATE TABLE parser_runs (
        id                TEXT PRIMARY KEY NOT NULL,
        source_version_id TEXT,
        parser            TEXT NOT NULL,
        parser_version    TEXT NOT NULL,
        started_at        REAL NOT NULL,
        ended_at          REAL,
        status            TEXT NOT NULL,
        block_count       INTEGER,
        warning_count     INTEGER,
        error             TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_parser_runs_version ON parser_runs(source_version_id);
    """

    // A5.2 — Assertion provenance columns. The Assertion substrate becomes the
    // claim–evidence layer between structural EvidenceBlocks and typed
    // Event/Relationship rows: each assertion records the exact evidence blocks
    // that support it, the verbatim direct quote, the source that asserted it,
    // whether it was source-asserted vs deterministically-derived vs inferred,
    // and the extractor version that produced it. Additive with defaults so
    // existing rows remain valid; the legacy evidence_object_ids_json (KO-level)
    // stays for backward compatibility.
    private static let v38: String = """
    ALTER TABLE assertions ADD COLUMN evidence_block_ids_json TEXT NOT NULL DEFAULT '[]';
    ALTER TABLE assertions ADD COLUMN direct_quote TEXT;
    ALTER TABLE assertions ADD COLUMN asserting_source_id TEXT;
    ALTER TABLE assertions ADD COLUMN provenance TEXT NOT NULL DEFAULT 'source_asserted';
    ALTER TABLE assertions ADD COLUMN extractor_version TEXT NOT NULL DEFAULT 'v1';
    CREATE INDEX IF NOT EXISTS idx_assertions_source ON assertions(asserting_source_id);
    """

    // A5.8 — reversible human review. A `.reverse` review row records the id of
    // the review it undoes; the undone row is preserved (append-only). Additive,
    // nullable — older rows and non-reversal actions leave it NULL.
    private static let v39: String = """
    ALTER TABLE fact_reviews ADD COLUMN reversal_of TEXT;
    CREATE INDEX IF NOT EXISTS idx_fact_reviews_reversal ON fact_reviews(reversal_of);
    """

    // A5.9 / A5.10 — answer→block replay. A claim_evidence row for an event
    // citation records the event's supporting EvidenceBlock ids (JSON array, so
    // multiple blocks fit one row without changing the composite PK), extending
    // the audit chain answer → claim → event → block → locator → source version.
    // Additive, nullable — older rows leave it NULL.
    private static let v40: String = """
    ALTER TABLE claim_evidence ADD COLUMN block_ids TEXT;
    """

    // A6.1 — full-text index over the structural evidence layer, so retrieval
    // can find typed EvidenceBlocks (with exact locators) directly rather than
    // only flattened chunks. External-content FTS5 over evidence_blocks
    // .normalized_text, kept in sync by triggers, rebuilt from existing rows.
    // Additive: no existing table/behaviour changes.
    private static let v41: String = """
    CREATE VIRTUAL TABLE IF NOT EXISTS evidence_blocks_fts USING fts5(
        normalized_text,
        content='evidence_blocks',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );

    CREATE TRIGGER IF NOT EXISTS evidence_blocks_fts_ai AFTER INSERT ON evidence_blocks BEGIN
        INSERT INTO evidence_blocks_fts(rowid, normalized_text) VALUES (new.rowid, new.normalized_text);
    END;
    CREATE TRIGGER IF NOT EXISTS evidence_blocks_fts_ad AFTER DELETE ON evidence_blocks BEGIN
        INSERT INTO evidence_blocks_fts(evidence_blocks_fts, rowid, normalized_text) VALUES('delete', old.rowid, old.normalized_text);
    END;
    CREATE TRIGGER IF NOT EXISTS evidence_blocks_fts_au AFTER UPDATE ON evidence_blocks BEGIN
        INSERT INTO evidence_blocks_fts(evidence_blocks_fts, rowid, normalized_text) VALUES('delete', old.rowid, old.normalized_text);
        INSERT INTO evidence_blocks_fts(rowid, normalized_text) VALUES (new.rowid, new.normalized_text);
    END;

    INSERT INTO evidence_blocks_fts(evidence_blocks_fts) VALUES('rebuild');
    """

    // A2 §7.3/§7.7 — durable per-file ingest outcome, so a failed or skipped
    // ingest is visible (Sources UI) and re-tryable rather than silently lost.
    // Append-only log keyed by URL + content hash; the latest row per URL is the
    // current state. Additive; no existing table/behaviour changes.
    private static let v42: String = """
    CREATE TABLE ingest_file_attempts (
        id            TEXT PRIMARY KEY NOT NULL,
        url           TEXT NOT NULL,
        content_hash  TEXT,
        status        TEXT NOT NULL,
        stage         TEXT,
        detail        TEXT,
        attempted_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_ingest_attempts_url ON ingest_file_attempts(url, attempted_at);
    CREATE INDEX IF NOT EXISTS idx_ingest_attempts_status ON ingest_file_attempts(status);
    """

    // A2 §7.6 — parent→child source provenance (email→attachment, archive→
    // member, …) persisted as explicit relations, so an attachment folded into
    // one canonical copy by dedup still records WHICH parents referenced it.
    // Additive; deduped by (parent, child, relation).
    private static let v43: String = """
    CREATE TABLE source_relations (
        id             TEXT PRIMARY KEY NOT NULL,
        parent_file_id TEXT NOT NULL,
        child_file_id  TEXT NOT NULL,
        relation       TEXT NOT NULL,
        created_at     REAL NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_source_relations_unique
        ON source_relations(parent_file_id, child_file_id, relation);
    CREATE INDEX IF NOT EXISTS idx_source_relations_child ON source_relations(child_file_id);
    """

    // PI.1 — version-instead-of-delete. When a known file's bytes change, the
    // pipeline USED to cascade-delete the old file row (destroying its
    // extracted KO content). That violated "never delete extracted data". These
    // additive history tables let ingest ARCHIVE the prior version's file record
    // + KO content BEFORE the active rows are refreshed, so no extraction is
    // ever silently lost and the change is auditable. Active tables still hold
    // only the current version (retrieval unchanged — zero regression); surfacing
    // old versions in retrieval is deferred to the version-aware fusion (P5.1).
    private static let v44: String = """
    CREATE TABLE IF NOT EXISTS file_versions (
        version_id     TEXT PRIMARY KEY NOT NULL,
        file_id        TEXT NOT NULL,
        url            TEXT NOT NULL,
        source_type    TEXT NOT NULL,
        size_bytes     INTEGER NOT NULL DEFAULT 0,
        modified_at    REAL,
        ingested_at    REAL,
        content_hash   TEXT,
        superseded_at  REAL NOT NULL,
        superseded_by  TEXT,
        created_at     REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_file_versions_file ON file_versions(file_id);
    CREATE INDEX IF NOT EXISTS idx_file_versions_hash ON file_versions(content_hash);

    CREATE TABLE IF NOT EXISTS knowledge_objects_history (
        history_id     TEXT PRIMARY KEY NOT NULL,
        object_id      TEXT NOT NULL,
        file_id        TEXT NOT NULL,
        source_type    TEXT NOT NULL,
        content        TEXT NOT NULL,
        metadata_json  TEXT NOT NULL DEFAULT '{}',
        confidence     REAL NOT NULL DEFAULT 1.0,
        superseded_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_ko_history_object ON knowledge_objects_history(object_id);
    CREATE INDEX IF NOT EXISTS idx_ko_history_file ON knowledge_objects_history(file_id);
    """

    // MARK: - v45 — Persona features Epic 1: the shared evidence-work engine
    //
    // (Research-grounded persona program, F1 + F2.) ONE engine, many
    // work-product templates — NOT five persona apps. This migration adds:
    //
    //   workspaces          — a bounded matter / investigation / research
    //       question / personal issue. A workspace is a FILTERED VIEW over the
    //       single ledger; membership rows point at existing files/entities and
    //       NEVER duplicate evidence. Removing a membership row never deletes
    //       evidence; deleting a file cascades only the membership pointer.
    //   workspace_sources   — file membership (a source may belong to many
    //       workspaces).
    //   workspace_entities  — entity membership.
    //
    //   review_tags         — tag definitions (workspace-scoped or global).
    //   review_decisions    — APPEND-ONLY review ledger. Every tag application,
    //       review-state change, and note is a new row carrying prior→new values
    //       and the reviewer; nothing is ever UPDATEd/DELETEd, so history is
    //       complete and a decision is reversed by appending a reversing row
    //       (mirrors fact_reviews v33/v39). Polymorphic target_kind covers
    //       source / evidenceBlock / assertion / event / entity / relationship /
    //       contradiction / gap / answerClaim.
    //   saved_views         — named, reopenable filter sets over a workspace.
    //   saved_view_filters  — key/value filter pairs for a saved view.
    //
    // Persona templates (F6) change only default fields, tags, layout, and
    // terminology — never these tables' semantics. Additive; no existing table
    // is touched.
    private static let v45: String = """
    CREATE TABLE workspaces (
        id                 TEXT PRIMARY KEY NOT NULL,
        title              TEXT NOT NULL,
        template_type      TEXT NOT NULL DEFAULT 'general',
        description        TEXT,
        status             TEXT NOT NULL DEFAULT 'active',
        default_date_start REAL,
        default_date_end   REAL,
        default_scope_json TEXT NOT NULL DEFAULT '{}',
        created_at         REAL NOT NULL,
        updated_at         REAL NOT NULL,
        archived_at        REAL
    );
    CREATE INDEX idx_workspaces_status ON workspaces(status);

    CREATE TABLE workspace_sources (
        workspace_id  TEXT NOT NULL,
        file_id       TEXT NOT NULL,
        added_at      REAL NOT NULL,
        PRIMARY KEY (workspace_id, file_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_workspace_sources_file ON workspace_sources(file_id);

    CREATE TABLE workspace_entities (
        workspace_id  TEXT NOT NULL,
        entity_id     TEXT NOT NULL,
        added_at      REAL NOT NULL,
        PRIMARY KEY (workspace_id, entity_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_workspace_entities_entity ON workspace_entities(entity_id);

    CREATE TABLE review_tags (
        id            TEXT PRIMARY KEY NOT NULL,
        workspace_id  TEXT,
        name          TEXT NOT NULL,
        color         TEXT,
        kind          TEXT NOT NULL DEFAULT 'user',
        created_at    REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_review_tags_workspace ON review_tags(workspace_id);

    CREATE TABLE review_decisions (
        id            TEXT PRIMARY KEY NOT NULL,
        workspace_id  TEXT,
        target_kind   TEXT NOT NULL,
        target_id     TEXT NOT NULL,
        dimension     TEXT NOT NULL DEFAULT 'reviewState',
        decision      TEXT,
        tag_id        TEXT,
        note          TEXT,
        prior_value   TEXT,
        reviewer      TEXT NOT NULL DEFAULT 'user',
        reversal_of   TEXT,
        created_at    REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_review_decisions_target ON review_decisions(target_kind, target_id, created_at);
    CREATE INDEX idx_review_decisions_workspace ON review_decisions(workspace_id);
    CREATE INDEX idx_review_decisions_tag ON review_decisions(tag_id);

    CREATE TABLE saved_views (
        id            TEXT PRIMARY KEY NOT NULL,
        workspace_id  TEXT,
        title         TEXT NOT NULL,
        created_at    REAL NOT NULL,
        updated_at    REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_saved_views_workspace ON saved_views(workspace_id);

    CREATE TABLE saved_view_filters (
        id            TEXT PRIMARY KEY NOT NULL,
        view_id       TEXT NOT NULL,
        filter_key    TEXT NOT NULL,
        filter_value  TEXT NOT NULL,
        FOREIGN KEY (view_id) REFERENCES saved_views(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_saved_view_filters_view ON saved_view_filters(view_id);
    """

    // MARK: - v46 — Persona features F9: research screening workflow
    //
    // A transparent, single-user screening log with PRISMA-COMPATIBLE flow
    // counts (§14). It does NOT claim independent dual-review compliance,
    // meta-analysis, or a final risk-of-bias judgment. `screening_protocols`
    // holds one structured inclusion protocol per workspace (JSON — PICO is
    // optional; not every review uses it). `screening_records` is one row per
    // candidate document with its current stage + decision + exclusion reason;
    // every exclusion must carry a reason (enforced in the repo/UI). Decisions
    // are reversible; the append-only WHY lives in the shared review ledger. No
    // LLM ever makes the final inclusion decision — suggestions stay separate
    // from reviewer decisions. Additive; no existing table touched.
    private static let v46: String = """
    CREATE TABLE screening_protocols (
        workspace_id   TEXT PRIMARY KEY NOT NULL,
        protocol_json  TEXT NOT NULL DEFAULT '{}',
        updated_at     REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );

    CREATE TABLE screening_records (
        id               TEXT PRIMARY KEY NOT NULL,
        workspace_id     TEXT NOT NULL,
        source_id        TEXT,
        title            TEXT NOT NULL,
        authors          TEXT,
        year             INTEGER,
        stage            TEXT NOT NULL DEFAULT 'identified',
        decision         TEXT NOT NULL DEFAULT 'unresolved',
        exclusion_reason TEXT,
        reviewer         TEXT NOT NULL DEFAULT 'user',
        disagreement     INTEGER NOT NULL DEFAULT 0,
        notes            TEXT,
        created_at       REAL NOT NULL,
        updated_at       REAL NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_screening_records_ws ON screening_records(workspace_id);
    CREATE INDEX idx_screening_records_stage ON screening_records(workspace_id, stage);
    CREATE INDEX idx_screening_records_decision ON screening_records(workspace_id, decision);
    """

    // MARK: - v47 — Persona features F8: timestamped transcript segments
    //
    // Timecoded transcript lines for audio/video sources (§13). Produced ON
    // DEMAND from the transcript UI (not during ingest), so the ingest path is
    // untouched. Each segment carries a real start/end (jump-to-time), the ASR
    // confidence, and a user-assignable speaker — speaker diarization is NOT
    // done on-device, so speakers default to unassigned and are renamed/merged
    // by the user (uncertain speakers stay visible, §13). `marked_quote` flags
    // a segment the user wants to export with its timecode. Additive.
    private static let v47: String = """
    CREATE TABLE transcript_segments (
        id                  TEXT PRIMARY KEY NOT NULL,
        source_file_id      TEXT NOT NULL,
        source_url          TEXT NOT NULL,
        ordinal             INTEGER NOT NULL,
        start_time          REAL NOT NULL,
        end_time            REAL NOT NULL,
        speaker             TEXT,
        speaker_confidence  REAL,
        text                TEXT NOT NULL,
        asr_confidence      REAL NOT NULL DEFAULT 0,
        review_state        TEXT NOT NULL DEFAULT 'unreviewed',
        marked_quote        INTEGER NOT NULL DEFAULT 0,
        engine              TEXT NOT NULL DEFAULT '',
        created_at          REAL NOT NULL
    );
    CREATE INDEX idx_transcript_segments_source ON transcript_segments(source_file_id, ordinal);
    CREATE INDEX idx_transcript_segments_quote ON transcript_segments(marked_quote);

    CREATE VIRTUAL TABLE IF NOT EXISTS transcript_segments_fts USING fts5(
        text,
        content='transcript_segments',
        content_rowid='rowid',
        tokenize='porter unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS transcript_segments_fts_ai AFTER INSERT ON transcript_segments BEGIN
        INSERT INTO transcript_segments_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS transcript_segments_fts_ad AFTER DELETE ON transcript_segments BEGIN
        INSERT INTO transcript_segments_fts(transcript_segments_fts, rowid, text) VALUES('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS transcript_segments_fts_au AFTER UPDATE ON transcript_segments BEGIN
        INSERT INTO transcript_segments_fts(transcript_segments_fts, rowid, text) VALUES('delete', old.rowid, old.text);
        INSERT INTO transcript_segments_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    """

    // MARK: - v48 — Stage 1 ingest quality gate: chunk embedding-admission flag
    //
    // "Do not embed everything." Chunks that are blank, tiny fragments, bare
    // page numbers, or lone navigation tokens carry no semantic signal. This
    // flag lets ingest mark such chunks as NOT admitted to the vector index
    // (ChunkAdmissionGate decides). Non-admitted chunks are still STORED and
    // remain FTS-/citation-searchable — nothing is deleted; they are only
    // excluded from embedding. Existing rows default to 1 (admitted), so the
    // vector layer is unchanged for anything ingested before this gate.
    private static let v48: String = """
    ALTER TABLE chunks ADD COLUMN admit_embedding INTEGER NOT NULL DEFAULT 1;
    CREATE INDEX IF NOT EXISTS idx_chunks_admit_embedding ON chunks(admit_embedding);
    """

    // MARK: - v49 — human-in-loop entity review status (soft-exclude, reversible)
    //
    // Lets a user REJECT (exclude) or RESTORE a canonical entity from the
    // Knowledge browser. Honoring the preserve-everything directive, a rejected
    // entity is NOT deleted: `review_status = 'rejected'` marks it so the entity
    // read surface (list / search / mention-ranked candidates) hides it by
    // default, and setting it back to NULL restores it. The action itself is
    // recorded append-only in fact_reviews (subject_kind = 'entity'), so it
    // shows in the Audit trail and can be undone. NULL = normal (the default for
    // every existing row), so nothing changes for data ingested before this.
    private static let v49: String = """
    ALTER TABLE entities ADD COLUMN review_status TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_entities_review_status ON entities(review_status);
    """

    // MARK: - v50 — human-in-loop event review status (soft-exclude, reversible)
    //
    // Extends the v49 entity mechanism to events: a user can Reject (exclude) or
    // Restore a single event from its detail sheet. `review_status = 'rejected'`
    // hides the event from the timeline, retrieval, and answers; NULL restores
    // it. The row and its trust `status` column are untouched (preserve-
    // everything). The action is recorded append-only in fact_reviews
    // (subject_kind = 'event'), so it shows in the Audit trail and is reversible.
    private static let v50: String = """
    ALTER TABLE events ADD COLUMN review_status TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_events_review_status ON events(review_status);
    """

    // MARK: - v51 — human-in-loop chunk review status (soft-exclude, reversible)
    //
    // Finest-grain reject: a user can exclude a single passage (chunk) from the
    // search index and answers, reversibly, from a search result. `review_status
    // = 'rejected'` drops the chunk from FTS, vector-hit hydration, and
    // first-chunk lookups; NULL restores it. Distinct from `admit_embedding`
    // (which is the ingest-time "don't embed noise" gate): this is an explicit
    // human decision, recorded append-only in fact_reviews (subject_kind =
    // 'chunk'). The chunk text and row are never deleted.
    private static let v51: String = """
    ALTER TABLE chunks ADD COLUMN review_status TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_chunks_review_status ON chunks(review_status);
    """

    // MARK: - v52 — human-in-loop entity merge (soft, reversible)
    //
    // Lets a user (or a deterministic suggester) unify two canonical entities
    // that are the same real-world thing ("J. Smith" → "John Smith"). Honoring
    // the preserve-everything directive, the loser row is NOT deleted or
    // FK-repointed: `merged_into = <winner id>` marks it, so canonical listings
    // hide it and the winner's mention view folds in the loser's mentions. NULL
    // = not merged (the default for every existing row). Setting it back to NULL
    // is a full unmerge (split). The action is recorded append-only in
    // fact_reviews (subject_kind = 'entity', action 'merge'/'reverse'), so it
    // shows in the Audit trail and is reversible. Self-reference is rejected in
    // the repository; a small resolve chain (with a depth cap) yields the final
    // canonical so a merged-into-a-merged case still resolves.
    private static let v52: String = """
    ALTER TABLE entities ADD COLUMN merged_into TEXT NULL REFERENCES entities(id);
    CREATE INDEX IF NOT EXISTS idx_entities_merged_into ON entities(merged_into);
    """

    // MARK: - v53 — proactive change-monitoring snapshots
    //
    // A snapshot captures the set of content-derived SIGNATURES of the
    // contradictions + gaps present at a moment (kind + normalized claims/desc,
    // NOT the volatile per-scan UUIDs), so a later diff can surface what's NEW or
    // RESOLVED since the user last acknowledged. One row per acknowledged
    // snapshot; the newest is the baseline. Derived data — safe to clear/rebuild.
    private static let v53: String = """
    CREATE TABLE IF NOT EXISTS monitor_snapshots (
        id                  TEXT PRIMARY KEY NOT NULL,
        created_at          REAL NOT NULL,
        signatures_json     TEXT NOT NULL DEFAULT '[]',
        contradiction_count INTEGER NOT NULL DEFAULT 0,
        gap_count           INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_monitor_snapshots_created ON monitor_snapshots(created_at);
    """

    // MARK: - v54 — evidence-first chunking + model-aware embeddings (Phase 1)
    //
    // Two additive changes, both preserving every existing row (audit P0:
    // "Do not remove chunks or vectors").
    //
    // 1. chunks.evidence_block_id + block_kind — a chunk derived from a typed
    //    EvidenceBlock records exactly which block it came from and that block's
    //    kind. NULL for legacy chunks (derived from flattened KO.content) and
    //    for formats with no structural parser, so retrieval can prefer
    //    block-backed chunks without breaking the fallback path.
    //
    // 2. chunk_embeddings — model-aware vector storage keyed by
    //    (chunk_id, model_id) so an Apple index and a quality (Core ML) index
    //    can COEXIST instead of one overwriting the other (audit P0 #6). The
    //    legacy `vectors` table is left untouched; its rows are backfilled here
    //    tagged with the current Apple model id, so no embedding is lost and the
    //    read path can migrate incrementally.
    private static let v54: String = """
    ALTER TABLE chunks ADD COLUMN evidence_block_id TEXT NULL;
    CREATE INDEX IF NOT EXISTS idx_chunks_evidence_block ON chunks(evidence_block_id);
    ALTER TABLE chunks ADD COLUMN block_kind TEXT NULL;

    CREATE TABLE IF NOT EXISTS chunk_embeddings (
        chunk_id      TEXT NOT NULL,
        model_id      TEXT NOT NULL,
        model_version TEXT NOT NULL DEFAULT '1',
        dim           INTEGER NOT NULL,
        q             BLOB NOT NULL,
        scale         REAL NOT NULL,
        created_at    REAL NOT NULL,
        PRIMARY KEY (chunk_id, model_id),
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_chunk_embeddings_model ON chunk_embeddings(model_id);
    INSERT OR IGNORE INTO chunk_embeddings (chunk_id, model_id, model_version, dim, q, scale, created_at)
        SELECT chunk_id, 'apple.nl.v1', '1', dim, q, scale, strftime('%s','now') FROM vectors;
    """

    // LAB-002 — durable, paged store for the Workbench EvidenceDataset kernel. A dataset's
    // columns live in `evidence_datasets`; its rows are paged in `dataset_rows` (cells as
    // JSON, each carrying its source-block lineage). Append-only, additive — no existing
    // table touched. FK cascade so deleting a dataset drops its rows.
    private static let v55: String = """
    CREATE TABLE IF NOT EXISTS evidence_datasets (
        id           TEXT PRIMARY KEY,
        name         TEXT NOT NULL,
        version      INTEGER NOT NULL DEFAULT 1,
        columns_json TEXT NOT NULL,
        created_at   REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS dataset_rows (
        dataset_id TEXT NOT NULL,
        ordinal    INTEGER NOT NULL,
        cells_json TEXT NOT NULL,
        PRIMARY KEY (dataset_id, ordinal),
        FOREIGN KEY (dataset_id) REFERENCES evidence_datasets(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_dataset_rows_dataset ON dataset_rows(dataset_id);
    """

    // ING-001 — durable ingest run-state so an interrupted ingest can be resumed instead of
    // silently half-done. `ingest_runs` is the run header; `ingest_run_files` records each
    // file's transition (pending→running→done/failed) keyed by a stable path hash. Append-only,
    // additive. A run left in 'running'/'paused' at boot is resumable.
    private static let v56: String = """
    CREATE TABLE IF NOT EXISTS ingest_runs (
        id              TEXT PRIMARY KEY,
        status          TEXT NOT NULL,        -- pending|running|paused|completed|failed
        total_files     INTEGER NOT NULL DEFAULT 0,
        completed_files INTEGER NOT NULL DEFAULT 0,
        failed_files    INTEGER NOT NULL DEFAULT 0,
        started_at      REAL NOT NULL,
        updated_at      REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ingest_run_files (
        run_id     TEXT NOT NULL,
        path_hash  TEXT NOT NULL,
        path       TEXT NOT NULL,
        state      TEXT NOT NULL,             -- pending|running|done|failed
        error      TEXT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (run_id, path_hash),
        FOREIGN KEY (run_id) REFERENCES ingest_runs(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_ingest_run_files_run ON ingest_run_files(run_id);
    CREATE INDEX IF NOT EXISTS idx_ingest_runs_status ON ingest_runs(status);
    """

    // SEM — durable store for domain-pack GenericFacts (subject/field/value + evidence + the
    // locked EvidenceStatus vocabulary). Source blocks kept as JSON so a fact always drills to
    // evidence. Append-only, additive. Indexed by (subject_label, field) for lookup.
    private static let v57: String = """
    CREATE TABLE IF NOT EXISTS generic_facts (
        id                TEXT PRIMARY KEY,
        subject_id        TEXT NULL,
        subject_label     TEXT NOT NULL,
        field             TEXT NOT NULL,
        value             TEXT NOT NULL,
        unit              TEXT NULL,
        status            TEXT NOT NULL,
        confidence        REAL NOT NULL,
        source_blocks_json TEXT NOT NULL,
        created_at        REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_generic_facts_subject_field ON generic_facts(subject_label, field);
    """

    // EV-004 — extend the EXISTING v28 `corpus_snapshots` census table with the
    // processing-version fields that make an output reproducible (embedding model,
    // retrieval-config / persona-policy / parser versions, scope, readiness), and add
    // `snapshot_sources` pinning the exact source-version IDs + content hashes the
    // snapshot covered. ALTER (not CREATE) because the table already exists — this is
    // the EV-006 "one version model" consolidation, not a parallel table. Append-only;
    // ADD COLUMN runs exactly once (guarded by user_version), so no duplicate-column
    // error. No cascade delete removes historical snapshots.
    private static let v58: String = """
    ALTER TABLE corpus_snapshots ADD COLUMN scope TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN embedding_model TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN retrieval_config_version TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN persona_policy_version TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN parser_versions_json TEXT;
    ALTER TABLE corpus_snapshots ADD COLUMN readiness REAL;
    CREATE TABLE IF NOT EXISTS snapshot_sources (
        snapshot_id       TEXT NOT NULL,
        source_version_id TEXT NOT NULL,
        content_hash      TEXT NULL,
        PRIMARY KEY (snapshot_id, source_version_id)
    );
    CREATE INDEX IF NOT EXISTS idx_snapshot_sources_snapshot ON snapshot_sources(snapshot_id);
    """

    // PERF.2 — durable enrichment-job ledger for the two-pass model (06_INGESTION §2/§4/§5).
    // The queryable core commits fast; deep enrichment (embeddings, typed facts, entity
    // reconciliation, contradiction/gap scans, OCR/ASR) is queued here as durable,
    // idempotent, resumable post-commit jobs. UNIQUE(subject_id, kind) makes enqueue
    // idempotent (a re-ingest doesn't duplicate work); state lets boot recovery find and
    // resume incomplete jobs and Sources show per-dimension readiness. Append-only rows;
    // never leaves invisible partial state.
    private static let v59: String = """
    CREATE TABLE IF NOT EXISTS enrichment_jobs (
        id           TEXT PRIMARY KEY NOT NULL,
        subject_id   TEXT NOT NULL,
        kind         TEXT NOT NULL,
        state        TEXT NOT NULL,
        attempts     INTEGER NOT NULL DEFAULT 0,
        last_error   TEXT,
        created_at   REAL NOT NULL,
        updated_at   REAL NOT NULL,
        UNIQUE(subject_id, kind)
    );
    CREATE INDEX IF NOT EXISTS idx_enrichment_jobs_state ON enrichment_jobs(state, kind);
    """

    // HIST-020/022 (Universal History, Phase 3) — subject-scoped temporal claims
    // (facts true over an interval). object/temporal values are JSON-encoded so the
    // neutral predicate model stays flexible. Also indexes event_entities(entity_id)
    // so the Phase-2 collector's allForEntity join is indexed (HIST-031).
    private static let v60: String = """
    CREATE TABLE IF NOT EXISTS temporal_claims (
        id                      TEXT PRIMARY KEY NOT NULL,
        subject_id              TEXT NOT NULL,
        predicate               TEXT NOT NULL,
        object_json             TEXT NOT NULL,
        valid_from_json         TEXT,
        valid_to_json           TEXT,
        observed_at_json        TEXT,
        status                  TEXT NOT NULL,
        confidence              REAL NOT NULL DEFAULT 0.5,
        source_object_ids_json  TEXT NOT NULL DEFAULT '[]',
        source_block_ids_json   TEXT NOT NULL DEFAULT '[]',
        assertion_ids_json      TEXT NOT NULL DEFAULT '[]',
        generic_fact_ids_json   TEXT NOT NULL DEFAULT '[]',
        extractor_id            TEXT NOT NULL,
        extractor_version       TEXT NOT NULL,
        created_at              REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_temporal_claims_subject ON temporal_claims(subject_id, predicate);
    CREATE INDEX IF NOT EXISTS idx_temporal_claims_subject_created ON temporal_claims(subject_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_event_entities_entity ON event_entities(entity_id);
    """

    // HIST-060/061 (Universal History, Phase 9) — persistent, versioned history
    // artifacts (spec §19). Rebuild creates a NEW artifact and links the old via
    // superseded_by; nothing is overwritten (preserve-not-delete).
    private static let v61: String = """
    CREATE TABLE IF NOT EXISTS history_artifacts (
        id                 TEXT PRIMARY KEY NOT NULL,
        subject_kind       TEXT NOT NULL,
        subject_id         TEXT,
        subject_label      TEXT NOT NULL,
        corpus_snapshot_id TEXT,
        engine_version     TEXT NOT NULL,
        request_json       TEXT NOT NULL DEFAULT '{}',
        title              TEXT NOT NULL,
        summary            TEXT,
        coverage_json      TEXT NOT NULL DEFAULT '{}',
        quality_json       TEXT NOT NULL DEFAULT '{}',
        created_at         REAL NOT NULL,
        superseded_by      TEXT
    );
    CREATE TABLE IF NOT EXISTS history_chapters (
        id                 TEXT PRIMARY KEY NOT NULL,
        artifact_id        TEXT NOT NULL,
        ordinal            INTEGER NOT NULL,
        title              TEXT NOT NULL,
        subtitle           TEXT,
        deterministic_text TEXT NOT NULL DEFAULT '',
        generated_text     TEXT,
        confidence         REAL NOT NULL DEFAULT 0.5
    );
    CREATE TABLE IF NOT EXISTS history_items (
        id                    TEXT PRIMARY KEY NOT NULL,
        artifact_id           TEXT NOT NULL,
        chapter_id            TEXT,
        item_kind             TEXT NOT NULL,
        title                 TEXT NOT NULL,
        description           TEXT,
        temporal_json         TEXT NOT NULL DEFAULT '{}',
        actors_json           TEXT NOT NULL DEFAULT '[]',
        status                TEXT NOT NULL,
        confidence            REAL NOT NULL DEFAULT 0.5,
        contradiction_group_id TEXT,
        alternative_account_id TEXT,
        review_status         TEXT
    );
    CREATE TABLE IF NOT EXISTS history_item_evidence (
        history_item_id     TEXT NOT NULL,
        knowledge_object_id TEXT NOT NULL,
        evidence_block_id   TEXT,
        assertion_id        TEXT,
        generic_fact_id     TEXT,
        event_id            TEXT,
        source_version_id   TEXT,
        locator_json        TEXT,
        evidence_role       TEXT NOT NULL DEFAULT 'supports',
        PRIMARY KEY (history_item_id, knowledge_object_id, evidence_block_id)
    );
    CREATE TABLE IF NOT EXISTS history_gaps (
        id                    TEXT PRIMARY KEY NOT NULL,
        artifact_id           TEXT NOT NULL,
        gap_kind              TEXT NOT NULL,
        description           TEXT NOT NULL,
        temporal_json         TEXT,
        expected_evidence_json TEXT NOT NULL DEFAULT '[]',
        confidence            REAL NOT NULL DEFAULT 0.5,
        review_status         TEXT
    );
    CREATE TABLE IF NOT EXISTS history_alternative_accounts (
        id                        TEXT PRIMARY KEY NOT NULL,
        artifact_id               TEXT NOT NULL,
        subject                   TEXT NOT NULL,
        account_json              TEXT NOT NULL,
        decisive_missing_evidence TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_history_artifacts_subject ON history_artifacts(subject_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_history_artifacts_snapshot ON history_artifacts(corpus_snapshot_id);
    CREATE INDEX IF NOT EXISTS idx_history_chapters_artifact ON history_chapters(artifact_id, ordinal);
    CREATE INDEX IF NOT EXISTS idx_history_items_artifact ON history_items(artifact_id);
    CREATE INDEX IF NOT EXISTS idx_history_item_evidence_ko ON history_item_evidence(knowledge_object_id);
    CREATE INDEX IF NOT EXISTS idx_history_gaps_artifact ON history_gaps(artifact_id);
    """

    // S0.5 item 2, Commit B — separate the overloaded EvidenceStatus into five
    // orthogonal dimensions (basis / review / origin / availability / conflict) as
    // ADDITIVE, nullable columns. The legacy `status` column is preserved and keeps
    // being written; `legacy_status` records the raw value that produced the split
    // (see EvidenceAssessment + LegacyEvidenceStatusAdapter). Legacy rows leave the
    // dimension columns NULL and are read back via read-time decode of `status`.
    //
    // history_items keeps its existing `review_status` (HistoryReviewStatus vocabulary)
    // UNCHANGED and gains a SEPARATE `review_disposition` (ReviewDisposition vocabulary,
    // which adds confirmed/disputed/needsReview). We backfill it deterministically from
    // review_status without rewriting the old column. Conflict for history items stays
    // DERIVED from contradiction_group_id + contradiction records — no column here.
    //
    // events / assertions / contradiction tables / review_decisions and the not-yet-
    // existing work-product tables are deliberately untouched (Commit C adds read
    // adapters for Events/Assertions).
    private static let v62: String = """
    ALTER TABLE generic_facts ADD COLUMN evidence_basis      TEXT;
    ALTER TABLE generic_facts ADD COLUMN review_disposition  TEXT;
    ALTER TABLE generic_facts ADD COLUMN proposal_origin     TEXT;
    ALTER TABLE generic_facts ADD COLUMN availability_status TEXT;
    ALTER TABLE generic_facts ADD COLUMN conflict_status     TEXT;
    ALTER TABLE generic_facts ADD COLUMN legacy_status       TEXT;

    ALTER TABLE temporal_claims ADD COLUMN evidence_basis      TEXT;
    ALTER TABLE temporal_claims ADD COLUMN review_disposition  TEXT;
    ALTER TABLE temporal_claims ADD COLUMN proposal_origin     TEXT;
    ALTER TABLE temporal_claims ADD COLUMN availability_status TEXT;
    ALTER TABLE temporal_claims ADD COLUMN conflict_status     TEXT;
    ALTER TABLE temporal_claims ADD COLUMN legacy_status       TEXT;

    ALTER TABLE history_items ADD COLUMN evidence_basis      TEXT;
    ALTER TABLE history_items ADD COLUMN review_disposition  TEXT;
    ALTER TABLE history_items ADD COLUMN proposal_origin     TEXT;
    ALTER TABLE history_items ADD COLUMN availability_status TEXT;
    ALTER TABLE history_items ADD COLUMN legacy_status       TEXT;

    UPDATE history_items SET review_disposition = CASE
        WHEN review_status IS NULL OR review_status = 'unreviewed' THEN 'unreviewed'
        WHEN review_status = 'accepted'  THEN 'confirmed'
        WHEN review_status = 'corrected' THEN 'corrected'
        WHEN review_status = 'rejected'  THEN 'rejected'
        ELSE 'needsReview'
    END
    WHERE review_disposition IS NULL;
    """

    // PA-009 (persona-v2 Stage 1) — the shared Claim engine. ONE canonical, persona-neutral
    // claim table all five personas point at, plus its evidence / lineage / contradiction /
    // review / usage links. Claims REFERENCE source truth by id (claim_lineage, claim_evidence)
    // and never duplicate it. Trust is the canonical five-dimension EvidenceAssessment stored
    // NOT NULL here (this is a brand-new table with no legacy rows) — never a forked enum;
    // `legacy_status` stays nullable for the lossy round-trip value only.
    private static let v63: String = """
    CREATE TABLE IF NOT EXISTS claims (
        id                      TEXT PRIMARY KEY NOT NULL,
        subject_id              TEXT,
        subject_label           TEXT NOT NULL,
        statement               TEXT NOT NULL,
        confidence              REAL NOT NULL DEFAULT 0.5,
        contradiction_group_id  TEXT,
        created_at              REAL NOT NULL,
        evidence_basis          TEXT NOT NULL,
        review_disposition      TEXT NOT NULL,
        proposal_origin         TEXT NOT NULL,
        availability_status     TEXT NOT NULL,
        conflict_status         TEXT NOT NULL,
        legacy_status           TEXT
    );
    -- EXACT evidence backing a canonical claim (mirrors history_item_evidence).
    -- NOTE: named `claim_evidence_ref` to avoid the pre-existing `claim_evidence`
    -- table (the unrelated answer→block replay feature); the two are distinct.
    CREATE TABLE IF NOT EXISTS claim_evidence_ref (
        claim_id            TEXT NOT NULL,
        knowledge_object_id TEXT NOT NULL,
        evidence_block_id   TEXT,
        assertion_id        TEXT,
        generic_fact_id     TEXT,
        event_id            TEXT,
        source_version_id   TEXT,
        evidence_role       TEXT NOT NULL DEFAULT 'supports',
        PRIMARY KEY (claim_id, knowledge_object_id, evidence_block_id)
    );
    -- What source-truth objects a claim was derived FROM (by id; DerivedReference.Kind).
    CREATE TABLE IF NOT EXISTS claim_lineage (
        claim_id    TEXT NOT NULL,
        source_kind TEXT NOT NULL,
        source_id   TEXT NOT NULL,
        PRIMARY KEY (claim_id, source_kind, source_id)
    );
    -- Many-to-many link between a claim and the Contradiction records it participates in.
    CREATE TABLE IF NOT EXISTS claim_contradictions (
        claim_id         TEXT NOT NULL,
        contradiction_id TEXT NOT NULL,
        PRIMARY KEY (claim_id, contradiction_id)
    );
    -- Append-only human review actions on a claim (preserve-not-delete).
    CREATE TABLE IF NOT EXISTS claim_reviews (
        id           TEXT PRIMARY KEY NOT NULL,
        claim_id     TEXT NOT NULL,
        disposition  TEXT NOT NULL,
        prior_value  TEXT,
        new_value    TEXT,
        reviewer     TEXT NOT NULL,
        reason       TEXT,
        reviewed_at  REAL NOT NULL
    );
    -- Append-only usage ledger: where a claim was used (answer / work product / export / …).
    CREATE TABLE IF NOT EXISTS claim_usage (
        id           TEXT PRIMARY KEY NOT NULL,
        claim_id     TEXT NOT NULL,
        context      TEXT NOT NULL,
        reference_id TEXT,
        note         TEXT,
        used_at      REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_claims_subject ON claims(subject_id);
    CREATE INDEX IF NOT EXISTS idx_claims_contradiction ON claims(contradiction_group_id);
    CREATE INDEX IF NOT EXISTS idx_claim_evidence_ref_claim ON claim_evidence_ref(claim_id);
    CREATE INDEX IF NOT EXISTS idx_claim_evidence_ref_object ON claim_evidence_ref(knowledge_object_id);
    CREATE INDEX IF NOT EXISTS idx_claim_lineage_claim ON claim_lineage(claim_id);
    CREATE INDEX IF NOT EXISTS idx_claim_contradictions_claim ON claim_contradictions(claim_id);
    CREATE INDEX IF NOT EXISTS idx_claim_contradictions_cid ON claim_contradictions(contradiction_id);
    CREATE INDEX IF NOT EXISTS idx_claim_reviews_claim ON claim_reviews(claim_id, reviewed_at);
    CREATE INDEX IF NOT EXISTS idx_claim_usage_claim ON claim_usage(claim_id);
    """

    // PA-009.1 — rebuild claim_evidence_ref with an ORDINAL identity. The v63 PK
    // (claim_id, knowledge_object_id, evidence_block_id) + empty-string block sentinel
    // meant two distinct evidence references for the same claim/object/block but different
    // assertion / fact / event / source-version / role COLLIDED, and INSERT OR IGNORE
    // silently dropped one. The ordinal PK gives each reference on a claim its own identity
    // and a stable load order; the empty-string sentinel becomes a real NULL. Existing rows
    // migrate deterministically (ordinal assigned per claim by a stable ordering).
    private static let v64: String = """
    CREATE TABLE claim_evidence_ref_v2 (
        claim_id            TEXT NOT NULL,
        ordinal             INTEGER NOT NULL,
        knowledge_object_id TEXT NOT NULL,
        evidence_block_id   TEXT,
        assertion_id        TEXT,
        generic_fact_id     TEXT,
        event_id            TEXT,
        source_version_id   TEXT,
        evidence_role       TEXT NOT NULL,
        PRIMARY KEY (claim_id, ordinal)
    );
    INSERT INTO claim_evidence_ref_v2
        (claim_id, ordinal, knowledge_object_id, evidence_block_id, assertion_id,
         generic_fact_id, event_id, source_version_id, evidence_role)
    SELECT claim_id,
           ROW_NUMBER() OVER (PARTITION BY claim_id
                              ORDER BY knowledge_object_id, evidence_block_id,
                                       assertion_id, generic_fact_id, event_id, source_version_id) - 1,
           knowledge_object_id,
           NULLIF(evidence_block_id, ''),
           assertion_id, generic_fact_id, event_id, source_version_id, evidence_role
    FROM claim_evidence_ref;
    DROP TABLE claim_evidence_ref;
    ALTER TABLE claim_evidence_ref_v2 RENAME TO claim_evidence_ref;
    CREATE INDEX IF NOT EXISTS idx_claim_evidence_ref_claim ON claim_evidence_ref(claim_id);
    CREATE INDEX IF NOT EXISTS idx_claim_evidence_ref_object ON claim_evidence_ref(knowledge_object_id);
    """

    // PA-PROD Commit B2 — durable, resumable Claim-projection substrate.
    //  • claim_projection_progress: per (producer_version, source_kind) keyset cursor +
    //    completion, so a background backfill resumes exactly where it stopped and a new
    //    producer version starts a fresh, independent pass (old completed rows untouched).
    //  • workspace_derived_entities: AUTOMATICALLY-derived workspace subjects, kept separate
    //    from user-curated workspace_entities so reconciliation can replace the derived set
    //    (add/remove as sources change) without ever deleting a manually-added member.
    private static let v65: String = """
    CREATE TABLE IF NOT EXISTS claim_projection_progress (
        producer_version TEXT NOT NULL,
        source_kind      TEXT NOT NULL,
        last_source_id   TEXT,
        complete         INTEGER NOT NULL DEFAULT 0,
        updated_at       REAL NOT NULL,
        PRIMARY KEY (producer_version, source_kind)
    );
    CREATE TABLE IF NOT EXISTS workspace_derived_entities (
        workspace_id TEXT NOT NULL,
        entity_id    TEXT NOT NULL,
        derived_at   REAL NOT NULL,
        PRIMARY KEY (workspace_id, entity_id)
    );
    CREATE INDEX IF NOT EXISTS idx_workspace_derived_ws ON workspace_derived_entities(workspace_id);
    """

    // PA-PROD Commit B6 — canonical EvidenceBlock → KnowledgeObject ownership.
    //  A parsed source's structural blocks belong to a specific KnowledgeObject (for a multi-KO
    //  source like MBOX, each message block belongs to ITS message KO). `source_versions
    //  .logical_source_id` stays at the file/logical-source level and must never be overloaded as
    //  a KnowledgeObject id; this table carries the real block→object identity so canonical Claim
    //  evidence resolves to a genuine `knowledge_objects` row. ON DELETE CASCADE on the object
    //  keeps links consistent with the KO cascade (re-ingest deletes the KO, its links follow).
    private static let v66: String = """
    CREATE TABLE IF NOT EXISTS evidence_block_objects (
        evidence_block_id   TEXT NOT NULL,
        knowledge_object_id TEXT NOT NULL,
        linked_at           REAL NOT NULL,
        PRIMARY KEY (evidence_block_id, knowledge_object_id),
        FOREIGN KEY (evidence_block_id)   REFERENCES evidence_blocks(id)   ON DELETE CASCADE,
        FOREIGN KEY (knowledge_object_id) REFERENCES knowledge_objects(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_ebo_block  ON evidence_block_objects(evidence_block_id);
    CREATE INDEX IF NOT EXISTS idx_ebo_object ON evidence_block_objects(knowledge_object_id);
    """

    // PA-DOC-001 — explicit Claim scope. `scope_kind` is 'entity' | 'knowledgeObject'; `scope_id`
    // is the anchoring Entity or KnowledgeObject id. Additive + nullable so existing claim rows
    // are untouched (they read back as scope == nil until reprojected under the new producer
    // version). The index serves source-scoped workspace selection (scope_id IN workspace KOs).
    private static let v67: String = """
    ALTER TABLE claims ADD COLUMN scope_kind TEXT;
    ALTER TABLE claims ADD COLUMN scope_id   TEXT;
    CREATE INDEX IF NOT EXISTS idx_claims_scope ON claims(scope_kind, scope_id);
    """

    // OPS-001 — shared professional Issue Engine. An Issue is persona-neutral WORKFLOW state
    // (question / evidence concern / contradiction review / missing-evidence issue / lead / risk /
    // scope concern / decision required / finding candidate). It REFERENCES canonical objects by
    // id via professional_issue_links and never copies or mutates them; every status transition is
    // recorded in the append-only professional_issue_reviews ledger. Workspace deletion cascades
    // the Issue working state (issues → links + reviews) while canonical evidence is untouched.
    // No Issue columns are added to claims / contradictions / gap_nodes / events.
    private static let v68: String = """
    CREATE TABLE professional_issues (
        id           TEXT PRIMARY KEY NOT NULL,
        workspace_id TEXT NOT NULL,
        title        TEXT NOT NULL,
        detail       TEXT,
        issue_type   TEXT NOT NULL,
        status       TEXT NOT NULL,
        priority     TEXT NOT NULL,
        created_at   REAL NOT NULL,
        updated_at   REAL NOT NULL,
        closed_at    REAL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_professional_issues_workspace ON professional_issues(workspace_id);
    CREATE INDEX idx_professional_issues_status    ON professional_issues(workspace_id, status);
    CREATE INDEX idx_professional_issues_type      ON professional_issues(workspace_id, issue_type);

    CREATE TABLE professional_issue_links (
        id          TEXT PRIMARY KEY NOT NULL,
        issue_id    TEXT NOT NULL,
        target_kind TEXT NOT NULL,
        target_id   TEXT NOT NULL,
        link_role   TEXT NOT NULL,
        created_at  REAL NOT NULL,
        FOREIGN KEY (issue_id) REFERENCES professional_issues(id) ON DELETE CASCADE,
        UNIQUE(issue_id, target_kind, target_id, link_role)
    );
    CREATE INDEX idx_professional_issue_links_issue  ON professional_issue_links(issue_id);
    CREATE INDEX idx_professional_issue_links_target ON professional_issue_links(target_kind, target_id);

    CREATE TABLE professional_issue_reviews (
        id           TEXT PRIMARY KEY NOT NULL,
        issue_id     TEXT NOT NULL,
        action       TEXT NOT NULL,
        prior_status TEXT,
        new_status   TEXT,
        reviewer     TEXT NOT NULL,
        reason       TEXT,
        reviewed_at  REAL NOT NULL,
        FOREIGN KEY (issue_id) REFERENCES professional_issues(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_professional_issue_reviews_issue ON professional_issue_reviews(issue_id, reviewed_at);
    """

    // OPS-002 — shared Task and Deadline Engine. THE truth rule: deadline_candidates (proposal
    // layer) ≠ deadlines (confirmed). Confirmation inserts a NEW deadlines row (UNIQUE on
    // source_candidate_id → one candidate promotes at most once) and preserves the candidate.
    // Overdue is never a stored status. Workflow state cascades from its workspace / parent task;
    // canonical evidence never cascades from these tables. No canonical table is modified.
    private static let v69: String = """
    CREATE TABLE professional_tasks (
        id               TEXT PRIMARY KEY NOT NULL,
        workspace_id     TEXT NOT NULL,
        primary_issue_id TEXT,
        title            TEXT NOT NULL,
        detail           TEXT,
        task_type        TEXT NOT NULL,
        status           TEXT NOT NULL,
        priority         TEXT NOT NULL,
        owner            TEXT,
        origin           TEXT NOT NULL,
        created_at       REAL NOT NULL,
        updated_at       REAL NOT NULL,
        completed_at     REAL,
        archived_at      REAL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        FOREIGN KEY (primary_issue_id) REFERENCES professional_issues(id) ON DELETE SET NULL
    );
    CREATE INDEX idx_professional_tasks_workspace ON professional_tasks(workspace_id);
    CREATE INDEX idx_professional_tasks_status    ON professional_tasks(workspace_id, status);
    CREATE INDEX idx_professional_tasks_type      ON professional_tasks(workspace_id, task_type);

    CREATE TABLE professional_task_dependencies (
        id                 TEXT PRIMARY KEY NOT NULL,
        task_id            TEXT NOT NULL,
        depends_on_task_id TEXT NOT NULL,
        dependency_kind    TEXT NOT NULL,
        created_at         REAL NOT NULL,
        FOREIGN KEY (task_id)            REFERENCES professional_tasks(id) ON DELETE CASCADE,
        FOREIGN KEY (depends_on_task_id) REFERENCES professional_tasks(id) ON DELETE CASCADE,
        UNIQUE(task_id, depends_on_task_id, dependency_kind),
        CHECK(task_id != depends_on_task_id)
    );
    CREATE INDEX idx_task_dependencies_task ON professional_task_dependencies(task_id);
    CREATE INDEX idx_task_dependencies_on   ON professional_task_dependencies(depends_on_task_id);

    CREATE TABLE deadline_candidates (
        id            TEXT PRIMARY KEY NOT NULL,
        task_id       TEXT NOT NULL,
        due_date      REAL NOT NULL,
        precision     INTEGER NOT NULL,
        time_zone     TEXT NOT NULL,
        deadline_kind TEXT NOT NULL,
        origin        TEXT NOT NULL,
        confidence    REAL,
        proposed_by   TEXT NOT NULL,
        rule_id       TEXT,
        rule_version  TEXT,
        status        TEXT NOT NULL,
        created_at    REAL NOT NULL,
        reviewed_at   REAL,
        FOREIGN KEY (task_id) REFERENCES professional_tasks(id) ON DELETE CASCADE,
        CHECK(confidence IS NULL OR confidence BETWEEN 0 AND 1)
    );
    CREATE INDEX idx_deadline_candidates_task ON deadline_candidates(task_id, status);

    CREATE TABLE deadlines (
        id                  TEXT PRIMARY KEY NOT NULL,
        task_id             TEXT NOT NULL,
        source_candidate_id TEXT,
        due_date            REAL NOT NULL,
        precision           INTEGER NOT NULL,
        time_zone           TEXT NOT NULL,
        deadline_kind       TEXT NOT NULL,
        status              TEXT NOT NULL,
        confirmation_kind   TEXT NOT NULL,
        confirmed_by        TEXT NOT NULL,
        confirmed_at        REAL NOT NULL,
        confirm_reason      TEXT,
        rule_id             TEXT,
        rule_version        TEXT,
        created_at          REAL NOT NULL,
        updated_at          REAL NOT NULL,
        satisfied_at        REAL,
        archived_at         REAL,
        FOREIGN KEY (task_id)             REFERENCES professional_tasks(id) ON DELETE CASCADE,
        FOREIGN KEY (source_candidate_id) REFERENCES deadline_candidates(id) ON DELETE SET NULL,
        UNIQUE(source_candidate_id)
    );
    CREATE INDEX idx_deadlines_task ON deadlines(task_id, status);

    CREATE TABLE professional_task_evidence_links (
        id          TEXT PRIMARY KEY NOT NULL,
        task_id     TEXT NOT NULL,
        scope_kind  TEXT NOT NULL,
        scope_id    TEXT NOT NULL DEFAULT '',
        target_kind TEXT NOT NULL,
        target_id   TEXT NOT NULL,
        link_role   TEXT NOT NULL,
        created_at  REAL NOT NULL,
        FOREIGN KEY (task_id) REFERENCES professional_tasks(id) ON DELETE CASCADE,
        UNIQUE(task_id, scope_kind, scope_id, target_kind, target_id, link_role)
    );
    CREATE INDEX idx_task_evidence_links_task   ON professional_task_evidence_links(task_id);
    CREATE INDEX idx_task_evidence_links_target ON professional_task_evidence_links(target_kind, target_id);

    CREATE TABLE professional_task_reviews (
        id           TEXT PRIMARY KEY NOT NULL,
        task_id      TEXT NOT NULL,
        action       TEXT NOT NULL,
        prior_status TEXT,
        new_status   TEXT,
        reviewer     TEXT NOT NULL,
        reason       TEXT,
        reviewed_at  REAL NOT NULL,
        FOREIGN KEY (task_id) REFERENCES professional_tasks(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_task_reviews_task ON professional_task_reviews(task_id, reviewed_at);

    CREATE TABLE deadline_candidate_reviews (
        id           TEXT PRIMARY KEY NOT NULL,
        candidate_id TEXT NOT NULL,
        action       TEXT NOT NULL,
        reviewer     TEXT NOT NULL,
        reason       TEXT,
        reviewed_at  REAL NOT NULL,
        FOREIGN KEY (candidate_id) REFERENCES deadline_candidates(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_candidate_reviews_candidate ON deadline_candidate_reviews(candidate_id, reviewed_at);

    CREATE TABLE deadline_reviews (
        id          TEXT PRIMARY KEY NOT NULL,
        deadline_id TEXT NOT NULL,
        action      TEXT NOT NULL,
        reviewer    TEXT NOT NULL,
        reason      TEXT,
        reviewed_at REAL NOT NULL,
        FOREIGN KEY (deadline_id) REFERENCES deadlines(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_deadline_reviews_deadline ON deadline_reviews(deadline_id, reviewed_at);
    """

    // OPS-002.1 — structured confirmation authority on the task review ledger. v69 validated a
    // deterministic rule's identity (ruleID + version) and then DISCARDED it: only origin + actor
    // name were persisted, so after reopening the database the application could not prove WHICH
    // rule and version confirmed a Task. Additive nullable columns (v69 already ran in
    // development and hosted CI — never rewrite a shipped migration); rows predating v70 keep
    // NULL authority, which is honest: their structured provenance was never recorded.
    private static let v70: String = """
    ALTER TABLE professional_task_reviews ADD COLUMN authority_kind TEXT;
    ALTER TABLE professional_task_reviews ADD COLUMN rule_id TEXT;
    ALTER TABLE professional_task_reviews ADD COLUMN rule_version TEXT;
    """

    // OPS-003A — shared SensitiveScope protection ledger. Two append-only tables:
    // `sensitive_scope_assignments` holds active and revoked protection assignments;
    // `sensitive_scope_reviews` is the audit ledger for every assign/revoke action.
    // All six enforcement surfaces (screen/retrieval/prompt/report/receipt/export) read
    // from these tables — no per-persona fork. The INSERT…SELECT backfills any legacy
    // knowledge_objects.privileged=1 rows into active restricted+privileged assignments
    // so existing privilege is preserved. The `legacy_privileged_column` origin is the
    // canonical marker for backfilled rows.
    private static let v71: String = """
    CREATE TABLE sensitive_scope_assignments (
        id             TEXT NOT NULL PRIMARY KEY,
        target_kind    TEXT NOT NULL,
        target_id      TEXT NOT NULL,
        sensitivity    INTEGER NOT NULL,
        privileged     INTEGER NOT NULL DEFAULT 0,
        origin         TEXT NOT NULL,
        reason         TEXT,
        assigned_by    TEXT NOT NULL,
        created_at     REAL NOT NULL,
        revoked_at     REAL,
        revoked_by     TEXT,
        revoked_reason TEXT
    );
    CREATE INDEX idx_ssa_target ON sensitive_scope_assignments(target_kind, target_id);
    CREATE INDEX idx_ssa_active ON sensitive_scope_assignments(target_kind, target_id, revoked_at);

    CREATE TABLE sensitive_scope_reviews (
        id             TEXT NOT NULL PRIMARY KEY,
        assignment_id  TEXT NOT NULL REFERENCES sensitive_scope_assignments(id) ON DELETE CASCADE,
        action         TEXT NOT NULL,
        actor_note     TEXT,
        created_at     REAL NOT NULL
    );
    CREATE INDEX idx_ssr_assignment ON sensitive_scope_reviews(assignment_id);

    INSERT INTO sensitive_scope_assignments
        (id, target_kind, target_id, sensitivity, privileged,
         origin, reason, assigned_by, created_at)
    SELECT
        lower(hex(randomblob(4))) || '-' ||
        lower(hex(randomblob(2))) || '-4' ||
        substr(lower(hex(randomblob(2))), 2) || '-8' ||
        substr(lower(hex(randomblob(2))), 2) || '-' ||
        lower(hex(randomblob(6))),
        'knowledgeObject',
        id,
        3,
        1,
        'legacy_privileged_column',
        'Migrated from knowledge_objects.privileged flag',
        'migration_v71',
        created_at
    FROM knowledge_objects WHERE privileged = 1;
    """

    // OPS-004 — WorkProductRun persistence. Four tables store immutable run records.
    // Runs are FK-linked to workspaces (CASCADE on delete); section/claim/manifest rows
    // CASCADE from their parent run. This migration adds no rows to canonical tables.
    private static let v72: String = """
    CREATE TABLE work_product_runs (
        id                 TEXT PRIMARY KEY NOT NULL,
        workspace_id       TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
        template           TEXT NOT NULL,
        title              TEXT NOT NULL,
        subtitle           TEXT,
        subject_label      TEXT NOT NULL,
        corpus_snapshot_id TEXT,
        schema_version     INTEGER NOT NULL,
        app_version        TEXT NOT NULL,
        composed_at        REAL NOT NULL,
        finding_count      INTEGER NOT NULL DEFAULT 0,
        disclaimer         TEXT
    );
    CREATE INDEX idx_wpr_workspace ON work_product_runs(workspace_id, composed_at DESC);

    CREATE TABLE work_product_sections (
        id       TEXT PRIMARY KEY NOT NULL,
        run_id   TEXT NOT NULL REFERENCES work_product_runs(id) ON DELETE CASCADE,
        ordinal  INTEGER NOT NULL,
        title    TEXT NOT NULL,
        preamble TEXT NOT NULL DEFAULT '[]'
    );
    CREATE INDEX idx_wps_run ON work_product_sections(run_id, ordinal);

    CREATE TABLE work_product_claim_occurrences (
        id                    TEXT PRIMARY KEY NOT NULL,
        section_id            TEXT NOT NULL REFERENCES work_product_sections(id) ON DELETE CASCADE,
        run_id                TEXT NOT NULL,
        ordinal               INTEGER NOT NULL,
        text                  TEXT NOT NULL,
        epistemic_status      TEXT NOT NULL,
        confidence            REAL,
        review_state          TEXT,
        source_claim_id       TEXT,
        assertability_decision TEXT,
        supporting_json       TEXT NOT NULL DEFAULT '[]',
        contradicting_json    TEXT NOT NULL DEFAULT '[]'
    );
    CREATE INDEX idx_wpco_section ON work_product_claim_occurrences(section_id, ordinal);
    CREATE INDEX idx_wpco_run     ON work_product_claim_occurrences(run_id);

    CREATE TABLE work_product_manifests (
        run_id                  TEXT PRIMARY KEY NOT NULL
                                REFERENCES work_product_runs(id) ON DELETE CASCADE,
        exported_at             REAL NOT NULL,
        workspace_title         TEXT,
        workspace_template      TEXT,
        source_version_ids      TEXT NOT NULL DEFAULT '[]',
        source_hashes           TEXT NOT NULL DEFAULT '[]',
        selected_finding_count  INTEGER NOT NULL DEFAULT 0,
        citation_map_json       TEXT NOT NULL DEFAULT '[]',
        applied_redactions_json TEXT NOT NULL DEFAULT '[]',
        review_status_summary   TEXT,
        known_limitations_json  TEXT NOT NULL DEFAULT '[]'
    );
    """

    // OPS-005 — email participant occurrence ledger. Each row records
    // one address in one role header for one email KO. Bcc addresses
    // are stored here but NEVER enter chunk text or embeddings
    // (guaranteed by EmailLoader which omits Bcc from headerLines).
    // CASCADE on source_ko_id removes occurrence rows when the KO is
    // hard-deleted. Canonical entity rows are never touched.
    private static let v73: String = """
    CREATE TABLE email_participant_occurrences (
        id           TEXT PRIMARY KEY NOT NULL,
        source_ko_id TEXT NOT NULL REFERENCES knowledge_objects(id) ON DELETE CASCADE,
        entity_id    TEXT NOT NULL,
        role         TEXT NOT NULL,
        raw_address  TEXT NOT NULL,
        display_name TEXT,
        created_at   REAL NOT NULL
    );
    CREATE INDEX idx_epo_source_ko   ON email_participant_occurrences(source_ko_id);
    CREATE INDEX idx_epo_entity      ON email_participant_occurrences(entity_id);
    CREATE INDEX idx_epo_entity_role ON email_participant_occurrences(entity_id, role);
    CREATE INDEX idx_epo_ko_role     ON email_participant_occurrences(source_ko_id, role);
    """

    // OPS-006 — shared source reliability assessment ledger. ONE assessment
    // per source version, shared across all personas. Reassessments are
    // append-only: the prior row's superseded_by_id is set to the new ID.
    // CASCADE on source_version_id removes assessments when a source version
    // is hard-deleted. superseded_by_id is a soft reference (no FK) to
    // preserve the audit chain. Canonical claims/entities are never touched.
    private static let v74: String = """
    CREATE TABLE source_reliability_assessments (
        id                TEXT PRIMARY KEY NOT NULL,
        source_version_id TEXT NOT NULL
            REFERENCES source_versions(id) ON DELETE CASCADE,
        reliability       TEXT NOT NULL
            CHECK(reliability IN ('high','medium','low','unknown')),
        independence      TEXT NOT NULL
            CHECK(independence IN ('independent','affiliated','potential_conflict','unknown')),
        rationale         TEXT,
        assessed_by       TEXT,
        assessed_at       REAL NOT NULL,
        created_at        REAL NOT NULL,
        superseded_by_id  TEXT
    );
    CREATE INDEX idx_sra_source_version
        ON source_reliability_assessments(source_version_id);
    CREATE INDEX idx_sra_active
        ON source_reliability_assessments(source_version_id, superseded_by_id);
    """

    // MARK: - v75 — persistent workflow run ledger (PJE-003)

    private static let v75: String = """
    -- Top-level run record locked to a frozen contract snapshot.
    -- circular FK: current_step_run_id → workflow_step_runs is declared here;
    -- workflow_step_runs.run_id → workflow_runs is declared in that table.
    -- SQLite checks FK constraints at DML time, not DDL time, so declaration order is safe.
    CREATE TABLE workflow_runs (
        id                              TEXT PRIMARY KEY NOT NULL,
        workspace_id                    TEXT NOT NULL
            REFERENCES workspaces(id) ON DELETE CASCADE,
        application_definition_id       TEXT NOT NULL,
        application_definition_version  INTEGER NOT NULL,
        workflow_definition_id          TEXT NOT NULL,
        workflow_definition_version     INTEGER NOT NULL,
        title                           TEXT,
        status                          TEXT NOT NULL
            CHECK(status IN ('draft','active','paused','waitingForHuman','blocked',
                             'completed','cancelled','superseded')),
        current_step_definition_id      TEXT,
        current_step_run_id             TEXT
            REFERENCES workflow_step_runs(id) ON DELETE SET NULL,
        contract_snapshot_json          TEXT NOT NULL,
        contract_snapshot_sha256        TEXT NOT NULL,
        snapshot_schema_version         INTEGER NOT NULL,
        revision                        INTEGER NOT NULL DEFAULT 1,
        parent_run_id                   TEXT
            REFERENCES workflow_runs(id) ON DELETE SET NULL,
        superseded_by_run_id            TEXT
            REFERENCES workflow_runs(id) ON DELETE SET NULL,
        created_at                      REAL NOT NULL,
        updated_at                      REAL NOT NULL,
        started_at                      REAL,
        paused_at                       REAL,
        completed_at                    REAL,
        cancelled_at                    REAL,
        cancellation_reason             TEXT
    );
    CREATE INDEX idx_wfr_workspace ON workflow_runs(workspace_id);
    CREATE INDEX idx_wfr_app ON workflow_runs(application_definition_id);
    CREATE INDEX idx_wfr_status ON workflow_runs(status);
    CREATE INDEX idx_wfr_created ON workflow_runs(created_at);

    CREATE TABLE workflow_step_runs (
        id                  TEXT PRIMARY KEY NOT NULL,
        run_id              TEXT NOT NULL
            REFERENCES workflow_runs(id) ON DELETE CASCADE,
        step_definition_id  TEXT NOT NULL,
        step_kind           TEXT NOT NULL,
        attempt             INTEGER NOT NULL DEFAULT 1,
        sequence            INTEGER NOT NULL,
        status              TEXT NOT NULL
            CHECK(status IN ('ready','active','waiting','blocked',
                             'completed','skipped','cancelled','superseded')),
        executor_id         TEXT,
        executor_version    TEXT,
        input_json          TEXT NOT NULL DEFAULT '{}',
        state_json          TEXT NOT NULL DEFAULT '{}',
        output_json         TEXT,
        state_sha256        TEXT NOT NULL,
        entered_at          REAL NOT NULL,
        updated_at          REAL NOT NULL,
        completed_at        REAL,
        UNIQUE(run_id, step_definition_id, attempt)
    );
    CREATE INDEX idx_wfsr_run ON workflow_step_runs(run_id);
    CREATE INDEX idx_wfsr_step ON workflow_step_runs(run_id, step_definition_id);

    CREATE TABLE workflow_decisions (
        id                      TEXT PRIMARY KEY NOT NULL,
        run_id                  TEXT NOT NULL
            REFERENCES workflow_runs(id) ON DELETE CASCADE,
        step_run_id             TEXT NOT NULL
            REFERENCES workflow_step_runs(id) ON DELETE CASCADE,
        decision_key            TEXT NOT NULL,
        kind                    TEXT NOT NULL
            CHECK(kind IN ('branchSelection','humanDecision','humanApproval')),
        selected_option         TEXT NOT NULL,
        rationale               TEXT,
        actor_kind              TEXT NOT NULL
            CHECK(actor_kind IN ('human','deterministicRule','system')),
        actor_identifier        TEXT,
        supersedes_decision_id  TEXT
            REFERENCES workflow_decisions(id) ON DELETE SET NULL,
        metadata_json           TEXT NOT NULL DEFAULT '{}',
        decided_at              REAL NOT NULL
    );
    CREATE INDEX idx_wfd_run ON workflow_decisions(run_id);
    CREATE INDEX idx_wfd_step ON workflow_decisions(step_run_id);

    CREATE TABLE workflow_artifacts (
        id                      TEXT PRIMARY KEY NOT NULL,
        run_id                  TEXT NOT NULL
            REFERENCES workflow_runs(id) ON DELETE CASCADE,
        step_run_id             TEXT
            REFERENCES workflow_step_runs(id) ON DELETE SET NULL,
        artifact_definition_id  TEXT NOT NULL,
        kind                    TEXT NOT NULL
            CHECK(kind IN ('attachment','generatedProduct','workProductRun','methodResult')),
        label                   TEXT NOT NULL,
        work_product_run_id     TEXT
            REFERENCES work_product_runs(id) ON DELETE SET NULL,
        target_kind             TEXT,
        target_id               TEXT,
        reference_uri           TEXT,
        media_type              TEXT,
        content_sha256          TEXT,
        metadata_json           TEXT NOT NULL DEFAULT '{}',
        supersedes_artifact_id  TEXT
            REFERENCES workflow_artifacts(id) ON DELETE SET NULL,
        created_at              REAL NOT NULL
    );
    CREATE INDEX idx_wfa_run ON workflow_artifacts(run_id);
    CREATE INDEX idx_wfa_step ON workflow_artifacts(step_run_id);

    CREATE TABLE workflow_checkpoints (
        id              TEXT PRIMARY KEY NOT NULL,
        run_id          TEXT NOT NULL
            REFERENCES workflow_runs(id) ON DELETE CASCADE,
        run_revision    INTEGER NOT NULL,
        reason          TEXT NOT NULL
            CHECK(reason IN ('explicitSave','pause','beforeDecision','afterDecision',
                             'beforeArtifactBuild','completion','recovery')),
        snapshot_json   TEXT NOT NULL,
        snapshot_sha256 TEXT NOT NULL,
        created_at      REAL NOT NULL
    );
    CREATE INDEX idx_wfc_run ON workflow_checkpoints(run_id);
    CREATE INDEX idx_wfc_revision ON workflow_checkpoints(run_id, run_revision);

    CREATE TABLE workflow_attention_items (
        id              TEXT PRIMARY KEY NOT NULL,
        run_id          TEXT NOT NULL
            REFERENCES workflow_runs(id) ON DELETE CASCADE,
        step_run_id     TEXT
            REFERENCES workflow_step_runs(id) ON DELETE SET NULL,
        source_kind     TEXT NOT NULL
            CHECK(source_kind IN ('requirement','validation','system','user','automation')),
        source_id       TEXT,
        severity        TEXT NOT NULL
            CHECK(severity IN ('informational','advisory','blocking')),
        status          TEXT NOT NULL
            CHECK(status IN ('open','resolved','dismissed')),
        title           TEXT NOT NULL,
        detail          TEXT,
        created_at      REAL NOT NULL,
        resolved_at     REAL,
        resolved_by     TEXT,
        resolution_note TEXT
    );
    CREATE INDEX idx_wfai_run ON workflow_attention_items(run_id);
    CREATE INDEX idx_wfai_status ON workflow_attention_items(run_id, status);

    -- Append-only event log; UNIQUE(run_id, sequence) enforces no gaps or duplicates.
    CREATE TABLE workflow_run_events (
        id               TEXT PRIMARY KEY NOT NULL,
        run_id           TEXT NOT NULL
            REFERENCES workflow_runs(id) ON DELETE CASCADE,
        sequence         INTEGER NOT NULL,
        run_revision     INTEGER NOT NULL,
        type             TEXT NOT NULL,
        actor_kind       TEXT NOT NULL
            CHECK(actor_kind IN ('human','deterministicRule','system')),
        actor_identifier TEXT,
        payload_json     TEXT NOT NULL DEFAULT '{}',
        occurred_at      REAL NOT NULL,
        UNIQUE(run_id, sequence)
    );
    CREATE INDEX idx_wfre_run ON workflow_run_events(run_id);
    CREATE INDEX idx_wfre_sequence ON workflow_run_events(run_id, sequence);
    """

    // MARK: - v76 — step-state hash semantics column (PJE-006B.1)

    private static let v76: String = """
    -- Records WHICH hash contract each step run's state_sha256 satisfies.
    -- 'legacyCanonicalizedJSON': pre-PJE-006B.1 rows (mixed raw-byte and
    --   canonicalized hash algorithms) — verified best-effort, never rewritten
    --   by reopen, upgraded only on the next legitimate state mutation.
    -- 'storedUTF8BytesV1': state_sha256 = SHA-256 of the exact UTF-8 bytes of
    --   state_json — verified strictly on reopen.
    ALTER TABLE workflow_step_runs
        ADD COLUMN state_hash_semantics TEXT NOT NULL DEFAULT 'legacyCanonicalizedJSON';
    """

    // MARK: - v77 — evidence, attachment and provenance bridge (PJE-007)

    private static let v77: String = """
    -- Version-aware provenance semantics on workflow rows.
    -- 'legacyUntracked': pre-PJE-007 rows — reopen without a snapshot, never
    --   rewritten by reopening, never given guessed provenance; upgrade only on
    --   a legitimate mutation.
    -- 'snapshotV1': the row has a hashed provenance snapshot with ordered,
    --   gate-verified canonical references.
    ALTER TABLE workflow_step_runs
        ADD COLUMN provenance_semantics TEXT NOT NULL DEFAULT 'legacyUntracked';
    ALTER TABLE workflow_artifacts
        ADD COLUMN provenance_semantics TEXT NOT NULL DEFAULT 'legacyUntracked';
    ALTER TABLE workflow_decisions
        ADD COLUMN provenance_semantics TEXT NOT NULL DEFAULT 'legacyUntracked';

    -- The provenance snapshot ledger: exactly one owner per row (CHECK below).
    -- snapshot_sha256 = SHA-256 of the exact UTF-8 bytes of snapshot_json
    -- (the PJE-006B.1 stored-byte contract; no third hash interpretation).
    CREATE TABLE workflow_provenance_snapshots (
        id                       TEXT PRIMARY KEY NOT NULL,
        workflow_run_id          TEXT NOT NULL,
        owner_kind               TEXT NOT NULL,
        step_run_id              TEXT,
        artifact_id              TEXT,
        decision_id              TEXT,
        workflow_run_revision    INTEGER NOT NULL,
        producer_id              TEXT NOT NULL,
        producer_version         TEXT NOT NULL,
        source_state_sha256      TEXT,
        snapshot_json            TEXT NOT NULL,
        snapshot_sha256          TEXT NOT NULL,
        created_at               REAL NOT NULL,
        FOREIGN KEY(workflow_run_id) REFERENCES workflow_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(step_run_id)     REFERENCES workflow_step_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(artifact_id)     REFERENCES workflow_artifacts(id) ON DELETE CASCADE,
        FOREIGN KEY(decision_id)     REFERENCES workflow_decisions(id) ON DELETE CASCADE,
        CHECK(workflow_run_revision >= 1),
        CHECK(owner_kind IN ('stepState','artifact','decision')),
        CHECK(
            (owner_kind = 'stepState' AND step_run_id IS NOT NULL
                AND artifact_id IS NULL AND decision_id IS NULL)
            OR
            (owner_kind = 'artifact' AND step_run_id IS NULL
                AND artifact_id IS NOT NULL AND decision_id IS NULL)
            OR
            (owner_kind = 'decision' AND step_run_id IS NULL
                AND artifact_id IS NULL AND decision_id IS NOT NULL)
        )
    );
    CREATE UNIQUE INDEX idx_wfps_step_revision
        ON workflow_provenance_snapshots(step_run_id, workflow_run_revision)
        WHERE owner_kind = 'stepState';
    CREATE UNIQUE INDEX idx_wfps_artifact
        ON workflow_provenance_snapshots(artifact_id)
        WHERE owner_kind = 'artifact';
    CREATE UNIQUE INDEX idx_wfps_decision
        ON workflow_provenance_snapshots(decision_id)
        WHERE owner_kind = 'decision';
    CREATE INDEX idx_wfps_run       ON workflow_provenance_snapshots(workflow_run_id);
    CREATE INDEX idx_wfps_step      ON workflow_provenance_snapshots(step_run_id);
    CREATE INDEX idx_wfps_artifact2 ON workflow_provenance_snapshots(artifact_id);
    CREATE INDEX idx_wfps_decision2 ON workflow_provenance_snapshots(decision_id);
    CREATE INDEX idx_wfps_revision  ON workflow_provenance_snapshots(workflow_run_revision);

    -- Ordered, normalized references belonging to one snapshot.
    -- Deliberately NO generic FK from canonical_object_id: the referenced kind
    -- varies, and historical workflow records must remain reopenable even when a
    -- canonical target later becomes unavailable. Every reference is validated
    -- through the evidence gate BEFORE insertion.
    CREATE TABLE workflow_provenance_references (
        id                       TEXT PRIMARY KEY NOT NULL,
        snapshot_id              TEXT NOT NULL,
        ordinal                  INTEGER NOT NULL,
        reference_kind           TEXT NOT NULL,
        canonical_object_id      TEXT NOT NULL,
        role                     TEXT NOT NULL,
        disposition              TEXT NOT NULL,
        source_version_id        TEXT,
        locator_json             TEXT,
        label                    TEXT,
        note                     TEXT,
        created_at               REAL NOT NULL,
        FOREIGN KEY(snapshot_id) REFERENCES workflow_provenance_snapshots(id) ON DELETE CASCADE,
        UNIQUE(snapshot_id, ordinal),
        CHECK(ordinal >= 0)
    );
    CREATE INDEX idx_wfpr_snapshot ON workflow_provenance_references(snapshot_id);

    -- Immutable attachment identity snapshot. Stores NO file bytes, NO extracted
    -- text, NO OCR output, NO copied EvidenceBlock or SourceVersion record —
    -- the canonical source store remains the one store; source_relations remains
    -- the parent-child attachment authority.
    CREATE TABLE workflow_attachment_bindings (
        artifact_id                  TEXT PRIMARY KEY NOT NULL,
        logical_source_id            TEXT NOT NULL,
        source_version_id            TEXT NOT NULL,
        parent_logical_source_id     TEXT,
        source_relation              TEXT,
        display_name                 TEXT NOT NULL,
        media_type                   TEXT,
        byte_count                   INTEGER,
        source_content_sha256        TEXT NOT NULL,
        created_at                   REAL NOT NULL,
        FOREIGN KEY(artifact_id) REFERENCES workflow_artifacts(id) ON DELETE CASCADE,
        CHECK(byte_count IS NULL OR byte_count >= 0)
    );
    CREATE INDEX idx_wfab_source_version ON workflow_attachment_bindings(source_version_id);
    CREATE INDEX idx_wfab_logical_source ON workflow_attachment_bindings(logical_source_id);
    """

    // MARK: - v78 — automation execution ledger (PJE-010)

    private static let v78: String = """
    -- The automation execution ledger: an idempotent, tamper-evident AUDIT
    -- RECEIPT for every runtime automation firing. It is NOT a task, deadline,
    -- evidence or attention store — proposal OUTPUTS live in their existing
    -- canonical tables (professional_tasks candidate, deadline_candidates,
    -- workflow_attention_items). This table only records that a version-pinned
    -- automation ran, what it produced, and its idempotency identity, so the
    -- same trigger event never creates a duplicate candidate on replay/relaunch.
    --
    -- idempotency_key = SHA-256 over (automation def id/version + workspace/run
    -- scope + trigger event identity). UNIQUE — a repeated delivery reuses the
    -- prior execution (status 'skippedDuplicate') instead of a second output.
    -- request_sha256 / result_sha256 are stored-byte hashes (the PJE-006B.1
    -- contract) so request/result tampering is detectable on reopen.
    CREATE TABLE workflow_automation_executions (
        id                            TEXT PRIMARY KEY NOT NULL,
        workspace_id                  TEXT NOT NULL,
        workflow_run_id               TEXT,
        step_run_id                   TEXT,
        application_definition_id     TEXT NOT NULL,
        automation_definition_id      TEXT NOT NULL,
        automation_definition_version INTEGER NOT NULL,
        trigger_kind                  TEXT NOT NULL,
        trigger_event_key             TEXT NOT NULL,
        action_kind                   TEXT NOT NULL,
        idempotency_key               TEXT NOT NULL,
        request_json                  TEXT NOT NULL,
        request_sha256                TEXT NOT NULL,
        status                        TEXT NOT NULL,
        output_kind                   TEXT,
        output_id                     TEXT,
        result_json                   TEXT,
        result_sha256                 TEXT,
        started_at                    REAL NOT NULL,
        completed_at                  REAL,
        failure_reason                TEXT,
        FOREIGN KEY(workflow_run_id) REFERENCES workflow_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(step_run_id)     REFERENCES workflow_step_runs(id) ON DELETE CASCADE,
        CHECK(automation_definition_version >= 1),
        CHECK(status IN ('started','succeeded','failed','skippedDuplicate'))
    );
    CREATE UNIQUE INDEX idx_wae_idempotency ON workflow_automation_executions(idempotency_key);
    CREATE INDEX idx_wae_workspace  ON workflow_automation_executions(workspace_id);
    CREATE INDEX idx_wae_run        ON workflow_automation_executions(workflow_run_id);
    CREATE INDEX idx_wae_automation ON workflow_automation_executions(automation_definition_id, automation_definition_version);
    CREATE INDEX idx_wae_trigger    ON workflow_automation_executions(trigger_event_key);
    """

    // MARK: - v79 — professional method run-state ledger (PM-002, Stage 4)

    private static let v79: String = """
    -- Stage 4 Professional Method Engine: the persistent MethodRun aggregate.
    -- These eight tables store WORKING METHOD STATE only — never canonical
    -- evidence. Definitions stay immutable, code-registry-backed (PM-003): there
    -- is deliberately NO professional_method_definitions table, so there is only
    -- ONE definition authority. method_runs stores the definition id + version.
    --
    -- Truth boundaries the schema helps enforce:
    --   working method state != canonical evidence   (own proposal-layer vocab)
    --   method finding       != confirmed Claim      (related_claim_id is a soft
    --                                                  reference, never a promotion)
    --   review               is HUMAN + append-only  (CHECK actor_kind='human')
    --   validation           may BLOCK, never confirm
    --
    -- Workflow references (workflow_run_id / workflow_step_run_id) are SOFT
    -- historical invocation identifiers, NOT ownership and NOT FK-enforced: a
    -- workflow deletion must not delete the MethodRun; the stored id is retained
    -- and simply becomes unresolved. related_claim_id and superseded_by_run_id
    -- are soft references for the same reason. Same-run ownership of the working
    -- graph IS enforced in SQL via composite (id, method_run_id) foreign keys.
    CREATE TABLE method_runs (
        id                        TEXT PRIMARY KEY NOT NULL,
        workspace_id              TEXT NOT NULL,
        method_definition_id      TEXT NOT NULL,
        method_definition_version INTEGER NOT NULL,
        workflow_run_id           TEXT,
        workflow_step_run_id      TEXT,
        status                    TEXT NOT NULL,
        title                     TEXT,
        revision                  INTEGER NOT NULL,
        created_by                TEXT NOT NULL,
        created_at                REAL NOT NULL,
        updated_at                REAL NOT NULL,
        completed_at              REAL,
        superseded_by_run_id      TEXT,
        FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        CHECK(method_definition_version >= 1),
        CHECK(revision >= 1),
        CHECK(length(trim(method_definition_id)) > 0),
        CHECK(length(trim(created_by)) > 0),
        CHECK(status IN ('draft','active','waitingForHuman','blocked','completed','cancelled','superseded')),
        CHECK(superseded_by_run_id IS NULL OR superseded_by_run_id <> id),
        CHECK(workflow_step_run_id IS NULL OR workflow_run_id IS NOT NULL),
        CHECK(completed_at IS NULL OR status = 'completed')
    );
    -- (id, method_run_id) uniqueness anchors the composite ownership foreign keys.
    CREATE UNIQUE INDEX idx_method_runs_owned ON method_runs(id);
    CREATE INDEX idx_method_runs_workspace  ON method_runs(workspace_id);
    CREATE INDEX idx_method_runs_definition ON method_runs(method_definition_id, method_definition_version);
    CREATE INDEX idx_method_runs_workflow   ON method_runs(workflow_run_id);

    CREATE TABLE method_nodes (
        id                 TEXT NOT NULL,
        method_run_id      TEXT NOT NULL,
        node_definition_key TEXT NOT NULL,
        node_kind          TEXT NOT NULL,
        label              TEXT NOT NULL,
        body               TEXT,
        working_state      TEXT NOT NULL,
        ordinal            INTEGER NOT NULL,
        parent_node_id     TEXT,
        created_at         REAL NOT NULL,
        updated_at         REAL NOT NULL,
        PRIMARY KEY(id),
        UNIQUE(id, method_run_id),
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(parent_node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        CHECK(ordinal >= 0),
        CHECK(length(trim(node_definition_key)) > 0),
        CHECK(length(trim(node_kind)) > 0),
        CHECK(length(trim(label)) > 0),
        CHECK(parent_node_id IS NULL OR parent_node_id <> id),
        CHECK(working_state IN ('proposal','ruleSupported','disputed','gap','humanRejected','humanAcceptedForWorkflow'))
    );
    CREATE INDEX idx_method_nodes_run    ON method_nodes(method_run_id, ordinal);
    CREATE INDEX idx_method_nodes_parent ON method_nodes(parent_node_id);

    CREATE TABLE method_edges (
        id            TEXT PRIMARY KEY NOT NULL,
        method_run_id TEXT NOT NULL,
        from_node_id  TEXT NOT NULL,
        to_node_id    TEXT NOT NULL,
        edge_kind     TEXT NOT NULL,
        label         TEXT,
        ordinal       INTEGER NOT NULL,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(from_node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        FOREIGN KEY(to_node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        CHECK(ordinal >= 0),
        CHECK(length(trim(edge_kind)) > 0),
        -- Duplicate identical edges FAIL (one documented contract).
        UNIQUE(method_run_id, from_node_id, to_node_id, edge_kind)
    );
    CREATE INDEX idx_method_edges_run  ON method_edges(method_run_id, ordinal);
    CREATE INDEX idx_method_edges_from ON method_edges(from_node_id);
    CREATE INDEX idx_method_edges_to   ON method_edges(to_node_id);

    -- Canonical evidence references: IDs only, reusing the PJE-007 reference
    -- vocabulary (target_kind). No evidence text/bytes/OCR/chunks are copied.
    CREATE TABLE method_evidence_links (
        id            TEXT PRIMARY KEY NOT NULL,
        method_run_id TEXT NOT NULL,
        node_id       TEXT,
        target_kind   TEXT NOT NULL,
        target_id     TEXT NOT NULL,
        role          TEXT NOT NULL,
        ordinal       INTEGER NOT NULL,
        added_by      TEXT NOT NULL,
        added_at      REAL NOT NULL,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        CHECK(ordinal >= 0),
        CHECK(length(trim(added_by)) > 0),
        CHECK(role IN ('supporting','contradicting','contextual'))
    );
    -- Partial unique indexes so duplicate links cannot slip through SQLite's NULL
    -- uniqueness behaviour — separately for node-scoped and run-level links.
    CREATE UNIQUE INDEX idx_method_evlink_node ON method_evidence_links(method_run_id, node_id, target_kind, target_id, role)
        WHERE node_id IS NOT NULL;
    CREATE UNIQUE INDEX idx_method_evlink_run  ON method_evidence_links(method_run_id, target_kind, target_id, role)
        WHERE node_id IS NULL;
    CREATE INDEX idx_method_evlink_target ON method_evidence_links(target_kind, target_id);

    CREATE TABLE method_assumptions (
        id            TEXT PRIMARY KEY NOT NULL,
        method_run_id TEXT NOT NULL,
        node_id       TEXT,
        statement     TEXT NOT NULL,
        status        TEXT NOT NULL,
        rationale     TEXT,
        created_by    TEXT NOT NULL,
        reviewed_by   TEXT,
        reviewed_at   REAL,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        CHECK(length(trim(statement)) > 0),
        CHECK(length(trim(created_by)) > 0),
        CHECK(status IN ('open','accepted','rejected','needsEvidence')),
        CHECK((reviewed_by IS NULL) = (reviewed_at IS NULL))
    );
    CREATE INDEX idx_method_assumptions_run ON method_assumptions(method_run_id);

    CREATE TABLE method_findings (
        id              TEXT NOT NULL,
        method_run_id   TEXT NOT NULL,
        node_id         TEXT,
        statement       TEXT NOT NULL,
        finding_kind    TEXT NOT NULL,
        support_status  TEXT NOT NULL,
        review_status   TEXT NOT NULL,
        related_claim_id TEXT,
        created_at      REAL NOT NULL,
        PRIMARY KEY(id),
        UNIQUE(id, method_run_id),
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        CHECK(length(trim(statement)) > 0),
        CHECK(length(trim(finding_kind)) > 0),
        CHECK(support_status IN ('unsupported','partiallySupported','supported','contradicted')),
        CHECK(review_status IN ('unreviewed','acceptedForWorkflow','rejected','needsRevision'))
    );
    CREATE INDEX idx_method_findings_run   ON method_findings(method_run_id, created_at);
    CREATE INDEX idx_method_findings_claim ON method_findings(related_claim_id);

    -- Append-only human review ledger (no update/delete API). actor_kind is
    -- CHECK-pinned to 'human' — no system/rule/automation impersonation.
    CREATE TABLE method_reviews (
        id               TEXT PRIMARY KEY NOT NULL,
        method_run_id    TEXT NOT NULL,
        node_id          TEXT,
        finding_id       TEXT,
        action           TEXT NOT NULL,
        actor_kind       TEXT NOT NULL,
        actor_identifier TEXT NOT NULL,
        comment          TEXT,
        reviewed_at      REAL NOT NULL,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        FOREIGN KEY(finding_id, method_run_id)
            REFERENCES method_findings(id, method_run_id) ON DELETE CASCADE,
        CHECK(actor_kind = 'human'),
        CHECK(length(trim(actor_identifier)) > 0),
        CHECK(action IN ('acceptForWorkflow','reject','requestRevision','comment','reopen'))
    );
    CREATE INDEX idx_method_reviews_run     ON method_reviews(method_run_id, reviewed_at);
    CREATE INDEX idx_method_reviews_finding ON method_reviews(finding_id);

    -- Append-only deterministic validation ledger (no update/delete API).
    -- A blocking result restricts completion; it never confirms a conclusion.
    CREATE TABLE method_validation_results (
        id                TEXT PRIMARY KEY NOT NULL,
        method_run_id     TEXT NOT NULL,
        validator_id      TEXT NOT NULL,
        validator_version TEXT NOT NULL,
        severity          TEXT NOT NULL,
        code              TEXT NOT NULL,
        message           TEXT NOT NULL,
        subject_kind      TEXT NOT NULL,
        subject_id        TEXT,
        created_at        REAL NOT NULL,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        CHECK(length(trim(validator_id)) > 0),
        CHECK(length(trim(validator_version)) > 0),
        CHECK(length(trim(code)) > 0),
        CHECK(length(trim(message)) > 0),
        CHECK(severity IN ('info','warning','error','blocking')),
        CHECK(subject_kind IN ('run','node','edge','assumption','finding','evidenceLink')),
        -- A non-run subject must name a concrete subject id; a run subject may omit it.
        CHECK(subject_kind = 'run' OR subject_id IS NOT NULL)
    );
    CREATE INDEX idx_method_validation_run ON method_validation_results(method_run_id, created_at);
    """

    // MARK: - v80 — method lifecycle (PM-004, Stage 4)

    private static let v80: String = """
    -- PM-004 evolves the Stage-4 method ledger with a lifecycle runtime:
    --   * method_runs gains content_revision + the 'paused' status (a table rebuild,
    --     because a CHECK constraint cannot be altered in place);
    --   * evidence links gain the fulfilled definition input_role;
    --   * reviews gain the definition review_key + the evaluated content revision;
    --   * validation results gain a batch id + the evaluated content revision;
    --   * a new append-only method_run_events lifecycle ledger.
    -- content_revision (analytical-content epoch) is distinct from revision (the CAS
    -- token): review/validation gates are valid only at the exact current content
    -- revision, so a later content change invalidates a stale acceptance without
    -- deleting its historical row.

    -- Rebuild method_runs to add content_revision + the 'paused' status (a CHECK
    -- cannot be altered in place). SchemaMigrations.migrate() disables foreign-key
    -- enforcement for the whole migration pass (the SQLite-recommended pattern for
    -- table rebuilds) and runs PRAGMA foreign_key_check afterward, so DROP TABLE
    -- does NOT cascade-delete the children; their FK text ("method_runs") re-binds
    -- to the new table after the rename, and every row id is preserved.
    CREATE TABLE method_runs__v80 (
        id                        TEXT PRIMARY KEY NOT NULL,
        workspace_id              TEXT NOT NULL,
        method_definition_id      TEXT NOT NULL,
        method_definition_version INTEGER NOT NULL,
        workflow_run_id           TEXT,
        workflow_step_run_id      TEXT,
        status                    TEXT NOT NULL,
        title                     TEXT,
        revision                  INTEGER NOT NULL,
        content_revision          INTEGER NOT NULL,
        created_by                TEXT NOT NULL,
        created_at                REAL NOT NULL,
        updated_at                REAL NOT NULL,
        completed_at              REAL,
        superseded_by_run_id      TEXT,
        FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        CHECK(method_definition_version >= 1),
        CHECK(revision >= 1),
        CHECK(content_revision >= 1),
        CHECK(length(trim(method_definition_id)) > 0),
        CHECK(length(trim(created_by)) > 0),
        CHECK(status IN ('draft','active','paused','waitingForHuman','blocked','completed','cancelled','superseded')),
        CHECK(superseded_by_run_id IS NULL OR superseded_by_run_id <> id),
        CHECK(workflow_step_run_id IS NULL OR workflow_run_id IS NOT NULL),
        -- completed status <=> completion timestamp
        CHECK(completed_at IS NULL OR status = 'completed'),
        CHECK(status <> 'completed' OR completed_at IS NOT NULL),
        -- superseded status <=> supersession reference
        CHECK(status <> 'superseded' OR superseded_by_run_id IS NOT NULL)
    );
    INSERT INTO method_runs__v80 (id, workspace_id, method_definition_id, method_definition_version,
                                  workflow_run_id, workflow_step_run_id, status, title, revision,
                                  content_revision, created_by, created_at, updated_at, completed_at, superseded_by_run_id)
        SELECT id, workspace_id, method_definition_id, method_definition_version,
               workflow_run_id, workflow_step_run_id, status, title, revision,
               1, created_by, created_at, updated_at, completed_at, superseded_by_run_id
          FROM method_runs;
    DROP TABLE method_runs;
    ALTER TABLE method_runs__v80 RENAME TO method_runs;
    CREATE UNIQUE INDEX idx_method_runs_owned ON method_runs(id);
    CREATE INDEX idx_method_runs_workspace  ON method_runs(workspace_id);
    CREATE INDEX idx_method_runs_definition ON method_runs(method_definition_id, method_definition_version);
    CREATE INDEX idx_method_runs_workflow   ON method_runs(workflow_run_id);

    -- Evidence links: the fulfilled definition input role (separate from analytical role).
    ALTER TABLE method_evidence_links ADD COLUMN input_role TEXT;
    DROP INDEX idx_method_evlink_node;
    DROP INDEX idx_method_evlink_run;
    -- NULL-safe uniqueness: one canonical reference may serve DIFFERENT input roles,
    -- but a duplicate within the same scope + analytical role + input role is rejected.
    CREATE UNIQUE INDEX idx_method_evlink_node ON method_evidence_links(
        method_run_id, node_id, target_kind, target_id, role, COALESCE(input_role, '')) WHERE node_id IS NOT NULL;
    CREATE UNIQUE INDEX idx_method_evlink_run ON method_evidence_links(
        method_run_id, target_kind, target_id, role, COALESCE(input_role, '')) WHERE node_id IS NULL;

    -- Reviews: the definition review key + the content revision the decision evaluated.
    ALTER TABLE method_reviews ADD COLUMN review_key TEXT NOT NULL DEFAULT 'legacy.unkeyed';
    ALTER TABLE method_reviews ADD COLUMN reviewed_content_revision INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX idx_method_reviews_key ON method_reviews(method_run_id, review_key, reviewed_content_revision);

    -- Validation results: the batch id + the content revision the batch evaluated.
    ALTER TABLE method_validation_results ADD COLUMN validation_batch_id TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000';
    ALTER TABLE method_validation_results ADD COLUMN evaluated_content_revision INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX idx_method_validation_contentrev ON method_validation_results(method_run_id, evaluated_content_revision);
    CREATE INDEX idx_method_validation_batch ON method_validation_results(method_run_id, validation_batch_id);
    CREATE INDEX idx_method_validation_validator ON method_validation_results(method_run_id, validator_id);

    -- Append-only lifecycle-event ledger. NOT canonical evidence events.
    CREATE TABLE method_run_events (
        id                 TEXT PRIMARY KEY NOT NULL,
        method_run_id      TEXT NOT NULL,
        sequence           INTEGER NOT NULL,
        run_revision       INTEGER NOT NULL,
        content_revision   INTEGER NOT NULL,
        action             TEXT NOT NULL,
        from_status        TEXT NOT NULL,
        to_status          TEXT NOT NULL,
        actor_kind         TEXT NOT NULL,
        actor_identifier   TEXT,
        reason             TEXT,
        occurred_at        REAL NOT NULL,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        UNIQUE(method_run_id, sequence),
        UNIQUE(method_run_id, run_revision),
        CHECK(sequence >= 1),
        CHECK(run_revision >= 2),
        CHECK(content_revision >= 1),
        CHECK(action IN ('start','pause','resume','requestHumanReview','continueAfterReview','block','unblock',
                         'validationRecorded','reviewRecorded','complete','cancel','supersede','reopen')),
        CHECK(from_status IN ('draft','active','paused','waitingForHuman','blocked','completed','cancelled','superseded')),
        CHECK(to_status IN ('draft','active','paused','waitingForHuman','blocked','completed','cancelled','superseded')),
        CHECK(actor_kind IN ('human','deterministicRule','system')),
        CHECK(actor_kind <> 'human' OR (actor_identifier IS NOT NULL AND length(trim(actor_identifier)) > 0))
    );
    CREATE INDEX idx_method_run_events_run ON method_run_events(method_run_id, sequence);
    """

    // MARK: - v81 — method lifecycle ledger hardening (PM-004.1, Stage 4)

    private static let v81: String = """
    -- PM-004.1 pushes the lifecycle invariants that PM-004 enforced only in Swift down
    -- into the ledger itself, by rebuilding three tables to add missing CHECKs (a CHECK
    -- cannot be altered in place). Adds NO new column and NO new table — every rebuild
    -- preserves every row (ids unchanged) and every legacy value satisfies the new
    -- CHECKs (legacy review_key 'legacy.unkeyed', legacy batch id all-zeros, revision 0).
    -- migrate() disables FK enforcement for the whole pass and runs foreign_key_check,
    -- so DROP TABLE method_runs does NOT cascade-delete its children.

    -- (1) method_runs: complete the BOTH-WAY supersession invariant. PM-004 enforced
    --     status='superseded' ⇒ successor exists, but NOT the reverse, so an active /
    --     blocked / completed run could carry a stray superseded_by_run_id. The reverse
    --     CHECK closes that: a successor reference implies the run IS superseded.
    CREATE TABLE method_runs__v81 (
        id                        TEXT PRIMARY KEY NOT NULL,
        workspace_id              TEXT NOT NULL,
        method_definition_id      TEXT NOT NULL,
        method_definition_version INTEGER NOT NULL,
        workflow_run_id           TEXT,
        workflow_step_run_id      TEXT,
        status                    TEXT NOT NULL,
        title                     TEXT,
        revision                  INTEGER NOT NULL,
        content_revision          INTEGER NOT NULL,
        created_by                TEXT NOT NULL,
        created_at                REAL NOT NULL,
        updated_at                REAL NOT NULL,
        completed_at              REAL,
        superseded_by_run_id      TEXT,
        FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        CHECK(method_definition_version >= 1),
        CHECK(revision >= 1),
        CHECK(content_revision >= 1),
        CHECK(length(trim(method_definition_id)) > 0),
        CHECK(length(trim(created_by)) > 0),
        CHECK(status IN ('draft','active','paused','waitingForHuman','blocked','completed','cancelled','superseded')),
        CHECK(superseded_by_run_id IS NULL OR superseded_by_run_id <> id),
        CHECK(workflow_step_run_id IS NULL OR workflow_run_id IS NOT NULL),
        -- completed status <=> completion timestamp
        CHECK(completed_at IS NULL OR status = 'completed'),
        CHECK(status <> 'completed' OR completed_at IS NOT NULL),
        -- superseded status <=> supersession reference (BOTH directions)
        CHECK(status <> 'superseded' OR superseded_by_run_id IS NOT NULL),
        CHECK(superseded_by_run_id IS NULL OR status = 'superseded')
    );
    INSERT INTO method_runs__v81 (id, workspace_id, method_definition_id, method_definition_version,
                                  workflow_run_id, workflow_step_run_id, status, title, revision,
                                  content_revision, created_by, created_at, updated_at, completed_at, superseded_by_run_id)
        SELECT id, workspace_id, method_definition_id, method_definition_version,
               workflow_run_id, workflow_step_run_id, status, title, revision,
               content_revision, created_by, created_at, updated_at, completed_at, superseded_by_run_id
          FROM method_runs;
    DROP TABLE method_runs;
    ALTER TABLE method_runs__v81 RENAME TO method_runs;
    CREATE UNIQUE INDEX idx_method_runs_owned ON method_runs(id);
    CREATE INDEX idx_method_runs_workspace  ON method_runs(workspace_id);
    CREATE INDEX idx_method_runs_definition ON method_runs(method_definition_id, method_definition_version);
    CREATE INDEX idx_method_runs_workflow   ON method_runs(workflow_run_id);

    -- (2) method_reviews: enforce the review contract physically — a non-blank review
    --     key, a non-negative evaluated revision, and never both a node and a finding.
    CREATE TABLE method_reviews__v81 (
        id                        TEXT PRIMARY KEY NOT NULL,
        method_run_id             TEXT NOT NULL,
        node_id                   TEXT,
        finding_id                TEXT,
        action                    TEXT NOT NULL,
        actor_kind                TEXT NOT NULL,
        actor_identifier          TEXT NOT NULL,
        comment                   TEXT,
        reviewed_at               REAL NOT NULL,
        review_key                TEXT NOT NULL DEFAULT 'legacy.unkeyed',
        reviewed_content_revision INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        FOREIGN KEY(node_id, method_run_id)
            REFERENCES method_nodes(id, method_run_id) ON DELETE CASCADE,
        FOREIGN KEY(finding_id, method_run_id)
            REFERENCES method_findings(id, method_run_id) ON DELETE CASCADE,
        CHECK(actor_kind = 'human'),
        CHECK(length(trim(actor_identifier)) > 0),
        CHECK(action IN ('acceptForWorkflow','reject','requestRevision','comment','reopen')),
        CHECK(length(trim(review_key)) > 0),
        CHECK(reviewed_content_revision >= 0),
        CHECK(NOT (node_id IS NOT NULL AND finding_id IS NOT NULL))
    );
    INSERT INTO method_reviews__v81 (id, method_run_id, node_id, finding_id, action, actor_kind,
                                     actor_identifier, comment, reviewed_at, review_key, reviewed_content_revision)
        SELECT id, method_run_id, node_id, finding_id, action, actor_kind,
               actor_identifier, comment, reviewed_at, review_key, reviewed_content_revision
          FROM method_reviews;
    DROP TABLE method_reviews;
    ALTER TABLE method_reviews__v81 RENAME TO method_reviews;
    CREATE INDEX idx_method_reviews_run     ON method_reviews(method_run_id, reviewed_at);
    CREATE INDEX idx_method_reviews_finding ON method_reviews(finding_id);
    CREATE INDEX idx_method_reviews_key     ON method_reviews(method_run_id, review_key, reviewed_content_revision);

    -- (3) method_validation_results: enforce a non-blank batch id + a non-negative
    --     evaluated revision physically.
    CREATE TABLE method_validation_results__v81 (
        id                        TEXT PRIMARY KEY NOT NULL,
        method_run_id             TEXT NOT NULL,
        validator_id              TEXT NOT NULL,
        validator_version         TEXT NOT NULL,
        severity                  TEXT NOT NULL,
        code                      TEXT NOT NULL,
        message                   TEXT NOT NULL,
        subject_kind              TEXT NOT NULL,
        subject_id                TEXT,
        created_at                REAL NOT NULL,
        validation_batch_id       TEXT NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000',
        evaluated_content_revision INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE,
        CHECK(length(trim(validator_id)) > 0),
        CHECK(length(trim(validator_version)) > 0),
        CHECK(length(trim(code)) > 0),
        CHECK(length(trim(message)) > 0),
        CHECK(severity IN ('info','warning','error','blocking')),
        CHECK(subject_kind IN ('run','node','edge','assumption','finding','evidenceLink')),
        CHECK(subject_kind = 'run' OR subject_id IS NOT NULL),
        CHECK(length(trim(validation_batch_id)) > 0),
        CHECK(evaluated_content_revision >= 0)
    );
    INSERT INTO method_validation_results__v81 (id, method_run_id, validator_id, validator_version, severity,
                                                code, message, subject_kind, subject_id, created_at,
                                                validation_batch_id, evaluated_content_revision)
        SELECT id, method_run_id, validator_id, validator_version, severity,
               code, message, subject_kind, subject_id, created_at,
               validation_batch_id, evaluated_content_revision
          FROM method_validation_results;
    DROP TABLE method_validation_results;
    ALTER TABLE method_validation_results__v81 RENAME TO method_validation_results;
    CREATE INDEX idx_method_validation_run ON method_validation_results(method_run_id, created_at);
    CREATE INDEX idx_method_validation_contentrev ON method_validation_results(method_run_id, evaluated_content_revision);
    CREATE INDEX idx_method_validation_batch ON method_validation_results(method_run_id, validation_batch_id);
    CREATE INDEX idx_method_validation_validator ON method_validation_results(method_run_id, validator_id);
    """

    // MARK: - v82 — universal safe intake & pre-parser source custody (USF-001)

    private static let v82: String = """
    -- USF-001 guarantees that every ACCESSIBLE file receives a durable canonical
    -- source + source-version custody record BEFORE any loader/parser/OCR/model runs.
    -- source_versions remains the ONE version authority; this migration extends it with
    -- intake custody metadata (a rebuild — CHECKs cannot be altered in place), repairs
    -- any legacy multi-current rows, and adds the append-only intake-receipt ledger and
    -- exact version-level parent/child relations. NO second source identity table.
    -- migrate() runs the whole pass with FK enforcement OFF + a final foreign_key_check.

    -- Repair legacy data BEFORE enforcing one-current-per-logical-source: demote every
    -- current row that is not the newest (by valid_from, ties by stable id) for its
    -- logical source, closing it with an appropriate valid_to. Never deletes a row.
    UPDATE source_versions SET is_current = 0,
        valid_to = COALESCE(valid_to, valid_from)
    WHERE is_current = 1 AND EXISTS (
        SELECT 1 FROM source_versions other
        WHERE other.logical_source_id = source_versions.logical_source_id
          AND other.is_current = 1
          AND (other.valid_from > source_versions.valid_from
               OR (other.valid_from = source_versions.valid_from AND other.id > source_versions.id))
    );

    -- Rebuild source_versions with intake custody metadata + CHECKs.
    CREATE TABLE source_versions__v82 (
        id                   TEXT PRIMARY KEY NOT NULL,
        logical_source_id    TEXT NOT NULL,
        document_id          TEXT,
        content_hash         TEXT NOT NULL,
        supersedes           TEXT,
        valid_from           REAL NOT NULL,
        valid_to             REAL,
        is_current           INTEGER NOT NULL DEFAULT 1,
        original_url         TEXT,
        created_at           REAL NOT NULL,
        -- Intake custody metadata. NOT-NULL with DEFAULTs so a legacy short-form insert
        -- (id, logical_source_id, document_id, content_hash, valid_from, is_current,
        -- created_at) still succeeds — source_versions has many existing writers.
        filename             TEXT NOT NULL DEFAULT 'legacy-source',
        declared_extension   TEXT NOT NULL DEFAULT '',
        detected_type        TEXT NOT NULL DEFAULT 'unknown',
        mime_type            TEXT,
        detection_basis      TEXT NOT NULL DEFAULT 'unknown',
        size_bytes           INTEGER NOT NULL DEFAULT 0,
        modified_at          REAL,
        custody_mode         TEXT NOT NULL DEFAULT 'referenced',
        preservation_status  TEXT NOT NULL DEFAULT 'referenceRecorded',
        vault_address        TEXT,
        intake_recorded_at   REAL NOT NULL DEFAULT 0,
        CHECK(length(trim(filename)) > 0),
        CHECK(length(trim(detected_type)) > 0),
        CHECK(detection_basis IN ('pathPattern','declaredExtension','magicBytes','unknown')),
        CHECK(size_bytes >= 0),
        -- content_hash is intentionally UNCONSTRAINED here (as it was pre-v82): the intake
        -- path (SourceByteCapture) always writes a normalized 64-char lowercase SHA-256, but
        -- legacy writers + a deliberately-missing custody hash (blocked downstream, not by the
        -- schema) must still round-trip.
        CHECK(custody_mode IN ('referenced','managed')),
        CHECK(preservation_status IN ('referenceRecorded','managedCopyStored','managedCopyFailed','legacyImported')),
        CHECK(is_current IN (0,1)),
        CHECK(supersedes IS NULL OR supersedes <> id),
        -- managedCopyStored requires managed custody + a vault address; a referenced
        -- source can never claim a stored managed copy.
        CHECK(preservation_status <> 'managedCopyStored'
              OR (custody_mode = 'managed' AND vault_address IS NOT NULL AND length(trim(vault_address)) > 0))
    );
    INSERT INTO source_versions__v82 (id, logical_source_id, document_id, content_hash, supersedes,
                                      valid_from, valid_to, is_current, original_url, created_at,
                                      filename, declared_extension, detected_type, mime_type, detection_basis,
                                      size_bytes, modified_at, custody_mode, preservation_status, vault_address, intake_recorded_at)
        SELECT sv.id, sv.logical_source_id, sv.document_id, lower(sv.content_hash), sv.supersedes,
               sv.valid_from, sv.valid_to, sv.is_current, sv.original_url, sv.created_at,
               COALESCE(NULLIF(sd.filename, ''),
                        NULLIF(replace(f.url, rtrim(f.url, replace(f.url, '/', '')), ''), ''),
                        'legacy-source-' || substr(sv.id, 1, 8)),
               '',
               COALESCE(NULLIF(sd.detected_type, ''), NULLIF(f.source_type, ''), 'unknown'),
               sd.mime_type,
               'unknown',
               COALESCE(dp.size_bytes, f.size_bytes, 0),
               f.modified_at,
               'referenced',
               'legacyImported',
               NULL,
               sv.created_at
          FROM source_versions sv
          LEFT JOIN source_documents sd ON sd.id = sv.document_id
          LEFT JOIN files f ON f.id = sv.logical_source_id
          LEFT JOIN document_profiles dp ON dp.source_version_id = sv.id;
    DROP TABLE source_versions;
    ALTER TABLE source_versions__v82 RENAME TO source_versions;
    CREATE INDEX idx_source_versions_logical ON source_versions(logical_source_id);
    CREATE INDEX idx_source_versions_current ON source_versions(logical_source_id, is_current);
    CREATE INDEX idx_source_versions_hash ON source_versions(content_hash);
    -- Exactly one current version per logical source.
    CREATE UNIQUE INDEX idx_source_versions_one_current ON source_versions(logical_source_id) WHERE is_current = 1;

    -- Append-only intake audit ledger. NOT a second source authority.
    CREATE TABLE source_intake_receipts (
        id                   TEXT PRIMARY KEY NOT NULL,
        occurrence_file_id   TEXT NOT NULL,
        logical_source_id    TEXT NOT NULL,
        source_version_id    TEXT NOT NULL,
        outcome              TEXT NOT NULL,
        original_url         TEXT,
        content_hash         TEXT NOT NULL,
        custody_mode         TEXT NOT NULL,
        preservation_status  TEXT NOT NULL,
        detail               TEXT,
        recorded_at          REAL NOT NULL,
        FOREIGN KEY(occurrence_file_id) REFERENCES files(id) ON DELETE CASCADE,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(outcome IN ('newLogicalSource','newVersion','unchanged','moved','aliased')),
        CHECK(custody_mode IN ('referenced','managed')),
        CHECK(preservation_status IN ('referenceRecorded','managedCopyStored','managedCopyFailed','legacyImported')),
        CHECK(content_hash = lower(content_hash) AND length(content_hash) = 64)
    );
    CREATE INDEX idx_source_intake_receipts_version ON source_intake_receipts(source_version_id);
    CREATE INDEX idx_source_intake_receipts_logical ON source_intake_receipts(logical_source_id, recorded_at);

    -- Exact version-level parent/child provenance (survives child parser failure).
    CREATE TABLE source_version_relations (
        id                        TEXT PRIMARY KEY NOT NULL,
        parent_source_version_id  TEXT NOT NULL,
        child_source_version_id   TEXT NOT NULL,
        relation                  TEXT NOT NULL,
        ordinal                   INTEGER,
        created_at                REAL NOT NULL,
        FOREIGN KEY(parent_source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        FOREIGN KEY(child_source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(parent_source_version_id <> child_source_version_id),
        CHECK(relation IN ('attachment','archiveMember','message','embedded','derivedConversion')),
        CHECK(ordinal IS NULL OR ordinal >= 0)
    );
    CREATE UNIQUE INDEX idx_source_version_relations_unique
        ON source_version_relations(parent_source_version_id, child_source_version_id, relation);
    CREATE INDEX idx_source_version_relations_child ON source_version_relations(child_source_version_id);

    -- Every processing attempt is tied to the exact source version once intake succeeds.
    ALTER TABLE ingest_file_attempts ADD COLUMN logical_source_id TEXT;
    ALTER TABLE ingest_file_attempts ADD COLUMN source_version_id TEXT;
    CREATE INDEX idx_ingest_attempts_logical ON ingest_file_attempts(logical_source_id);
    CREATE INDEX idx_ingest_attempts_version ON ingest_file_attempts(source_version_id);
    """

    // MARK: - v83 — single-path intake & custody-ledger integrity (USF-001.1)

    private static let v83: String = """
    -- USF-001.1 makes intake the SOLE pre-parser identity authority and hardens the ledger
    -- so the custody contract is enforced by the database, not just by code. Rebuilds three
    -- tables (a CHECK / composite-FK cannot be altered in place). NO new column. migrate()
    -- disables FK enforcement for the whole pass + runs foreign_key_check afterward.

    -- (1) source_versions: a NON-legacy custody version must carry a normalized 64-char
    --     lowercase SHA-256; `supersedes` must reference a version of the SAME logical
    --     source (composite self-FK); UNIQUE(id, logical_source_id) + UNIQUE(id, content_hash)
    --     back the composite FKs from receipts + attempts. Legacy-imported rows are exempt
    --     from the SHA rule (and any pre-existing non-SHA custody row is demoted to legacy).
    CREATE TABLE source_versions__v83 (
        id                   TEXT PRIMARY KEY NOT NULL,
        logical_source_id    TEXT NOT NULL,
        document_id          TEXT,
        content_hash         TEXT NOT NULL,
        supersedes           TEXT,
        valid_from           REAL NOT NULL,
        valid_to             REAL,
        is_current           INTEGER NOT NULL DEFAULT 1,
        original_url         TEXT,
        created_at           REAL NOT NULL,
        filename             TEXT NOT NULL DEFAULT 'legacy-source',
        declared_extension   TEXT NOT NULL DEFAULT '',
        detected_type        TEXT NOT NULL DEFAULT 'unknown',
        mime_type            TEXT,
        detection_basis      TEXT NOT NULL DEFAULT 'unknown',
        size_bytes           INTEGER NOT NULL DEFAULT 0,
        modified_at          REAL,
        custody_mode         TEXT NOT NULL DEFAULT 'referenced',
        preservation_status  TEXT NOT NULL DEFAULT 'legacyImported',
        vault_address        TEXT,
        intake_recorded_at   REAL NOT NULL DEFAULT 0,
        FOREIGN KEY(supersedes, logical_source_id) REFERENCES source_versions(id, logical_source_id),
        CHECK(length(trim(filename)) > 0),
        CHECK(length(trim(detected_type)) > 0),
        CHECK(detection_basis IN ('pathPattern','declaredExtension','magicBytes','unknown')),
        CHECK(size_bytes >= 0),
        CHECK(custody_mode IN ('referenced','managed')),
        CHECK(preservation_status IN ('referenceRecorded','managedCopyStored','managedCopyFailed','legacyImported')),
        CHECK(is_current IN (0,1)),
        CHECK(supersedes IS NULL OR supersedes <> id),
        CHECK(preservation_status <> 'managedCopyStored'
              OR (custody_mode = 'managed' AND vault_address IS NOT NULL AND length(trim(vault_address)) > 0)),
        -- A newly-admitted custody version must carry a normalized SHA-256; legacy is exempt.
        CHECK(preservation_status = 'legacyImported'
              OR (content_hash = lower(content_hash) AND length(content_hash) = 64))
    );
    INSERT INTO source_versions__v83 (id, logical_source_id, document_id, content_hash, supersedes,
                                      valid_from, valid_to, is_current, original_url, created_at,
                                      filename, declared_extension, detected_type, mime_type, detection_basis,
                                      size_bytes, modified_at, custody_mode, preservation_status, vault_address, intake_recorded_at)
        SELECT id, logical_source_id, document_id, content_hash, supersedes,
               valid_from, valid_to, is_current, original_url, created_at,
               filename, declared_extension, detected_type, mime_type, detection_basis,
               size_bytes, modified_at, custody_mode,
               CASE WHEN preservation_status <> 'legacyImported'
                         AND (content_hash <> lower(content_hash) OR length(content_hash) <> 64)
                    THEN 'legacyImported' ELSE preservation_status END,
               vault_address, intake_recorded_at
          FROM source_versions;
    DROP TABLE source_versions;
    ALTER TABLE source_versions__v83 RENAME TO source_versions;
    CREATE INDEX idx_source_versions_logical ON source_versions(logical_source_id);
    CREATE INDEX idx_source_versions_current ON source_versions(logical_source_id, is_current);
    CREATE INDEX idx_source_versions_hash ON source_versions(content_hash);
    CREATE UNIQUE INDEX idx_source_versions_one_current ON source_versions(logical_source_id) WHERE is_current = 1;
    CREATE UNIQUE INDEX idx_source_versions_id_logical ON source_versions(id, logical_source_id);
    CREATE UNIQUE INDEX idx_source_versions_id_hash ON source_versions(id, content_hash);

    -- (2) source_intake_receipts: composite FKs pin the receipt to the EXACT source version
    --     (same logical source AND same content hash) — a receipt can never name a hash that
    --     differs from its version.
    CREATE TABLE source_intake_receipts__v83 (
        id                   TEXT PRIMARY KEY NOT NULL,
        occurrence_file_id   TEXT NOT NULL,
        logical_source_id    TEXT NOT NULL,
        source_version_id    TEXT NOT NULL,
        outcome              TEXT NOT NULL,
        original_url         TEXT,
        content_hash         TEXT NOT NULL,
        custody_mode         TEXT NOT NULL,
        preservation_status  TEXT NOT NULL,
        detail               TEXT,
        recorded_at          REAL NOT NULL,
        FOREIGN KEY(occurrence_file_id) REFERENCES files(id) ON DELETE CASCADE,
        FOREIGN KEY(source_version_id, logical_source_id) REFERENCES source_versions(id, logical_source_id) ON DELETE CASCADE,
        FOREIGN KEY(source_version_id, content_hash) REFERENCES source_versions(id, content_hash) ON DELETE CASCADE,
        CHECK(outcome IN ('newLogicalSource','newVersion','unchanged','moved','aliased')),
        CHECK(custody_mode IN ('referenced','managed')),
        CHECK(preservation_status IN ('referenceRecorded','managedCopyStored','managedCopyFailed','legacyImported'))
    );
    INSERT INTO source_intake_receipts__v83
        SELECT id, occurrence_file_id, logical_source_id, source_version_id, outcome, original_url,
               content_hash, custody_mode, preservation_status, detail, recorded_at
          FROM source_intake_receipts;
    DROP TABLE source_intake_receipts;
    ALTER TABLE source_intake_receipts__v83 RENAME TO source_intake_receipts;
    CREATE INDEX idx_source_intake_receipts_version ON source_intake_receipts(source_version_id);
    CREATE INDEX idx_source_intake_receipts_logical ON source_intake_receipts(logical_source_id, recorded_at);

    -- (3) ingest_file_attempts: the version + logical-source ids are BOTH null (pre-intake) or
    --     BOTH present (post-intake, tied to the exact source version via a composite FK).
    CREATE TABLE ingest_file_attempts__v83 (
        id                 TEXT PRIMARY KEY NOT NULL,
        url                TEXT NOT NULL,
        content_hash       TEXT,
        status             TEXT NOT NULL,
        stage              TEXT,
        detail             TEXT,
        attempted_at       REAL NOT NULL,
        logical_source_id  TEXT,
        source_version_id  TEXT,
        FOREIGN KEY(source_version_id, logical_source_id) REFERENCES source_versions(id, logical_source_id),
        CHECK((logical_source_id IS NULL) = (source_version_id IS NULL))
    );
    INSERT INTO ingest_file_attempts__v83
        SELECT id, url, content_hash, status, stage, detail, attempted_at, logical_source_id, source_version_id
          FROM ingest_file_attempts;
    DROP TABLE ingest_file_attempts;
    ALTER TABLE ingest_file_attempts__v83 RENAME TO ingest_file_attempts;
    CREATE INDEX idx_ingest_attempts_url ON ingest_file_attempts(url, attempted_at);
    CREATE INDEX idx_ingest_attempts_status ON ingest_file_attempts(status);
    CREATE INDEX idx_ingest_attempts_logical ON ingest_file_attempts(logical_source_id);
    CREATE INDEX idx_ingest_attempts_version ON ingest_file_attempts(source_version_id);
    """

    // MARK: - v84 — USF-001.2 exact-byte binding: hexadecimal SHA-256 enforcement

    private static let v84: String = """
    -- USF-001.2 closes the last content-hash gap: v83 accepted ANY 64-char lowercase string
    -- as a non-legacy custody hash (e.g. a 64-char run of 'z'), so a hash that was never a
    -- real SHA-256 could satisfy the CHECK. A genuine SHA-256 hex digest is 64 characters
    -- drawn ONLY from [0-9a-f]. This rebuild adds `content_hash NOT GLOB '*[^0-9a-f]*'` to the
    -- non-legacy branch so every custody hash is provably hexadecimal, and demotes any existing
    -- non-hex custody row to legacyImported (the same repair v83 used for non-SHA rows). NO new
    -- column — CHECK-only, so the self-heal sentinel confirms it via a CHECK-text probe.
    -- migrate() disables FK enforcement for the whole pass + runs foreign_key_check afterward.
    CREATE TABLE source_versions__v84 (
        id                   TEXT PRIMARY KEY NOT NULL,
        logical_source_id    TEXT NOT NULL,
        document_id          TEXT,
        content_hash         TEXT NOT NULL,
        supersedes           TEXT,
        valid_from           REAL NOT NULL,
        valid_to             REAL,
        is_current           INTEGER NOT NULL DEFAULT 1,
        original_url         TEXT,
        created_at           REAL NOT NULL,
        filename             TEXT NOT NULL DEFAULT 'legacy-source',
        declared_extension   TEXT NOT NULL DEFAULT '',
        detected_type        TEXT NOT NULL DEFAULT 'unknown',
        mime_type            TEXT,
        detection_basis      TEXT NOT NULL DEFAULT 'unknown',
        size_bytes           INTEGER NOT NULL DEFAULT 0,
        modified_at          REAL,
        custody_mode         TEXT NOT NULL DEFAULT 'referenced',
        preservation_status  TEXT NOT NULL DEFAULT 'legacyImported',
        vault_address        TEXT,
        intake_recorded_at   REAL NOT NULL DEFAULT 0,
        FOREIGN KEY(supersedes, logical_source_id) REFERENCES source_versions(id, logical_source_id),
        CHECK(length(trim(filename)) > 0),
        CHECK(length(trim(detected_type)) > 0),
        CHECK(detection_basis IN ('pathPattern','declaredExtension','magicBytes','unknown')),
        CHECK(size_bytes >= 0),
        CHECK(custody_mode IN ('referenced','managed')),
        CHECK(preservation_status IN ('referenceRecorded','managedCopyStored','managedCopyFailed','legacyImported')),
        CHECK(is_current IN (0,1)),
        CHECK(supersedes IS NULL OR supersedes <> id),
        CHECK(preservation_status <> 'managedCopyStored'
              OR (custody_mode = 'managed' AND vault_address IS NOT NULL AND length(trim(vault_address)) > 0)),
        -- A newly-admitted custody version must carry a normalized HEXADECIMAL SHA-256:
        -- lowercase, exactly 64 characters, every character in [0-9a-f]. Legacy is exempt.
        CHECK(preservation_status = 'legacyImported'
              OR (content_hash = lower(content_hash)
                  AND length(content_hash) = 64
                  AND content_hash NOT GLOB '*[^0-9a-f]*'))
    );
    INSERT INTO source_versions__v84 (id, logical_source_id, document_id, content_hash, supersedes,
                                      valid_from, valid_to, is_current, original_url, created_at,
                                      filename, declared_extension, detected_type, mime_type, detection_basis,
                                      size_bytes, modified_at, custody_mode, preservation_status, vault_address, intake_recorded_at)
        SELECT id, logical_source_id, document_id, content_hash, supersedes,
               valid_from, valid_to, is_current, original_url, created_at,
               filename, declared_extension, detected_type, mime_type, detection_basis,
               size_bytes, modified_at, custody_mode,
               CASE WHEN preservation_status <> 'legacyImported'
                         AND (content_hash <> lower(content_hash)
                              OR length(content_hash) <> 64
                              OR content_hash GLOB '*[^0-9a-f]*')
                    THEN 'legacyImported' ELSE preservation_status END,
               vault_address, intake_recorded_at
          FROM source_versions;
    DROP TABLE source_versions;
    ALTER TABLE source_versions__v84 RENAME TO source_versions;
    CREATE INDEX idx_source_versions_logical ON source_versions(logical_source_id);
    CREATE INDEX idx_source_versions_current ON source_versions(logical_source_id, is_current);
    CREATE INDEX idx_source_versions_hash ON source_versions(content_hash);
    CREATE UNIQUE INDEX idx_source_versions_one_current ON source_versions(logical_source_id) WHERE is_current = 1;
    CREATE UNIQUE INDEX idx_source_versions_id_logical ON source_versions(id, logical_source_id);
    CREATE UNIQUE INDEX idx_source_versions_id_hash ON source_versions(id, content_hash);
    """

    // MARK: - v85 — USF-002 independent source readiness dimensions

    private static let v85: String = """
    -- USF-002 persists the readiness of every EXACT source version across independent
    -- dimensions — Preserved ≠ Searchable ≠ Evidence-ready ≠ Analytically ready. One aggregate
    -- and exactly ten dimension rows per source version; an append-only event ledger records
    -- every transition. Readiness belongs to the source VERSION (a changed file gets a fresh
    -- aggregate); it is NOT a second source authority and never confirms a Claim. The overall
    -- completion state is DERIVED (SourceReadinessEvaluator), never stored or caller-declared.

    -- (1) Aggregate: one row per source version. revision + event_sequence back the optimistic
    --     CAS and the contiguous event ledger. NO completion-state column (it is derived).
    CREATE TABLE source_readiness_aggregates (
        source_version_id  TEXT PRIMARY KEY NOT NULL,
        revision           INTEGER NOT NULL DEFAULT 1,
        event_sequence     INTEGER NOT NULL DEFAULT 0,
        created_at         REAL NOT NULL,
        updated_at         REAL NOT NULL,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(revision >= 1),
        CHECK(event_sequence >= 0)
    );

    -- (2) Dimensions: exactly ten closed rows per source version. Applicability lets a native
    --     text document report transcription as notApplicable (ready) without calling it failed.
    CREATE TABLE source_readiness_dimensions (
        source_version_id  TEXT NOT NULL,
        dimension          TEXT NOT NULL,
        state              TEXT NOT NULL,
        applicability      TEXT NOT NULL,
        condition          TEXT,
        completed_units    INTEGER,
        total_units        INTEGER,
        producer_id        TEXT NOT NULL,
        producer_version   TEXT NOT NULL,
        basis_kind         TEXT,
        basis_identifier   TEXT,
        detail             TEXT,
        revision           INTEGER NOT NULL DEFAULT 1,
        updated_at         REAL NOT NULL,
        PRIMARY KEY(source_version_id, dimension),
        FOREIGN KEY(source_version_id) REFERENCES source_readiness_aggregates(source_version_id) ON DELETE CASCADE,
        CHECK(dimension IN ('preservation','metadataExtraction','textExtraction','structuralExtraction',
                            'ocr','transcription','indexing','basicQuestionAnswering','typedFieldExtraction','analyticalReadiness')),
        CHECK(state IN ('notStarted','running','ready','partial','blocked','unsupported','failed')),
        CHECK(applicability IN ('required','conditional','notApplicable')),
        CHECK(condition IS NULL OR condition IN ('deferred','encrypted','corrupt','sourceUnavailable',
                            'missingDependency','awaitingUserAction','policy','resourceLimit')),
        -- blocked ⇔ a blocking condition is present; no other state may carry one.
        CHECK((state = 'blocked') = (condition IS NOT NULL)),
        CHECK(length(trim(producer_id)) > 0),
        CHECK(length(trim(producer_version)) > 0),
        CHECK(basis_kind IS NULL OR basis_kind IN ('sourceVersion','sourceDocument','documentProfile',
                            'evidenceBlock','parserRun','ftsIndex','vectorIndex','custody')),
        -- unit counts are both null or both non-negative, completed never exceeds total.
        CHECK((completed_units IS NULL) = (total_units IS NULL)),
        CHECK(completed_units IS NULL OR (completed_units >= 0 AND total_units >= 0)),
        CHECK(completed_units IS NULL OR completed_units <= total_units),
        -- a ready row with a positive total must have completed every unit.
        CHECK(state <> 'ready' OR total_units IS NULL OR total_units = 0 OR completed_units = total_units),
        -- notApplicable is expressed as ready, no condition, no units.
        CHECK(applicability <> 'notApplicable'
              OR (state = 'ready' AND condition IS NULL AND completed_units IS NULL AND total_units IS NULL)),
        -- an unsupported dimension is a real limitation, never "not applicable".
        CHECK(state <> 'unsupported' OR applicability <> 'notApplicable'),
        CHECK(revision >= 1)
    );
    CREATE INDEX idx_readiness_dim_state ON source_readiness_dimensions(dimension, state);

    -- (3) Append-only event ledger. One event per changed dimension; contiguous per source.
    CREATE TABLE source_readiness_events (
        id                 TEXT PRIMARY KEY NOT NULL,
        source_version_id  TEXT NOT NULL,
        sequence           INTEGER NOT NULL,
        aggregate_revision INTEGER NOT NULL,
        dimension          TEXT NOT NULL,
        action             TEXT NOT NULL,
        from_state         TEXT,
        to_state           TEXT NOT NULL,
        applicability      TEXT NOT NULL,
        condition          TEXT,
        completed_units    INTEGER,
        total_units        INTEGER,
        producer_id        TEXT NOT NULL,
        producer_version   TEXT NOT NULL,
        basis_kind         TEXT,
        basis_identifier   TEXT,
        detail             TEXT,
        occurred_at        REAL NOT NULL,
        FOREIGN KEY(source_version_id) REFERENCES source_readiness_aggregates(source_version_id) ON DELETE CASCADE,
        CHECK(action IN ('initialize','begin','satisfy','partiallySatisfy','block','markUnsupported','fail','invalidate','reconcile')),
        CHECK(sequence >= 0),
        CHECK(aggregate_revision >= 1),
        UNIQUE(source_version_id, sequence),
        UNIQUE(source_version_id, aggregate_revision, dimension)
    );
    CREATE INDEX idx_readiness_events_seq ON source_readiness_events(source_version_id, sequence);

    -- ------------------------------------------------------------------------------------
    -- Conservative backfill: every existing source version receives one aggregate + ten
    -- dimension rows derived from CANONICAL evidence (never optimistic). Dimensions that
    -- cannot be proved from the ledger (indexing, basic QA, typed fields, analysis) start at
    -- notStarted; forward processing raises them through the repository.
    -- ------------------------------------------------------------------------------------
    INSERT INTO source_readiness_aggregates (source_version_id, revision, event_sequence, created_at, updated_at)
        SELECT id, 1, 10, CAST(strftime('%s','now') AS REAL), CAST(strftime('%s','now') AS REAL) FROM source_versions;

    INSERT INTO source_readiness_dimensions
        (source_version_id, dimension, state, applicability, condition, completed_units, total_units,
         producer_id, producer_version, basis_kind, basis_identifier, detail, revision, updated_at)
    SELECT x.source_version_id, x.dimension, x.state, x.applicability, x.condition, x.completed_units, x.total_units,
           'usf-002.backfill', '1', 'sourceVersion', x.source_version_id, NULL, 1, CAST(strftime('%s','now') AS REAL)
    FROM (
        -- preservation
        SELECT sv.id AS source_version_id, 'preservation' AS dimension,
               CASE WHEN sv.preservation_status IN ('referenceRecorded','managedCopyStored') THEN 'ready' ELSE 'partial' END AS state,
               'required' AS applicability, NULL AS condition, NULL AS completed_units, NULL AS total_units
          FROM source_versions sv
        UNION ALL
        -- metadataExtraction
        SELECT sv.id, 'metadataExtraction',
               CASE WHEN sv.document_id IS NOT NULL THEN 'ready' ELSE 'partial' END,
               'required', NULL, NULL, NULL FROM source_versions sv
        UNION ALL
        -- textExtraction
        SELECT sv.id, 'textExtraction',
               CASE
                 WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'blocked'
                 WHEN sd.extraction_status = 'complete' THEN 'ready'
                 WHEN sd.extraction_status = 'partial' THEN 'partial'
                 WHEN sd.extraction_status = 'empty' THEN 'ready'
                 WHEN sd.extraction_status = 'unsupported' THEN 'unsupported'
                 WHEN sd.extraction_status IN ('encrypted','corrupt','deferred') THEN 'blocked'
                 WHEN sd.extraction_status = 'failed' THEN 'failed'
                 ELSE 'notStarted' END,
               'required',
               CASE
                 WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'deferred'
                 WHEN sd.extraction_status IN ('encrypted','corrupt','deferred') THEN sd.extraction_status
                 ELSE NULL END,
               CASE WHEN sd.extraction_status = 'empty' THEN 0 ELSE NULL END,
               CASE WHEN sd.extraction_status = 'empty' THEN 0 ELSE NULL END
          FROM source_versions sv LEFT JOIN source_documents sd ON sd.id = sv.document_id
        UNION ALL
        -- structuralExtraction
        SELECT sv.id, 'structuralExtraction',
               CASE
                 WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'blocked'
                 WHEN sd.extraction_status = 'complete' AND (SELECT COUNT(*) FROM evidence_blocks eb WHERE eb.source_version_id = sv.id) > 0 THEN 'ready'
                 WHEN sd.extraction_status = 'complete' THEN 'partial'
                 WHEN sd.extraction_status = 'partial' THEN 'partial'
                 WHEN sd.extraction_status = 'unsupported' THEN 'unsupported'
                 WHEN sd.extraction_status IN ('encrypted','corrupt','deferred') THEN 'blocked'
                 WHEN sd.extraction_status = 'failed' THEN 'failed'
                 ELSE 'notStarted' END,
               'required',
               CASE
                 WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'deferred'
                 WHEN sd.extraction_status IN ('encrypted','corrupt','deferred') THEN sd.extraction_status
                 ELSE NULL END,
               NULL, NULL
          FROM source_versions sv LEFT JOIN source_documents sd ON sd.id = sv.document_id
        UNION ALL
        -- ocr (conditional for image/pdf, notApplicable otherwise)
        SELECT sv.id, 'ocr',
               CASE WHEN sv.detected_type IN ('png','jpg','heic','tiff','webp','pdf') THEN 'notStarted' ELSE 'ready' END,
               CASE WHEN sv.detected_type IN ('png','jpg','heic','tiff','webp','pdf') THEN 'conditional' ELSE 'notApplicable' END,
               NULL, NULL, NULL FROM source_versions sv
        UNION ALL
        -- transcription (required for media, notApplicable otherwise)
        SELECT sv.id, 'transcription',
               CASE WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'blocked' ELSE 'ready' END,
               CASE WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'required' ELSE 'notApplicable' END,
               CASE WHEN sv.detected_type IN ('mp3','wav','m4a','aac','aiff','caf','flac','threegp','mp4','mov') THEN 'deferred' ELSE NULL END,
               NULL, NULL FROM source_versions sv
        UNION ALL
        SELECT sv.id, 'indexing', 'notStarted', 'required', NULL, NULL, NULL FROM source_versions sv
        UNION ALL
        SELECT sv.id, 'basicQuestionAnswering', 'notStarted', 'required', NULL, NULL, NULL FROM source_versions sv
        UNION ALL
        SELECT sv.id, 'typedFieldExtraction', 'notStarted', 'conditional', NULL, NULL, NULL FROM source_versions sv
        UNION ALL
        SELECT sv.id, 'analyticalReadiness', 'notStarted', 'required', NULL, NULL, NULL FROM source_versions sv
    ) AS x;

    -- One initialize event per backfilled dimension (sequence = the dimension's fixed ordinal).
    INSERT INTO source_readiness_events
        (id, source_version_id, sequence, aggregate_revision, dimension, action, from_state, to_state,
         applicability, condition, completed_units, total_units, producer_id, producer_version,
         basis_kind, basis_identifier, detail, occurred_at)
    SELECT lower(hex(randomblob(16))), d.source_version_id,
           CASE d.dimension
               WHEN 'preservation' THEN 0 WHEN 'metadataExtraction' THEN 1 WHEN 'textExtraction' THEN 2
               WHEN 'structuralExtraction' THEN 3 WHEN 'ocr' THEN 4 WHEN 'transcription' THEN 5
               WHEN 'indexing' THEN 6 WHEN 'basicQuestionAnswering' THEN 7 WHEN 'typedFieldExtraction' THEN 8
               WHEN 'analyticalReadiness' THEN 9 END,
           1, d.dimension, 'initialize', NULL, d.state, d.applicability, d.condition,
           d.completed_units, d.total_units, d.producer_id, d.producer_version,
           d.basis_kind, d.basis_identifier, NULL, d.updated_at
      FROM source_readiness_dimensions d;
    """

    // MARK: - v86 — USF-002.1 exact-version chunk ownership (indexing readiness proof)

    private static let v86: String = """
    -- USF-002.1 lets indexing readiness be RECONSTRUCTED from persisted rows rather than asserted
    -- by the pipeline: each chunk records the EXACT source version it belongs to, so a parent
    -- source version's FTS coverage can never be inflated by a child attachment's chunks. This is a
    -- retrieval PROJECTION field, not a second source authority (source_versions stays the one
    -- version authority). A soft reference (column + index, no hard FK): SQLite cannot ALTER-ADD a
    -- foreign key, and rebuilding `chunks` would invalidate the external chunks_fts rowid mapping —
    -- disproportionate for a projection column. Provability comes from the exact-ownership backfill
    -- below and the ftsCoverage query, not from FK enforcement.
    ALTER TABLE chunks ADD COLUMN source_version_id TEXT;
    CREATE INDEX IF NOT EXISTS idx_chunks_source_version ON chunks(source_version_id);

    -- Backfill ONLY where exact ownership is provable: chunk → its EvidenceBlock → that block's
    -- source_version_id. Legacy/fallback chunks (no evidence_block_id, or a block whose version is
    -- itself null) stay NULL rather than guessing. New production chunks carry the id at insert.
    UPDATE chunks SET source_version_id = (
        SELECT eb.source_version_id FROM evidence_blocks eb WHERE eb.id = chunks.evidence_block_id
    )
    WHERE evidence_block_id IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM evidence_blocks eb WHERE eb.id = chunks.evidence_block_id AND eb.source_version_id IS NOT NULL
      );
    """

    // MARK: - v87 — USF-M2 container coverage projection (container_manifests + container_members)

    private static let v87: String = """
    -- USF-M2 (USF-006 + USF-007) — two PROCESSING-PROJECTION tables that record, for a container
    -- SourceVersion (zip/rar/7z), exactly what the archive claims to contain and how each member was
    -- disposed. They are NOT source/evidence authorities: source_versions stays the one version
    -- authority, source_version_relations stays the parent→child provenance authority, and
    -- source_readiness_* stays the readiness authority. A discovered container member is NOT a source;
    -- only an ADMITTED member becomes a canonical child SourceVersion. Blocked / encrypted /
    -- unsupported / failed members remain VISIBLE here rather than silently dropped.

    -- One current inspection manifest per exact container SourceVersion.
    CREATE TABLE container_manifests (
        source_version_id            TEXT PRIMARY KEY NOT NULL,
        revision                     INTEGER NOT NULL,
        container_type               TEXT NOT NULL,
        inspector_id                 TEXT NOT NULL,
        inspector_version            TEXT NOT NULL,
        policy_version               TEXT NOT NULL,
        status                       TEXT NOT NULL,
        total_entries                INTEGER NOT NULL,
        regular_file_entries         INTEGER NOT NULL,
        admitted_members             INTEGER NOT NULL,
        blocked_members              INTEGER NOT NULL,
        unsupported_members          INTEGER NOT NULL,
        failed_members               INTEGER NOT NULL,
        declared_uncompressed_bytes  INTEGER NOT NULL,
        created_at                   REAL NOT NULL,
        updated_at                   REAL NOT NULL,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(revision >= 1),
        CHECK(length(trim(inspector_id)) > 0),
        CHECK(length(trim(inspector_version)) > 0),
        CHECK(length(trim(policy_version)) > 0),
        CHECK(status IN ('complete','partial','blocked','unsupported','failed')),
        CHECK(total_entries >= 0),
        CHECK(regular_file_entries >= 0),
        CHECK(admitted_members >= 0),
        CHECK(blocked_members >= 0),
        CHECK(unsupported_members >= 0),
        CHECK(failed_members >= 0),
        CHECK(declared_uncompressed_bytes >= 0),
        -- disposition counts can never exceed the number of regular (non-directory) file entries.
        CHECK(admitted_members + blocked_members + unsupported_members + failed_members <= regular_file_entries)
    );
    CREATE INDEX idx_container_manifests_status ON container_manifests(status);

    -- Every significant member disposition, including members that never became sources. Ordinal is
    -- the stable disambiguator (ZIP entries can share duplicate path names, so member_path is NOT
    -- unique). An ADMITTED member must carry BOTH a child SourceVersion and its content hash, pinned
    -- to the exact source_versions(id, content_hash) authority; a NON-admitted member must never
    -- fabricate a child SourceVersion.
    CREATE TABLE container_members (
        id                        TEXT PRIMARY KEY NOT NULL,
        parent_source_version_id  TEXT NOT NULL,
        ordinal                   INTEGER NOT NULL,
        member_path               TEXT NOT NULL,
        normalized_member_path    TEXT NOT NULL,
        entry_kind                TEXT NOT NULL,
        compressed_size           INTEGER NOT NULL DEFAULT 0,
        uncompressed_size         INTEGER NOT NULL DEFAULT 0,
        detected_type             TEXT,
        disposition               TEXT NOT NULL,
        child_source_version_id   TEXT,
        content_hash              TEXT,
        detail                    TEXT,
        created_at                REAL NOT NULL,
        updated_at                REAL NOT NULL,
        FOREIGN KEY(parent_source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        -- Composite pin to the exact (id, content_hash) version authority. Default RESTRICT: an
        -- admitted child version cannot be deleted while its coverage row references it (nulling the
        -- pair would violate the admitted CHECK). Deleting the PARENT container cascades members away.
        FOREIGN KEY(child_source_version_id, content_hash) REFERENCES source_versions(id, content_hash),
        UNIQUE(parent_source_version_id, ordinal),
        CHECK(ordinal >= 0),
        CHECK(entry_kind IN ('file','directory')),
        CHECK(compressed_size >= 0),
        CHECK(uncompressed_size >= 0),
        CHECK(disposition IN ('admitted','directory','blockedUnsafePath','blockedDepth',
              'blockedEntryLimit','blockedSizeLimit','blockedCompressionRatio','blockedRootBudget',
              'blockedCycle','encrypted','unsupported','failedExtraction')),
        -- Admitted ⇒ child + hash present; non-admitted ⇒ never a fabricated child.
        CHECK((disposition = 'admitted' AND child_source_version_id IS NOT NULL AND content_hash IS NOT NULL)
           OR (disposition <> 'admitted' AND child_source_version_id IS NULL))
    );
    CREATE INDEX idx_container_members_parent ON container_members(parent_source_version_id);
    CREATE INDEX idx_container_members_child ON container_members(child_source_version_id);
    """

    // MARK: - v88 — USF-M3 progressive upgrade ledger (exact-source-version background work)

    private static let v88: String = """
    -- USF-M3 (USF-009) EVOLVES the existing enrichment_jobs ledger into an exact-SourceVersion
    -- progressive-upgrade queue rather than adding a competing background-work system. The table is
    -- rebuilt (SQLite cannot ALTER a UNIQUE constraint / add many columns at once): legacy rows are
    -- preserved verbatim as scope_kind='legacySubject' with source_version_id NULL (we NEVER guess an
    -- exact version for an old ambiguous subject_id); their states/attempts/errors/timestamps carry
    -- over. New USF-M3 production jobs are scope_kind='sourceVersion' with a non-null source_version_id.
    -- A job describes WORK; it never asserts readiness (source_readiness_* stays the authority).
    -- FK-safe with enforcement ON: nothing references the old enrichment_jobs, and legacy rows carry a
    -- NULL source_version_id so the new FK to source_versions is never triggered.
    CREATE TABLE enrichment_jobs__v88 (
        id                 TEXT PRIMARY KEY NOT NULL,
        scope_kind         TEXT NOT NULL DEFAULT 'legacySubject',
        subject_id         TEXT,
        source_version_id  TEXT,
        kind               TEXT NOT NULL,
        target_dimension   TEXT,
        requested_goal     TEXT,
        priority           INTEGER NOT NULL DEFAULT 40,
        origin             TEXT NOT NULL DEFAULT 'legacy',
        state              TEXT NOT NULL DEFAULT 'pending',
        attempts           INTEGER NOT NULL DEFAULT 0,
        max_attempts       INTEGER NOT NULL DEFAULT 3,
        last_error         TEXT,
        producer_id        TEXT NOT NULL DEFAULT 'legacy',
        producer_version   TEXT NOT NULL DEFAULT '1',
        not_before         REAL NOT NULL DEFAULT 0,
        lease_token        TEXT,
        lease_expires_at   REAL,
        created_at         REAL NOT NULL,
        updated_at         REAL NOT NULL,
        completed_at       REAL,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(scope_kind IN ('legacySubject','sourceVersion')),
        CHECK(state IN ('pending','running','done','failed','blocked','cancelled','superseded')),
        CHECK(priority >= 0),
        CHECK(attempts >= 0),
        CHECK(max_attempts >= 1),
        -- Scope integrity: a sourceVersion job MUST carry an exact source_version_id; a legacySubject
        -- job MUST carry a subject_id.
        CHECK((scope_kind = 'sourceVersion' AND source_version_id IS NOT NULL)
           OR (scope_kind = 'legacySubject' AND subject_id IS NOT NULL)),
        -- A running sourceVersion job MUST hold a lease token + expiry. The lease mechanic is a property
        -- of the exact-version upgrade queue ONLY; legacy subject jobs never leased, so preserving their
        -- claim-sets-running-without-a-lease contract is required (they carry NULL lease columns).
        CHECK(scope_kind <> 'sourceVersion' OR state <> 'running'
              OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL))
    );

    -- Preserve legacy jobs exactly (unknown states collapse to pending; NEVER invent a source version).
    INSERT INTO enrichment_jobs__v88
        (id, scope_kind, subject_id, source_version_id, kind, priority, origin, state, attempts,
         max_attempts, last_error, producer_id, producer_version, not_before, created_at, updated_at)
    SELECT id, 'legacySubject', subject_id, NULL, kind, 40, 'legacy',
           CASE state WHEN 'pending' THEN 'pending' WHEN 'running' THEN 'running'
                      WHEN 'done' THEN 'done' WHEN 'failed' THEN 'failed' ELSE 'pending' END,
           attempts, 3, last_error, 'legacy', '1', 0, created_at, updated_at
      FROM enrichment_jobs;

    DROP TABLE enrichment_jobs;
    ALTER TABLE enrichment_jobs__v88 RENAME TO enrichment_jobs;

    -- Claim ordering: highest priority, earliest eligible, oldest first, stable by id.
    CREATE INDEX idx_enrichment_jobs_claim ON enrichment_jobs(state, priority, not_before, created_at, id);
    CREATE INDEX idx_enrichment_jobs_sv ON enrichment_jobs(source_version_id);
    CREATE INDEX idx_enrichment_jobs_lease ON enrichment_jobs(state, lease_expires_at);
    -- Idempotency: at most ONE active (pending/running) sourceVersion job per exact work identity.
    CREATE UNIQUE INDEX idx_enrichment_jobs_active_sv
        ON enrichment_jobs(source_version_id, kind, producer_id, producer_version)
        WHERE scope_kind = 'sourceVersion' AND state IN ('pending','running');
    -- Preserve the legacy (subject_id, kind) idempotency for legacySubject jobs.
    CREATE UNIQUE INDEX idx_enrichment_jobs_active_subject
        ON enrichment_jobs(subject_id, kind)
        WHERE scope_kind = 'legacySubject';

    -- Append-only operational provenance for each job (NOT evidence).
    CREATE TABLE enrichment_job_events (
        id           TEXT PRIMARY KEY NOT NULL,
        job_id       TEXT NOT NULL,
        sequence     INTEGER NOT NULL,
        action       TEXT NOT NULL,
        from_state   TEXT,
        to_state     TEXT,
        detail       TEXT,
        occurred_at  REAL NOT NULL,
        FOREIGN KEY(job_id) REFERENCES enrichment_jobs(id) ON DELETE CASCADE,
        UNIQUE(job_id, sequence),
        CHECK(sequence >= 1),
        CHECK(action IN ('enqueue','claim','succeed','fail','block','retry','recover','cancel','supersede'))
    );
    CREATE INDEX idx_enrichment_job_events_job ON enrichment_job_events(job_id, sequence);
    """

    // MARK: - v89 — AEE-M2 progressive answer revision ledger + durable final-answer audit

    private static let v89: String = """
    -- AEE-M2 EXTENDS the existing answer-ledger authority (answers / answer_claims /
    -- claim_evidence, created at v28) — it does NOT introduce a second answer store. Two new
    -- tables record the per-answer REVISION chain and its append-only lifecycle events; the
    -- existing answers/answer_claims gain nullable compat/audit columns. Legacy pre-v89 rows
    -- stay valid and are NEVER given fabricated revision history — v89 history begins when a
    -- v89 answer is first written. No backfill.

    -- answers — compat/audit metadata (nullable / defaulted so legacy short-form inserts and
    -- existing rows round-trip unchanged).
    ALTER TABLE answers ADD COLUMN request_id TEXT;
    ALTER TABLE answers ADD COLUMN mission_lane TEXT;
    ALTER TABLE answers ADD COLUMN mission_objective TEXT;
    ALTER TABLE answers ADD COLUMN mission_deliverable TEXT;
    ALTER TABLE answers ADD COLUMN is_terminal INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE answers ADD COLUMN updated_at REAL;

    -- answer_claims — pin every NEW v89 claim to the EXACT revision it belongs to. Legacy
    -- rows stay NULL (their ownership predates the revision chain and is never guessed).
    ALTER TABLE answer_claims ADD COLUMN revision_id TEXT;

    -- answer_revisions — the immutable revision chain for one answer. A revision is never
    -- updated or deleted; a materially different answer is a NEW revision. A correction points
    -- at the exact PRIOR revision it replaces (same answer, enforced by the composite FK) and
    -- carries a nonblank reason; a non-correction carries neither.
    CREATE TABLE answer_revisions (
        id                        TEXT PRIMARY KEY NOT NULL,
        answer_id                 TEXT NOT NULL,
        revision_number           INTEGER NOT NULL,
        body                      TEXT NOT NULL,
        answer_state              TEXT NOT NULL,
        confidence                REAL NOT NULL DEFAULT 0.0,
        source                    TEXT,
        content_hash              TEXT NOT NULL,
        correction_of_revision_id TEXT,
        correction_reason         TEXT,
        correction_reason_kind    TEXT,
        created_at                REAL NOT NULL,
        FOREIGN KEY(answer_id) REFERENCES answers(id) ON DELETE CASCADE,
        FOREIGN KEY(correction_of_revision_id, answer_id)
            REFERENCES answer_revisions(id, answer_id) ON DELETE RESTRICT,
        UNIQUE(answer_id, revision_number),
        UNIQUE(id, answer_id),
        CHECK(revision_number >= 1),
        -- SHA-256-shaped: 64 lowercase hex chars (matches the ProgressiveAnswerContentHasher).
        CHECK(length(content_hash) = 64 AND content_hash NOT GLOB '*[^0-9a-f]*'),
        -- A correction needs a referenced prior revision AND a nonblank reason; a
        -- non-correction has neither.
        CHECK(
            (correction_of_revision_id IS NULL AND correction_reason IS NULL)
            OR (correction_of_revision_id IS NOT NULL AND length(trim(correction_reason)) > 0)
        )
    );
    CREATE INDEX idx_answer_revisions_answer ON answer_revisions(answer_id, revision_number);

    -- answer_revision_events — append-only progressive-answer lifecycle ledger. Exactly the
    -- seven AEE-M2 lifecycle states. A content-bearing state MUST reference a revision;
    -- analysisProgress (status only) MAY be revision-less.
    CREATE TABLE answer_revision_events (
        id          TEXT PRIMARY KEY NOT NULL,
        answer_id   TEXT NOT NULL,
        sequence    INTEGER NOT NULL,
        revision_id TEXT,
        state       TEXT NOT NULL,
        detail      TEXT,
        created_at  REAL NOT NULL,
        FOREIGN KEY(answer_id) REFERENCES answers(id) ON DELETE CASCADE,
        FOREIGN KEY(revision_id) REFERENCES answer_revisions(id) ON DELETE CASCADE,
        UNIQUE(answer_id, sequence),
        CHECK(sequence >= 1),
        CHECK(state IN ('immediateFinding','groundedWorkingResult','analysisProgress',
                        'reviewReady','verifiedFinal','corrected','incomplete')),
        -- Content-bearing states MUST reference a revision. analysisProgress (status only) and
        -- incomplete (may be interrupted before any content, or carry a partial revision) may
        -- be revision-less.
        CHECK(state IN ('analysisProgress','incomplete') OR revision_id IS NOT NULL)
    );
    CREATE INDEX idx_answer_revision_events_answer ON answer_revision_events(answer_id, sequence);
    """

    // MARK: - v90 — MMI typed identity/document fields (deterministic, block-backed, provenance-complete)

    private static let v90: String = """
    -- MMI-FINAL. A deterministic typed-field producer (the FIRST accepted producer for the
    -- USF-004 typedFields surface + the typedFieldExtraction readiness dimension) extracts
    -- identity/document fields (personName, documentNumber, issueDate, email, amount, …) FROM
    -- the ALREADY-ACCEPTED EvidenceBlocks. Each typed value is pinned to the EXACT EvidenceBlock
    -- + SourceVersion + locator it came from, so a value can always reopen its source region.
    -- A typed field is NOT a confirmed Claim — it is a located, source-backed extraction with a
    -- confidence band; conflicts between locations are preserved, never silently resolved.
    CREATE TABLE typed_fields (
        id                 TEXT PRIMARY KEY NOT NULL,
        source_version_id  TEXT NOT NULL,
        evidence_block_id  TEXT NOT NULL,
        field_type         TEXT NOT NULL,
        raw_value          TEXT NOT NULL,
        normalized_value   TEXT NOT NULL,
        confidence         REAL NOT NULL,
        extraction_method  TEXT NOT NULL,          -- carried from the block (native/ocr/vision/…)
        locator            TEXT,                   -- JSON SourceLocator (page / bbox / char range)
        ocr_confidence     REAL,                   -- the block's OCR confidence when method='ocr'
        bounding_box       TEXT,                   -- JSON [x,y,w,h] for OCR/vision fields
        producer_id        TEXT NOT NULL,
        producer_version   TEXT NOT NULL,
        created_at         REAL NOT NULL,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        FOREIGN KEY(evidence_block_id) REFERENCES evidence_blocks(id) ON DELETE CASCADE,
        CHECK(confidence >= 0.0 AND confidence <= 1.0),
        CHECK(length(trim(field_type)) > 0),
        CHECK(length(trim(raw_value)) > 0),
        CHECK(ocr_confidence IS NULL OR (ocr_confidence >= 0.0 AND ocr_confidence <= 1.0))
    );
    CREATE INDEX idx_typed_fields_version ON typed_fields(source_version_id, field_type);
    CREATE INDEX idx_typed_fields_block ON typed_fields(evidence_block_id);
    CREATE INDEX idx_typed_fields_producer ON typed_fields(source_version_id, producer_id, producer_version);
    """

    private static let v91: String = """
    -- TBJ-FINAL (Time-Bounded Job core). A Job is a durable PLANNING ENVELOPE over the work a user
    -- must deliver against a time budget. It is NOT a second task system and NOT a second deadline
    -- system: every plan item REFERENCES an existing authority object (a ProfessionalTask, a
    -- WorkflowRun / step / requirement, an evidence requirement, or an expected artifact). Progress,
    -- priority and the time-bounded outcome are DERIVED at plan time from those live authorities —
    -- never stored here as a competing truth, and never as a fabricated completion percentage.
    --
    -- Time-budget integrity: the ONLY deadline a job may bind as its budget basis is a row in
    -- `deadlines` — which holds ONLY confirmed deadlines (candidates live in the separate
    -- `deadline_candidates` table). JobRepository enforces this at write time (it resolves the id in
    -- `deadlines` before binding), so a DeadlineCandidate CANNOT become a job's authoritative budget;
    -- an unconfirmed candidate is surfaced by the planning service as "possible deadline — needs
    -- confirmation", never as a confirmed countdown. The deadline / workflow pointers are SOFT
    -- references (plain columns validated by the repository, the same idiom as method_runs' soft
    -- workflow references) — not hard FKs — so an ON DELETE action can never null a budget column out
    -- from under the basis-integrity CHECK below, and a deleted deadline simply reads as no-longer-
    -- available when the planning service resolves it. Ownership edges (workspace, owning job) ARE
    -- hard FKs with CASCADE.
    CREATE TABLE job_objectives (
        id                      TEXT PRIMARY KEY NOT NULL,
        workspace_id            TEXT NOT NULL,
        title                   TEXT NOT NULL,
        objective_detail        TEXT,
        -- Time budget. `budget_basis` selects which (if any) authority defines the usable time.
        budget_basis            TEXT NOT NULL,        -- explicitDuration | confirmedDeadline | workflowConstraint | none
        budget_seconds          REAL,                 -- set iff basis = explicitDuration (> 0)
        budget_deadline_id      TEXT,                 -- set iff basis = confirmedDeadline (soft ref → deadlines.id)
        budget_workflow_run_id  TEXT,                 -- set iff basis = workflowConstraint (soft ref → workflow_runs.id)
        primary_workflow_run_id TEXT,                 -- optional run the job is executed through (soft ref)
        -- Job-envelope lifecycle. DISTINCT vocabulary from ProfessionalTaskStatus / WorkflowRunStatus:
        -- a job is an objective the user opens, then explicitly closes or abandons. Underlying task /
        -- workflow completion is a SEPARATE, derived fact and is never inferred from this column.
        lifecycle               TEXT NOT NULL,        -- active | closed | abandoned
        revision                INTEGER NOT NULL,
        created_at              REAL NOT NULL,
        updated_at              REAL NOT NULL,
        closed_at               REAL,
        closure_reason          TEXT,
        FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        CHECK(length(trim(title)) > 0),
        CHECK(budget_basis IN ('explicitDuration','confirmedDeadline','workflowConstraint','none')),
        CHECK(lifecycle IN ('active','closed','abandoned')),
        CHECK(revision >= 1),
        -- Exactly the column matching the basis is populated; the others stay NULL.
        CHECK(
            (budget_basis = 'explicitDuration'   AND budget_seconds IS NOT NULL AND budget_seconds > 0
                 AND budget_deadline_id IS NULL AND budget_workflow_run_id IS NULL) OR
            (budget_basis = 'confirmedDeadline'  AND budget_deadline_id IS NOT NULL
                 AND budget_seconds IS NULL AND budget_workflow_run_id IS NULL) OR
            (budget_basis = 'workflowConstraint' AND budget_workflow_run_id IS NOT NULL
                 AND budget_seconds IS NULL AND budget_deadline_id IS NULL) OR
            (budget_basis = 'none'
                 AND budget_seconds IS NULL AND budget_deadline_id IS NULL AND budget_workflow_run_id IS NULL)
        ),
        -- active forbids a closure timestamp; closed/abandoned require one.
        CHECK(
            (lifecycle = 'active'                    AND closed_at IS NULL) OR
            (lifecycle IN ('closed','abandoned')     AND closed_at IS NOT NULL)
        )
    );
    CREATE INDEX idx_job_objectives_workspace ON job_objectives(workspace_id, lifecycle);
    CREATE INDEX idx_job_objectives_deadline ON job_objectives(budget_deadline_id);
    CREATE INDEX idx_job_objectives_workflow ON job_objectives(primary_workflow_run_id);

    -- The persisted JobExecutionPlan: an ordered set of references to existing authority objects.
    -- The MinimumAcceptableDeliverable is the subset flagged `is_minimum_deliverable = 1` (no separate
    -- table, no separate truth). A reference NEVER becomes an executable object of its own — it points
    -- at one that already exists in the canonical engine.
    CREATE TABLE job_plan_references (
        id                     TEXT PRIMARY KEY NOT NULL,
        job_id                 TEXT NOT NULL,
        reference_kind         TEXT NOT NULL,   -- professionalTask | workflowRun | workflowStep | workflowRequirement | evidenceRequirement | expectedArtifact
        reference_id           TEXT NOT NULL,   -- UUID (task/run/step) or stable string id (requirement / artifact-definition)
        workflow_run_id        TEXT,            -- soft context run for step / requirement / artifact references
        role                   TEXT NOT NULL,   -- required | supporting | optional
        is_minimum_deliverable INTEGER NOT NULL DEFAULT 0,
        ordinal                INTEGER NOT NULL,
        note                   TEXT,
        created_at             REAL NOT NULL,
        FOREIGN KEY(job_id) REFERENCES job_objectives(id) ON DELETE CASCADE,
        CHECK(length(trim(reference_id)) > 0),
        CHECK(reference_kind IN ('professionalTask','workflowRun','workflowStep','workflowRequirement','evidenceRequirement','expectedArtifact')),
        CHECK(role IN ('required','supporting','optional')),
        CHECK(is_minimum_deliverable IN (0,1)),
        CHECK(ordinal >= 0)
    );
    CREATE INDEX idx_job_plan_refs_job ON job_plan_references(job_id, ordinal);
    -- One reference per (job, kind, target, context-run). COALESCE folds NULL context runs together so
    -- a duplicate with no run is still rejected (a bare UNIQUE would treat NULLs as distinct).
    CREATE UNIQUE INDEX idx_job_plan_refs_unique
        ON job_plan_references(job_id, reference_kind, reference_id, COALESCE(workflow_run_id, ''));

    -- Append-only audit ledger for the job envelope. Durable so a job's history survives relaunch and
    -- provides provenance for every planning change. Contiguous per-job sequence.
    CREATE TABLE job_events (
        id            TEXT PRIMARY KEY NOT NULL,
        job_id        TEXT NOT NULL,
        sequence      INTEGER NOT NULL,
        job_revision  INTEGER NOT NULL,
        action        TEXT NOT NULL,   -- created | budgetSet | referenceAdded | referenceRemoved | referenceUpdated | closed | abandoned | reopened
        actor         TEXT NOT NULL,
        detail        TEXT,
        occurred_at   REAL NOT NULL,
        FOREIGN KEY(job_id) REFERENCES job_objectives(id) ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(job_revision >= 1),
        CHECK(action IN ('created','budgetSet','referenceAdded','referenceRemoved','referenceUpdated','closed','abandoned','reopened')),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_job_events_seq ON job_events(job_id, sequence);
    """

    private static let v92: String = """
    -- LAB-001 (Stage C, Evidence Workbench / DataLab). The ONE canonical dataset authority. A
    -- Workbench dataset is a working table DERIVED from the read-only evidence ledger: every
    -- source-derived cell drills through to its exact canonical origin (EvidenceBlock / Claim /
    -- Event / … + SourceVersion + locator), and every cell declares its KIND so a derived, entered
    -- or proposed value is never mistaken for a direct source observation. Canonical evidence is
    -- NEVER copied into or mutated through this store — a dataset only references it. This supersedes
    -- the earlier evidence_datasets / dataset_rows prototype (kept decode-only for compatibility;
    -- WorkbenchDatasetRepository is the sole canonical writer). Transformations (LAB-002), scenarios
    -- (LAB-003), visual surfaces (LAB-004) and modes build ON this model.
    CREATE TABLE workbench_datasets (
        id           TEXT PRIMARY KEY NOT NULL,
        workspace_id TEXT NOT NULL,
        title        TEXT NOT NULL,
        mode         TEXT NOT NULL DEFAULT 'advanced',   -- simple | advanced (one truth, two presentations)
        revision     INTEGER NOT NULL,
        created_at   REAL NOT NULL,
        updated_at   REAL NOT NULL,
        FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        CHECK(length(trim(title)) > 0),
        CHECK(mode IN ('simple','advanced')),
        CHECK(revision >= 1)
    );
    CREATE INDEX idx_workbench_datasets_workspace ON workbench_datasets(workspace_id);

    -- Typed columns. value_shape carries the field's shape (text/number/date/…); ordinal gives
    -- deterministic left-to-right order.
    CREATE TABLE workbench_fields (
        id          TEXT PRIMARY KEY NOT NULL,
        dataset_id  TEXT NOT NULL,
        name        TEXT NOT NULL,
        value_shape TEXT NOT NULL,
        ordinal     INTEGER NOT NULL,
        created_at  REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        CHECK(length(trim(name)) > 0),
        CHECK(ordinal >= 0)
    );
    CREATE UNIQUE INDEX idx_workbench_fields_ordinal ON workbench_fields(dataset_id, ordinal);

    -- STABLE row identity (the contract requires it): a row keeps its id across edits/reopens so
    -- cells, scenarios and lineage stay attached through revisions. ordinal gives display order.
    CREATE TABLE workbench_rows (
        id          TEXT PRIMARY KEY NOT NULL,
        dataset_id  TEXT NOT NULL,
        ordinal     INTEGER NOT NULL,
        created_at  REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        CHECK(ordinal >= 0)
    );
    CREATE UNIQUE INDEX idx_workbench_rows_ordinal ON workbench_rows(dataset_id, ordinal);

    -- One cell per (row, field). `kind` is the provenance class the whole Workbench turns on:
    -- a source value must bind evidence; a deterministic calculation records its transformation
    -- (LAB-002); user-entered / user-corrected / model-proposal / reviewed values are NEVER treated
    -- as source observations. `status` carries the evidence/claim disposition.
    CREATE TABLE workbench_cells (
        id         TEXT PRIMARY KEY NOT NULL,
        dataset_id TEXT NOT NULL,
        row_id     TEXT NOT NULL,
        field_id   TEXT NOT NULL,
        kind       TEXT NOT NULL,   -- sourceValue | deterministicCalculation | userEntered | userCorrected | modelProposal | reviewed
        value      TEXT,            -- NULL = missing (a missing cell binds no evidence)
        status     TEXT NOT NULL,
        created_at REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        FOREIGN KEY(row_id)     REFERENCES workbench_rows(id)     ON DELETE CASCADE,
        FOREIGN KEY(field_id)   REFERENCES workbench_fields(id)   ON DELETE CASCADE,
        CHECK(kind IN ('sourceValue','deterministicCalculation','userEntered','userCorrected','modelProposal','reviewed')),
        CHECK(length(trim(status)) > 0)
    );
    CREATE UNIQUE INDEX idx_workbench_cells_rowfield ON workbench_cells(row_id, field_id);
    CREATE INDEX idx_workbench_cells_dataset ON workbench_cells(dataset_id);

    -- The drill-through: a source-derived cell binds to its EXACT canonical origin. target_kind names
    -- the canonical authority (evidence block / claim / event / entity / source version / contradiction
    -- / gap / knowledge object); source_version_id + locator_json pin the exact region so the Evidence
    -- Inspector can reopen it, and stale-source detection can compare producer versions. Soft
    -- references (validated by the repository) — canonical rows are never cascade-mutated by a dataset.
    CREATE TABLE workbench_source_bindings (
        id                TEXT PRIMARY KEY NOT NULL,
        cell_id           TEXT NOT NULL,
        target_kind       TEXT NOT NULL,
        target_id         TEXT NOT NULL,
        source_version_id TEXT,
        locator_json      TEXT,
        ordinal           INTEGER NOT NULL,
        created_at        REAL NOT NULL,
        FOREIGN KEY(cell_id) REFERENCES workbench_cells(id) ON DELETE CASCADE,
        CHECK(target_kind IN ('evidenceBlock','claim','event','entity','sourceVersion','contradiction','gap','knowledgeObject')),
        CHECK(length(trim(target_id)) > 0),
        CHECK(ordinal >= 0)
    );
    CREATE INDEX idx_workbench_source_bindings_cell ON workbench_source_bindings(cell_id);

    -- Saved projections/filters over a dataset (the "saved view" of the LAB-001 model).
    CREATE TABLE workbench_saved_views (
        id              TEXT PRIMARY KEY NOT NULL,
        dataset_id      TEXT NOT NULL,
        name            TEXT NOT NULL,
        projection_json TEXT NOT NULL,
        created_at      REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        CHECK(length(trim(name)) > 0)
    );
    CREATE INDEX idx_workbench_saved_views_dataset ON workbench_saved_views(dataset_id);

    -- Append-only revision history so a dataset's construction survives relaunch and is auditable.
    CREATE TABLE workbench_dataset_events (
        id               TEXT PRIMARY KEY NOT NULL,
        dataset_id       TEXT NOT NULL,
        sequence         INTEGER NOT NULL,
        dataset_revision INTEGER NOT NULL,
        action           TEXT NOT NULL,   -- created | fieldAdded | rowAdded | cellSet | sourceBound | viewSaved | renamed | modeChanged | converted
        actor            TEXT NOT NULL,
        detail           TEXT,
        occurred_at      REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(dataset_revision >= 1),
        CHECK(action IN ('created','fieldAdded','rowAdded','cellSet','sourceBound','viewSaved','renamed','modeChanged','converted')),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_workbench_dataset_events_seq ON workbench_dataset_events(dataset_id, sequence);
    """

    private static let v93: String = """
    -- LAB-002 (Stage C, Evidence Workbench / DataLab). The safe transformation engine's DURABLE
    -- lineage. A transformation is a deterministic, reproducible operation over a v92 dataset
    -- computed by a parsed, allowlisted expression language (tokenizer → parser → evaluator) —
    -- NEVER `eval`, never arbitrary code. It NEVER mutates canonical evidence and never overwrites a
    -- source cell: it produces new deterministicCalculation cells (calculated / running-total
    -- columns), a projection (filter / sort / deduplicate), or grouped aggregates. Per the contract,
    -- every derived value stores its formula/transformation, the EXACT input cell IDs it read, the
    -- engine version, and its output, so the value can be reproduced and audited.

    -- One applied transformation (append-only history; sequence is per-dataset and monotone). kind is
    -- the closed transform vocabulary; formula_text is the canonical formula source (calculated
    -- column / filter predicate / running-total field), NULL for a purely structural transform;
    -- spec_json is the full typed spec; engine_version pins the evaluator semantics; target_field_id
    -- is the new column a row-wise transform created; result_json holds a projection's ordered row-id
    -- set (filter/sort/deduplicate) for audit.
    CREATE TABLE workbench_transformations (
        id             TEXT PRIMARY KEY NOT NULL,
        dataset_id     TEXT NOT NULL,
        sequence       INTEGER NOT NULL,
        kind           TEXT NOT NULL,
        formula_text   TEXT,
        engine_version TEXT NOT NULL,
        spec_json      TEXT NOT NULL,
        target_field_id TEXT,
        result_json    TEXT,
        actor          TEXT NOT NULL,
        created_at     REAL NOT NULL,
        FOREIGN KEY(dataset_id)      REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        FOREIGN KEY(target_field_id) REFERENCES workbench_fields(id)   ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(kind IN ('calculatedColumn','runningTotal','filter','sort','deduplicate','aggregate','pivot','join','rollingCalculation')),
        CHECK(length(trim(engine_version)) > 0),
        CHECK(length(trim(spec_json)) > 0),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_workbench_transformations_seq ON workbench_transformations(dataset_id, sequence);
    CREATE INDEX idx_workbench_transformations_dataset ON workbench_transformations(dataset_id);

    -- One derived value produced by a transformation. output_cell_id points at the
    -- deterministicCalculation cell a row-wise column produced (NULL for an aggregate/projection
    -- result); result_key labels an aggregate group; output_value is the computed value string
    -- (NULL = a null / not-computable result). Reproducing (formula + inputs + engine_version) must
    -- yield output_value again.
    CREATE TABLE workbench_derivations (
        id                TEXT PRIMARY KEY NOT NULL,
        transformation_id TEXT NOT NULL,
        dataset_id        TEXT NOT NULL,
        output_cell_id    TEXT,
        result_key        TEXT,
        output_value      TEXT,
        created_at        REAL NOT NULL,
        FOREIGN KEY(transformation_id) REFERENCES workbench_transformations(id) ON DELETE CASCADE,
        FOREIGN KEY(dataset_id)        REFERENCES workbench_datasets(id)         ON DELETE CASCADE,
        FOREIGN KEY(output_cell_id)    REFERENCES workbench_cells(id)            ON DELETE CASCADE
    );
    CREATE INDEX idx_workbench_derivations_transformation ON workbench_derivations(transformation_id);
    CREATE INDEX idx_workbench_derivations_cell ON workbench_derivations(output_cell_id);

    -- The EXACT input cells a derived value read (its provenance). ordinal preserves argument order.
    -- ON DELETE CASCADE from the input cell keeps lineage honest: if a source cell is removed the
    -- derivation input link goes with it (the derivation itself remains, with fewer inputs, surfaced
    -- by the LAB-005 data-quality pass rather than silently repaired).
    CREATE TABLE workbench_derivation_inputs (
        id            TEXT PRIMARY KEY NOT NULL,
        derivation_id TEXT NOT NULL,
        input_cell_id TEXT NOT NULL,
        ordinal       INTEGER NOT NULL,
        FOREIGN KEY(derivation_id) REFERENCES workbench_derivations(id) ON DELETE CASCADE,
        FOREIGN KEY(input_cell_id) REFERENCES workbench_cells(id)       ON DELETE CASCADE,
        CHECK(ordinal >= 0)
    );
    CREATE INDEX idx_workbench_derivation_inputs_derivation ON workbench_derivation_inputs(derivation_id);
    CREATE UNIQUE INDEX idx_workbench_derivation_inputs_unique ON workbench_derivation_inputs(derivation_id, ordinal);

    -- Extend the dataset revision-history vocabulary with 'transformed'. SQLite cannot ALTER a CHECK,
    -- so rebuild workbench_dataset_events (created empty at v92) with the widened action set. Copy any
    -- existing rows verbatim (no history is invented or dropped), then swap the table and its unique
    -- (dataset_id, sequence) index back into place.
    CREATE TABLE workbench_dataset_events_v93 (
        id               TEXT PRIMARY KEY NOT NULL,
        dataset_id       TEXT NOT NULL,
        sequence         INTEGER NOT NULL,
        dataset_revision INTEGER NOT NULL,
        action           TEXT NOT NULL,
        actor            TEXT NOT NULL,
        detail           TEXT,
        occurred_at      REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(dataset_revision >= 1),
        CHECK(action IN ('created','fieldAdded','rowAdded','cellSet','sourceBound','viewSaved','renamed','modeChanged','converted','transformed')),
        CHECK(length(trim(actor)) > 0)
    );
    INSERT INTO workbench_dataset_events_v93 (id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at)
        SELECT id, dataset_id, sequence, dataset_revision, action, actor, detail, occurred_at FROM workbench_dataset_events;
    DROP TABLE workbench_dataset_events;
    ALTER TABLE workbench_dataset_events_v93 RENAME TO workbench_dataset_events;
    CREATE UNIQUE INDEX idx_workbench_dataset_events_seq ON workbench_dataset_events(dataset_id, sequence);
    """

    private static let v94: String = """
    -- LAB-003 (Stage C, Evidence Workbench / DataLab). Scenario overlays: a NON-DESTRUCTIVE analytical
    -- what-if layer on a v92 dataset. A scenario is an append-only OPERATION LOG plus an undo/redo
    -- pointer (current_op_seq) — the current state is REPLAYED from the log, never a stored mutated
    -- blob, so history is reconstructable and undo/redo is a deterministic pointer move. Canonical
    -- evidence, source cells and LAB-002 derivations are NEVER mutated here. Promotion of a scenario
    -- proposal into canonical/professional truth happens ONLY through an explicit human-reviewed action
    -- recorded in workbench_scenario_reviews, routed to an EXISTING authority; a rejected promotion
    -- leaves canonical state unchanged. Discard marks a scenario inactive without erasing its history.

    -- The scenario header. base_dataset_revision pins the dataset revision the scenario was built on
    -- (for staleness detection); current_op_seq is the undo/redo pointer (0 = origin); revision is the
    -- optimistic-CAS counter; status active|discarded|promoted.
    CREATE TABLE workbench_scenarios (
        id                   TEXT PRIMARY KEY NOT NULL,
        dataset_id           TEXT NOT NULL,
        base_dataset_revision INTEGER NOT NULL,
        title                TEXT NOT NULL,
        status               TEXT NOT NULL DEFAULT 'active',
        current_op_seq       INTEGER NOT NULL DEFAULT 0,
        revision             INTEGER NOT NULL,
        actor                TEXT NOT NULL,
        created_at           REAL NOT NULL,
        updated_at           REAL NOT NULL,
        FOREIGN KEY(dataset_id) REFERENCES workbench_datasets(id) ON DELETE CASCADE,
        CHECK(length(trim(title)) > 0),
        CHECK(status IN ('active','discarded','promoted')),
        CHECK(current_op_seq >= 0),
        CHECK(base_dataset_revision >= 1),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE INDEX idx_workbench_scenarios_dataset ON workbench_scenarios(dataset_id);

    -- The durable overlay operation log (append-only; sequence is monotone and never reused). status
    -- is 'live' (on the current branch) or 'abandoned' (a redo branch truncated by a new operation
    -- after an undo — retained for audit, never re-applied). before_value captures the projected value
    -- at the target immediately before this op. A cell op requires a field; a row op does not.
    CREATE TABLE workbench_scenario_operations (
        id           TEXT PRIMARY KEY NOT NULL,
        scenario_id  TEXT NOT NULL,
        sequence     INTEGER NOT NULL,
        kind         TEXT NOT NULL,
        target_kind  TEXT NOT NULL,
        row_id       TEXT NOT NULL,
        field_id     TEXT,
        before_value TEXT,
        after_value  TEXT,
        reason       TEXT,
        status       TEXT NOT NULL DEFAULT 'live',
        actor        TEXT NOT NULL,
        created_at   REAL NOT NULL,
        FOREIGN KEY(scenario_id) REFERENCES workbench_scenarios(id) ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(kind IN ('valueOverride','proposedCorrection','classification','annotation','derivedExperimentalValue','rowInclusion','rowExclusion')),
        CHECK(target_kind IN ('cell','row')),
        CHECK(target_kind = 'row' OR field_id IS NOT NULL),
        CHECK(status IN ('live','abandoned')),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_workbench_scenario_ops_seq ON workbench_scenario_operations(scenario_id, sequence);
    CREATE INDEX idx_workbench_scenario_ops_scenario ON workbench_scenario_operations(scenario_id);

    -- The reviewed-promotion ledger. A row records ONE human decision (accepted|rejected) routing a
    -- specific operation to an EXISTING authority (destination) + the resulting canonical/professional
    -- object reference. LAB-003 records the routing + reference; it never writes the canonical object
    -- itself and never bypasses the destination authority's own review rules.
    CREATE TABLE workbench_scenario_reviews (
        id                  TEXT PRIMARY KEY NOT NULL,
        scenario_id         TEXT NOT NULL,
        operation_id        TEXT NOT NULL,
        destination         TEXT NOT NULL,
        decision            TEXT NOT NULL,
        reviewer            TEXT NOT NULL,
        reason              TEXT,
        resulting_reference TEXT,
        decided_at          REAL NOT NULL,
        FOREIGN KEY(scenario_id)  REFERENCES workbench_scenarios(id)            ON DELETE CASCADE,
        FOREIGN KEY(operation_id) REFERENCES workbench_scenario_operations(id)  ON DELETE CASCADE,
        CHECK(destination IN ('userCorrection','workingFinding','methodRunInput','claimReview','workProductInput')),
        CHECK(decision IN ('accepted','rejected')),
        CHECK(length(trim(reviewer)) > 0)
    );
    CREATE INDEX idx_workbench_scenario_reviews_scenario ON workbench_scenario_reviews(scenario_id);

    -- Append-only scenario audit history so construction, undo/redo, promotion and discard survive
    -- relaunch and are provable.
    CREATE TABLE workbench_scenario_events (
        id                TEXT PRIMARY KEY NOT NULL,
        scenario_id       TEXT NOT NULL,
        sequence          INTEGER NOT NULL,
        scenario_revision INTEGER NOT NULL,
        action            TEXT NOT NULL,
        actor             TEXT NOT NULL,
        detail            TEXT,
        occurred_at       REAL NOT NULL,
        FOREIGN KEY(scenario_id) REFERENCES workbench_scenarios(id) ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(scenario_revision >= 1),
        CHECK(action IN ('created','operationApplied','undone','redone','reset','discarded','duplicated','promotionAccepted','promotionRejected')),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_workbench_scenario_events_seq ON workbench_scenario_events(scenario_id, sequence);
    """

    private static let v95: String = """
    -- SHELL-001 (product shell). The shared macOS shell's LOCATION navigation history, autosaved so a
    -- relaunch resumes at the exact place the user left. This is browser-style Back/Forward across app
    -- locations — DELIBERATELY DISTINCT from workflow Prev/Next (stepping through one workflow run's
    -- ordered steps). One session per scope_key (e.g. a workspace or the default shell); its entries are
    -- an ordered stack and current_index is the cursor (-1 when empty).
    CREATE TABLE app_navigation_sessions (
        id            TEXT PRIMARY KEY NOT NULL,
        scope_key     TEXT NOT NULL,
        current_index INTEGER NOT NULL,
        revision      INTEGER NOT NULL,
        updated_at    REAL NOT NULL,
        CHECK(length(trim(scope_key)) > 0),
        CHECK(current_index >= -1),
        CHECK(revision >= 1)
    );
    CREATE UNIQUE INDEX idx_app_navigation_sessions_scope ON app_navigation_sessions(scope_key);

    -- One visited location. destination is the closed top-level place; context_kind/context_id pin the
    -- exact item (e.g. a specific dataset) so Back/Forward returns to precisely where the user was.
    CREATE TABLE app_navigation_entries (
        id           TEXT PRIMARY KEY NOT NULL,
        session_id   TEXT NOT NULL,
        ordinal      INTEGER NOT NULL,
        destination  TEXT NOT NULL,
        context_kind TEXT,
        context_id   TEXT,
        FOREIGN KEY(session_id) REFERENCES app_navigation_sessions(id) ON DELETE CASCADE,
        CHECK(ordinal >= 0),
        CHECK(destination IN ('home','sources','timeline','entities','relationships','dataLab','methods','jobs','answers','reports','evidenceInspector','settings'))
    );
    CREATE UNIQUE INDEX idx_app_navigation_entries_ordinal ON app_navigation_entries(session_id, ordinal);
    CREATE INDEX idx_app_navigation_entries_session ON app_navigation_entries(session_id);
    """

    private static let v106: String = """
    -- REGISTERS (owner request 2026-08-20) — the day-to-day repeating-record tools
    -- (interview/statement logs, records-request/FOIA trackers, research logs). These
    -- reuse work_center_documents as the numbered store (INT/REQ/LOG doc types) but,
    -- unlike confirm-once workflow steps, their records are EDITABLE. This append-only
    -- log seals every field change so an edited record still carries who-changed-what-
    -- when — the human-input-with-history contract. One row per changed field per edit;
    -- rows are never rewritten or deleted (edits are corrected by further edits).
    CREATE TABLE work_center_record_edits (
        id         TEXT PRIMARY KEY,
        doc_id     TEXT NOT NULL REFERENCES work_center_documents(id) ON DELETE CASCADE,
        field_key  TEXT NOT NULL,
        old_value  TEXT NOT NULL DEFAULT '',
        new_value  TEXT NOT NULL DEFAULT '',
        editor     TEXT NOT NULL,
        note       TEXT NOT NULL DEFAULT '',
        edited_at  REAL NOT NULL,
        CHECK(length(trim(field_key)) > 0)
    );
    CREATE INDEX idx_wc_record_edits_doc ON work_center_record_edits(doc_id, edited_at);
    """

    private static let v105: String = """
    -- WORK-CENTER (maxmailin/SAP port, owner request 2026-08-17) — numbered documents.
    -- "Nothing is real until it has a number you can quote": every workflow run is a
    -- WF-YEAR-#### document; confirming a step that posts (Intake, Report, Production…)
    -- issues that step its own number. Documents are the durable, findable record of
    -- guided work — they REFERENCE the evidence/work products the shared services wrote
    -- (soft refs), never a second store of them. Statuses follow the SAP lifecycle
    -- open -> released -> confirmed and only ever advance.
    CREATE TABLE work_center_documents (
        id             TEXT PRIMARY KEY,
        doc_number     TEXT NOT NULL UNIQUE,      -- WF-2026-0012 / IMP-2026-0004 …
        doc_type       TEXT NOT NULL,             -- typed prefix (WF, IMP, RPT, PRD, PUB, EDN, ARC…)
        run_id         TEXT,                      -- owning WF run document (NULL for run docs themselves)
        def_id         TEXT,                      -- workflow definition id (run docs)
        step_seq       INTEGER,                   -- posting step (step docs)
        title          TEXT NOT NULL,
        status         TEXT NOT NULL DEFAULT 'open',
        fields_json    TEXT NOT NULL DEFAULT '{}',   -- captured field values ({seq:{key:value}} for runs)
        confirmed_seqs TEXT NOT NULL DEFAULT '',     -- run docs: comma-joined confirmed step seqs
        actor          TEXT NOT NULL,
        created_at     REAL NOT NULL,
        updated_at     REAL NOT NULL,
        CHECK(status IN ('open','released','confirmed')),
        CHECK(length(trim(doc_number)) > 0),
        CHECK(length(trim(doc_type)) > 0),
        CHECK(length(trim(title)) > 0)
    );
    CREATE INDEX idx_wc_documents_run ON work_center_documents(run_id);
    CREATE INDEX idx_wc_documents_type ON work_center_documents(doc_type, created_at);

    -- Transactional per-type-per-year number ranges (the SAP number-range object).
    CREATE TABLE work_center_counters (
        doc_type TEXT NOT NULL,
        year     INTEGER NOT NULL,
        next_seq INTEGER NOT NULL,
        PRIMARY KEY (doc_type, year),
        CHECK(next_seq >= 1)
    );
    """

    private static let v104: String = """
    -- AUD-CHAIN (SAP-inspired change-document audit trail) — a tamper-EVIDENT hash chain SEALING
    -- the app's existing append-only audit ledgers (custody_events + fact_reviews). This adds NO
    -- second source of truth: each row is a SEAL over one already-recorded audit event, ordered
    -- deterministically, with entry_hash = HMAC(payload || prev_hash). Any insertion, edit,
    -- deletion or reordering of a sealed event breaks the chain at that point; a user-facing
    -- "Verify integrity" pass reports the first broken seq. Append-only: seals are never rewritten.
    CREATE TABLE audit_chain (
        seq          INTEGER PRIMARY KEY,          -- 1-based position in the chain
        source       TEXT NOT NULL,                -- 'custody' | 'review'
        event_id     TEXT NOT NULL,                -- the sealed event's UUID
        occurred_at  REAL NOT NULL,                -- the sealed event's timestamp
        payload_hash TEXT NOT NULL,                -- HMAC of the event's canonical payload
        prev_hash    TEXT NOT NULL,                -- previous row's entry_hash (genesis for seq 1)
        entry_hash   TEXT NOT NULL,                -- HMAC(payload_hash || prev_hash)
        sealed_at    REAL NOT NULL,
        CHECK(source IN ('custody','review')),
        CHECK(seq >= 1),
        CHECK(length(entry_hash) > 0),
        CHECK(length(prev_hash) > 0)
    );
    -- One seal per (source, event) — sealing is idempotent, re-sealing a seen event is a no-op.
    CREATE UNIQUE INDEX idx_audit_chain_event ON audit_chain(source, event_id);
    """

    private static let v103: String = """
    -- P9.3 (GOV-005) — disk-backed ANN: IVF coarse-quantizer state in the SINGLE ledger. Pure DDL;
    -- population is a background build (ANNIndexCoordinator.maintain), never migration work.
    -- ann_index_meta: one row per embedding model — the persisted index-strategy decision, geometry,
    -- and build state. state='building' is the crash marker: a reopen that finds it treats the disk
    -- index as not-ready (queries brute-force) and the background job resumes the rebuild.
    CREATE TABLE ann_index_meta (
        model_id             TEXT PRIMARY KEY NOT NULL,   -- 'bge-small.v1' | 'apple.nl.v1'
        strategy             TEXT NOT NULL DEFAULT 'inMemoryHNSW',
        state                TEXT NOT NULL DEFAULT 'empty',
        dimension            INTEGER NOT NULL,
        cell_count           INTEGER NOT NULL DEFAULT 0,
        trained_vector_count INTEGER NOT NULL DEFAULT 0,  -- corpus size at last k-means train
        train_seed           INTEGER NOT NULL DEFAULT 0,  -- deterministic PRNG seed → reproducible builds
        created_at           REAL NOT NULL,
        updated_at           REAL NOT NULL,
        CHECK(strategy IN ('inMemoryHNSW','diskIVF')),
        CHECK(state IN ('empty','building','ready')),
        CHECK(dimension > 0),
        CHECK(cell_count >= 0),
        CHECK(trained_vector_count >= 0)
    );
    -- Coarse-quantizer centroids (float32 LE blob, dimension × 4 bytes). Cascade from meta so a
    -- model reset is one DELETE.
    CREATE TABLE ann_cells (
        model_id     TEXT NOT NULL,
        cell_id      INTEGER NOT NULL,
        centroid     BLOB NOT NULL,
        vector_count INTEGER NOT NULL DEFAULT 0,
        updated_at   REAL NOT NULL,
        PRIMARY KEY (model_id, cell_id),
        FOREIGN KEY (model_id) REFERENCES ann_index_meta(model_id) ON DELETE CASCADE,
        CHECK(cell_id >= 0),
        CHECK(vector_count >= 0)
    ) WITHOUT ROWID;
    -- Posting lists, physically CLUSTERED by (model_id, cell_id, …) via WITHOUT ROWID so a probe is
    -- a sequential range scan. q/scale are denormalized copies of chunk_embeddings (int8 blob +
    -- max|x|/127 scale) for read locality — a documented disk-for-latency trade. Deliberately NO FK
    -- to ann_cells: a retrain replaces cells and reassigns postings inside one repository-managed
    -- rebuild. Chunk deletion cascades the posting.
    CREATE TABLE ann_postings (
        model_id TEXT NOT NULL,
        cell_id  INTEGER NOT NULL,
        chunk_id TEXT NOT NULL,
        q        BLOB NOT NULL,
        scale    REAL NOT NULL,
        PRIMARY KEY (model_id, cell_id, chunk_id),
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
    ) WITHOUT ROWID;
    -- Leading chunk_id serves the FK-cascade lookup AND enforces one cell per (chunk, model).
    CREATE UNIQUE INDEX idx_ann_postings_chunk_model ON ann_postings(chunk_id, model_id);
    """

    private static let v102: String = """
    -- INV-19 (Findings & export). The durable, APPEND-ONLY human approval/withdrawal decision log for a
    -- case's FINDINGS work product. The findings work product itself is the SHARED WorkProductRun
    -- (work_product_runs) — this table introduces NO second reporting authority. It records only the
    -- explicit human decision that a specific, immutable findings run is APPROVED as the case's findings.
    -- Approval is NEVER inferred: building findings, a completed workflow / method, high confidence, or the
    -- absence of a contradiction do not approve anything. work_product_run_id is a soft reference to the
    -- approved run; receipt_seal pins the sealed receipt at approval (report==receipt integrity);
    -- scope_fingerprint pins the exact case scope the findings were built under (no export-time widening).
    -- A withdrawal is a NEW row that never rewrites the approval it follows, so the decision genealogy
    -- survives. Truth boundary: a finding is not a confirmed fact — approval authorizes the report, it does
    -- not verify the world.
    CREATE TABLE investigation_findings_approvals (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        sequence            INTEGER NOT NULL,
        decision            TEXT NOT NULL,   -- approved | withdrawn
        work_product_run_id TEXT NOT NULL,   -- soft ref to work_product_runs(id) (the immutable findings run)
        receipt_seal        TEXT NOT NULL,   -- the sealed receipt's seal at approval (report==receipt)
        scope_fingerprint   TEXT NOT NULL,
        rationale           TEXT NOT NULL,
        actor               TEXT NOT NULL,
        created_at          REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(decision IN ('approved','withdrawn')),
        CHECK(length(trim(work_product_run_id)) > 0),
        CHECK(length(trim(receipt_seal)) > 0),
        CHECK(length(scope_fingerprint) = 64 AND scope_fingerprint NOT GLOB '*[^0-9a-f]*'),
        CHECK(length(trim(rationale)) > 0),
        CHECK(sequence >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_investigation_findings_approvals_seq ON investigation_findings_approvals(case_id, sequence);
    CREATE INDEX idx_investigation_findings_approvals_case ON investigation_findings_approvals(case_id);
    """

    private static let v101: String = """
    -- INV-20 (Closure & export). The durable, APPEND-ONLY human closure/reopen decision log. A case is
    -- CLOSED only by a recorded human decision — never auto-closed by task/method completion, export, or
    -- confidence. Closure is HONEST: the unresolved items known at closure (gaps / open contradictions /
    -- pending evidence / residual risk) are retained here, never erased. A reopen is a NEW row that never
    -- rewrites the closure it follows, so the decision genealogy survives. work_product_run_id is a soft
    -- reference to the sealed findings work product; scope_fingerprint pins the case scope at the decision;
    -- receipt_seal pins the sealed export receipt (both optional — a case may be closed without a report).
    CREATE TABLE investigation_case_closures (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        sequence            INTEGER NOT NULL,
        decision            TEXT NOT NULL,   -- closed | reopened
        rationale           TEXT NOT NULL,
        work_product_run_id TEXT,            -- soft ref to work_product_runs(id) (the sealed findings report)
        scope_fingerprint   TEXT NOT NULL,
        unresolved_json     TEXT NOT NULL DEFAULT '[]',
        receipt_seal        TEXT,            -- the sealed export receipt's seal hash, when exported
        actor               TEXT NOT NULL,
        created_at          REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(decision IN ('closed','reopened')),
        CHECK(length(trim(rationale)) > 0),
        CHECK(length(scope_fingerprint) = 64 AND scope_fingerprint NOT GLOB '*[^0-9a-f]*'),
        CHECK(sequence >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_investigation_case_closures_seq ON investigation_case_closures(case_id, sequence);
    CREATE INDEX idx_investigation_case_closures_case ON investigation_case_closures(case_id);
    """

    private static let v100: String = """
    -- INV-08 (Source reliability) + INV-12 (Contradiction & gap desk). A thin, CASE-SCOPED human review
    -- decision that REFERENCES a shared canonical item by id — a source-reliability assessment
    -- (source_reliability_assessments, OPS-006), a contradiction (contradictions), or a gap (gap_nodes).
    -- It forks none of those authorities: the shared item keeps its own global status; this table records
    -- only what THIS case decided, so one case's dismissal never hides an item from another persona or case.
    -- item_id is a soft reference (reliability → source_version_id; contradiction/gap → the item's id).
    -- Truth boundaries: a reliability rating is not a verified fact; a contradiction is not a resolved
    -- truth; a gap is not a guessed answer — the desk records a human disposition, it resolves nothing.
    CREATE TABLE investigation_desk_reviews (
        id          TEXT PRIMARY KEY NOT NULL,
        case_id     TEXT NOT NULL,
        item_kind   TEXT NOT NULL,   -- reliability | contradiction | gap
        item_id     TEXT NOT NULL,
        decision    TEXT NOT NULL,   -- confirmed | dismissed
        note        TEXT,
        actor       TEXT NOT NULL,
        created_at  REAL NOT NULL,
        updated_at  REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(item_kind IN ('reliability','contradiction','gap')),
        CHECK(decision IN ('confirmed','dismissed')),
        CHECK(length(trim(item_id)) > 0),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_investigation_desk_reviews_unique ON investigation_desk_reviews(case_id, item_kind, item_id);
    CREATE INDEX idx_investigation_desk_reviews_case ON investigation_desk_reviews(case_id);
    """

    private static let v99: String = """
    -- INV-04..07 — the Investigator analytical spine. Persona reasoning state bounded to a case: it
    -- REFERENCES canonical evidence (source versions + knowledge objects + known Claims) by id and forks no
    -- second Claim/contradiction/gap authority. Four truth boundaries are enforced here, not just documented:
    --   • an idea is never a fact          (a lead/hypothesis is typed reasoning, not a Claim)
    --   • proposal ≠ hypothesis            (a lead is promoted to a hypothesis by a human decision)
    --   • unsupported stays a proposal     (a hypothesis is confirmed by a human, never auto-won)
    --   • an unknown is never fabricated   (a 5W1H cell either cites exact evidence or is marked unknown)

    -- Leads + hypotheses. kind='lead' is a captured idea (INV-04); a lead is PROMOTED into kind='hypothesis'
    -- (origin_hypothesis_id → the lead). status is a HUMAN decision: proposed → confirmed | rejected |
    -- dismissed. A hypothesis is never auto-confirmed. (INV-04 Brainstorm, INV-07 Hypothesis matrix.)
    CREATE TABLE investigation_hypotheses (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        kind                TEXT NOT NULL,   -- lead | hypothesis
        statement           TEXT NOT NULL,
        status              TEXT NOT NULL DEFAULT 'proposed',   -- proposed | confirmed | rejected | dismissed
        origin_hypothesis_id TEXT,           -- a promoted hypothesis links back to the lead it came from
        revision            INTEGER NOT NULL,
        actor               TEXT NOT NULL,
        created_at          REAL NOT NULL,
        updated_at          REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        FOREIGN KEY(origin_hypothesis_id) REFERENCES investigation_hypotheses(id) ON DELETE SET NULL,
        CHECK(kind IN ('lead','hypothesis')),
        CHECK(length(trim(statement)) > 0),
        CHECK(status IN ('proposed','confirmed','rejected','dismissed')),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE INDEX idx_investigation_hypotheses_case ON investigation_hypotheses(case_id);

    -- For/against evidence links (INV-07 HypothesisEvidenceLink). Each link cites EXACT evidence — a source
    -- version + knowledge object — with a stance. The evidence profile is COUNTED from these rows; the engine
    -- never picks a winner. UNIQUE so the same evidence isn't double-counted for a stance.
    CREATE TABLE investigation_hypothesis_evidence (
        id                  TEXT PRIMARY KEY NOT NULL,
        hypothesis_id       TEXT NOT NULL,
        stance              TEXT NOT NULL,   -- for | against
        source_version_id   TEXT NOT NULL,
        knowledge_object_id TEXT NOT NULL,
        note                TEXT,
        added_by            TEXT NOT NULL,
        created_at          REAL NOT NULL,
        FOREIGN KEY(hypothesis_id) REFERENCES investigation_hypotheses(id) ON DELETE CASCADE,
        CHECK(stance IN ('for','against')),
        CHECK(length(trim(added_by)) > 0)
    );
    CREATE UNIQUE INDEX idx_investigation_hypothesis_evidence_unique
        ON investigation_hypothesis_evidence(hypothesis_id, stance, source_version_id, knowledge_object_id);
    CREATE INDEX idx_investigation_hypothesis_evidence_hyp ON investigation_hypothesis_evidence(hypothesis_id);

    -- Evidence requests (INV-06 EvidenceRequest). A request describes MISSING evidence to gather; it never
    -- asserts the evidence exists. It may link to the hypothesis it would test (SET NULL if that hypothesis
    -- is deleted). status is a human decision: open → confirmed | fulfilled | cancelled.
    CREATE TABLE investigation_evidence_requests (
        id            TEXT PRIMARY KEY NOT NULL,
        case_id       TEXT NOT NULL,
        hypothesis_id TEXT,
        description   TEXT NOT NULL,
        status        TEXT NOT NULL DEFAULT 'open',   -- open | confirmed | fulfilled | cancelled
        revision      INTEGER NOT NULL,
        actor         TEXT NOT NULL,
        created_at    REAL NOT NULL,
        updated_at    REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        FOREIGN KEY(hypothesis_id) REFERENCES investigation_hypotheses(id) ON DELETE SET NULL,
        CHECK(length(trim(description)) > 0),
        CHECK(status IN ('open','confirmed','fulfilled','cancelled')),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE INDEX idx_investigation_evidence_requests_case ON investigation_evidence_requests(case_id);

    -- The 5W1H worksheet (INV-05). One cell per dimension per case. A cell is either 'answered' — carrying an
    -- answer AND a cited source version + knowledge object — or 'unknown', carrying NEITHER (an unknown is
    -- never fabricated). UNIQUE(case, dimension) so a case has exactly one cell per dimension.
    CREATE TABLE investigation_worksheet_cells (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        dimension           TEXT NOT NULL,   -- who | what | when | where | why | how
        status              TEXT NOT NULL DEFAULT 'unknown',   -- unknown | answered
        answer_text         TEXT,
        source_version_id   TEXT,
        knowledge_object_id TEXT,
        revision            INTEGER NOT NULL,
        actor               TEXT NOT NULL,
        updated_at          REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(dimension IN ('who','what','when','where','why','how')),
        CHECK(status IN ('unknown','answered')),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0),
        -- answered ⇔ an answer + cited evidence are present; unknown ⇔ none of them (no fabricated unknown).
        CHECK((status = 'answered') OR (answer_text IS NULL AND source_version_id IS NULL AND knowledge_object_id IS NULL)),
        CHECK((status <> 'answered') OR (length(trim(answer_text)) > 0 AND source_version_id IS NOT NULL AND knowledge_object_id IS NOT NULL))
    );
    CREATE UNIQUE INDEX idx_investigation_worksheet_cells_unique ON investigation_worksheet_cells(case_id, dimension);
    """

    private static let v98: String = """
    -- INV-02 (Subject dossier) + INV-03 (Identity resolution). Persona state over the ONE canonical entity
    -- engine: a subject REFERENCES a canonical `entities` row by id (never copies it), and the identity
    -- decision log records the human-gated, reversible merges that compose the SHARED EntitiesRepository
    -- merge/unmerge. No second entity, alias, or merge authority is forked.

    -- A subject of an investigation, anchored to one canonical entity. identity_status is proposed until a
    -- human CONFIRMS it (confirmed_by / confirmed_at then set) or rejects it. UNIQUE(case, entity) so a
    -- canonical entity is a subject at most once per case.
    CREATE TABLE investigation_subjects (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        canonical_entity_id TEXT NOT NULL,   -- soft ref to entities(id); entities may soft-merge underneath
        label               TEXT NOT NULL,
        identity_status     TEXT NOT NULL DEFAULT 'proposed',   -- proposed | confirmed | rejected
        confirmed_by        TEXT,                               -- the human who confirmed (NULL until confirmed)
        confirmed_at        REAL,
        revision            INTEGER NOT NULL,
        actor               TEXT NOT NULL,
        created_at          REAL NOT NULL,
        updated_at          REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(length(trim(label)) > 0),
        CHECK(identity_status IN ('proposed','confirmed','rejected')),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0),
        -- confirmed ⇔ a confirmer + timestamp are recorded; any non-confirmed status carries neither.
        CHECK((identity_status = 'confirmed') OR (confirmed_by IS NULL AND confirmed_at IS NULL)),
        CHECK((identity_status <> 'confirmed') OR (confirmed_by IS NOT NULL AND confirmed_at IS NOT NULL))
    );
    CREATE UNIQUE INDEX idx_investigation_subjects_unique ON investigation_subjects(case_id, canonical_entity_id);
    CREATE INDEX idx_investigation_subjects_case ON investigation_subjects(case_id);

    -- Append-only identity-resolution decision log. Every proposed / confirmed / rejected / reversed merge
    -- is a new row (never an update), so the decision is RECORDED and a reversal never erases the
    -- confirmation it undoes (INV-03 validation invariant: merge reversible; decision recorded). winner and
    -- loser are soft refs to canonical entities; prior_decision_id links a confirmation to its proposal and
    -- a reversal to its confirmation.
    CREATE TABLE investigation_identity_decisions (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        sequence          INTEGER NOT NULL,
        decision_kind     TEXT NOT NULL,   -- mergeProposed | mergeConfirmed | mergeRejected | mergeReversed
        winner_entity_id  TEXT NOT NULL,
        loser_entity_id   TEXT NOT NULL,
        rationale         TEXT,
        actor             TEXT NOT NULL,
        prior_decision_id TEXT,
        occurred_at       REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        FOREIGN KEY(prior_decision_id) REFERENCES investigation_identity_decisions(id) ON DELETE SET NULL,
        CHECK(decision_kind IN ('mergeProposed','mergeConfirmed','mergeRejected','mergeReversed')),
        CHECK(length(trim(winner_entity_id)) > 0),
        CHECK(length(trim(loser_entity_id)) > 0),
        CHECK(winner_entity_id <> loser_entity_id),
        CHECK(sequence >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_investigation_identity_decisions_seq ON investigation_identity_decisions(case_id, sequence);
    CREATE INDEX idx_investigation_identity_decisions_pair ON investigation_identity_decisions(case_id, winner_entity_id, loser_entity_id);
    """

    private static let v97: String = """
    -- INV-01-C4 — the canonical case-scope fingerprint / staleness ledger. ONE deterministic scope
    -- identity per case-produced analytical artifact (an Ask answer, a MethodRun, a Workbench dataset,
    -- a work product), so a later scope change can mark current surfaces stale WITHOUT rewriting the
    -- historical artifact: each row keeps the fingerprint + case revision under which it was produced.
    -- The fingerprint is computed by the ONE CaseScopeFingerprinter (never a per-engine variant); this
    -- table only records it. Canonical evidence is untouched — a soft artifact_id reference by design.
    CREATE TABLE investigation_scope_artifacts (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        artifact_kind     TEXT NOT NULL,   -- ask | methodRun | workbenchDataset | workProduct
        artifact_id       TEXT NOT NULL,
        scope_fingerprint TEXT NOT NULL,
        case_revision     INTEGER NOT NULL,
        created_at        REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(artifact_kind IN ('ask','methodRun','workbenchDataset','workProduct')),
        CHECK(length(trim(artifact_id)) > 0),
        CHECK(length(scope_fingerprint) = 64 AND scope_fingerprint NOT GLOB '*[^0-9a-f]*'),
        CHECK(case_revision >= 1)
    );
    CREATE UNIQUE INDEX idx_investigation_scope_artifacts_unique
        ON investigation_scope_artifacts(case_id, artifact_kind, artifact_id);
    CREATE INDEX idx_investigation_scope_artifacts_case ON investigation_scope_artifacts(case_id);
    """

    private static let v96: String = """
    -- INV-01-A (Investigator persona pack — Case Intake & Scope). The Investigator is a professional
    -- LENS over the one canonical engine: a case REFERENCES canonical sources, deadlines and evidence
    -- by id — it never copies them and never forks a second evidence/task/deadline/workflow authority.
    -- The set of in-scope case sources is the HARD evidence boundary that downstream Ask / Full Evidence
    -- / Methods / DataLab / exports must respect: a source being present in the workspace does NOT put
    -- it inside the active investigation until it is added in-scope here.
    CREATE TABLE investigation_cases (
        id                     TEXT PRIMARY KEY NOT NULL,
        workspace_id           TEXT NOT NULL,
        title                  TEXT NOT NULL,
        purpose                TEXT,
        scope_statement        TEXT,
        out_of_scope_statement TEXT,
        time_window_start      REAL,
        time_window_end        REAL,
        status                 TEXT NOT NULL DEFAULT 'open',   -- open | scopeConfirmed | closed
        confirmed_deadline_id  TEXT,                           -- soft ref to a CONFIRMED deadlines row only
        possible_deadline_note TEXT,                           -- advisory candidate text, never authoritative
        revision               INTEGER NOT NULL,
        actor                  TEXT NOT NULL,
        created_at             REAL NOT NULL,
        updated_at             REAL NOT NULL,
        FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
        CHECK(length(trim(title)) > 0),
        CHECK(status IN ('open','scopeConfirmed','closed')),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE INDEX idx_investigation_cases_workspace ON investigation_cases(workspace_id);

    -- The scope binding: which canonical sources are authorized for this case. source_ref is a soft
    -- reference to a canonical source identity (logical source / source version / workspace source);
    -- in_scope = 1 authorizes it, 0 explicitly excludes it. UNIQUE(case, source_ref) so a source has
    -- exactly one disposition per case. Canonical source rows are never cascade-mutated by a case.
    CREATE TABLE investigation_case_sources (
        id          TEXT PRIMARY KEY NOT NULL,
        case_id     TEXT NOT NULL,
        source_ref  TEXT NOT NULL,
        source_kind TEXT NOT NULL,   -- logicalSource | sourceVersion | workspaceSource
        in_scope    INTEGER NOT NULL DEFAULT 1,
        note        TEXT,
        created_at  REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(length(trim(source_ref)) > 0),
        CHECK(source_kind IN ('logicalSource','sourceVersion','workspaceSource')),
        CHECK(in_scope IN (0,1))
    );
    CREATE UNIQUE INDEX idx_investigation_case_sources_unique ON investigation_case_sources(case_id, source_ref);
    CREATE INDEX idx_investigation_case_sources_case ON investigation_case_sources(case_id);

    -- Append-only case audit so intake, scope changes, confirmation, deadline binding and reopen survive
    -- relaunch and are provable.
    CREATE TABLE investigation_case_events (
        id            TEXT PRIMARY KEY NOT NULL,
        case_id       TEXT NOT NULL,
        sequence      INTEGER NOT NULL,
        case_revision INTEGER NOT NULL,
        action        TEXT NOT NULL,   -- created | scopeSet | sourceIncluded | sourceExcluded | scopeConfirmed | deadlineBound | reopened
        actor         TEXT NOT NULL,
        detail        TEXT,
        occurred_at   REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        CHECK(sequence >= 1),
        CHECK(case_revision >= 1),
        CHECK(action IN ('created','scopeSet','sourceIncluded','sourceExcluded','scopeConfirmed','deadlineBound','reopened')),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE UNIQUE INDEX idx_investigation_case_events_seq ON investigation_case_events(case_id, sequence);
    """

    // MARK: - v107 — conformance assessments (roadmap 1.0.x-A, Level 1 persistence)
    //
    // One row per recorded conformance assessment of a run: the EXACT Sutra
    // snapshot (canonical JSON + SHA-256) frozen at recording, every rule
    // evaluation, the fail-closed status, and the optional signed seal. Old
    // runs reopen against this stored snapshot — never against the live
    // compiler value. Append-only by convention: recording again inserts a
    // new row (new revision); nothing here is updated or cascaded away.
    private static let v107: String = """
    CREATE TABLE conformance_assessments (
        id                   TEXT PRIMARY KEY NOT NULL,
        case_id              TEXT NOT NULL,
        run_revision         INTEGER NOT NULL DEFAULT 1,
        sutra_citation       TEXT NOT NULL,
        sutra_sha256         TEXT NOT NULL,
        sutra_snapshot_json  TEXT NOT NULL,
        evaluations_json     TEXT NOT NULL,
        status               TEXT NOT NULL,
        seal_json            TEXT,
        assessed_at          REAL NOT NULL,
        created_at           REAL NOT NULL,
        CHECK(status IN ('conformant','notConformant','indeterminate')),
        CHECK(run_revision >= 1),
        CHECK(length(trim(sutra_sha256)) = 64)
    );
    CREATE INDEX idx_conformance_assessments_case ON conformance_assessments(case_id, created_at);
    """

    // MARK: - v108 — signed offline protocol packs + governed review records
    //
    // Roadmap 1.1. protocol_registry: every imported, signature-verified pack
    // with its full signed JSON; exactly one row per (sutra, version); status
    // moves imported → active → superseded/revoked — activation supersedes the
    // previous active version of the same sutra, revocation is recorded with a
    // reason, and NOTHING here ever mutates a frozen run (assessments carry
    // their own snapshot). protocol_review_records: governed "reviewed as of"
    // records for the assurance board — reviewer, source hash, diff, affected
    // rules, decision, optional P-256-signed record. Both append-only by
    // convention.
    private static let v108: String = """
    CREATE TABLE protocol_registry (
        id                TEXT PRIMARY KEY NOT NULL,   -- "<sutra_id>@v<version>"
        sutra_id          TEXT NOT NULL,
        version           INTEGER NOT NULL,
        sutra_sha256      TEXT NOT NULL,
        pack_json         TEXT NOT NULL,               -- full SignedProtocolPack, canonical
        publisher         TEXT NOT NULL,
        assurance         TEXT NOT NULL,
        signer_key_id     TEXT NOT NULL,
        status            TEXT NOT NULL DEFAULT 'imported',
        imported_at       REAL NOT NULL,
        activated_at      REAL,
        revoked_at        REAL,
        revocation_reason TEXT,
        CHECK(status IN ('imported','active','superseded','revoked')),
        CHECK(version >= 1),
        CHECK(length(trim(sutra_sha256)) = 64)
    );
    CREATE UNIQUE INDEX idx_protocol_registry_identity ON protocol_registry(sutra_id, version);
    CREATE INDEX idx_protocol_registry_status ON protocol_registry(sutra_id, status);

    CREATE TABLE protocol_review_records (
        id               TEXT PRIMARY KEY NOT NULL,
        subject_id       TEXT NOT NULL,     -- ComplianceBoard SOP id or protocol_registry id
        reviewer         TEXT NOT NULL,
        role             TEXT,
        source_note      TEXT,              -- the official source or imported snapshot consulted
        source_sha256    TEXT,
        diff_summary     TEXT,
        affected_rules   TEXT,              -- comma-joined rule IDs
        decision         TEXT NOT NULL,     -- current | updateRequired | notApplicable
        notes            TEXT,
        record_seal_json TEXT,              -- optional P-256 signed canonical record
        reviewed_at      REAL NOT NULL,
        CHECK(length(trim(reviewer)) > 0),
        CHECK(decision IN ('current','updateRequired','notApplicable'))
    );
    CREATE INDEX idx_protocol_review_subject ON protocol_review_records(subject_id, reviewed_at);
    """

    // MARK: - v109 — assessments bind to the real run and carry their facts
    //
    // Audit 2026-08-25 items 1/2/5: run_id + run_state_sha256 bind each
    // assessment to the immutable findings run it judged; facts_json carries
    // the exact ConformanceFacts consulted (incl. actor-bound per-rule
    // attestations) so verification bundles can RERUN the evaluators instead
    // of merely re-adding recorded outcomes.
    private static let v109: String = """
    ALTER TABLE conformance_assessments ADD COLUMN run_id TEXT;
    ALTER TABLE conformance_assessments ADD COLUMN run_state_sha256 TEXT;
    ALTER TABLE conformance_assessments ADD COLUMN facts_json TEXT;
    """

    // MARK: - v110 — deviations become a DISTINCT sealed status
    //
    // Audit item 8: 'conformantWithDeviations' joins the status vocabulary so a
    // deviated run is never blended into plain conformant. SQLite cannot alter
    // a CHECK, so the table is recreated with the 4-state constraint and rows
    // copied verbatim (append-only history preserved). Adds evidence_manifest_json
    // so bundles export the manifest the signed envelope hashes.
    private static let v110: String = """
    CREATE TABLE conformance_assessments_v110 (
        id                     TEXT PRIMARY KEY NOT NULL,
        case_id                TEXT NOT NULL,
        run_revision           INTEGER NOT NULL DEFAULT 1,
        sutra_citation         TEXT NOT NULL,
        sutra_sha256           TEXT NOT NULL,
        sutra_snapshot_json    TEXT NOT NULL,
        evaluations_json       TEXT NOT NULL,
        status                 TEXT NOT NULL,
        seal_json              TEXT,
        assessed_at            REAL NOT NULL,
        created_at             REAL NOT NULL,
        run_id                 TEXT,
        run_state_sha256       TEXT,
        facts_json             TEXT,
        evidence_manifest_json TEXT,
        CHECK(status IN ('conformant','conformantWithDeviations','notConformant','indeterminate')),
        CHECK(run_revision >= 1),
        CHECK(length(trim(sutra_sha256)) = 64)
    );
    INSERT INTO conformance_assessments_v110
        (id, case_id, run_revision, sutra_citation, sutra_sha256, sutra_snapshot_json,
         evaluations_json, status, seal_json, assessed_at, created_at,
         run_id, run_state_sha256, facts_json)
    SELECT id, case_id, run_revision, sutra_citation, sutra_sha256, sutra_snapshot_json,
           evaluations_json, status, seal_json, assessed_at, created_at,
           run_id, run_state_sha256, facts_json
    FROM conformance_assessments;
    DROP TABLE conformance_assessments;
    ALTER TABLE conformance_assessments_v110 RENAME TO conformance_assessments;
    CREATE INDEX idx_conformance_assessments_case ON conformance_assessments(case_id, created_at);
    """

    // MARK: - v111 — governance events ledger (fifth audit: audit-chain scope)
    //
    // Append-only record of the governance acts the audit chain must cover
    // beyond custody/fact-review: findings approval, approval withdrawal,
    // assessment recording, verification-bundle export. Rows are never
    // updated or deleted; the AUD-CHAIN seals them as a third source.
    private static let v111: String = """
    CREATE TABLE governance_events (
        id          TEXT PRIMARY KEY,
        kind        TEXT NOT NULL,
        case_id     TEXT NOT NULL,
        actor       TEXT NOT NULL,
        detail      TEXT NOT NULL DEFAULT '',
        occurred_at REAL NOT NULL,
        CHECK(kind IN ('findings.approved','approval.withdrawn','assessment.recorded','bundle.exported'))
    );
    CREATE INDEX idx_governance_events_case ON governance_events(case_id, occurred_at);
    -- Admit the governance ledger as a third audit-chain source. SQLite cannot
    -- alter a CHECK: recreate and copy rows VERBATIM — every sealed hash is
    -- untouched, so the existing HMAC chain remains intact end-to-end.
    CREATE TABLE audit_chain_v111 (
        seq          INTEGER PRIMARY KEY,
        source       TEXT NOT NULL,
        event_id     TEXT NOT NULL,
        occurred_at  REAL NOT NULL,
        payload_hash TEXT NOT NULL,
        prev_hash    TEXT NOT NULL,
        entry_hash   TEXT NOT NULL,
        sealed_at    REAL NOT NULL,
        CHECK(source IN ('custody','review','governance')),
        CHECK(seq >= 1),
        CHECK(length(entry_hash) > 0),
        CHECK(length(prev_hash) > 0)
    );
    INSERT INTO audit_chain_v111 SELECT * FROM audit_chain;
    DROP TABLE audit_chain;
    ALTER TABLE audit_chain_v111 RENAME TO audit_chain;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_chain_event ON audit_chain(source, event_id);
    """

    // MARK: - v112 — durable approval state (Phase C, seventh audit)
    //
    // 'approved' is written ONLY by the atomic approval composite (approval
    // row + sealed assessment + governance event in ONE savepoint — see
    // ApprovalTransactionRepository). 'recorded' covers assessments stored
    // without an approval act (projections, tests, legacy rows). The
    // intermediate states of the pending → assessed → sealed → approved
    // machine never persist because the transition is a single transaction.
    private static let v112: String = """
    ALTER TABLE conformance_assessments
        ADD COLUMN approval_state TEXT NOT NULL DEFAULT 'recorded'
        CHECK(approval_state IN ('recorded','approved'));
    """

    // MARK: - v113 — case ↔ method-run linkage (Phase B, seventh audit)
    //
    // Method runs were workspace-scoped only, so the conformance assessor
    // could never OBSERVE the method-family phases (methods, causalAnalysis,
    // linkage, capaRegister) for a case. startMethod now records the link at
    // run creation; phase completion is DERIVED by joining onto method_runs —
    // the runs table remains the single source of truth for run state.
    private static let v113: String = """
    CREATE TABLE case_method_runs (
        case_id       TEXT NOT NULL,
        method_run_id TEXT NOT NULL,
        phase_kind    TEXT NOT NULL,
        created_at    REAL NOT NULL,
        PRIMARY KEY (case_id, method_run_id),
        FOREIGN KEY(method_run_id) REFERENCES method_runs(id) ON DELETE CASCADE
    );
    CREATE INDEX idx_case_method_runs_case ON case_method_runs(case_id, phase_kind);
    """

    // MARK: - v114 — PUBLIC hash chain columns (Phase D, seventh audit)
    //
    // The HMAC chain detects local tampering but its key is private, so an
    // OUTSIDE verifier could never replay it. Each new seal now also links a
    // plain SHA-256 chain over the same canonical payloads:
    //   public_hash = SHA256(canonicalPayload || public_prev)
    // The head is SIGNED into the conformance envelope and bundles export the
    // event payloads (metadata only — never document content), so anyone can
    // recompute the chain to the signed head. Legacy rows keep NULL (their
    // payloads were sealed before the public chain existed); the public chain
    // starts at the first post-v114 seal — stated, not hidden.
    private static let v114: String = """
    ALTER TABLE audit_chain ADD COLUMN public_prev TEXT;
    ALTER TABLE audit_chain ADD COLUMN public_hash TEXT;
    """

    // MARK: - v115 — generic case-phase artifacts (Phase B-2)
    //
    // The last two attestation-only phases become machine-observable: the
    // case-scoped Ask records one row per verified answer (a question HASH
    // only — never the question text), and DataLab records one row per
    // prepared dataset. The observation service derives phase completion
    // from these rows; artifacts themselves stay in their own authorities.
    private static let v115: String = """
    CREATE TABLE case_phase_artifacts (
        id          TEXT PRIMARY KEY,
        case_id     TEXT NOT NULL,
        phase_kind  TEXT NOT NULL,
        artifact_id TEXT NOT NULL,
        detail      TEXT NOT NULL DEFAULT '',
        created_at  REAL NOT NULL
    );
    CREATE INDEX idx_case_phase_artifacts_case ON case_phase_artifacts(case_id, phase_kind);
    """

    // MARK: - v116 — public-chain rule v2 reset (eighth audit)
    //
    // The public (keyless SHA-256) chain link now binds the FULL entry —
    // seq, source, event ID and occurrence time — not just the payload, so
    // exported trail metadata cannot be edited without breaking the fold to
    // the signed head. Links written under the v114 payload-only rule cannot
    // satisfy rule v2, so they are RESET (the private HMAC chain, the actual
    // tamper evidence, is untouched); the public chain restarts at the next
    // seal under the v2 genesis. Pre-release rule change: no signed envelope
    // committing to a v1 public head has ever left a released build.
    private static let v116: String = """
    UPDATE audit_chain SET public_prev = NULL, public_hash = NULL;
    """

    // MARK: - v117 — phase artifacts bound to case + revision + scope (eleventh audit)
    //
    // A phase observation must be bound to the EXACT case state it was
    // produced under: FK to investigation_cases, the case revision, and the
    // INV-01-C4 scope fingerprint — and one artifact may serve exactly one
    // case (UNIQUE(phase_kind, artifact_id)), so a case-A answer can never
    // count as case-B phase evidence. Pre-v117 rows carried no binding and
    // cannot be trusted retroactively — they are DROPPED (fail-closed: those
    // phases return to machine-unobserved; attestation still covers them).
    private static let v117: String = """
    DROP TABLE case_phase_artifacts;
    CREATE TABLE case_phase_artifacts (
        id                TEXT PRIMARY KEY,
        case_id           TEXT NOT NULL,
        case_revision     INTEGER NOT NULL,
        scope_fingerprint TEXT NOT NULL,
        phase_kind        TEXT NOT NULL,
        artifact_id       TEXT NOT NULL,
        detail            TEXT NOT NULL DEFAULT '',
        created_at        REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        UNIQUE(phase_kind, artifact_id),
        CHECK(case_revision >= 1),
        CHECK(length(scope_fingerprint) = 64 AND scope_fingerprint NOT GLOB '*[^0-9a-f]*')
    );
    CREATE INDEX idx_case_phase_artifacts_case ON case_phase_artifacts(case_id, phase_kind);
    """

    // MARK: - v118 — self-heal recovery rebuild + answer origin (twelfth audit)
    //
    // P0: the stale-counter self-heal sentinel had not been extended past
    // v106, so a REAL database at user_version 107–117 with the full v106
    // shape could be stamped to latest WITHOUT the pending migrations
    // running — in particular, a v116 database could report v117 while
    // case_phase_artifacts still had the unbound v115 shape. v118 recovers
    // FAIL-CLOSED: rebuild the table idempotently to the bound v117 shape
    // (dropping any rows — unbound rows cannot be trusted retroactively),
    // and the sentinel below now carries distinguishing markers for every
    // migration v107…v118, so the skip can never recur.
    //
    // v118 also adds the ORIGIN column on answers: the producing request's
    // bounded evidence scope (the investigation case for case-scoped Asks;
    // NULL for global Asks). Phase evidence then requires artifact ORIGIN,
    // not merely first-binding.
    private static let v118: String = """
    DROP TABLE IF EXISTS case_phase_artifacts;
    CREATE TABLE case_phase_artifacts (
        id                TEXT PRIMARY KEY,
        case_id           TEXT NOT NULL,
        case_revision     INTEGER NOT NULL,
        scope_fingerprint TEXT NOT NULL,
        phase_kind        TEXT NOT NULL,
        artifact_id       TEXT NOT NULL,
        detail            TEXT NOT NULL DEFAULT '',
        created_at        REAL NOT NULL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        UNIQUE(phase_kind, artifact_id),
        CHECK(case_revision >= 1),
        CHECK(length(scope_fingerprint) = 64 AND scope_fingerprint NOT GLOB '*[^0-9a-f]*')
    );
    CREATE INDEX idx_case_phase_artifacts_case ON case_phase_artifacts(case_id, phase_kind);
    ALTER TABLE answers ADD COLUMN origin_scope_id TEXT;
    """

    // MARK: - v119 — immutable dataset case origin (thirteenth audit)
    //
    // A case-produced Workbench dataset carries the case it was produced FOR,
    // stamped once at creation by the case-scoped DataLab service and never
    // updated (the repository has no setter). Phase evidence then requires
    // dataset ORIGIN — a workspace check is not enough: two cases in the SAME
    // workspace must not be able to claim each other's datasets. NULL means
    // "not case-produced" (workspace-global or pre-v119), which is never
    // acceptable as case phase evidence — fail-closed.
    private static let v119: String = """
    ALTER TABLE workbench_datasets ADD COLUMN origin_case_id TEXT;
    """

    // MARK: - v120 — the v1.1 Stage-1 column batch (V1, one migration)
    //
    // All nullable/advisory; NO behavior change in v120 itself (V1 spec).
    // - producer_version on facts/entities/events: NULL = v0 — absence is a
    //   version; the SourceReprocessingCoordinator's staleness predicate
    //   selects exactly the legacy set per producer once producers register.
    // - chunk_version + embedding_model_version on chunks: the Stage-2
    //   re-chunk of the 141 oversized chunks and any embedder swap become
    //   versioned rewrites instead of erase/re-ingest.
    // - B-1 bi-temporal on generic_facts: supersession is recorded, never
    //   averaged ("X until DATE, then Y").
    // - exhaust_class on knowledge_objects: the provenance-class flag (unit
    //   C-i law) — future answer-path writers self-mark; evidentiary
    //   surfaces filter on the class, so pipe #3 is excluded by
    //   construction. NULL = primary source material.
    private static let v120: String = """
    ALTER TABLE generic_facts ADD COLUMN producer_version INTEGER;
    ALTER TABLE generic_facts ADD COLUMN valid_at REAL;
    ALTER TABLE generic_facts ADD COLUMN invalid_at REAL;
    ALTER TABLE generic_facts ADD COLUMN superseded_by TEXT;
    ALTER TABLE entities ADD COLUMN producer_version INTEGER;
    ALTER TABLE events ADD COLUMN producer_version INTEGER;
    ALTER TABLE chunks ADD COLUMN chunk_version INTEGER;
    ALTER TABLE chunks ADD COLUMN embedding_model_version TEXT;
    ALTER TABLE knowledge_objects ADD COLUMN exhaust_class TEXT;
    """

    // MARK: - v121 — V2 capture-group provenance (C-1 + C-10)
    //
    // Nullable/advisory; no behavior change in v121 itself (versioning-before-
    // logic, per the V1-before-V2 rule). V2's extractor rewrite fills them.
    // - raw_match: the FULL matched text a fact was captured from ("Patent
    //   No. 555489"), kept as provenance while `value` becomes the normalized
    //   atom ("555489") — the Element Calculus split. Six spellings collapse
    //   to one value, but the receipt can still show all six raw forms.
    // - source_count: C-10 corroboration — distinct DOCUMENTS asserting this
    //   value; confidence rises with corroboration instead of first-wins/max.
    //   Denormalized: the merge asserts source_count == distinct source_blocks.
    private static let v121: String = """
    ALTER TABLE generic_facts ADD COLUMN raw_match TEXT;
    ALTER TABLE generic_facts ADD COLUMN source_count INTEGER;
    """

    // V2 (C-10) gate-3 provenance (owner ruling 2026-09-02). When the cross-field
    // mislabel resolver REASSIGNS a value to its true home field, the reassigned
    // evidence blocks ride along as corroboration — but a forensic reader of the
    // receipt would see a block whose text says "Patent No. …" cited under
    // applicationNumber and read it as an error. `reassigned_from` records the
    // origin field id the mislabel was captured under, so the reassignment is
    // auditable, not silent: the receipt can annotate "includes a reassigned
    // attestation (originally labeled <reassigned_from>)". ADVISORY — NEVER
    // sealed (the evidence-state stamp counts rows, not this column) and NEVER
    // gates surfacing; it is also QUERYABLE, so reassignment counts by field pair
    // join the guard-telemetry family (a reassignment-rate spike = rule defect).
    private static let v122: String = """
    ALTER TABLE generic_facts ADD COLUMN reassigned_from TEXT;
    """

    // MARK: - v123 — V4 (D-17 Part A): document_class on knowledge_objects
    //
    // The document's classified kind ("email", "invoice", "legalDocument",
    // "certificate", …) stamped at ingest so event extraction and retrieval can
    // gate by class (EV-1: commercial markers never fire on a legal document).
    // NULLABLE by design: fresh ingests stamp it; the BACKFILL for existing rows
    // RIDES THE V5 DRAIN (never a standalone rewrite of the archive).
    private static let v123: String = """
    ALTER TABLE knowledge_objects ADD COLUMN document_class TEXT;
    """

    // MARK: - v124 — S2-U1 (D-17 Part B): structural salience on chunks
    //
    // How much a chunk's STRUCTURAL position says "this is what the document is
    // about" (email subject > quoted tail; table row > footer). Written at
    // insert from the class-aware weight table (SalienceTable); DEFAULT 0.6 =
    // the neutral prior, so pre-existing rows and unknown kinds change nothing
    // until the versioned backfill (rides the shared S2 reindex) rewrites them.
    // Presentation-and-ranking only: nothing is dropped for scoring low.
    private static let v124: String = """
    ALTER TABLE chunks ADD COLUMN salience REAL NOT NULL DEFAULT 0.6;
    """

    // MARK: - v125 — S2-U2 (R-3): deterministic context-prefix template version
    //
    // Which version of the DETERMINISTIC prefix template (title · class ·
    // block kind) produced this chunk's context_prefix. NULL = a legacy
    // LLM/heuristic prefix or no prefix; the shared S2 reindex rewrites
    // those rows under the current template. Index-only, like the prefix
    // itself — never shown, never FTS-indexed.
    private static let v125: String = """
    ALTER TABLE chunks ADD COLUMN context_template_version INTEGER;
    """

    // MARK: - v126 — TT (Amendment A1): term salience per document
    //
    // The WINNER TERMS of each document: in-doc frequency × archive rarity ×
    // structural salience × corroboration. Identifiers rank highest by
    // construction; proper nouns need corroboration (≥2 documents). The topic
    // tree's labels and seeds read from here; versioned so a scoring change
    // is an era, refreshed by targeted refresh — never silent drift.
    private static let v126: String = """
    CREATE TABLE IF NOT EXISTS document_terms (
        object_id        TEXT NOT NULL REFERENCES knowledge_objects(id) ON DELETE CASCADE,
        term             TEXT NOT NULL,
        score            REAL NOT NULL,
        is_identifier    INTEGER NOT NULL DEFAULT 0,
        corroboration    INTEGER NOT NULL DEFAULT 1,
        producer_version INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (object_id, term)
    );
    CREATE INDEX IF NOT EXISTS idx_document_terms_term ON document_terms(term);
    """

    // MARK: - v127 — P4-U1: the story's second door (durable, honest persistence)
    //
    // history_artifacts gains the Ask-door columns: review_state ('verified'
    // for the Dossier's reviewed path — the historical default — vs
    // 'unreviewed' for stories persisted straight from a question),
    // anchor_key + request_shape + ledger_stamp for dedup by
    // (anchor, request-shape, ledger version) and for stale-flagging: an
    // artifact whose stamp no longer matches the live ledger is SHOWN as
    // possibly out of date — never silently wrong, never deleted.
    private static let v127: String = """
    ALTER TABLE history_artifacts ADD COLUMN review_state TEXT NOT NULL DEFAULT 'verified';
    ALTER TABLE history_artifacts ADD COLUMN anchor_key TEXT;
    ALTER TABLE history_artifacts ADD COLUMN request_shape TEXT;
    ALTER TABLE history_artifacts ADD COLUMN ledger_stamp TEXT;
    CREATE INDEX IF NOT EXISTS idx_history_artifacts_dedup
        ON history_artifacts(anchor_key, request_shape, ledger_stamp);
    """

    // MARK: - v128 — G2/Stage-3: durable conversation reopening
    //
    // An assistant conversation turn gains a link to its durable answer in
    // the answer ledger (answer_ledger_id). On reopen the citations,
    // verification status and receipt controls are restored from that
    // ledger row instead of being lost — the turn binds to the durable
    // revision, never a second divergent copy of verification truth. NULL
    // for legacy turns (an honest "evidence not linked" state) and for user
    // turns.
    private static let v128: String = """
    ALTER TABLE conversation_turns ADD COLUMN answer_ledger_id TEXT;
    """

    // MARK: - v129 — C-4 / OCR derivation provenance on generic_facts
    //
    // A fact's value is normally read verbatim from ONE block. Two producers
    // recover values the strict reader cannot see, and both must be
    // distinguishable from a verbatim capture forever after:
    //   CROSS_BLOCK_ASSEMBLED — the field label ended one block and its value
    //     began the next (a page break between "Patent No." and the number).
    //     Such a fact cites BOTH blocks, because neither alone supports it.
    //   OCR_CORRECTED — a scanner read digits as letters ("7OO321"); the digits
    //     were restored and `raw_match` keeps the scanned form as the receipt.
    // Before this column both cases were invisible: the page-break value was not
    // extracted at all, and the OCR value was dropped with nothing recording
    // that a labeled identifier had been seen and abandoned. Confidence alone
    // cannot carry this — it cannot answer "which values did we repair, and
    // how?". NULL means verbatim, which is the overwhelming majority of rows
    // and every row written before this migration. ADVISORY: never sealed (the
    // evidence-state stamp counts rows, not this column), never gates
    // surfacing, and QUERYABLE so a derivation-rate spike reads as the rule
    // defect it would be.
    private static let v129: String = """
    ALTER TABLE generic_facts ADD COLUMN derivation TEXT;
    """

    // MARK: - v130 — P1.2: derivation failures get a REASON that survives
    //
    // The ingest path carried 11 `try? await <persist>` sites. Each turned a
    // real database or extractor failure into silence: the row simply was not
    // there afterwards, indistinguishable from "there was nothing to write".
    // For a tool whose product is evidence that is the worst possible loss —
    // an examiner cannot tell "not in the container" from "failed to parse",
    // and a chunk missing an embedding reads identically to one not yet
    // drained.
    //
    // This table is where a tolerated failure goes. Stages that CORRUPT on
    // failure now propagate instead (see P1.1); stages that merely lose
    // something additive record here and carry on, so the Ingestion Report can
    // say what was lost and why rather than reporting a smaller number with no
    // explanation.
    //
    // `stage` is a producer id ("entities.insert", "evidence.linkBlocks",
    // "embeddings.upsert", "member.ingest"); `reason` is the error's
    // description, truncated at the writer. Both source_version_id and
    // knowledge_object_id are NULLABLE because some failures happen before
    // either exists. Derived + advisory: never sealed, never gates an answer.
    private static let v130: String = """
    CREATE TABLE IF NOT EXISTS derivation_failures (
        id                  TEXT PRIMARY KEY NOT NULL,
        source_version_id   TEXT,
        knowledge_object_id TEXT,
        file_path           TEXT,
        detected_type       TEXT,
        stage               TEXT NOT NULL,
        reason              TEXT NOT NULL,
        occurred_at         REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_derivation_failures_stage
        ON derivation_failures(stage);
    CREATE INDEX IF NOT EXISTS idx_derivation_failures_type
        ON derivation_failures(detected_type);
    CREATE INDEX IF NOT EXISTS idx_derivation_failures_sv
        ON derivation_failures(source_version_id);
    """

    // MARK: - v131 — P1.3: a KO's derivation is either COMPLETE or resumable
    //
    // processKnowledgeObject writes in sequence: knowledge_objects → chunks →
    // synthetic_questions → entities → events → relationships. The transaction
    // boundary across that sequence was UNKNOWN — recorded as unknown in
    // PIPELINE_WORKFLOW.md rather than assumed either way. The hazard it leaves
    // is specific: a process killed between chunks and entities leaves a KO
    // that LOOKS finished, is counted as finished, and is silently missing its
    // ledger. On a whole-archive re-ingest a mid-run kill is likely, not
    // hypothetical, and a partial KO that looks complete is invisible to the
    // Ingestion Report's counts while being wrong.
    //
    // WHY A MARKER AND NOT ONE BIG SAVEPOINT. The sequence interleaves database
    // writes with long-running async work (NER, event extraction, embedding).
    // Wrapping all of it in a single SQLite SAVEPOINT would hold a write
    // transaction open across model inference, blocking the embedding drain and
    // any concurrent read for the duration. So the choice is the second option
    // this project's own acceptance criteria allowed: an EXPLICITLY RESUMABLE
    // PARTIAL. `derivation_complete` is set only after the last stage returns;
    // anything NULL is a KO whose derivation did not finish, which
    // resumeIncompleteIngests can finish and the report can count separately
    // from "derived and empty".
    //
    // NULL for every pre-v131 row, which is honest: those KOs were derived
    // before the marker existed, so their completeness is genuinely unknown
    // rather than assumed. The backfill rides the drain, never a standalone
    // rewrite of the archive.
    private static let v131: String = """
    ALTER TABLE knowledge_objects ADD COLUMN derivation_complete INTEGER;
    CREATE INDEX IF NOT EXISTS idx_ko_derivation_complete
        ON knowledge_objects(derivation_complete);
    """

    // MARK: - v132 — P3.3: the induction ATTEMPT is the resume marker
    //
    // Schema induction (InducedSchemaExtractor) is the first and only writer in
    // this system whose output a model had a hand in, and therefore the first
    // that is not reproducible. That collides head-on with the drain's central
    // promise — "RESUME MARKER = producer_version itself: a second run is a
    // no-op by construction" — and with the Fixed-Point Law (U-5): running
    // everything twice must change nothing.
    //
    // It collides in a specific place. Induction runs only on documents with
    // ZERO facts, so a SUCCESSFUL induction is self-limiting: the facts it
    // writes make the document ineligible next time. The hole is the
    // UNSUCCESSFUL one. A document where the model proposed nothing verifiable
    // still has zero facts, so a second drain would call the model again — and
    // being non-deterministic, it might write on run 2 what it declined to
    // write on run 1. That is a fixed-point violation, and it would also pay
    // the model cost again on every drain, forever, for exactly the documents
    // where it has already failed.
    //
    // The fix is not to weaken the law but to give this pass the same kind of
    // marker every other pass has. One row per SOURCE VERSION says the attempt
    // happened; the pass skips any version already present. Keyed on the source
    // version, not the KO, because a NEW version of a file is genuinely new
    // content and deserves a fresh attempt — the same rule the rest of the
    // derivation layer follows.
    //
    // `decline_reason` is the point of the table beyond idempotence: it
    // separates "we tried and the model proposed nothing that could be found in
    // the document" from "we never tried" from "there was no model available".
    // Those are three different facts about a near-empty ledger and a bare row
    // count cannot tell them apart — the absence-as-verification defect this
    // whole program keeps closing. `rejected_*` keep the per-gate tallies, so a
    // model that has started fabricating is visible as a rise in
    // `rejected_not_found` rather than as a vague drop in yield.
    //
    // Derived + advisory: never sealed, never gates an answer. Dropping this
    // table costs only the memory of what was attempted.
    private static let v132: String = """
    CREATE TABLE IF NOT EXISTS induced_schema_attempts (
        source_version_id   TEXT PRIMARY KEY NOT NULL,
        knowledge_object_id TEXT,
        attempted_at        REAL NOT NULL,
        fields_written      INTEGER NOT NULL DEFAULT 0,
        decline_reason      TEXT,
        rejected_not_found  INTEGER NOT NULL DEFAULT 0,
        rejected_reserved   INTEGER NOT NULL DEFAULT 0,
        rejected_other      INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_induced_attempts_ko
        ON induced_schema_attempts(knowledge_object_id);
    CREATE INDEX IF NOT EXISTS idx_induced_attempts_written
        ON induced_schema_attempts(fields_written);
    """

    // MARK: - v133 — L1 chunk packing: a retrieval chunk's FULL block lineage
    //
    // The block-derived chunker emitted one chunk per EvidenceBlock; many
    // parsers make a block per LINE, so 36% of the owner's chunks were under
    // 40 characters ("Cell : 9960270472") and the composer quoted fragments.
    // Adjacent small blocks now pack into one chunk up to the size budget.
    // `chunks.evidence_block_id` keeps the chunk's FIRST block (every existing
    // consumer keeps working and the projection invariant still holds); this
    // table records EVERY block a chunk was assembled from, so a citation can
    // resolve to the exact block rather than the group's first line.
    // Derived rows: they follow their chunk (ON DELETE CASCADE).
    private static let v133: String = """
    CREATE TABLE IF NOT EXISTS chunk_blocks (
        chunk_id          TEXT NOT NULL,
        evidence_block_id TEXT NOT NULL,
        ordinal           INTEGER NOT NULL,
        PRIMARY KEY (chunk_id, evidence_block_id),
        FOREIGN KEY (chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_chunk_blocks_block ON chunk_blocks(evidence_block_id);
    """


    // MARK: - v134 — F15 evidence fingerprint on readiness records
    //
    // Readiness was trusted as recorded: completion compared COUNTS, so replacing one derivation
    // with another (same total) or losing blocks behind a "ready" record went unseen. Each readiness
    // dimension now records the fingerprint of the version's derived evidence it was measured
    // against — aggregates over its chunks, blocks and block ownership (count, rowid sum/max, text
    // length, distinct owners). Reconciliation re-measures a dimension only when the live
    // fingerprint differs. Computed at readiness-write time, NOT maintained by row triggers: a
    // trigger per chunk insert measured +43% ingest time on a 3,000-message mailbox.
    // NULL = recorded before v134 (unknown → always re-checked).
    private static let v134: String = """
    ALTER TABLE source_readiness_dimensions ADD COLUMN evidence_fingerprint TEXT;
    """

    // MARK: - v135 — F16 versioned structural derivations
    //
    // Committed structure was attach-once: a newer parser whose output differed could never be
    // activated, so reprocessing left the version stale forever. A version's blocks now form
    // derivations. `superseded_by_run` is NULL for the ACTIVE derivation; activating a new parser's
    // output stamps the old blocks with the parser_runs id that replaced them, in the same savepoint
    // that inserts the new ones. Superseded blocks are never deleted — citations that name them keep
    // resolving by id — but version-scoped reads (structure, search, readiness) see only the active set.
    private static let v135: String = """
    ALTER TABLE evidence_blocks ADD COLUMN superseded_by_run TEXT;
    CREATE INDEX IF NOT EXISTS idx_blocks_version_active ON evidence_blocks(source_version_id) WHERE superseded_by_run IS NULL;
    """

    // MARK: - v136 — F03 SQLite acquisitions that did not preserve their WAL
    //
    // Before the logical-derivative acquisition, a live WAL database was versioned by its MAIN
    // file's hash and only the main file reached the vault; its receipt recorded the WAL as a
    // sidecar. Those versions' committed WAL rows cannot be reopened. They are marked, not rewritten:
    // their historical evidence stays as it is, and reopening/reprocessing refuses them explicitly
    // (`acquisitionIncomplete`) instead of re-reading main-file bytes under the version's identity.
    // A fresh ingest of the database acquires it completely as a new version.
    private static let v136: String = """
    ALTER TABLE source_versions ADD COLUMN acquisition_limitation TEXT;
    UPDATE source_versions SET acquisition_limitation = 'walNotPreserved'
     WHERE id IN (SELECT source_version_id FROM source_intake_receipts WHERE detail LIKE '%"sqliteSidecars"%');
    """

    // MARK: - v137 — F15 genuine evidence revisions
    //
    // v134's fingerprint (counts, rowid sums, text lengths, distinct owners) was not a revision: an
    // equal-length text or locator change, or an ownership swap preserving owner counts, left it
    // unchanged, so a stale readiness proof stayed "current". Each source version now carries a
    // monotonically increasing revision per evidence LANE — chunks, blocks, ownership — bumped
    // transactionally by triggers on every insert, delete and material update (including the F16
    // active-generation switch, an UPDATE of superseded_by_run, and FK-cascade deletes). A readiness
    // dimension records the revisions of the lanes it depends on; reconciliation re-verifies it only
    // when one moved. Absent row = revision 0. Old v134 fingerprints never equal the new tokens, so
    // every migrated proof is revalidated once. Cost is one indexed upsert per evidence row write.
    private static let v137: String = """
    CREATE TABLE IF NOT EXISTS evidence_revisions (
        source_version_id TEXT NOT NULL,
        lane              TEXT NOT NULL,
        revision          INTEGER NOT NULL,
        PRIMARY KEY (source_version_id, lane)
    ) WITHOUT ROWID;
    CREATE TRIGGER IF NOT EXISTS evrev_chunks_ins AFTER INSERT ON chunks WHEN NEW.source_version_id IS NOT NULL BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) VALUES (NEW.source_version_id, 'chunks', 1) ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_chunks_del AFTER DELETE ON chunks WHEN OLD.source_version_id IS NOT NULL BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) VALUES (OLD.source_version_id, 'chunks', 1) ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_chunks_upd AFTER UPDATE OF text, object_id, source_version_id, evidence_block_id ON chunks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT OLD.source_version_id, 'chunks', 1 WHERE OLD.source_version_id IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT NEW.source_version_id, 'chunks', 1 WHERE NEW.source_version_id IS NOT NULL AND NEW.source_version_id IS NOT OLD.source_version_id ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_blocks_ins AFTER INSERT ON evidence_blocks WHEN NEW.source_version_id IS NOT NULL BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) VALUES (NEW.source_version_id, 'blocks', 1) ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_blocks_del AFTER DELETE ON evidence_blocks WHEN OLD.source_version_id IS NOT NULL BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) VALUES (OLD.source_version_id, 'blocks', 1) ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_blocks_upd AFTER UPDATE OF raw_text, normalized_text, locator, kind, attributes, ordinal, parent_block_id, extraction_method, source_version_id, superseded_by_run ON evidence_blocks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT OLD.source_version_id, 'blocks', 1 WHERE OLD.source_version_id IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT NEW.source_version_id, 'blocks', 1 WHERE NEW.source_version_id IS NOT NULL AND NEW.source_version_id IS NOT OLD.source_version_id ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_owner_ins AFTER INSERT ON evidence_block_objects BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM evidence_blocks WHERE id = NEW.evidence_block_id), 'ownership', 1 WHERE (SELECT source_version_id FROM evidence_blocks WHERE id = NEW.evidence_block_id) IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_owner_del AFTER DELETE ON evidence_block_objects BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM evidence_blocks WHERE id = OLD.evidence_block_id), 'ownership', 1 WHERE (SELECT source_version_id FROM evidence_blocks WHERE id = OLD.evidence_block_id) IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_owner_upd AFTER UPDATE ON evidence_block_objects BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM evidence_blocks WHERE id = OLD.evidence_block_id), 'ownership', 1 WHERE (SELECT source_version_id FROM evidence_blocks WHERE id = OLD.evidence_block_id) IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM evidence_blocks WHERE id = NEW.evidence_block_id), 'ownership', 1 WHERE (SELECT source_version_id FROM evidence_blocks WHERE id = NEW.evidence_block_id) IS NOT NULL AND NEW.evidence_block_id IS NOT OLD.evidence_block_id ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    """

    // MARK: - v138 — F16/F25 search chunks follow the active derivation
    //
    // Activating a changed derivation superseded its blocks but left the old derivation's chunks and
    // vectors serving as current search output. Chunks now carry `superseded_by_run` like blocks: the
    // index switch stamps the replaced chunks (their rows stay — a historical claim may cite a chunk
    // id) and a superseded chunk leaves the FTS index (the update trigger re-inserts only an active
    // chunk). Current-output reads filter it; by-id citation reads do not. The chunk revision trigger
    // now also counts this column, so a switch moves the chunks lane.
    private static let v138: String = """
    ALTER TABLE chunks ADD COLUMN superseded_by_run TEXT;
    CREATE INDEX IF NOT EXISTS idx_chunks_version_active ON chunks(source_version_id, object_id) WHERE superseded_by_run IS NULL;
    DROP TRIGGER IF EXISTS chunks_fts_au;
    CREATE TRIGGER chunks_fts_au AFTER UPDATE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) SELECT 'delete', old.rowid, old.text WHERE old.superseded_by_run IS NULL;
        INSERT INTO chunks_fts(rowid, text) SELECT new.rowid, new.text WHERE new.superseded_by_run IS NULL;
    END;
    DROP TRIGGER IF EXISTS chunks_fts_ad;
    CREATE TRIGGER chunks_fts_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text) SELECT 'delete', old.rowid, old.text WHERE old.superseded_by_run IS NULL;
    END;
    DROP TRIGGER IF EXISTS evrev_chunks_upd;
    CREATE TRIGGER evrev_chunks_upd AFTER UPDATE OF text, object_id, source_version_id, evidence_block_id, superseded_by_run ON chunks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT OLD.source_version_id, 'chunks', 1 WHERE OLD.source_version_id IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT NEW.source_version_id, 'chunks', 1 WHERE NEW.source_version_id IS NOT NULL AND NEW.source_version_id IS NOT OLD.source_version_id ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    """

    // MARK: - v139 — F01/F15 durable outcome for every streamed record
    //
    // The streaming ingest caught a failing record, logged it and continued; readiness then measured
    // the surviving chunks, so a lost record disappeared behind "ready". Each record of a streamed
    // version now has a row keyed by its position in the (immutable) acquired stream: `attempting`
    // before its writes, `committed` after them, `failed` with the reason otherwise. The row also
    // carries the object id of the attempt (so a half-written attempt can be rolled back before a
    // retry — never duplicated) and the record's ownership keys (so block ownership is linked from
    // durable rows, not an in-memory list that grows with the file).
    private static let v139: String = """
    CREATE TABLE IF NOT EXISTS stream_record_outcomes (
        source_version_id TEXT NOT NULL,
        position          INTEGER NOT NULL,
        state             TEXT NOT NULL CHECK (state IN ('attempting', 'committed', 'failed')),
        object_id         TEXT,
        ownership_keys    TEXT,
        reason            TEXT,
        attempts          INTEGER NOT NULL DEFAULT 0,
        updated_at        REAL NOT NULL,
        PRIMARY KEY (source_version_id, position)
    ) WITHOUT ROWID;
    """

    // MARK: - v140 — F04 durable continuation cursor per scope of a resumable stream
    //
    // SQLite ingest stopped each table at a hard 500,000-row cap (and cited only the first 5,000 rows),
    // so a larger table was never complete. A run now stops at a WORK budget instead and records, per
    // table (scope) of the EXACT source version, the serialized keyset cursor it reached, the rows it
    // processed and the rows it discovered. The cursor advances in the same savepoint that commits the
    // record, so it never runs ahead of committed evidence; a later run resumes from it over the same
    // immutable acquired bytes. Deferred = discovered − processed, reported, never hidden.
    private static let v140: String = """
    CREATE TABLE IF NOT EXISTS stream_cursors (
        source_version_id TEXT NOT NULL,
        scope             TEXT NOT NULL,
        scope_index       INTEGER NOT NULL,
        cursor            TEXT,
        processed         INTEGER NOT NULL DEFAULT 0,
        discovered        INTEGER,
        updated_at        REAL NOT NULL,
        PRIMARY KEY (source_version_id, scope)
    ) WITHOUT ROWID;
    """

    // MARK: - v141 — F15 citation lineage and every material block field move the evidence revision
    //
    // v137 counted chunks, blocks and ownership but not `chunk_blocks` — the lineage that says which
    // blocks a chunk was assembled from (and therefore what a citation resolves to). Deleting, moving or
    // re-ordering lineage left every revision unchanged, so the readiness fast path skipped reconciling a
    // version whose citations had changed. A fourth lane, `lineage`, now moves on every insert, delete
    // and update of `chunk_blocks`, resolved to the source version THROUGH the chunk (a move between
    // chunks of different versions moves both). A lineage row deleted by the cascade of its chunk can no
    // longer resolve that chunk — the chunk's own delete trigger has already moved the `chunks` lane,
    // which every lineage-dependent dimension also depends on. The block update trigger now also covers
    // `language`, `extraction_confidence` and `document_id`.
    //
    // `chunks.derivation_digest` (F15/F25) binds each chunk to what it was derived from — chunker
    // version, its text and, in lineage order, each block's id, kind and text — so reconciliation can
    // tell derived output that no longer matches its evidence from output that merely has the right
    // counts. NULL for rows written before v141 (a first reconciliation records their baseline).
    private static let v141: String = """
    ALTER TABLE chunks ADD COLUMN derivation_digest TEXT;
    CREATE TRIGGER IF NOT EXISTS evrev_lineage_ins AFTER INSERT ON chunk_blocks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM chunks WHERE id = NEW.chunk_id), 'lineage', 1 WHERE (SELECT source_version_id FROM chunks WHERE id = NEW.chunk_id) IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_lineage_del AFTER DELETE ON chunk_blocks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM chunks WHERE id = OLD.chunk_id), 'lineage', 1 WHERE (SELECT source_version_id FROM chunks WHERE id = OLD.chunk_id) IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    CREATE TRIGGER IF NOT EXISTS evrev_lineage_upd AFTER UPDATE ON chunk_blocks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM chunks WHERE id = OLD.chunk_id), 'lineage', 1 WHERE (SELECT source_version_id FROM chunks WHERE id = OLD.chunk_id) IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT (SELECT source_version_id FROM chunks WHERE id = NEW.chunk_id), 'lineage', 1 WHERE (SELECT source_version_id FROM chunks WHERE id = NEW.chunk_id) IS NOT NULL AND (SELECT source_version_id FROM chunks WHERE id = NEW.chunk_id) IS NOT (SELECT source_version_id FROM chunks WHERE id = OLD.chunk_id) ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    DROP TRIGGER IF EXISTS evrev_blocks_upd;
    CREATE TRIGGER evrev_blocks_upd AFTER UPDATE OF raw_text, normalized_text, locator, kind, attributes, ordinal, parent_block_id, extraction_method, extraction_confidence, language, document_id, source_version_id, superseded_by_run ON evidence_blocks BEGIN INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT OLD.source_version_id, 'blocks', 1 WHERE OLD.source_version_id IS NOT NULL ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; INSERT INTO evidence_revisions (source_version_id, lane, revision) SELECT NEW.source_version_id, 'blocks', 1 WHERE NEW.source_version_id IS NOT NULL AND NEW.source_version_id IS NOT OLD.source_version_id ON CONFLICT (source_version_id, lane) DO UPDATE SET revision = revision + 1; END;
    """


    // MARK: - v142 — W1-4 user tags (beat-DEVONthink plan)
    //
    // Tags are the user's own organisation: they never change what the evidence says.
    // Nothing here is ever deleted (owner rule): untagging stamps `removed_at`, re-tagging
    // clears it; merging re-points links and stamps the old tag `retired_at`.
    private static let v142: String = """
    CREATE TABLE IF NOT EXISTS user_tags (
        id          TEXT PRIMARY KEY NOT NULL,
        name        TEXT NOT NULL COLLATE NOCASE,
        color       TEXT,
        created_at  REAL NOT NULL,
        retired_at  REAL,
        merged_into TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_tags_live_name ON user_tags(name) WHERE retired_at IS NULL;
    CREATE TABLE IF NOT EXISTS user_tag_links (
        tag_id       TEXT NOT NULL,
        subject_kind TEXT NOT NULL CHECK (subject_kind IN ('object','fact','entity','event','chunk')),
        subject_id   TEXT NOT NULL,
        created_at   REAL NOT NULL,
        removed_at   REAL,
        PRIMARY KEY (tag_id, subject_kind, subject_id),
        FOREIGN KEY (tag_id) REFERENCES user_tags(id)
    );
    CREATE INDEX IF NOT EXISTS idx_user_tag_links_subject ON user_tag_links(subject_kind, subject_id);
    """


    // MARK: - v143 — O-5 outbound log (Online mode)
    //
    // Every online send is recorded: when, to which provider/host/model, how many
    // bytes, how many personal details were masked, the SHA-256 of exactly what
    // was sent (and the text itself, which is the user's own data on their own
    // Mac), and the outcome. Append-only; nothing here is ever deleted.
    private static let v143: String = """
    CREATE TABLE IF NOT EXISTS outbound_log (
        id             TEXT PRIMARY KEY NOT NULL,
        sent_at        REAL NOT NULL,
        provider       TEXT NOT NULL,
        model          TEXT NOT NULL,
        host           TEXT NOT NULL,
        bytes_sent     INTEGER NOT NULL,
        masked_count   INTEGER NOT NULL DEFAULT 0,
        payload_sha256 TEXT NOT NULL,
        payload_text   TEXT NOT NULL,
        response_bytes INTEGER,
        outcome        TEXT NOT NULL,
        detail         TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_outbound_log_sent ON outbound_log(sent_at);
    """


    // MARK: - v144 — beat-DEVONthink plan: watchlists (N-3), question monitors (N-11),
    // issues (N-1), review coding (N-4), custom record types (N-12), alerts (W3-4).
    //
    // All user organisation or derived signals: none changes evidence status. Nothing is
    // deleted (owner rule): removals stamp removed_at / retired_at.
    private static let v144: String = """
    CREATE TABLE IF NOT EXISTS watchlists (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, created_at REAL NOT NULL, retired_at REAL
    );
    CREATE TABLE IF NOT EXISTS watchlist_entries (
        id TEXT PRIMARY KEY NOT NULL, watchlist_id TEXT NOT NULL, term TEXT NOT NULL,
        note TEXT, created_at REAL NOT NULL, removed_at REAL,
        FOREIGN KEY (watchlist_id) REFERENCES watchlists(id)
    );
    CREATE INDEX IF NOT EXISTS idx_watchlist_entries_list ON watchlist_entries(watchlist_id);
    CREATE TABLE IF NOT EXISTS pinned_questions (
        id TEXT PRIMARY KEY NOT NULL, question TEXT NOT NULL, created_at REAL NOT NULL,
        last_checked_at REAL, last_answer_text TEXT, last_answer_fingerprint TEXT,
        last_citation_ids TEXT, last_contradictions INTEGER, retired_at REAL
    );
    CREATE TABLE IF NOT EXISTS case_issues (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL COLLATE NOCASE, description TEXT,
        created_at REAL NOT NULL, retired_at REAL
    );
    CREATE TABLE IF NOT EXISTS case_issue_links (
        issue_id TEXT NOT NULL, subject_kind TEXT NOT NULL CHECK (subject_kind IN ('event','fact','object','chunk')),
        subject_id TEXT NOT NULL, created_at REAL NOT NULL, removed_at REAL,
        PRIMARY KEY (issue_id, subject_kind, subject_id),
        FOREIGN KEY (issue_id) REFERENCES case_issues(id)
    );
    CREATE TABLE IF NOT EXISTS review_codes (
        id TEXT PRIMARY KEY NOT NULL, object_id TEXT NOT NULL,
        code TEXT NOT NULL CHECK (code IN ('responsive','not_responsive','privileged','hot')),
        reviewer TEXT NOT NULL, coded_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_review_codes_object ON review_codes(object_id);
    CREATE TABLE IF NOT EXISTS custom_record_types (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, fields_json TEXT NOT NULL,
        created_at REAL NOT NULL, retired_at REAL
    );
    CREATE TABLE IF NOT EXISTS product_alerts (
        id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, detail TEXT,
        object_id TEXT, created_at REAL NOT NULL, read_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_product_alerts_created ON product_alerts(created_at);
    """


    // MARK: - v145 — beat-DEVONthink plan: annotations (W2-1), near-duplicate groups (W2-4),
    // legal holds and Bates runs (W2-5), smart collections and rules (W3-5).
    //
    // User work product and derived links only — none changes evidence. Nothing is deleted:
    // removals stamp removed_at / released_at / retired_at.
    private static let v145: String = """
    CREATE TABLE IF NOT EXISTS annotations (
        id TEXT PRIMARY KEY NOT NULL, object_id TEXT NOT NULL, chunk_id TEXT,
        source_url TEXT, quote TEXT NOT NULL, note TEXT, color TEXT NOT NULL DEFAULT 'yellow',
        stance TEXT NOT NULL DEFAULT 'note', created_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_annotations_object ON annotations(object_id);
    CREATE INDEX IF NOT EXISTS idx_annotations_source ON annotations(source_url);
    CREATE TABLE IF NOT EXISTS near_duplicate_members (
        object_id TEXT PRIMARY KEY NOT NULL, group_id TEXT NOT NULL,
        similarity REAL NOT NULL, computed_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_near_dup_group ON near_duplicate_members(group_id);
    CREATE TABLE IF NOT EXISTS legal_holds (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, created_at REAL NOT NULL, released_at REAL
    );
    CREATE TABLE IF NOT EXISTS legal_hold_items (
        hold_id TEXT NOT NULL, object_id TEXT NOT NULL, created_at REAL NOT NULL, removed_at REAL,
        PRIMARY KEY (hold_id, object_id), FOREIGN KEY (hold_id) REFERENCES legal_holds(id)
    );
    CREATE TABLE IF NOT EXISTS bates_runs (
        id TEXT PRIMARY KEY NOT NULL, prefix TEXT NOT NULL, first_number INTEGER NOT NULL,
        last_number INTEGER NOT NULL, documents INTEGER NOT NULL, created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS smart_collections (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, query TEXT NOT NULL,
        created_at REAL NOT NULL, retired_at REAL
    );
    CREATE TABLE IF NOT EXISTS automation_rules (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, query TEXT NOT NULL,
        action TEXT NOT NULL CHECK (action IN ('tag','alert')), action_value TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1, created_at REAL NOT NULL, retired_at REAL
    );
    """

    // MARK: - v146 — note links (N-9): links between notes from notes apps (Obsidian
    // [[wiki-links]], Notion page links). Derived from the notes' own text; a re-run
    // stamps removed_at on links that no longer exist. Nothing is deleted.
    private static let v146: String = """
    CREATE TABLE IF NOT EXISTS note_links (
        id TEXT PRIMARY KEY NOT NULL, from_object_id TEXT NOT NULL, to_object_id TEXT,
        target TEXT NOT NULL, kind TEXT NOT NULL, created_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_note_links_from ON note_links(from_object_id);
    CREATE INDEX IF NOT EXISTS idx_note_links_to ON note_links(to_object_id);
    """


    // MARK: - v147 — X-2 your own folders: groups (a tree) and their members. A document
    // may sit in several groups at once (a replicant: one document, many places). User
    // organisation only — never changes evidence. Nothing is deleted: removing a member
    // stamps removed_at; retiring a group stamps retired_at and leaves its members restorable.
    private static let v147: String = """
    CREATE TABLE IF NOT EXISTS user_groups (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, parent_id TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, retired_at REAL,
        source_path TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_user_groups_parent ON user_groups(parent_id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_user_groups_live_name
        ON user_groups(COALESCE(parent_id, ''), name COLLATE NOCASE) WHERE retired_at IS NULL;
    CREATE TABLE IF NOT EXISTS user_group_members (
        group_id TEXT NOT NULL, object_id TEXT NOT NULL, added_at REAL NOT NULL, removed_at REAL,
        PRIMARY KEY (group_id, object_id), FOREIGN KEY (group_id) REFERENCES user_groups(id)
    );
    CREATE INDEX IF NOT EXISTS idx_user_group_members_object ON user_group_members(object_id);
    """


    // MARK: - v148 — X-1 document vectors for See Also and filing suggestions: the mean of a
    // document's live chunk embeddings for one embedding model, cached with the signature of
    // the chunk set it was built from (count + newest embedding time) so a changed document
    // is rebuilt. Derived and disposable; never evidence.
    private static let v148: String = """
    CREATE TABLE IF NOT EXISTS document_vectors (
        object_id TEXT NOT NULL, model_id TEXT NOT NULL, dims INTEGER NOT NULL,
        vector BLOB NOT NULL, chunk_count INTEGER NOT NULL, signature TEXT NOT NULL,
        computed_at REAL NOT NULL,
        PRIMARY KEY (object_id, model_id)
    );
    """


    // MARK: - v149 — X-3 marks on PDFs (highlight, underline, strike-out, note), kept in the
    // ledger beside the PDF — the original file is never written. Rectangles are in PDF page
    // space, one per line of the marked text. A text mark also has a W2-1 annotation
    // (annotation_id) so it shows in Highlights; removing the mark removes both (stamps).
    private static let v149: String = """
    CREATE TABLE IF NOT EXISTS pdf_marks (
        id TEXT PRIMARY KEY NOT NULL, object_id TEXT NOT NULL, page INTEGER NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('highlight','underline','strikeout','note')),
        rects_json TEXT NOT NULL, color TEXT NOT NULL DEFAULT 'yellow', quote TEXT, contents TEXT,
        annotation_id TEXT, created_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_pdf_marks_object ON pdf_marks(object_id);
    """


    // MARK: - v150 — X-5 sync through a folder. Bookkeeping only: which of the person's own
    // rows changed since the last sync (filled by triggers on the user-organisation tables —
    // never on evidence tables), the clock that last set each synced field, where each other
    // device's changes were read up to, changes waiting for a document that is not here yet,
    // conflicts shown to the person, and batches that failed verification. Each field's clock
    // keeps the value last synced, so a change made here and not yet sent is recognised (and
    // kept) when another device's older-or-newer change to the same field arrives. The triggers stay
    // silent while a sync is applying another device's changes (sync_state 'applying').
    private static let v150: String = """
    CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY NOT NULL, value TEXT);
    CREATE TABLE IF NOT EXISTS sync_dirty (
        tbl TEXT NOT NULL, row_key TEXT NOT NULL, changed_at REAL NOT NULL, PRIMARY KEY (tbl, row_key)
    );
    CREATE TABLE IF NOT EXISTS sync_field_clocks (
        tbl TEXT NOT NULL, row_key TEXT NOT NULL, field TEXT NOT NULL, lamport INTEGER NOT NULL, device TEXT NOT NULL,
        synced_value TEXT,
        PRIMARY KEY (tbl, row_key, field)
    );
    CREATE TABLE IF NOT EXISTS sync_pending (
        id TEXT PRIMARY KEY NOT NULL, op_json TEXT NOT NULL, reason TEXT NOT NULL,
        first_seen REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, applied_at REAL
    );
    CREATE TABLE IF NOT EXISTS sync_conflicts (
        id TEXT PRIMARY KEY NOT NULL, tbl TEXT NOT NULL, row_key TEXT NOT NULL, field TEXT NOT NULL,
        kept_value TEXT, other_value TEXT, other_device TEXT NOT NULL, detected_at REAL NOT NULL, resolved_at REAL
    );
    CREATE TABLE IF NOT EXISTS sync_quarantine (
        device TEXT NOT NULL, seq INTEGER NOT NULL, reason TEXT NOT NULL, seen_at REAL NOT NULL,
        PRIMARY KEY (device, seq)
    );
    CREATE TABLE IF NOT EXISTS sync_files (
        kind TEXT NOT NULL, name TEXT NOT NULL, sha256 TEXT NOT NULL, lamport INTEGER NOT NULL, device TEXT NOT NULL,
        trashed INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (kind, name)
    );
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_tags_ins AFTER INSERT ON user_tags
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_tags', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_tags_upd AFTER UPDATE ON user_tags
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_tags', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_tag_links_ins AFTER INSERT ON user_tag_links
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_tag_links', NEW.tag_id || '|' || NEW.subject_kind || '|' || NEW.subject_id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_tag_links_upd AFTER UPDATE ON user_tag_links
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_tag_links', NEW.tag_id || '|' || NEW.subject_kind || '|' || NEW.subject_id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_groups_ins AFTER INSERT ON user_groups
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_groups', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_groups_upd AFTER UPDATE ON user_groups
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_groups', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_group_members_ins AFTER INSERT ON user_group_members
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_group_members', NEW.group_id || '|' || NEW.object_id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_user_group_members_upd AFTER UPDATE ON user_group_members
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('user_group_members', NEW.group_id || '|' || NEW.object_id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_annotations_ins AFTER INSERT ON annotations
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('annotations', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_annotations_upd AFTER UPDATE ON annotations
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('annotations', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_pdf_marks_ins AFTER INSERT ON pdf_marks
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('pdf_marks', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_pdf_marks_upd AFTER UPDATE ON pdf_marks
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('pdf_marks', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_smart_collections_ins AFTER INSERT ON smart_collections
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('smart_collections', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_smart_collections_upd AFTER UPDATE ON smart_collections
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('smart_collections', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_automation_rules_ins AFTER INSERT ON automation_rules
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('automation_rules', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_automation_rules_upd AFTER UPDATE ON automation_rules
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('automation_rules', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_review_codes_ins AFTER INSERT ON review_codes
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('review_codes', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_review_codes_upd AFTER UPDATE ON review_codes
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('review_codes', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_watchlists_ins AFTER INSERT ON watchlists
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('watchlists', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_watchlists_upd AFTER UPDATE ON watchlists
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('watchlists', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_watchlist_entries_ins AFTER INSERT ON watchlist_entries
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('watchlist_entries', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_watchlist_entries_upd AFTER UPDATE ON watchlist_entries
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('watchlist_entries', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_pinned_questions_ins AFTER INSERT ON pinned_questions
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('pinned_questions', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_pinned_questions_upd AFTER UPDATE ON pinned_questions
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('pinned_questions', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_case_issues_ins AFTER INSERT ON case_issues
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('case_issues', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_case_issues_upd AFTER UPDATE ON case_issues
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('case_issues', NEW.id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_case_issue_links_ins AFTER INSERT ON case_issue_links
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('case_issue_links', NEW.issue_id || '|' || NEW.subject_kind || '|' || NEW.subject_id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    CREATE TRIGGER IF NOT EXISTS sync_dirty_case_issue_links_upd AFTER UPDATE ON case_issue_links
    WHEN (SELECT value FROM sync_state WHERE key = 'applying') IS NULL
    BEGIN INSERT INTO sync_dirty (tbl, row_key, changed_at) VALUES ('case_issue_links', NEW.issue_id || '|' || NEW.subject_kind || '|' || NEW.subject_id, (julianday('now') - 2440587.5) * 86400.0)
          ON CONFLICT (tbl, row_key) DO UPDATE SET changed_at = excluded.changed_at; END;
    """


    // MARK: - v151 — Investigations Made Easy: the case file around an InvestigationCase. Everything an
    // investigation needs from intake to closure that is the INVESTIGATOR'S record (not evidence):
    // intake + triage + stage + owner/team + plan + retention on case_profiles; allegations with their
    // evidence grid and dispositions; links to the ONE task engine (professional_tasks) — tasks and their
    // deadlines are never forked here; the journal and manual chronology entries; people (subjects,
    // witnesses, complainants, custodians) with a contact log; interviews from plan to attested statement
    // with structured credibility factors; the exhibit register; legal-hold notices per custodian; the
    // redaction log; review batches with QC; conflict-of-interest checks; and an append-only action log.
    // Evidence is referenced by id (source_ref / evidence_ref), never copied. Nothing here deletes
    // anything: retention marks a case for review; erasure stays the existing, confirmed path.
    private static let v151: String = """
    CREATE TABLE IF NOT EXISTS case_profiles (
        case_id TEXT PRIMARY KEY NOT NULL, kind TEXT,
        stage TEXT NOT NULL DEFAULT 'intake' CHECK (stage IN ('intake','triage','open','inProgress','onHold','findings','closed','declined','referred')),
        severity TEXT CHECK (severity IS NULL OR severity IN ('low','medium','high','critical')),
        risk_note TEXT, triage_decision TEXT CHECK (triage_decision IS NULL OR triage_decision IN ('accept','decline','refer')),
        triage_reason TEXT, triage_by TEXT, triage_at REAL,
        owner TEXT, team_json TEXT NOT NULL DEFAULT '[]', reviewer TEXT,
        received_at REAL, channel TEXT, anonymous INTEGER NOT NULL DEFAULT 0, complainant TEXT, complainant_contact TEXT,
        allegation_summary TEXT, incident_date TEXT, incident_location TEXT, people_named TEXT,
        plan_method TEXT, plan_evidence TEXT, plan_interviews TEXT, plan_notes TEXT,
        retention_policy TEXT, retain_until REAL, archived_at REAL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_allegations (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, sequence INTEGER NOT NULL, text TEXT NOT NULL,
        disposition TEXT NOT NULL DEFAULT 'pending' CHECK (disposition IN ('pending','substantiated','unsubstantiated','inconclusive','withdrawn')),
        rationale TEXT, decided_by TEXT, decided_at REAL, created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_allegations_case ON case_allegations(case_id, sequence);
    CREATE TABLE IF NOT EXISTS case_allegation_evidence (
        id TEXT PRIMARY KEY NOT NULL, allegation_id TEXT NOT NULL, evidence_ref TEXT NOT NULL, label TEXT,
        stance TEXT NOT NULL CHECK (stance IN ('supports','contradicts','neutral')), note TEXT,
        added_by TEXT NOT NULL, created_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_case_allegation_evidence ON case_allegation_evidence(allegation_id);
    CREATE TABLE IF NOT EXISTS case_task_links (
        case_id TEXT NOT NULL, task_id TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY (case_id, task_id)
    );
    CREATE TABLE IF NOT EXISTS case_journal (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL,
        entry_kind TEXT NOT NULL CHECK (entry_kind IN ('note','chronology')),
        event_date REAL, text TEXT NOT NULL, evidence_ref TEXT, author TEXT NOT NULL, created_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_case_journal_case ON case_journal(case_id, created_at);
    CREATE TABLE IF NOT EXISTS case_people (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, name TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('subject','witness','complainant','custodian','other')),
        entity_id TEXT, contact TEXT, notes TEXT, created_at REAL NOT NULL, removed_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_case_people_case ON case_people(case_id);
    CREATE TABLE IF NOT EXISTS case_contacts (
        id TEXT PRIMARY KEY NOT NULL, person_id TEXT NOT NULL, at REAL NOT NULL, mode TEXT NOT NULL, note TEXT,
        by TEXT NOT NULL, created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_interviews (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, person_id TEXT,
        status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','scheduled','held','summarised','attested','cancelled')),
        scheduled_at REAL, mode TEXT, location TEXT, questions TEXT, recording_ref TEXT, transcript_ref TEXT,
        summary TEXT, statement_text TEXT, attested_by TEXT, attested_at REAL, statement_sha256 TEXT,
        created_at REAL NOT NULL, updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_interviews_case ON case_interviews(case_id);
    CREATE TABLE IF NOT EXISTS case_credibility (
        id TEXT PRIMARY KEY NOT NULL, interview_id TEXT NOT NULL,
        factor TEXT NOT NULL CHECK (factor IN ('consistency','corroboration','plausibility','motive','demeanour')),
        assessment TEXT NOT NULL CHECK (assessment IN ('supports','neutral','undermines')),
        note TEXT, evidence_ref TEXT, by TEXT NOT NULL, created_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_exhibits (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, number TEXT NOT NULL, description TEXT NOT NULL,
        source_ref TEXT, sha256 TEXT, collected_by TEXT, collected_at REAL, collected_where TEXT,
        created_at REAL NOT NULL, withdrawn_at REAL, UNIQUE (case_id, number)
    );
    CREATE TABLE IF NOT EXISTS case_hold_notices (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, custodian TEXT NOT NULL, person_id TEXT,
        notice_text TEXT NOT NULL, issued_at REAL NOT NULL, issued_by TEXT NOT NULL,
        acknowledged_at REAL, reminder_due REAL, released_at REAL, release_reason TEXT
    );
    CREATE TABLE IF NOT EXISTS case_redaction_log (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, source_ref TEXT NOT NULL, location TEXT NOT NULL,
        reason TEXT NOT NULL, redacted_by TEXT NOT NULL, at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_review_batches (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, name TEXT NOT NULL, reviewer TEXT,
        source_refs_json TEXT NOT NULL DEFAULT '[]',
        status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','firstPassDone','qcDone')),
        qc_reviewer TEXT, qc_note TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_conflict_checks (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, investigator TEXT NOT NULL,
        result TEXT NOT NULL CHECK (result IN ('clear','conflict','waived')), matched TEXT, note TEXT,
        checked_by TEXT NOT NULL, checked_at REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_actions (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, sequence INTEGER NOT NULL, actor TEXT NOT NULL,
        action TEXT NOT NULL, detail TEXT, at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_actions_case ON case_actions(case_id, sequence);
    """

    // MARK: - v152 — A-6 Competing hypotheses (ACH) in the ledger. The matrix used to live in one
    // @AppStorage JSON blob; it is now four tables: the analysis (question, assumptions, indicators,
    // the analyst's written conclusion), its hypotheses (columns), its evidence rows, and the
    // consistency cells. Scoped by an optional case (investigation_cases.id) or workspace. Every row
    // carries who/when; nothing is deleted — removing a hypothesis, an evidence row or a whole
    // analysis sets retracted_at/retracted_by and the row stays in the record. Cells are keyed by
    // (evidence, hypothesis) and updated in place (a rating is the analyst's current judgement).
    // ach_legacy_imports records the one-time import of the old AppStorage blob (the blob itself
    // is left untouched in UserDefaults).
    private static let v152: String = """
    CREATE TABLE IF NOT EXISTS ach_analyses (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT, workspace_id TEXT,
        title TEXT NOT NULL, question TEXT NOT NULL DEFAULT '',
        assumptions_json TEXT NOT NULL DEFAULT '[]', indicators_json TEXT NOT NULL DEFAULT '[]',
        leading_hypothesis_id TEXT,
        confidence TEXT NOT NULL DEFAULT 'moderate' CHECK (confidence IN ('low','moderate','high')),
        conclusion_summary TEXT NOT NULL DEFAULT '', history_json TEXT NOT NULL DEFAULT '[]',
        origin TEXT NOT NULL DEFAULT 'ledger' CHECK (origin IN ('ledger','appStorageImport')),
        created_by TEXT NOT NULL, created_at REAL NOT NULL, updated_by TEXT NOT NULL, updated_at REAL NOT NULL,
        retracted_by TEXT, retracted_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_ach_analyses_case ON ach_analyses(case_id, updated_at);
    CREATE INDEX IF NOT EXISTS idx_ach_analyses_workspace ON ach_analyses(workspace_id, updated_at);
    CREATE TABLE IF NOT EXISTS ach_hypotheses (
        id TEXT PRIMARY KEY NOT NULL, analysis_id TEXT NOT NULL, position INTEGER NOT NULL, text TEXT NOT NULL,
        created_by TEXT NOT NULL, created_at REAL NOT NULL, updated_by TEXT NOT NULL, updated_at REAL NOT NULL,
        retracted_by TEXT, retracted_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_ach_hypotheses_analysis ON ach_hypotheses(analysis_id, position);
    CREATE TABLE IF NOT EXISTS ach_evidence (
        id TEXT PRIMARY KEY NOT NULL, analysis_id TEXT NOT NULL, position INTEGER NOT NULL, text TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT '',
        created_by TEXT NOT NULL, created_at REAL NOT NULL, updated_by TEXT NOT NULL, updated_at REAL NOT NULL,
        retracted_by TEXT, retracted_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_ach_evidence_analysis ON ach_evidence(analysis_id, position);
    CREATE TABLE IF NOT EXISTS ach_cells (
        analysis_id TEXT NOT NULL, evidence_id TEXT NOT NULL, hypothesis_id TEXT NOT NULL,
        consistency TEXT NOT NULL CHECK (consistency IN ('veryConsistent','consistent','neutral','inconsistent','veryInconsistent')),
        updated_by TEXT NOT NULL, updated_at REAL NOT NULL,
        PRIMARY KEY (evidence_id, hypothesis_id)
    );
    CREATE INDEX IF NOT EXISTS idx_ach_cells_analysis ON ach_cells(analysis_id);
    CREATE TABLE IF NOT EXISTS ach_legacy_imports (
        source_key TEXT PRIMARY KEY NOT NULL, analysis_count INTEGER NOT NULL,
        imported_by TEXT NOT NULL, imported_at REAL NOT NULL
    );
    """

    // MARK: - v153 — the case-action log is append-only and inside the audit chain (implementation
    // brief §5). case_actions rows could be updated or deleted by any SQL; the audit chain sealed
    // custody, reviews and governance but not case actions. Triggers now refuse UPDATE and DELETE,
    // and the seal boundary records where sealed history begins: rows written before this
    // migration are legacy, unsealed history — never claimed to have been protected.
    private static let v153: String = """
    CREATE TABLE IF NOT EXISTS case_action_seal_boundaries (
        id TEXT PRIMARY KEY NOT NULL,
        sealed_from_at REAL NOT NULL,
        legacy_action_count INTEGER NOT NULL,
        created_at REAL NOT NULL
    );
    INSERT INTO case_action_seal_boundaries (id, sealed_from_at, legacy_action_count, created_at)
        SELECT 'v153', CAST(strftime('%s','now') AS REAL), (SELECT COUNT(*) FROM case_actions), CAST(strftime('%s','now') AS REAL)
        WHERE NOT EXISTS (SELECT 1 FROM case_action_seal_boundaries WHERE id = 'v153');
    CREATE TRIGGER IF NOT EXISTS case_actions_append_only_update BEFORE UPDATE ON case_actions
    BEGIN SELECT RAISE(ABORT, 'case_actions is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS case_actions_append_only_delete BEFORE DELETE ON case_actions
    BEGIN SELECT RAISE(ABORT, 'case_actions is append-only'); END;
    """


    // MARK: - v154 — a hypothesis is confirmed by reasons, not by a count (implementation brief §8).
    // The profile used to allow confirmation when "for >= against"; neither a majority nor the absence
    // of contradiction proves a hypothesis. A confirmation now records the reviewer's rationale, how the
    // contrary evidence was weighed, the alternatives considered, and the evidence profile at that moment
    // (append-only). Each evidence link may carry a source-reliability and diagnostic-relevance assessment.
    private static let v154: String = """
    CREATE TABLE IF NOT EXISTS investigation_hypothesis_decisions (
        id                TEXT PRIMARY KEY NOT NULL,
        hypothesis_id     TEXT NOT NULL,
        decision          TEXT NOT NULL,
        rationale         TEXT NOT NULL,
        contrary_evidence TEXT,
        alternatives      TEXT,
        for_count         INTEGER NOT NULL,
        against_count     INTEGER NOT NULL,
        for_lineages      INTEGER NOT NULL,
        against_lineages  INTEGER NOT NULL,
        unassessed_count  INTEGER NOT NULL,
        actor             TEXT NOT NULL,
        decided_at        REAL NOT NULL,
        FOREIGN KEY(hypothesis_id) REFERENCES investigation_hypotheses(id) ON DELETE CASCADE,
        CHECK(decision IN ('confirmed','rejected','dismissed')),
        CHECK(length(trim(rationale)) > 0),
        CHECK(decision <> 'confirmed' OR (length(trim(coalesce(contrary_evidence,''))) > 0 AND length(trim(coalesce(alternatives,''))) > 0)),
        CHECK(length(trim(actor)) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_investigation_hypothesis_decisions_hyp ON investigation_hypothesis_decisions(hypothesis_id);
    CREATE TRIGGER IF NOT EXISTS investigation_hypothesis_decisions_append_only_update BEFORE UPDATE ON investigation_hypothesis_decisions
    BEGIN SELECT RAISE(ABORT, 'investigation_hypothesis_decisions is append-only'); END;
    CREATE TABLE IF NOT EXISTS investigation_hypothesis_evidence_assessments (
        link_id              TEXT PRIMARY KEY NOT NULL,
        reliability          TEXT NOT NULL,
        diagnostic_relevance TEXT NOT NULL,
        note                 TEXT,
        assessed_by          TEXT NOT NULL,
        assessed_at          REAL NOT NULL,
        FOREIGN KEY(link_id) REFERENCES investigation_hypothesis_evidence(id) ON DELETE CASCADE,
        CHECK(reliability IN ('high','medium','low','unknown')),
        CHECK(diagnostic_relevance IN ('high','medium','low','none')),
        CHECK(length(trim(assessed_by)) > 0)
    );
    """


    // MARK: - v155 — schema conformance is verified per database (implementation brief §11). The
    // "already checked" marker lived in global UserDefaults, so a restored ledger, or a second
    // ledger at the same version, was never checked. The mark now lives in the ledger it describes,
    // pinned to the schema version and a fingerprint of that ledger's own schema; an incomplete
    // repair is recorded, not hidden.
    private static let v155: String = """
    CREATE TABLE IF NOT EXISTS schema_conformance_marks (
        schema_version     INTEGER PRIMARY KEY NOT NULL,
        schema_fingerprint TEXT NOT NULL,
        status             TEXT NOT NULL,
        added              TEXT NOT NULL DEFAULT '',
        could_not_add      TEXT NOT NULL DEFAULT '',
        checked_at         REAL NOT NULL,
        CHECK(status IN ('clean','incomplete'))
    );
    """


    // MARK: - v156 — a confirmed statement is corrected by an addendum, never edited (implementation
    // brief §9). Each addendum links to its interview, carries its own SHA-256 and reason, and can be
    // confirmed once. Rows are append-only: text, reason and fingerprint never change, a confirmation
    // is written once, and nothing is deleted except with the interview itself.
    private static let v156: String = """
    CREATE TABLE IF NOT EXISTS case_statement_addenda (
        id            TEXT PRIMARY KEY NOT NULL,
        interview_id  TEXT NOT NULL,
        case_id       TEXT NOT NULL,
        text          TEXT NOT NULL,
        reason        TEXT NOT NULL,
        sha256        TEXT NOT NULL,
        recorded_by   TEXT NOT NULL,
        recorded_at   REAL NOT NULL,
        confirmed_by  TEXT,
        confirmed_at  REAL,
        FOREIGN KEY(interview_id) REFERENCES case_interviews(id) ON DELETE CASCADE,
        CHECK(length(trim(text)) > 0),
        CHECK(length(trim(reason)) > 0),
        CHECK(length(trim(recorded_by)) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_statement_addenda_case ON case_statement_addenda(case_id, interview_id);
    CREATE TRIGGER IF NOT EXISTS case_statement_addenda_fixed BEFORE UPDATE ON case_statement_addenda
    WHEN NEW.text IS NOT OLD.text OR NEW.reason IS NOT OLD.reason OR NEW.sha256 IS NOT OLD.sha256
      OR NEW.interview_id IS NOT OLD.interview_id OR NEW.case_id IS NOT OLD.case_id
      OR NEW.recorded_by IS NOT OLD.recorded_by OR NEW.recorded_at IS NOT OLD.recorded_at
      OR OLD.confirmed_by IS NOT NULL
    BEGIN SELECT RAISE(ABORT, 'case_statement_addenda is append-only'); END;
    """


    // MARK: - v157 — the rest of a case's history is fixed once written and sealed (brief §5).
    // Case events (scope membership, reopening), findings approvals/withdrawals and hypothesis
    // decisions join the audit chain; rows can no longer be edited in place. Deletion is left to the
    // case's own cascade and is caught by the chain (a sealed event that disappears breaks it).
    // The boundary rows record when sealing of each began; earlier rows were not protected before.
    private static let v157: String = """
    -- Admit the case-history sources. audit_chain's CHECK listed only custody/review/governance, so
    -- since v153 a case action made every seal fail (found 2026-10-26 by the first test that sealed
    -- one). SQLite cannot alter a CHECK: recreate and copy rows VERBATIM, as v111 did — every sealed
    -- hash is untouched and the existing chain stays intact.
    CREATE TABLE audit_chain__v157 (
        seq          INTEGER PRIMARY KEY,
        source       TEXT NOT NULL,
        event_id     TEXT NOT NULL,
        occurred_at  REAL NOT NULL,
        payload_hash TEXT NOT NULL,
        prev_hash    TEXT NOT NULL,
        entry_hash   TEXT NOT NULL,
        sealed_at    REAL NOT NULL,
        public_prev  TEXT,
        public_hash  TEXT,
        CHECK(source IN ('custody','review','governance','caseAction','caseEvent','findingsApproval','hypothesisDecision')),
        CHECK(seq >= 1),
        CHECK(length(entry_hash) > 0),
        CHECK(length(prev_hash) > 0)
    );
    INSERT INTO audit_chain__v157 (seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at, public_prev, public_hash)
        SELECT seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at, public_prev, public_hash FROM audit_chain;
    DROP TABLE audit_chain;
    ALTER TABLE audit_chain__v157 RENAME TO audit_chain;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_chain_event ON audit_chain(source, event_id);
    CREATE TRIGGER IF NOT EXISTS investigation_case_events_fixed BEFORE UPDATE ON investigation_case_events
    BEGIN SELECT RAISE(ABORT, 'investigation_case_events is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS investigation_findings_approvals_fixed BEFORE UPDATE ON investigation_findings_approvals
    BEGIN SELECT RAISE(ABORT, 'investigation_findings_approvals is append-only'); END;
    CREATE TABLE IF NOT EXISTS audit_seal_boundaries (
        history        TEXT PRIMARY KEY NOT NULL,
        sealed_from_at REAL NOT NULL,
        legacy_count   INTEGER NOT NULL,
        created_at     REAL NOT NULL
    );
    INSERT OR IGNORE INTO audit_seal_boundaries (history, sealed_from_at, legacy_count, created_at)
        VALUES ('investigation_case_events', CAST(strftime('%s','now') AS REAL), (SELECT COUNT(*) FROM investigation_case_events), CAST(strftime('%s','now') AS REAL)),
               ('investigation_findings_approvals', CAST(strftime('%s','now') AS REAL), (SELECT COUNT(*) FROM investigation_findings_approvals), CAST(strftime('%s','now') AS REAL)),
               ('investigation_hypothesis_decisions', CAST(strftime('%s','now') AS REAL), (SELECT COUNT(*) FROM investigation_hypothesis_decisions), CAST(strftime('%s','now') AS REAL));
    """


    // MARK: - v158 — studio work in the encrypted ledger, bound to its case (final brief §3.1).
    //
    // Privilege logs, workplace investigations, SIU referrals, forensic engagements, fact-check memos,
    // reasoning analyses and the shell studios used to live as JSON in app preferences — outside the
    // encrypted ledger, outside backups, and tied to no case. One row per draft here, with its case or
    // workspace, persona/job, model version, revision, who and when, and review state; every saved
    // revision and every export snapshot is kept (append-only). Legacy JSON that cannot be decoded is
    // quarantined byte for byte, never dropped.
    private static let v158: String = """
    CREATE TABLE IF NOT EXISTS studio_records (
        id             TEXT PRIMARY KEY NOT NULL,
        studio         TEXT NOT NULL,
        persona        TEXT,
        job_id         TEXT,
        case_id        TEXT,
        workspace_id   TEXT,
        title          TEXT NOT NULL DEFAULT '',
        model_version  INTEGER NOT NULL DEFAULT 1,
        revision       INTEGER NOT NULL DEFAULT 1,
        payload_json   TEXT NOT NULL,
        payload_sha256 TEXT NOT NULL,
        review_state   TEXT NOT NULL DEFAULT 'draft' CHECK (review_state IN ('draft','inReview','approved','superseded')),
        origin         TEXT NOT NULL DEFAULT 'ledger' CHECK (origin IN ('ledger','appStorageImport')),
        created_by     TEXT NOT NULL,
        created_at     REAL NOT NULL,
        updated_by     TEXT NOT NULL,
        updated_at     REAL NOT NULL,
        retracted_at   REAL,
        retracted_by   TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_studio_records_studio ON studio_records(studio, updated_at);
    CREATE INDEX IF NOT EXISTS idx_studio_records_case ON studio_records(case_id);
    CREATE TABLE IF NOT EXISTS studio_record_revisions (
        record_id      TEXT NOT NULL,
        revision       INTEGER NOT NULL,
        payload_json   TEXT NOT NULL,
        payload_sha256 TEXT NOT NULL,
        reason         TEXT NOT NULL,
        saved_by       TEXT NOT NULL,
        saved_at       REAL NOT NULL,
        PRIMARY KEY (record_id, revision)
    );
    CREATE TRIGGER IF NOT EXISTS studio_record_revisions_fixed BEFORE UPDATE ON studio_record_revisions
    BEGIN SELECT RAISE(ABORT, 'studio_record_revisions is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS studio_record_revisions_kept BEFORE DELETE ON studio_record_revisions
    BEGIN SELECT RAISE(ABORT, 'studio_record_revisions is append-only'); END;
    CREATE TABLE IF NOT EXISTS studio_record_exports (
        id              TEXT PRIMARY KEY NOT NULL,
        record_id       TEXT NOT NULL,
        revision        INTEGER NOT NULL,
        format          TEXT NOT NULL,
        artifact_sha256 TEXT NOT NULL,
        snapshot_text   TEXT NOT NULL,
        exported_by     TEXT NOT NULL,
        exported_at     REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_studio_record_exports_record ON studio_record_exports(record_id, exported_at);
    CREATE TRIGGER IF NOT EXISTS studio_record_exports_fixed BEFORE UPDATE ON studio_record_exports
    BEGIN SELECT RAISE(ABORT, 'studio_record_exports is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS studio_record_exports_kept BEFORE DELETE ON studio_record_exports
    BEGIN SELECT RAISE(ABORT, 'studio_record_exports is append-only'); END;
    CREATE TABLE IF NOT EXISTS studio_legacy_imports (
        source_key        TEXT PRIMARY KEY NOT NULL,
        imported_count    INTEGER NOT NULL,
        quarantined_count INTEGER NOT NULL,
        imported_by       TEXT NOT NULL,
        imported_at       REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS studio_legacy_quarantine (
        id            TEXT PRIMARY KEY NOT NULL,
        source_key    TEXT NOT NULL,
        element_index INTEGER NOT NULL,
        raw_json      TEXT NOT NULL,
        error         TEXT NOT NULL,
        captured_at   REAL NOT NULL
    );
    """


    // MARK: - v159 — the legacy studio store kept byte for byte; an outcome for every element
    // (ship-readiness review R4); approvals bound to the approved content (R3). The old preference blob is stored exactly as it was, with its
    // SHA-256, BEFORE anything is converted; each element of it gets one recorded outcome
    // (imported, identical duplicate, already migrated, quarantined), so nothing can be skipped.
    private static let v159: String = """
    CREATE TABLE IF NOT EXISTS studio_legacy_blobs (
        source_key   TEXT PRIMARY KEY NOT NULL,
        raw_blob     TEXT NOT NULL,
        sha256       TEXT NOT NULL,
        byte_count   INTEGER NOT NULL,
        captured_at  REAL NOT NULL
    );
    CREATE TRIGGER IF NOT EXISTS studio_legacy_blobs_fixed BEFORE UPDATE ON studio_legacy_blobs
    BEGIN SELECT RAISE(ABORT, 'studio_legacy_blobs is kept as captured'); END;
    CREATE TABLE IF NOT EXISTS studio_legacy_outcomes (
        source_key    TEXT NOT NULL,
        element_index INTEGER NOT NULL,
        record_id     TEXT,
        outcome       TEXT NOT NULL CHECK (outcome IN ('imported','identicalDuplicate','alreadyMigrated','quarantined')),
        detail        TEXT NOT NULL,
        recorded_at   REAL NOT NULL,
        PRIMARY KEY (source_key, element_index)
    );
    -- Review R3: an approval is bound to the exact content approved (revisions coalesce for five
    -- minutes, so a revision number alone cannot say what was approved).
    ALTER TABLE studio_records ADD COLUMN approved_payload_sha256 TEXT;
    ALTER TABLE studio_records ADD COLUMN approved_by TEXT;
    ALTER TABLE studio_records ADD COLUMN approved_at REAL;
    """


    // MARK: - v160 — governed erasure of studio work (ship-readiness review L4). Retraction keeps a
    // draft; erasure removes its content. An erasure is a recorded act (who, when, why, on what basis)
    // and is refused while a legal hold (v145 legal_holds / legal_hold_items, on the draft or its case)
    // is active — enforced in StudioRecordRepository.erase. Revision and export rows stay (their dates
    // and SHA-256s say that something existed and was erased); only their content may be cleared, and
    // only when a recorded erasure for that draft exists. Rows are still never deleted.
    private static let v160: String = """
    CREATE TABLE IF NOT EXISTS studio_erasures (
        id                 TEXT PRIMARY KEY NOT NULL,
        record_id          TEXT NOT NULL,
        case_id            TEXT,
        reason             TEXT NOT NULL,
        legal_basis        TEXT,
        payload_sha256     TEXT NOT NULL,
        revisions_cleared  INTEGER NOT NULL,
        exports_cleared    INTEGER NOT NULL,
        quarantine_cleared INTEGER NOT NULL,
        legacy_originals   INTEGER NOT NULL,
        erased_by          TEXT NOT NULL,
        erased_at          REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_studio_erasures_record ON studio_erasures(record_id);
    CREATE TRIGGER IF NOT EXISTS studio_erasures_fixed BEFORE UPDATE ON studio_erasures
    BEGIN SELECT RAISE(ABORT, 'studio_erasures is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS studio_erasures_kept BEFORE DELETE ON studio_erasures
    BEGIN SELECT RAISE(ABORT, 'studio_erasures is append-only'); END;
    ALTER TABLE studio_records ADD COLUMN erased_at REAL;
    DROP TRIGGER IF EXISTS studio_record_revisions_fixed;
    CREATE TRIGGER studio_record_revisions_fixed BEFORE UPDATE ON studio_record_revisions
    WHEN NOT (NEW.payload_json = '' AND NEW.record_id = OLD.record_id AND NEW.revision = OLD.revision
              AND NEW.payload_sha256 = OLD.payload_sha256 AND NEW.reason = OLD.reason
              AND NEW.saved_by = OLD.saved_by AND NEW.saved_at = OLD.saved_at
              AND EXISTS (SELECT 1 FROM studio_erasures e WHERE e.record_id = OLD.record_id))
    BEGIN SELECT RAISE(ABORT, 'studio_record_revisions is append-only (content is cleared only by a recorded erasure)'); END;
    DROP TRIGGER IF EXISTS studio_record_exports_fixed;
    CREATE TRIGGER studio_record_exports_fixed BEFORE UPDATE ON studio_record_exports
    WHEN NOT (NEW.snapshot_text = '' AND NEW.id = OLD.id AND NEW.record_id = OLD.record_id
              AND NEW.revision = OLD.revision AND NEW.format = OLD.format
              AND NEW.artifact_sha256 = OLD.artifact_sha256 AND NEW.exported_by = OLD.exported_by
              AND NEW.exported_at = OLD.exported_at
              AND EXISTS (SELECT 1 FROM studio_erasures e WHERE e.record_id = OLD.record_id))
    BEGIN SELECT RAISE(ABORT, 'studio_record_exports is append-only (content is cleared only by a recorded erasure)'); END;
    """


    // MARK: - v161 — the user's full erase passes the append-only guards (2026-10-28). "Delete all my
    // data" is the person's deliberate destroy act; the append-only triggers (case_actions v153, studio
    // revisions/exports v158, studio_erasures v160) made it silently leave those rows behind. Each guard
    // now stands aside only while a full-erase marker row exists — written and removed inside the one
    // savepoint of AppState.deleteAllData — so no ordinary delete can pass it.
    private static let v161: String = """
    CREATE TABLE IF NOT EXISTS ledger_full_erase (
        started_at REAL NOT NULL
    );
    DROP TRIGGER IF EXISTS case_actions_append_only_delete;
    CREATE TRIGGER case_actions_append_only_delete BEFORE DELETE ON case_actions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
    BEGIN SELECT RAISE(ABORT, 'case_actions is append-only'); END;
    DROP TRIGGER IF EXISTS studio_record_revisions_kept;
    CREATE TRIGGER studio_record_revisions_kept BEFORE DELETE ON studio_record_revisions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
    BEGIN SELECT RAISE(ABORT, 'studio_record_revisions is append-only'); END;
    DROP TRIGGER IF EXISTS studio_record_exports_kept;
    CREATE TRIGGER studio_record_exports_kept BEFORE DELETE ON studio_record_exports
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
    BEGIN SELECT RAISE(ABORT, 'studio_record_exports is append-only'); END;
    DROP TRIGGER IF EXISTS studio_erasures_kept;
    CREATE TRIGGER studio_erasures_kept BEFORE DELETE ON studio_erasures
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
    BEGIN SELECT RAISE(ABORT, 'studio_erasures is append-only'); END;
    """


    // MARK: - v162 — erasure reaches the captured pre-ledger store (final completion instructions K3). A
    // studio erasure used to count the captured preference stores (v159) still holding the draft and leave
    // them. The store's content may now be cleared — only after a recorded erasure of a draft that store
    // held — keeping its SHA-256, size and capture time, with the reason. Its other elements are not lost:
    // each was imported into the ledger or kept byte for byte in quarantine.
    private static let v162: String = """
    ALTER TABLE studio_legacy_blobs ADD COLUMN cleared_reason TEXT;
    ALTER TABLE studio_legacy_blobs ADD COLUMN cleared_at REAL;
    -- K5: the scope an export was authorised against (a digest of the case's accessible source
    -- versions at the moment of the final check).
    ALTER TABLE studio_record_exports ADD COLUMN scope_fingerprint TEXT;
    DROP TRIGGER IF EXISTS studio_legacy_blobs_fixed;
    CREATE TRIGGER studio_legacy_blobs_fixed BEFORE UPDATE ON studio_legacy_blobs
    WHEN NOT (NEW.raw_blob = '' AND NEW.source_key = OLD.source_key AND NEW.sha256 = OLD.sha256
              AND NEW.byte_count = OLD.byte_count AND NEW.captured_at = OLD.captured_at
              AND NEW.cleared_reason IS NOT NULL AND NEW.cleared_at IS NOT NULL
              AND EXISTS (SELECT 1 FROM studio_erasures e JOIN studio_legacy_outcomes o ON o.record_id = e.record_id
                          WHERE o.source_key = OLD.source_key))
    BEGIN SELECT RAISE(ABORT, 'studio_legacy_blobs is kept as captured (cleared only by a recorded erasure)'); END;
    """


    // MARK: - v163 — persisted job results (final completion instructions §3). A job that runs a
    // shared executor saves its typed result here: draft (generated, awaiting the person), blocked
    // (an input is missing — the reason is in the payload), completed (accepted), superseded (a later
    // run replaced it). Each run is a new row; earlier rows stay, marked superseded.
    private static let v163: String = """
    CREATE TABLE IF NOT EXISTS job_results (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        job_id         TEXT NOT NULL,
        family         TEXT NOT NULL,
        state          TEXT NOT NULL CHECK (state IN ('draft','blocked','completed','superseded')),
        payload_json   TEXT NOT NULL,
        payload_sha256 TEXT NOT NULL,
        created_by     TEXT NOT NULL,
        created_at     REAL NOT NULL,
        superseded_by  TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_job_results_case_job ON job_results(case_id, job_id, created_at);
    """

    // MARK: - v164 — case and person erasure (final completion instructions K10). One case, or one
    // person's derived record, can be erased on the person's deliberate act: every case-scoped row is
    // removed in one savepoint and a content-free erasure record is kept (who, when, why, how much —
    // never the content; a person is recorded by a SHA-256 of the name, not the name). The append-only
    // guards on case_actions and studio revisions/exports stand aside only for the case named in the
    // ledger_case_erase marker, written and removed inside that savepoint. Erasure records cannot be
    // changed, and are removed only by a full erase.
    private static let v164: String = """
    CREATE TABLE IF NOT EXISTS ledger_case_erase (
        case_id TEXT PRIMARY KEY NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_erasures (
        id             TEXT PRIMARY KEY NOT NULL,
        scope          TEXT NOT NULL CHECK (scope IN ('case','person')),
        case_id        TEXT,
        subject_sha256 TEXT,
        reason         TEXT NOT NULL,
        legal_basis    TEXT,
        rows_json      TEXT NOT NULL,
        sources_erased INTEGER NOT NULL DEFAULT 0,
        sources_kept   INTEGER NOT NULL DEFAULT 0,
        erased_by      TEXT NOT NULL,
        erased_at      REAL NOT NULL
    );
    CREATE TRIGGER IF NOT EXISTS case_erasures_fixed BEFORE UPDATE ON case_erasures
    BEGIN SELECT RAISE(ABORT, 'case_erasures is a fixed record'); END;
    CREATE TRIGGER IF NOT EXISTS case_erasures_kept BEFORE DELETE ON case_erasures
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
    BEGIN SELECT RAISE(ABORT, 'case_erasures is kept'); END;
    DROP TRIGGER IF EXISTS case_actions_append_only_delete;
    CREATE TRIGGER case_actions_append_only_delete BEFORE DELETE ON case_actions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_actions is append-only'); END;
    DROP TRIGGER IF EXISTS studio_record_revisions_kept;
    CREATE TRIGGER studio_record_revisions_kept BEFORE DELETE ON studio_record_revisions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m JOIN studio_records r ON r.case_id = m.case_id WHERE r.id = OLD.record_id)
    BEGIN SELECT RAISE(ABORT, 'studio_record_revisions is append-only'); END;
    DROP TRIGGER IF EXISTS studio_record_exports_kept;
    CREATE TRIGGER studio_record_exports_kept BEFORE DELETE ON studio_record_exports
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m JOIN studio_records r ON r.case_id = m.case_id WHERE r.id = OLD.record_id)
    BEGIN SELECT RAISE(ABORT, 'studio_record_exports is append-only'); END;
    """

    // MARK: - v165 — job result exports (completion instructions 2026-10-29, B2). An export of a job
    // result is recorded only after the file was written and read back: which revision (by its
    // payload digest), the written bytes' SHA-256 and the exact text. Kept like studio exports —
    // removed only with its case (ledger_case_erase) or by a full erase.
    private static let v165: String = """
    CREATE TABLE IF NOT EXISTS job_result_exports (
        id             TEXT PRIMARY KEY NOT NULL,
        result_id      TEXT NOT NULL,
        case_id        TEXT NOT NULL,
        job_id         TEXT NOT NULL,
        result_sha256  TEXT NOT NULL,
        file_name      TEXT NOT NULL,
        file_sha256    TEXT NOT NULL,
        snapshot_text  TEXT NOT NULL,
        exported_by    TEXT NOT NULL,
        exported_at    REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_job_result_exports_result ON job_result_exports(result_id);
    CREATE TRIGGER IF NOT EXISTS job_result_exports_fixed BEFORE UPDATE ON job_result_exports
    BEGIN SELECT RAISE(ABORT, 'job_result_exports is a fixed record'); END;
    CREATE TRIGGER IF NOT EXISTS job_result_exports_kept BEFORE DELETE ON job_result_exports
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'job_result_exports is append-only'); END;
    """

    // MARK: - v166 — ACH unassessed cells and structured citations (investigator workflow review
    // 2026-10-30, I3). A cell nobody rated used to be indistinguishable from a neutral rating, and a
    // rating once written could not be taken back to "unassessed" because the CHECK admitted only the
    // five ratings. ach_cells is rebuilt with 'unassessed' as a recordable state (who cleared it, when),
    // existing rows carried over unchanged; ach_evidence gains citation_json — an exact source version
    // and quote — so an uncited row can be labelled as the investigator's own note.
    private static let v166: String = """
    ALTER TABLE ach_evidence ADD COLUMN citation_json TEXT;
    CREATE TABLE IF NOT EXISTS ach_cells__v166 (
        analysis_id TEXT NOT NULL, evidence_id TEXT NOT NULL, hypothesis_id TEXT NOT NULL,
        consistency TEXT NOT NULL CHECK (consistency IN ('veryConsistent','consistent','neutral','inconsistent','veryInconsistent','unassessed')),
        updated_by TEXT NOT NULL, updated_at REAL NOT NULL,
        PRIMARY KEY (evidence_id, hypothesis_id)
    );
    INSERT OR IGNORE INTO ach_cells__v166 (analysis_id, evidence_id, hypothesis_id, consistency, updated_by, updated_at)
        SELECT analysis_id, evidence_id, hypothesis_id, consistency, updated_by, updated_at FROM ach_cells;
    DROP INDEX IF EXISTS idx_ach_cells_analysis;
    DROP TABLE ach_cells;
    ALTER TABLE ach_cells__v166 RENAME TO ach_cells;
    CREATE INDEX IF NOT EXISTS idx_ach_cells_analysis ON ach_cells(analysis_id);
    """

    // MARK: - v167 — passage-level case evidence and reviewed-result handoffs (investigator workflow
    // review 2026-10-30, I4/I5). An allegation's evidence link and a chronology entry carry the exact
    // passage (quote, block, object) beside the source version, and the reviewed job-result row they
    // came from (origin), so a reviewer opens the passage from the allegation or the report without
    // searching the document again. An allegation records the response put to the respondent and,
    // for an adverse finding without one, the explicit exception. The final report's selection is
    // explicit: case_report_items lists what is included and what is excluded with the reason.
    private static let v167: String = """
    ALTER TABLE case_allegation_evidence ADD COLUMN quote TEXT;
    ALTER TABLE case_allegation_evidence ADD COLUMN block_id TEXT;
    ALTER TABLE case_allegation_evidence ADD COLUMN object_id TEXT;
    ALTER TABLE case_allegation_evidence ADD COLUMN origin TEXT;
    ALTER TABLE case_journal ADD COLUMN quote TEXT;
    ALTER TABLE case_journal ADD COLUMN origin TEXT;
    ALTER TABLE case_allegations ADD COLUMN response TEXT;
    ALTER TABLE case_allegations ADD COLUMN exception_note TEXT;
    CREATE TABLE IF NOT EXISTS case_report_items (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, allegation_id TEXT,
        text TEXT NOT NULL, quote TEXT, evidence_ref TEXT, origin TEXT,
        included INTEGER NOT NULL DEFAULT 1, exclusion_reason TEXT,
        added_by TEXT NOT NULL, created_at REAL NOT NULL, decided_by TEXT, decided_at REAL
    );
    CREATE INDEX IF NOT EXISTS idx_case_report_items_case ON case_report_items(case_id, created_at);
    """

    // MARK: - v168 — verified evidence, truthful handoffs and recorded case outputs (App Store completion
    // instructions 2026-10-30 §2–§4). Every case evidence link, chronology entry and report item records
    // its verification state (verified passage / exhibit / investigator's note / unverified + reason),
    // the review state of the result row it was carried from, the saved result revision's digest and
    // every citation it carries (not only the first). Legacy rows keep NULL and read as unverified.
    // ACH evidence rows record their citation's verification. Case document outputs (reports, lists,
    // statements, notices, person-data exports, copies and prints) are recorded with the snapshot and
    // file digests and a status, so a write whose record failed is a pending operation, not a silent gap.
    private static let v168: String = """
    ALTER TABLE case_allegation_evidence ADD COLUMN verification TEXT;
    ALTER TABLE case_allegation_evidence ADD COLUMN verification_detail TEXT;
    ALTER TABLE case_allegation_evidence ADD COLUMN verified_at REAL;
    ALTER TABLE case_allegation_evidence ADD COLUMN review_state TEXT;
    ALTER TABLE case_allegation_evidence ADD COLUMN origin_digest TEXT;
    ALTER TABLE case_journal ADD COLUMN verification TEXT;
    ALTER TABLE case_journal ADD COLUMN verification_detail TEXT;
    ALTER TABLE case_journal ADD COLUMN verified_at REAL;
    ALTER TABLE case_journal ADD COLUMN citations_json TEXT;
    ALTER TABLE case_journal ADD COLUMN review_state TEXT;
    ALTER TABLE case_journal ADD COLUMN origin_digest TEXT;
    ALTER TABLE case_report_items ADD COLUMN verification TEXT;
    ALTER TABLE case_report_items ADD COLUMN verification_detail TEXT;
    ALTER TABLE case_report_items ADD COLUMN verified_at REAL;
    ALTER TABLE case_report_items ADD COLUMN citations_json TEXT;
    ALTER TABLE case_report_items ADD COLUMN review_state TEXT;
    ALTER TABLE case_report_items ADD COLUMN origin_digest TEXT;
    ALTER TABLE ach_evidence ADD COLUMN citation_state TEXT;
    ALTER TABLE ach_evidence ADD COLUMN citation_detail TEXT;
    CREATE TABLE IF NOT EXISTS case_document_outputs (
        id TEXT PRIMARY KEY NOT NULL, case_id TEXT NOT NULL, kind TEXT NOT NULL, route TEXT NOT NULL,
        snapshot_sha256 TEXT NOT NULL, file_name TEXT, file_sha256 TEXT,
        status TEXT NOT NULL CHECK (status IN ('released','written','recordPending','refused','failed')),
        detail TEXT, released_by TEXT NOT NULL, released_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_document_outputs_case ON case_document_outputs(case_id, released_at);
    """

    // MARK: - v169 — a "verified" mark only a person can set (N3, 2026-11-03). A chronology entry's
    // machine check (the quote was found in the pinned source) is not a person's verification. A person
    // marks an entry verified, or withdraws the mark with a reason; each mark names who, when, an optional
    // note and the SHA-256 of the entry as it stood (text, date, source, quote), so a later change to the
    // entry shows the mark as made on an earlier version. Rows are append-only: the current state is the
    // latest row. Removed only with the case (ledger_case_erase) or by a full erase, like job_result_exports.
    private static let v169: String = """
    CREATE TABLE IF NOT EXISTS case_fact_attestations (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        journal_entry_id TEXT NOT NULL,
        state            TEXT NOT NULL CHECK (state IN ('verified','withdrawn')),
        attested_by      TEXT NOT NULL CHECK (length(trim(attested_by)) > 0),
        attested_at      REAL NOT NULL,
        note             TEXT,
        entry_digest     TEXT NOT NULL CHECK (length(entry_digest) = 64),
        CHECK (state <> 'withdrawn' OR length(trim(coalesce(note,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_fact_attestations_entry ON case_fact_attestations(case_id, journal_entry_id, attested_at);
    CREATE TRIGGER IF NOT EXISTS case_fact_attestations_fixed BEFORE UPDATE ON case_fact_attestations
    BEGIN SELECT RAISE(ABORT, 'case_fact_attestations is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS case_fact_attestations_kept BEFORE DELETE ON case_fact_attestations
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_fact_attestations is append-only'); END;
    """

    // MARK: - v170 — review in place, durable decisions and evidence requests that can be followed
    // through (owner's implementation plan 2026-11-04, P0-C 3–4 and P1-B).
    // • investigation_review_decisions: every confirm / dismiss / defer of a case review item, with its
    //   reason, note, who and when, and the source version each side was read from when it was decided —
    //   so an unchanged rerun keeps the decision and a changed source reopens it visibly. Append-only:
    //   the current decision is the latest row; investigation_desk_reviews keeps the current
    //   confirmed/dismissed disposition for the existing desk.
    // • investigation_evidence_requests is rebuilt (rows carried over unchanged) so a request can also be
    //   partial, refused or unobtainable, and gains its linked allegation or question, custodian, the
    //   period asked for and a due date. Expected items, the documents received against them (each a
    //   source version; a duplicate is kept and marked, never counted twice) and an append-only history
    //   sit beside it. Fulfilment stays a recorded decision. Removed only with the case or a full erase.
    private static let v170: String = """
    CREATE TABLE IF NOT EXISTS investigation_review_decisions (
        id                   TEXT PRIMARY KEY NOT NULL,
        case_id              TEXT NOT NULL,
        item_kind            TEXT NOT NULL CHECK (item_kind IN ('reliability','contradiction','gap')),
        item_id              TEXT NOT NULL CHECK (length(trim(item_id)) > 0),
        decision             TEXT NOT NULL CHECK (decision IN ('confirmed','dismissed','deferred')),
        reason               TEXT CHECK (reason IS NULL OR reason IN ('differentEvent','differentPerson','changedEstimate','transcriptionError','insufficientContext','other')),
        note                 TEXT,
        source_versions_json TEXT NOT NULL DEFAULT '{}',
        actor                TEXT NOT NULL CHECK (length(trim(actor)) > 0),
        decided_at           REAL NOT NULL,
        CHECK (decision <> 'dismissed' OR reason IS NOT NULL),
        CHECK (coalesce(reason,'') <> 'other' OR length(trim(coalesce(note,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_investigation_review_decisions_item ON investigation_review_decisions(case_id, item_kind, item_id, decided_at);
    CREATE TRIGGER IF NOT EXISTS investigation_review_decisions_fixed BEFORE UPDATE ON investigation_review_decisions
    BEGIN SELECT RAISE(ABORT, 'investigation_review_decisions is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS investigation_review_decisions_kept BEFORE DELETE ON investigation_review_decisions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'investigation_review_decisions is append-only'); END;

    CREATE TABLE IF NOT EXISTS investigation_evidence_requests__new (
        id            TEXT PRIMARY KEY NOT NULL,
        case_id       TEXT NOT NULL,
        hypothesis_id TEXT,
        description   TEXT NOT NULL,
        status        TEXT NOT NULL DEFAULT 'open',
        revision      INTEGER NOT NULL,
        actor         TEXT NOT NULL,
        created_at    REAL NOT NULL,
        updated_at    REAL NOT NULL,
        allegation_id TEXT,
        question      TEXT,
        custodian     TEXT,
        period_start  REAL,
        period_end    REAL,
        due_at        REAL,
        FOREIGN KEY(case_id) REFERENCES investigation_cases(id) ON DELETE CASCADE,
        FOREIGN KEY(hypothesis_id) REFERENCES investigation_hypotheses(id) ON DELETE SET NULL,
        CHECK(length(trim(description)) > 0),
        CHECK(status IN ('open','confirmed','partial','refused','unobtainable','fulfilled','cancelled')),
        CHECK(revision >= 1),
        CHECK(length(trim(actor)) > 0),
        CHECK(period_start IS NULL OR period_end IS NULL OR period_start <= period_end)
    );
    INSERT INTO investigation_evidence_requests__new (id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at)
        SELECT id, case_id, hypothesis_id, description, status, revision, actor, created_at, updated_at FROM investigation_evidence_requests;
    DROP INDEX IF EXISTS idx_investigation_evidence_requests_case;
    DROP TABLE investigation_evidence_requests;
    ALTER TABLE investigation_evidence_requests__new RENAME TO investigation_evidence_requests;
    CREATE INDEX IF NOT EXISTS idx_investigation_evidence_requests_case ON investigation_evidence_requests(case_id);

    CREATE TABLE IF NOT EXISTS investigation_evidence_request_items (
        id           TEXT PRIMARY KEY NOT NULL,
        case_id      TEXT NOT NULL,
        request_id   TEXT NOT NULL,
        ordinal      INTEGER NOT NULL CHECK (ordinal >= 1),
        label        TEXT NOT NULL CHECK (length(trim(label)) > 0),
        period_start REAL,
        period_end   REAL,
        created_by   TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at   REAL NOT NULL,
        UNIQUE(request_id, ordinal)
    );
    CREATE INDEX IF NOT EXISTS idx_investigation_evidence_request_items_request ON investigation_evidence_request_items(request_id, ordinal);
    CREATE TABLE IF NOT EXISTS investigation_evidence_request_receipts (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        request_id          TEXT NOT NULL,
        item_id             TEXT,
        source_version_id   TEXT NOT NULL,
        knowledge_object_id TEXT,
        content_hash        TEXT,
        duplicate_of        TEXT,
        origin              TEXT NOT NULL CHECK (origin IN ('manual','suggestion')),
        note                TEXT,
        linked_by           TEXT NOT NULL CHECK (length(trim(linked_by)) > 0),
        linked_at           REAL NOT NULL,
        withdrawn_by        TEXT,
        withdrawn_at        REAL,
        withdrawn_reason    TEXT,
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_investigation_evidence_request_receipts_request ON investigation_evidence_request_receipts(request_id, linked_at);
    CREATE TABLE IF NOT EXISTS investigation_evidence_request_events (
        id           TEXT PRIMARY KEY NOT NULL,
        case_id      TEXT NOT NULL,
        request_id   TEXT NOT NULL,
        event        TEXT NOT NULL CHECK (event IN ('created','requested','responded','received','duplicateReceived','receiptWithdrawn','statusDecided','note')),
        status_after TEXT,
        item_id      TEXT,
        receipt_id   TEXT,
        detail       TEXT,
        actor        TEXT NOT NULL CHECK (length(trim(actor)) > 0),
        occurred_at  REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_investigation_evidence_request_events_request ON investigation_evidence_request_events(request_id, occurred_at);
    CREATE TRIGGER IF NOT EXISTS investigation_evidence_request_events_fixed BEFORE UPDATE ON investigation_evidence_request_events
    BEGIN SELECT RAISE(ABORT, 'investigation_evidence_request_events is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS investigation_evidence_request_events_kept BEFORE DELETE ON investigation_evidence_request_events
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'investigation_evidence_request_events is append-only'); END;
    """

    // MARK: - v171 — the living case map (plan 2026-11-06, M2/M3): only what has no other canonical home.
    // • case_map_views: the person's saved views of a case — a name, the view it is based on, its filters
    //   (identifiers, kinds, review states and the person's search words) and its place in the strip. A view
    //   stores references and display settings only; it never copies or forks case records.
    // • case_map_layout: where each map item sits (world coordinates) and whether the person pinned it,
    //   keyed by the item's stable identity (record kind + canonical record id). Geometry only.
    // • case_map_links: typed links the investigator draws that no existing record can hold, each with
    //   its rationale and author. A link is withdrawn with a reason, never edited; withdrawn links stay.
    // All three carry case_id, so case erasure and full erasure remove them; person erasure removes the
    // layout and links that point at the erased person's case-person rows. Everything is in the encrypted
    // ledger (and therefore in backups); the preferences file keeps identifiers and geometry only.
    private static let v171: String = """
    CREATE TABLE IF NOT EXISTS case_map_views (
        id           TEXT PRIMARY KEY NOT NULL,
        case_id      TEXT NOT NULL,
        name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
        base_view    TEXT NOT NULL CHECK (base_view IN ('overview','questions','people','chronology','findings','changes')),
        filters_json TEXT NOT NULL DEFAULT '{}',
        ordinal      INTEGER NOT NULL DEFAULT 0,
        created_by   TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at   REAL NOT NULL,
        updated_at   REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_map_views_case ON case_map_views(case_id, ordinal);
    CREATE TABLE IF NOT EXISTS case_map_layout (
        case_id     TEXT NOT NULL,
        record_kind TEXT NOT NULL CHECK (length(trim(record_kind)) > 0),
        record_id   TEXT NOT NULL CHECK (length(trim(record_id)) > 0),
        x           REAL NOT NULL,
        y           REAL NOT NULL,
        pinned      INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
        updated_at  REAL NOT NULL,
        PRIMARY KEY (case_id, record_kind, record_id)
    );
    CREATE TABLE IF NOT EXISTS case_map_links (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        link_type        TEXT NOT NULL CHECK (link_type IN ('supports','challenges','mentions','attributedTo','occurredBefore','occurredAfter','possibleSamePerson','dependsOn','requestsEvidenceFor','receivedInResponseTo','derivedFrom','supersedes','selectedForReport')),
        from_kind        TEXT NOT NULL,
        from_id          TEXT NOT NULL,
        to_kind          TEXT NOT NULL,
        to_id            TEXT NOT NULL,
        rationale        TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (NOT (from_kind = to_kind AND from_id = to_id)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_map_links_case ON case_map_links(case_id, created_at);
    CREATE TRIGGER IF NOT EXISTS case_map_links_fixed BEFORE UPDATE ON case_map_links
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.link_type <> OLD.link_type
      OR NEW.from_kind <> OLD.from_kind OR NEW.from_id <> OLD.from_id OR NEW.to_kind <> OLD.to_kind OR NEW.to_id <> OLD.to_id
      OR NEW.rationale <> OLD.rationale OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_map_links: a link is withdrawn with a reason, never edited'); END;
    """

    // MARK: - v172 — saved case evidence searches (Living Case Map plan 2026-11-06 §8, M5).
    // • case_saved_searches: a search of ONE case's documents saved by the person. kind 'live' keeps the query
    //   (its text, version and tree), its options, the case scope it ran over (fingerprint + authorised versions),
    //   the index revision of the documents searched, when it ran, and the baseline of what it found — so a later
    //   run can say what is new. kind 'receipt' is a frozen record of one run (the same columns, never updated:
    //   the trigger refuses it). The query text is the person's search words: it lives here, in the encrypted
    //   ledger, never in preferences. case_id makes case erasure and full erasure remove it; person erasure
    //   removes the searches whose words or results name the person; backups carry it as part of the ledger.
    private static let v172: String = """
    CREATE TABLE IF NOT EXISTS case_saved_searches (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        name                TEXT NOT NULL CHECK (length(trim(name)) > 0),
        kind                TEXT NOT NULL CHECK (kind IN ('live','receipt')),
        query_text          TEXT NOT NULL,
        query_version       INTEGER NOT NULL CHECK (query_version >= 1),
        query_json          TEXT NOT NULL,
        options_json        TEXT NOT NULL,
        scope_fingerprint   TEXT NOT NULL,
        scope_versions_json TEXT NOT NULL DEFAULT '[]',
        index_revision      TEXT NOT NULL,
        executed_at         REAL NOT NULL,
        result_json         TEXT NOT NULL,
        created_by          TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at          REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_saved_searches_case ON case_saved_searches(case_id, created_at);
    CREATE TRIGGER IF NOT EXISTS case_saved_searches_receipt_frozen BEFORE UPDATE ON case_saved_searches
    WHEN OLD.kind = 'receipt' OR NEW.kind <> OLD.kind OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id
      OR NEW.query_text <> OLD.query_text OR NEW.query_json <> OLD.query_json OR NEW.query_version <> OLD.query_version
      OR NEW.options_json <> OLD.options_json OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_saved_searches: a receipt is frozen and a live search keeps its query; save a new one'); END;
    """

    // MARK: - v173 — case changes, history and recovery (Living Case Map plan 2026-11-06 §6.3, §6.4, §9; M6–M8).
    // • case_history_install: the explicit historical baseline — when this build began recording case history.
    //   Map states before it were never recorded and are never invented ("full map state not recorded before …").
    //   One row, written by this migration; a full erase empties it and the next read starts a new baseline.
    // • case_record_revisions: typed before/after copies of a case record, written in the SAME savepoint as the
    //   change and its case_actions row, for the updates that used to overwrite (the case profile, an allegation's
    //   disposition and response, a report item's selection, a person, an interview, retractions). Append-only.
    // • case_change_seen: each case's own "seen" position for its change feed (a time and the identifiers of what
    //   was detected, readable and open at that moment — no document text). Seen is not reviewed or accepted.
    // • case_checkpoints: immutable recorded states of the case map (manifest, scope fingerprint, content digest,
    //   the projected items and links with their display text, and layout), built from one validated revision
    //   fence. Never edited; a person erasure may only clear a checkpoint's content (marked erased, kept as a stub).
    // • ledger_person_erase: the marker a person erasure writes and removes inside its savepoint, so the guards on
    //   revisions and checkpoints stand aside for that act only (like ledger_case_erase for a case erasure).
    // Everything carries case_id, so case erasure removes it and backups carry it as part of the encrypted ledger.
    private static let v173: String = """
    CREATE TABLE IF NOT EXISTS ledger_person_erase (
        erasure_id TEXT PRIMARY KEY NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_history_install (
        id           INTEGER PRIMARY KEY CHECK (id = 1),
        installed_at REAL NOT NULL
    );
    INSERT OR IGNORE INTO case_history_install (id, installed_at) VALUES (1, (julianday('now') - 2440587.5) * 86400.0);
    CREATE TABLE IF NOT EXISTS case_record_revisions (
        id          TEXT PRIMARY KEY NOT NULL,
        case_id     TEXT NOT NULL,
        action_id   TEXT,
        record_kind TEXT NOT NULL CHECK (length(trim(record_kind)) > 0),
        record_id   TEXT NOT NULL CHECK (length(trim(record_id)) > 0),
        change      TEXT NOT NULL CHECK (length(trim(change)) > 0),
        before_json TEXT,
        after_json  TEXT,
        actor       TEXT NOT NULL CHECK (length(trim(actor)) > 0),
        recorded_at REAL NOT NULL,
        CHECK (before_json IS NOT NULL OR after_json IS NOT NULL)
    );
    CREATE INDEX IF NOT EXISTS idx_case_record_revisions_case ON case_record_revisions(case_id, recorded_at);
    CREATE INDEX IF NOT EXISTS idx_case_record_revisions_record ON case_record_revisions(case_id, record_kind, record_id, recorded_at);
    CREATE TRIGGER IF NOT EXISTS case_record_revisions_fixed BEFORE UPDATE ON case_record_revisions
    BEGIN SELECT RAISE(ABORT, 'case_record_revisions is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS case_record_revisions_kept BEFORE DELETE ON case_record_revisions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
     AND NOT EXISTS (SELECT 1 FROM ledger_person_erase)
    BEGIN SELECT RAISE(ABORT, 'case_record_revisions is append-only'); END;
    CREATE TABLE IF NOT EXISTS case_change_seen (
        case_id      TEXT PRIMARY KEY NOT NULL,
        seen_through REAL NOT NULL,
        state_json   TEXT NOT NULL DEFAULT '{}',
        seen_by      TEXT NOT NULL CHECK (length(trim(seen_by)) > 0),
        seen_at      REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS case_checkpoints (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        kind              TEXT NOT NULL CHECK (kind IN ('automatic','manual','milestone')),
        name              TEXT,
        fence             TEXT NOT NULL,
        scope_fingerprint TEXT NOT NULL,
        content_digest    TEXT NOT NULL,
        manifest_json     TEXT NOT NULL,
        payload_json      TEXT NOT NULL,
        format_version    INTEGER NOT NULL CHECK (format_version >= 1),
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        erased_at         REAL,
        erased_reason     TEXT,
        CHECK (kind <> 'milestone' OR length(trim(coalesce(name,''))) > 0),
        CHECK ((erased_at IS NULL) = (erased_reason IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_case_checkpoints_case ON case_checkpoints(case_id, recorded_at);
    CREATE TRIGGER IF NOT EXISTS case_checkpoints_fixed BEFORE UPDATE ON case_checkpoints
    WHEN NOT EXISTS (SELECT 1 FROM ledger_person_erase) OR OLD.erased_at IS NOT NULL OR NEW.erased_at IS NULL
      OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.kind <> OLD.kind OR NEW.recorded_at <> OLD.recorded_at
      OR NEW.recorded_by <> OLD.recorded_by OR NEW.fence <> OLD.fence
    BEGIN SELECT RAISE(ABORT, 'case_checkpoints: a recorded state is never edited (an erasure may only clear its content)'); END;
    CREATE TRIGGER IF NOT EXISTS case_checkpoints_kept BEFORE DELETE ON case_checkpoints
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_checkpoints are kept'); END;
    """

    // MARK: - v174 — Ask conversations bound to their case (candidate review LS24, 2026-11-07).
    // A conversation started by Ask inside an open case carries that case's id; Ask in a case resumes and lists
    // only that case's conversations, library Ask only the unbound ones (case_id NULL — every conversation that
    // existed before this migration stays a library conversation). The column is named case_id, so case erasure's
    // generic case-table pass removes the conversation with the case (its turns and in-case answers are removed
    // explicitly first, CaseErasure.eraseCaseAsk); a full erase empties the table as before.
    private static let v174: String = """
    ALTER TABLE conversations ADD COLUMN case_id TEXT;
    CREATE INDEX IF NOT EXISTS idx_conversations_case ON conversations(case_id, started_at);
    """

    // MARK: - v175 — chronology date precision and original wording (smart-map TIME-02, 2026-11-08).
    // A date-only chronology entry was stored as that day's midnight and nothing said the time was not known.
    // `date_precision` (DatePrecision.displayName: day, minute, …, unknown) travels with `event_date`;
    // `date_text` keeps the source's own wording of the date. Existing dated rows: 'unknown', except an entry
    // carried from a source (origin set: a passage or a result row, whose dates are day-only) stored at exactly
    // local midnight, which is 'day'. Nothing else is changed.
    private static let v175: String = """
    ALTER TABLE case_journal ADD COLUMN date_precision TEXT
        CHECK (date_precision IS NULL OR date_precision IN ('unknown','decade','year','quarter','month','day','minute','instant'));
    ALTER TABLE case_journal ADD COLUMN date_text TEXT;
    UPDATE case_journal SET date_precision =
        CASE WHEN origin IS NOT NULL AND event_date = CAST(event_date AS INTEGER)
                  AND time(event_date, 'unixepoch', 'localtime') = '00:00:00' THEN 'day' ELSE 'unknown' END
     WHERE event_date IS NOT NULL;
    """

    // MARK: - v176 — recursive frames, supplied reports with points, and the child-action contract (smart-map M1,
    // 2026-11-08: ARCH-03, GRAPH-01–03, REPORT-01–05, ACTION-01/03/04/11).
    // • case_map_layout is rebuilt with frame_key in its key: one canonical record can sit in several frames, each with
    //   its own position. Every existing position is kept as the case's root frame ('').
    // • case_reports: a supplied report (or a recorded result) as a canonical case record — its exact source version
    //   (when it has one), producer, author, examined material, report date (with the source's own wording), methods
    //   and limitations. An amendment or supplement is a NEW row naming the report it amends; nothing overwrites the
    //   first report. A result names the child action (task) it answers and the point it came from. Identity fields are
    //   never edited; a report is withdrawn with a reason.
    // • case_report_points: addressable points of a report — its kind (claim, finding, recommendation, allegation), the
    //   investigator's statement of the point, the exact quoted words with their locator (source version, block, the
    //   character span in that block, and a page/section note), the verification state, and the review state. A point
    //   accepted on review cannot have its wording, quote or locator changed (the trigger refuses it).
    // • case_report_qualifications: uncertainty, limitations, exclusions and conditions attached to a point (append-only).
    // • case_work_links: where work came from and what it serves — a question (allegation) or a task raised from a point,
    //   a task serving several questions or points. Withdrawn with a reason, never edited.
    // • case_action_contracts: the child-action contract over the ONE task engine (professional_tasks): mother case,
    //   parent action, purpose, deliverable, responsible person and reviewer (free text), the review state
    //   (not submitted / submitted / returned / accepted) and the outcome, both separate from the task's status, and
    //   self-review labelled as such.
    // Every table carries case_id, so case erasure's generic pass removes it, a full erase empties it, and backups carry
    // it as part of the encrypted ledger.
    private static let v176: String = """
    CREATE TABLE IF NOT EXISTS case_map_layout__v176 (
        case_id     TEXT NOT NULL,
        frame_key   TEXT NOT NULL DEFAULT '',
        record_kind TEXT NOT NULL CHECK (length(trim(record_kind)) > 0),
        record_id   TEXT NOT NULL CHECK (length(trim(record_id)) > 0),
        x           REAL NOT NULL,
        y           REAL NOT NULL,
        pinned      INTEGER NOT NULL DEFAULT 0 CHECK (pinned IN (0,1)),
        updated_at  REAL NOT NULL,
        PRIMARY KEY (case_id, frame_key, record_kind, record_id)
    );
    INSERT OR IGNORE INTO case_map_layout__v176 (case_id, frame_key, record_kind, record_id, x, y, pinned, updated_at)
        SELECT case_id, '', record_kind, record_id, x, y, pinned, updated_at FROM case_map_layout;
    DROP TABLE case_map_layout;
    ALTER TABLE case_map_layout__v176 RENAME TO case_map_layout;
    CREATE TABLE IF NOT EXISTS case_reports (
        id                 TEXT PRIMARY KEY NOT NULL,
        case_id            TEXT NOT NULL,
        title              TEXT NOT NULL CHECK (length(trim(title)) > 0),
        report_kind        TEXT NOT NULL CHECK (report_kind IN ('original','amendment','supplement','result')),
        amends_report_id   TEXT,
        source_version_id  TEXT,
        producer           TEXT,
        author             TEXT,
        examined_material  TEXT,
        report_date        REAL,
        report_date_text   TEXT,
        methods            TEXT,
        limitations        TEXT,
        origin_task_id     TEXT,
        origin_point_id    TEXT,
        recorded_by        TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at        REAL NOT NULL,
        withdrawn_by       TEXT,
        withdrawn_at       REAL,
        withdrawn_reason   TEXT,
        CHECK (report_kind NOT IN ('amendment','supplement') OR amends_report_id IS NOT NULL),
        CHECK (report_kind <> 'result' OR origin_task_id IS NOT NULL),
        CHECK (amends_report_id IS NULL OR amends_report_id <> id),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_reports_case ON case_reports(case_id, recorded_at);
    CREATE TRIGGER IF NOT EXISTS case_reports_fixed BEFORE UPDATE ON case_reports
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.report_kind <> OLD.report_kind
      OR NEW.amends_report_id IS NOT OLD.amends_report_id OR NEW.source_version_id IS NOT OLD.source_version_id
      OR NEW.title <> OLD.title OR NEW.origin_task_id IS NOT OLD.origin_task_id OR NEW.origin_point_id IS NOT OLD.origin_point_id
      OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_reports: a report is amended by a new report and withdrawn with a reason, never edited'); END;
    CREATE TABLE IF NOT EXISTS case_report_points (
        id                 TEXT PRIMARY KEY NOT NULL,
        case_id            TEXT NOT NULL,
        report_id          TEXT NOT NULL,
        ordinal            INTEGER NOT NULL DEFAULT 0,
        point_kind         TEXT NOT NULL CHECK (point_kind IN ('claim','finding','recommendation','allegation')),
        statement          TEXT NOT NULL CHECK (length(trim(statement)) > 0),
        quote              TEXT,
        source_version_id  TEXT,
        object_id          TEXT,
        block_id           TEXT,
        char_start         INTEGER,
        char_end           INTEGER,
        locator_note       TEXT,
        support_state      TEXT NOT NULL DEFAULT 'unverified' CHECK (support_state IN ('verified','unverified','note')),
        support_detail     TEXT,
        review_state       TEXT NOT NULL DEFAULT 'unreviewed' CHECK (review_state IN ('unreviewed','accepted','rejected')),
        reviewed_by        TEXT,
        reviewed_at        REAL,
        recorded_by        TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at        REAL NOT NULL,
        withdrawn_by       TEXT,
        withdrawn_at       REAL,
        withdrawn_reason   TEXT,
        CHECK (char_start IS NULL OR (char_end IS NOT NULL AND char_start >= 0 AND char_end >= char_start)),
        CHECK (review_state = 'unreviewed' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_report_points_case ON case_report_points(case_id, report_id, ordinal);
    CREATE TRIGGER IF NOT EXISTS case_report_points_accepted_fixed BEFORE UPDATE ON case_report_points
    WHEN NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.report_id <> OLD.report_id
      OR (OLD.review_state = 'accepted' AND (NEW.statement <> OLD.statement OR NEW.point_kind <> OLD.point_kind
          OR NEW.quote IS NOT OLD.quote OR NEW.source_version_id IS NOT OLD.source_version_id OR NEW.block_id IS NOT OLD.block_id
          OR NEW.char_start IS NOT OLD.char_start OR NEW.char_end IS NOT OLD.char_end))
    BEGIN SELECT RAISE(ABORT, 'case_report_points: an accepted point is not changed; record a new point or reopen its review'); END;
    CREATE TABLE IF NOT EXISTS case_report_qualifications (
        id                 TEXT PRIMARY KEY NOT NULL,
        case_id            TEXT NOT NULL,
        point_id           TEXT NOT NULL,
        qualification_kind TEXT NOT NULL CHECK (qualification_kind IN ('uncertainty','limitation','exclusion','condition')),
        text               TEXT NOT NULL CHECK (length(trim(text)) > 0),
        quote              TEXT,
        recorded_by        TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at        REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_report_qualifications_point ON case_report_qualifications(case_id, point_id);
    CREATE TRIGGER IF NOT EXISTS case_report_qualifications_fixed BEFORE UPDATE ON case_report_qualifications
    BEGIN SELECT RAISE(ABORT, 'case_report_qualifications are append-only'); END;
    CREATE TABLE IF NOT EXISTS case_work_links (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        work_kind        TEXT NOT NULL CHECK (work_kind IN ('allegation','task','report')),
        work_id          TEXT NOT NULL,
        target_kind      TEXT NOT NULL CHECK (target_kind IN ('point','allegation','hypothesis','report','task')),
        target_id        TEXT NOT NULL,
        role             TEXT NOT NULL CHECK (role IN ('raisedFrom','serves')),
        purpose          TEXT,
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (NOT (work_kind = target_kind AND work_id = target_id)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_case_work_links_case ON case_work_links(case_id, created_at);
    CREATE TRIGGER IF NOT EXISTS case_work_links_fixed BEFORE UPDATE ON case_work_links
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.work_kind <> OLD.work_kind
      OR NEW.work_id <> OLD.work_id OR NEW.target_kind <> OLD.target_kind OR NEW.target_id <> OLD.target_id OR NEW.role <> OLD.role
    BEGIN SELECT RAISE(ABORT, 'case_work_links: a link is withdrawn with a reason, never edited'); END;
    CREATE TABLE IF NOT EXISTS case_action_contracts (
        task_id        TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        parent_task_id TEXT,
        purpose        TEXT NOT NULL CHECK (length(trim(purpose)) > 0),
        deliverable    TEXT NOT NULL CHECK (length(trim(deliverable)) > 0),
        responsible    TEXT,
        reviewer       TEXT,
        review_state   TEXT NOT NULL DEFAULT 'notSubmitted' CHECK (review_state IN ('notSubmitted','submitted','returned','accepted')),
        review_kind    TEXT CHECK (review_kind IS NULL OR review_kind IN ('independent','self')),
        reviewed_by    TEXT,
        reviewed_at    REAL,
        review_note    TEXT,
        outcome        TEXT NOT NULL DEFAULT 'notRecorded' CHECK (outcome IN ('notRecorded','answered','discrepancyExplained','contradictionRemains','evidenceUnavailable','noRelevantResult','hypothesisChallenged','furtherWorkNeeded')),
        outcome_note   TEXT,
        created_by     TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at     REAL NOT NULL,
        updated_at     REAL NOT NULL,
        CHECK (parent_task_id IS NULL OR parent_task_id <> task_id),
        CHECK (review_state NOT IN ('returned','accepted') OR (review_kind IS NOT NULL AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_case_action_contracts_case ON case_action_contracts(case_id, parent_task_id);
    CREATE TRIGGER IF NOT EXISTS case_action_contracts_fixed BEFORE UPDATE ON case_action_contracts
    WHEN NEW.task_id <> OLD.task_id OR NEW.case_id <> OLD.case_id OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_action_contracts: an action keeps its case and its creation record'); END;
    """

    // MARK: - v177 — record and relationship contracts (smart-map M0, 2026-11-08: ARCH-02, ARCH-06, ARCH-07, DATA-01–DATA-05).
    // • case_frame_members: the investigator places a record of the case in a frame anchored on another record ("put
    //   this in that branch"). Membership is its own record — not a copy of either record and not a position — so one
    //   record can be a member of several frames while it is stored once. Withdrawn with a reason, never edited; one
    //   active membership per (frame, member).
    // • Action dependencies use the ONE task engine's existing professional_task_dependencies (v-era task schema, kind
    //   'waitsFor'); no new table. The case write checks both tasks are the case's and refuses a cycle.
    // • case_actors: stable actor identities per case. Every free-text actor name already in the case's action log is
    //   registered here as a LEGACY name (origin 'legacyName', authentication 'notAuthenticated'); a legacy name can
    //   never be turned into an authenticated user (the trigger refuses it) — it is history, not an account.
    // • Times kept apart: case_reports.received_at/received_text (when the report reached the case, as against its own
    //   report date and when it was entered), case_action_contracts.submitted_by/submitted_at (when a result was handed
    //   in, as against when it was reviewed).
    // • Integrity (DATA-02): the new tables refuse a row whose case does not exist, inside the same statement.
    // • Indexes (DATA-04): link endpoints, work-link endpoints, frame membership by frame and by member, contracts by
    //   review state (task dependencies are already indexed in both directions).
    // Every table carries case_id, so case erasure's generic pass removes it, a full erase empties it, and backups carry
    // it as part of the encrypted ledger.
    private static let v177: String = """
    CREATE TABLE IF NOT EXISTS case_frame_members (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        frame_kind       TEXT NOT NULL CHECK (length(trim(frame_kind)) > 0),
        frame_id         TEXT NOT NULL CHECK (length(trim(frame_id)) > 0),
        member_kind      TEXT NOT NULL CHECK (length(trim(member_kind)) > 0),
        member_id        TEXT NOT NULL CHECK (length(trim(member_id)) > 0),
        purpose          TEXT,
        added_by         TEXT NOT NULL CHECK (length(trim(added_by)) > 0),
        added_at         REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (NOT (frame_kind = member_kind AND frame_id = member_id)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_frame_members_active ON case_frame_members(case_id, frame_kind, frame_id, member_kind, member_id) WHERE withdrawn_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_case_frame_members_member ON case_frame_members(case_id, member_kind, member_id);
    CREATE TRIGGER IF NOT EXISTS case_frame_members_case BEFORE INSERT ON case_frame_members
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_frame_members: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_frame_members_fixed BEFORE UPDATE ON case_frame_members
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.frame_kind <> OLD.frame_kind
      OR NEW.frame_id <> OLD.frame_id OR NEW.member_kind <> OLD.member_kind OR NEW.member_id <> OLD.member_id
      OR NEW.purpose IS NOT OLD.purpose OR NEW.added_by <> OLD.added_by OR NEW.added_at <> OLD.added_at
    BEGIN SELECT RAISE(ABORT, 'case_frame_members: a membership is withdrawn with a reason, never edited'); END;
    CREATE TABLE IF NOT EXISTS case_actors (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        actor_kind     TEXT NOT NULL CHECK (actor_kind IN ('localUser','authenticatedUser','caseParticipant','reportedExternal','software')),
        display_name   TEXT NOT NULL CHECK (length(trim(display_name)) > 0),
        origin         TEXT NOT NULL CHECK (origin IN ('legacyName','recorded')),
        legacy_name    TEXT,
        authentication TEXT NOT NULL DEFAULT 'notAuthenticated' CHECK (authentication IN ('notAuthenticated','authenticated')),
        identity_ref   TEXT,
        case_person_id TEXT,
        created_at     REAL NOT NULL,
        CHECK (origin <> 'legacyName' OR (legacy_name IS NOT NULL AND authentication = 'notAuthenticated' AND actor_kind = 'localUser')),
        CHECK (authentication <> 'authenticated' OR (actor_kind = 'authenticatedUser' AND identity_ref IS NOT NULL))
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_actors_legacy ON case_actors(case_id, legacy_name) WHERE origin = 'legacyName';
    CREATE TRIGGER IF NOT EXISTS case_actors_case BEFORE INSERT ON case_actors
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_actors: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_actors_fixed BEFORE UPDATE ON case_actors
    WHEN NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.origin <> OLD.origin OR NEW.legacy_name IS NOT OLD.legacy_name
      OR NEW.created_at <> OLD.created_at OR (OLD.origin = 'legacyName' AND NEW.authentication <> 'notAuthenticated')
    BEGIN SELECT RAISE(ABORT, 'case_actors: an actor keeps its identity, and a legacy name never becomes an authenticated user'); END;
    INSERT OR IGNORE INTO case_actors (id, case_id, actor_kind, display_name, origin, legacy_name, authentication, created_at)
        SELECT upper(substr(h, 1, 8) || '-' || substr(h, 9, 4) || '-4' || substr(h, 14, 3) || '-8' || substr(h, 18, 3) || '-' || substr(h, 21, 12)),
               case_id, 'localUser', name, 'legacyName', name, 'notAuthenticated', first_at
        FROM (SELECT lower(hex(randomblob(16))) AS h, a.case_id AS case_id, trim(a.actor) AS name, MIN(a.at) AS first_at
              FROM case_actions a WHERE length(trim(coalesce(a.actor,''))) > 0 AND a.case_id IN (SELECT id FROM investigation_cases)
              GROUP BY a.case_id, trim(a.actor));
    ALTER TABLE case_reports ADD COLUMN received_at REAL;
    ALTER TABLE case_reports ADD COLUMN received_text TEXT;
    ALTER TABLE case_action_contracts ADD COLUMN submitted_by TEXT;
    ALTER TABLE case_action_contracts ADD COLUMN submitted_at REAL;
    CREATE INDEX IF NOT EXISTS idx_case_map_links_from ON case_map_links(case_id, from_kind, from_id);
    CREATE INDEX IF NOT EXISTS idx_case_map_links_to ON case_map_links(case_id, to_kind, to_id);
    CREATE INDEX IF NOT EXISTS idx_case_work_links_work ON case_work_links(case_id, work_kind, work_id);
    CREATE INDEX IF NOT EXISTS idx_case_work_links_target ON case_work_links(case_id, target_kind, target_id);
    CREATE INDEX IF NOT EXISTS idx_case_action_contracts_review ON case_action_contracts(case_id, review_state);
    """

    // MARK: - v178 — contribution intake and exact sources (smart-map S2, 2026-11-08: IN-01–IN-12, SRC-01–SRC-10).
    // Section comments name the task each statement serves. Case tables are registered in CaseDataInventory.
    private static let v178: String = """
    -- S2-A intake (IN-01, IN-05, IN-06, IN-07, IN-11, IN-12)
    -- IN-05: named trusted-source policies. An automatic inclusion names the policy that authorised it. 'workspaceAtOpening'
    --   covers only what the case's workspace held when the case was opened (covers_until); 'channelArrivals' covers only
    --   documents that arrive through its channel after the policy was made. A policy is withdrawn with a reason, never edited.
    CREATE TABLE IF NOT EXISTS case_intake_policies (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        name             TEXT NOT NULL CHECK (length(trim(name)) > 0),
        rule             TEXT NOT NULL CHECK (rule IN ('workspaceAtOpening','channelArrivals')),
        channel          TEXT NOT NULL CHECK (channel IN ('workspace','folderImport','fileImport','dragDrop','shareInbox','capture','deviceImport','manualEntry','message')),
        covers_until     REAL,
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (rule <> 'workspaceAtOpening' OR (covers_until IS NOT NULL AND channel = 'workspace')),
        CHECK (rule <> 'channelArrivals' OR (covers_until IS NULL AND channel NOT IN ('workspace','manualEntry','message'))),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_intake_policies_active ON case_intake_policies(case_id, rule, channel) WHERE withdrawn_at IS NULL;
    CREATE TRIGGER IF NOT EXISTS case_intake_policies_case BEFORE INSERT ON case_intake_policies
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_intake_policies: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_intake_policies_fixed BEFORE UPDATE ON case_intake_policies
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.name <> OLD.name OR NEW.rule <> OLD.rule
      OR NEW.channel <> OLD.channel OR NEW.covers_until IS NOT OLD.covers_until OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_intake_policies: a policy is withdrawn with a reason, never edited'); END;
    -- IN-01 / IN-11: the case-intake contract record. Every item a case takes in (a document from its workspace or a channel, a
    --   typed entry or message) has one row: channel, provenance, who supplied it, who entered it, who it claims to be written by,
    --   when it was captured (NULL = not known) and when it was actually received. The scope itself stays in
    --   investigation_case_sources; the first decision (by a person, or by a named policy) is recorded here once.
    CREATE TABLE IF NOT EXISTS case_intake_items (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        channel           TEXT NOT NULL CHECK (channel IN ('workspace','folderImport','fileImport','dragDrop','shareInbox','capture','deviceImport','manualEntry','message')),
        content_form      TEXT NOT NULL CHECK (content_form IN ('sourceDocument','typedEntry')),
        source_version_id TEXT,
        record_kind       TEXT,
        record_id         TEXT,
        label             TEXT NOT NULL CHECK (length(trim(label)) > 0),
        provenance        TEXT NOT NULL CHECK (length(trim(provenance)) > 0),
        ingest_run_id     TEXT,
        supplied_by       TEXT CHECK (supplied_by IS NULL OR length(trim(supplied_by)) > 0),
        entered_by        TEXT NOT NULL CHECK (length(trim(entered_by)) > 0),
        claimed_author    TEXT CHECK (claimed_author IS NULL OR length(trim(claimed_author)) > 0),
        captured_at       REAL,
        captured_text     TEXT,
        received_at       REAL NOT NULL,
        recorded_at       REAL NOT NULL,
        decision          TEXT CHECK (decision IS NULL OR decision IN ('included','excluded')),
        decided_via       TEXT CHECK (decided_via IS NULL OR decided_via IN ('person','policy')),
        decided_by        TEXT,
        decided_at        REAL,
        decision_note     TEXT,
        policy_id         TEXT,
        CHECK (content_form <> 'sourceDocument' OR (source_version_id IS NOT NULL AND record_id IS NULL AND channel NOT IN ('manualEntry','message'))),
        CHECK (content_form <> 'typedEntry' OR (source_version_id IS NULL AND record_kind = 'journal' AND record_id IS NOT NULL AND channel IN ('manualEntry','message'))),
        CHECK ((decided_at IS NULL) = (decision IS NULL) AND (decided_at IS NULL) = (decided_via IS NULL) AND (decided_at IS NULL) = (decided_by IS NULL)),
        CHECK (decided_via IS NOT 'policy' OR (policy_id IS NOT NULL AND decision = 'included')),
        CHECK (decided_via IS NOT 'person' OR policy_id IS NULL)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_intake_items_version ON case_intake_items(case_id, source_version_id) WHERE source_version_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_intake_items_record ON case_intake_items(case_id, record_kind, record_id) WHERE record_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS idx_case_intake_items_channel ON case_intake_items(case_id, channel, received_at);
    CREATE TRIGGER IF NOT EXISTS case_intake_items_case BEFORE INSERT ON case_intake_items
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_intake_items: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_intake_items_policy_insert BEFORE INSERT ON case_intake_items
    WHEN NEW.policy_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM case_intake_policies p WHERE p.id = NEW.policy_id AND p.case_id = NEW.case_id AND p.withdrawn_at IS NULL)
    BEGIN SELECT RAISE(ABORT, 'case_intake_items: an automatic inclusion must name an active policy of the same case'); END;
    CREATE TRIGGER IF NOT EXISTS case_intake_items_policy_update BEFORE UPDATE ON case_intake_items
    WHEN NEW.policy_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM case_intake_policies p WHERE p.id = NEW.policy_id AND p.case_id = NEW.case_id AND p.withdrawn_at IS NULL)
    BEGIN SELECT RAISE(ABORT, 'case_intake_items: an automatic inclusion must name an active policy of the same case'); END;
    CREATE TRIGGER IF NOT EXISTS case_intake_items_fixed BEFORE UPDATE ON case_intake_items
    WHEN OLD.decided_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.channel <> OLD.channel
      OR NEW.content_form <> OLD.content_form OR NEW.source_version_id IS NOT OLD.source_version_id OR NEW.record_kind IS NOT OLD.record_kind
      OR NEW.record_id IS NOT OLD.record_id OR NEW.label <> OLD.label OR NEW.provenance <> OLD.provenance OR NEW.ingest_run_id IS NOT OLD.ingest_run_id
      OR NEW.supplied_by IS NOT OLD.supplied_by OR NEW.entered_by <> OLD.entered_by OR NEW.claimed_author IS NOT OLD.claimed_author
      OR NEW.captured_at IS NOT OLD.captured_at OR NEW.captured_text IS NOT OLD.captured_text OR NEW.received_at <> OLD.received_at
      OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_intake_items: who supplied, entered and wrote an item and when it was captured and received are fixed; the first decision is recorded once'); END;
    -- IN-12: the durable ingest run (PI.3) is the batch receipt. Each file it selected records what happened to it: received (a new
    --   document or version), already held, an exact duplicate of another document, failed or timed out, with the version it became.
    ALTER TABLE ingest_runs ADD COLUMN channel TEXT CHECK (channel IS NULL OR channel IN ('workspace','folderImport','fileImport','dragDrop','shareInbox','capture','deviceImport','manualEntry','message'));
    ALTER TABLE ingest_run_files ADD COLUMN channel TEXT CHECK (channel IS NULL OR channel IN ('workspace','folderImport','fileImport','dragDrop','shareInbox','capture','deviceImport','manualEntry','message'));
    ALTER TABLE ingest_run_files ADD COLUMN outcome TEXT CHECK (outcome IS NULL OR outcome IN ('received','alreadyHeld','duplicate','failed','timedOut'));
    ALTER TABLE ingest_run_files ADD COLUMN source_version_id TEXT;
    ALTER TABLE ingest_run_files ADD COLUMN intake_outcome TEXT CHECK (intake_outcome IS NULL OR intake_outcome IN ('newLogicalSource','newVersion','unchanged','moved','aliased'));
    CREATE INDEX IF NOT EXISTS idx_ingest_run_files_version ON ingest_run_files(source_version_id) WHERE source_version_id IS NOT NULL;
    -- IN-06: content-equivalent sources (same normalised text, different bytes) are a class of their own, found through a text
    --   digest per version; a revised document at a new location is linked to its earlier version only when a person confirms it.
    --   Neither merges anything: both versions, their receipts and every transaction or event read from them stay separate.
    CREATE TABLE IF NOT EXISTS source_text_digests (
        source_version_id TEXT PRIMARY KEY NOT NULL,
        text_sha256       TEXT NOT NULL CHECK (length(text_sha256) = 64),
        normalizer        TEXT NOT NULL CHECK (length(trim(normalizer)) > 0),
        character_count   INTEGER NOT NULL CHECK (character_count > 0),
        computed_at       REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_source_text_digests_text ON source_text_digests(text_sha256);
    CREATE TABLE IF NOT EXISTS source_version_links (
        id                        TEXT PRIMARY KEY NOT NULL,
        source_version_id         TEXT NOT NULL,
        earlier_source_version_id TEXT NOT NULL,
        relation                  TEXT NOT NULL CHECK (relation IN ('revisionOf')),
        basis                     TEXT NOT NULL CHECK (length(trim(basis)) > 0),
        confirmed_by              TEXT NOT NULL CHECK (length(trim(confirmed_by)) > 0),
        confirmed_at              REAL NOT NULL,
        withdrawn_by              TEXT,
        withdrawn_at              REAL,
        withdrawn_reason          TEXT,
        CHECK (source_version_id <> earlier_source_version_id),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_source_version_links_active ON source_version_links(source_version_id, earlier_source_version_id, relation) WHERE withdrawn_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_source_version_links_earlier ON source_version_links(earlier_source_version_id);
    CREATE TRIGGER IF NOT EXISTS source_version_links_versions BEFORE INSERT ON source_version_links
    WHEN NOT EXISTS (SELECT 1 FROM source_versions WHERE id = NEW.source_version_id)
      OR NOT EXISTS (SELECT 1 FROM source_versions WHERE id = NEW.earlier_source_version_id)
      OR (SELECT logical_source_id FROM source_versions WHERE id = NEW.source_version_id) = (SELECT logical_source_id FROM source_versions WHERE id = NEW.earlier_source_version_id)
    BEGIN SELECT RAISE(ABORT, 'source_version_links: both versions must exist and belong to different documents'); END;
    CREATE TRIGGER IF NOT EXISTS source_version_links_fixed BEFORE UPDATE ON source_version_links
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.source_version_id <> OLD.source_version_id
      OR NEW.earlier_source_version_id <> OLD.earlier_source_version_id OR NEW.relation <> OLD.relation OR NEW.basis <> OLD.basis
      OR NEW.confirmed_by <> OLD.confirmed_by OR NEW.confirmed_at <> OLD.confirmed_at
    BEGIN SELECT RAISE(ABORT, 'source_version_links: a link is withdrawn with a reason, never edited'); END;
    -- Erasure: a source version that is erased takes its digest, its links (either end), its intake records and its batch-receipt
    --   lines with it (the generic source pass already removes rows keyed by source_version_id; this also covers the other end).
    CREATE TRIGGER IF NOT EXISTS source_versions_erase_intake AFTER DELETE ON source_versions
    BEGIN
        DELETE FROM source_version_links WHERE source_version_id = OLD.id OR earlier_source_version_id = OLD.id;
        DELETE FROM source_text_digests WHERE source_version_id = OLD.id;
        DELETE FROM case_intake_items WHERE source_version_id = OLD.id;
        DELETE FROM ingest_run_files WHERE source_version_id = OLD.id;
    END;
    -- end S2-A
    -- S2-B extraction (SRC-02, SRC-03, SRC-04, SRC-07, SRC-10)
    -- SRC-02: each passage names the reader run that produced it (reader, reader version, start and end of the run, the
    -- run's coverage), and each run records the recognition engines it used with their versions (OCR / speech / layout).
    -- Both ride with their source version (source_version_id), so case erasure's generic pass and full erase remove them.
    ALTER TABLE evidence_blocks ADD COLUMN parser_run_id TEXT;
    ALTER TABLE parser_runs ADD COLUMN engines TEXT;
    CREATE INDEX IF NOT EXISTS idx_blocks_parser_run ON evidence_blocks(parser_run_id);
    -- SRC-03: the qualifiers of the source sentence a point's words were cut from (speaker, reported speech, negation,
    -- uncertainty, proposed/future, condition, date) and that full sentence; the qualifiers of an extracted assertion's quote.
    ALTER TABLE case_report_points ADD COLUMN qualifiers_json TEXT;
    ALTER TABLE case_report_points ADD COLUMN quote_context TEXT;
    ALTER TABLE assertions ADD COLUMN qualifiers_json TEXT;
    -- SRC-04: the quoted words and their locator never change after they are recorded — a summary or statement may be
    -- reworded, the source quotation may not (a different quotation is a new record).
    CREATE TRIGGER IF NOT EXISTS case_report_points_words_fixed BEFORE UPDATE ON case_report_points
    WHEN NEW.quote IS NOT OLD.quote OR NEW.source_version_id IS NOT OLD.source_version_id OR NEW.object_id IS NOT OLD.object_id
      OR NEW.block_id IS NOT OLD.block_id OR NEW.char_start IS NOT OLD.char_start OR NEW.char_end IS NOT OLD.char_end
      OR NEW.qualifiers_json IS NOT OLD.qualifiers_json OR NEW.quote_context IS NOT OLD.quote_context
    BEGIN SELECT RAISE(ABORT, 'case_report_points: the quoted words and their locator are never changed; record a new point'); END;
    CREATE TRIGGER IF NOT EXISTS case_journal_quote_fixed BEFORE UPDATE ON case_journal
    WHEN NEW.quote IS NOT OLD.quote OR NEW.citations_json IS NOT OLD.citations_json OR NEW.evidence_ref IS NOT OLD.evidence_ref
    BEGIN SELECT RAISE(ABORT, 'case_journal: the quoted source words and citations are never changed in place'); END;
    CREATE TRIGGER IF NOT EXISTS case_report_items_quote_fixed BEFORE UPDATE ON case_report_items
    WHEN NEW.quote IS NOT OLD.quote OR NEW.citations_json IS NOT OLD.citations_json OR NEW.evidence_ref IS NOT OLD.evidence_ref
    BEGIN SELECT RAISE(ABORT, 'case_report_items: the quoted source words and citations are never changed in place'); END;
    -- end S2-B
    -- S2-C sources (IN-03, IN-04, IN-08, IN-09, IN-10, SRC-05, SRC-06)
    -- IN-09: the OUTCOME of each attempt to open a protected source version. The password is never
    -- stored (there is no column for it); `derived_source_version_id` names the opened copy, if any.
    -- Keyed by source_version_id, so source erasure removes it with the version (and the FK cascades).
    CREATE TABLE IF NOT EXISTS source_unlock_attempts (
        id                         TEXT PRIMARY KEY NOT NULL,
        source_version_id          TEXT NOT NULL,
        outcome                    TEXT NOT NULL,
        detail                     TEXT,
        derived_source_version_id  TEXT,
        attempted_at               REAL NOT NULL,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(outcome IN ('notProtected','unlocked','wrongPassword','passwordNeeded',
                          'unsupportedEncryption','corrupt','locked','unavailable'))
    );
    CREATE INDEX IF NOT EXISTS idx_source_unlock_attempts_version ON source_unlock_attempts(source_version_id, attempted_at);
    -- SRC-06: how a derived source version (a decrypted copy, a converted image, a transcript file) was
    -- made from its original. The derived copy is its own source version linked by the existing
    -- 'derivedConversion' source_version_relations row; this records the method. source_version_id is
    -- the DERIVED version, so erasing either version removes the row.
    CREATE TABLE IF NOT EXISTS source_conversions (
        source_version_id           TEXT PRIMARY KEY NOT NULL,
        original_source_version_id  TEXT NOT NULL,
        method                      TEXT NOT NULL,
        detail                      TEXT,
        recorded_at                 REAL NOT NULL,
        FOREIGN KEY(source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        FOREIGN KEY(original_source_version_id) REFERENCES source_versions(id) ON DELETE CASCADE,
        CHECK(source_version_id <> original_source_version_id),
        CHECK(length(trim(method)) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_source_conversions_original ON source_conversions(original_source_version_id);
    -- end S2-C
    """
    // MARK: - v179 — graph, map and brief (smart-map S3, 2026-11-08: GRAPH-04/08/09, BRIEF-02/05/06/08).
    // Section comments name the task each statement serves. Case tables are registered in CaseDataInventory; every one
    // carries case_id, so the generic pass of a case erasure removes it and a backup carries it inside the encrypted ledger.
    private static let v179: String = """
    -- MAP-06: the view strip gains Evidence, Money and Work, so a saved view may be based on them. case_map_views is rebuilt
    --   with the wider CHECK (every row and the index kept exactly; nothing else refers to the table).
    CREATE TABLE case_map_views__v179 (
        id           TEXT PRIMARY KEY NOT NULL,
        case_id      TEXT NOT NULL,
        name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
        base_view    TEXT NOT NULL CHECK (base_view IN ('overview','questions','people','evidence','money','chronology','work','findings','changes')),
        filters_json TEXT NOT NULL DEFAULT '{}',
        ordinal      INTEGER NOT NULL DEFAULT 0,
        created_by   TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at   REAL NOT NULL,
        updated_at   REAL NOT NULL
    );
    INSERT INTO case_map_views__v179 (id, case_id, name, base_view, filters_json, ordinal, created_by, created_at, updated_at)
        SELECT id, case_id, name, base_view, filters_json, ordinal, created_by, created_at, updated_at FROM case_map_views;
    DROP TABLE case_map_views;
    ALTER TABLE case_map_views__v179 RENAME TO case_map_views;
    CREATE INDEX IF NOT EXISTS idx_case_map_views_case ON case_map_views(case_id, ordinal);
    -- GRAPH-04 / GRAPH-08: an investigator's link states how certain it is (never assumed), when it holds (a period, or the
    --   source's own wording), and which earlier link it revises. A revision is a NEW link; the earlier one is withdrawn
    --   with the reason, so the history of a link is its chain. None of these is ever edited.
    ALTER TABLE case_map_links ADD COLUMN certainty TEXT CHECK (certainty IS NULL OR certainty IN ('notStated','statedBySource','probable','possible','doubtful'));
    ALTER TABLE case_map_links ADD COLUMN valid_from REAL;
    ALTER TABLE case_map_links ADD COLUMN valid_to REAL;
    ALTER TABLE case_map_links ADD COLUMN valid_text TEXT;
    ALTER TABLE case_map_links ADD COLUMN revises_link_id TEXT;
    CREATE TRIGGER IF NOT EXISTS case_map_links_v179_fixed BEFORE UPDATE ON case_map_links
    WHEN NEW.certainty IS NOT OLD.certainty OR NEW.valid_from IS NOT OLD.valid_from OR NEW.valid_to IS NOT OLD.valid_to
      OR NEW.valid_text IS NOT OLD.valid_text OR NEW.revises_link_id IS NOT OLD.revises_link_id
    BEGIN SELECT RAISE(ABORT, 'case_map_links: certainty, validity and revision are fixed; revise the link instead'); END;
    CREATE INDEX IF NOT EXISTS idx_case_map_links_revises ON case_map_links(revises_link_id) WHERE revises_link_id IS NOT NULL;
    -- GRAPH-09: a recorded decision that two case-person rows are, or are not, the same person. Nothing is merged: both rows
    --   keep their own statements, links and history; withdrawing the decision (with a reason) puts the pair back to
    --   pending. One active decision per pair (person_a < person_b).
    CREATE TABLE IF NOT EXISTS case_person_identity_decisions (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        person_a         TEXT NOT NULL,
        person_b         TEXT NOT NULL,
        decision         TEXT NOT NULL CHECK (decision IN ('samePerson','differentPeople')),
        rationale        TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
        decided_by       TEXT NOT NULL CHECK (length(trim(decided_by)) > 0),
        decided_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (person_a < person_b),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_person_identity_active ON case_person_identity_decisions(case_id, person_a, person_b) WHERE withdrawn_at IS NULL;
    CREATE TRIGGER IF NOT EXISTS case_person_identity_case BEFORE INSERT ON case_person_identity_decisions
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_person_identity_decisions: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_person_identity_fixed BEFORE UPDATE ON case_person_identity_decisions
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.person_a <> OLD.person_a OR NEW.person_b <> OLD.person_b
      OR NEW.decision <> OLD.decision OR NEW.rationale <> OLD.rationale OR NEW.decided_by <> OLD.decided_by OR NEW.decided_at <> OLD.decided_at
    BEGIN SELECT RAISE(ABORT, 'case_person_identity_decisions: a decision is withdrawn with a reason, never edited'); END;
    -- BRIEF-02 / BRIEF-06: the investigator's structured brief of the case (anchor 'case') or of one branch (any record),
    --   kept as numbered versions. A version is written as a draft, may be accepted once, and is then never edited; a change
    --   is a new version that names the one it supersedes. Each version keeps the case revision fence it was written
    --   against, so a later change shows it as written before that change. origin says who wrote it: a person, or (later)
    --   generated text, which must name what generated it and is labelled as such.
    CREATE TABLE IF NOT EXISTS case_briefs (
        id            TEXT PRIMARY KEY NOT NULL,
        case_id       TEXT NOT NULL,
        anchor_kind   TEXT NOT NULL CHECK (length(trim(anchor_kind)) > 0),
        anchor_id     TEXT NOT NULL CHECK (length(trim(anchor_id)) > 0),
        version       INTEGER NOT NULL CHECK (version >= 1),
        purpose       TEXT,
        position      TEXT,
        unresolved    TEXT,
        alternatives  TEXT,
        next_work     TEXT,
        origin        TEXT NOT NULL CHECK (origin IN ('manual','generated')),
        generated_by  TEXT,
        fence         TEXT NOT NULL CHECK (length(fence) > 0),
        written_by    TEXT NOT NULL CHECK (length(trim(written_by)) > 0),
        written_at    REAL NOT NULL,
        accepted_by   TEXT,
        accepted_at   REAL,
        supersedes_id TEXT,
        CHECK (origin <> 'generated' OR length(trim(coalesce(generated_by,''))) > 0),
        CHECK (origin <> 'manual' OR generated_by IS NULL),
        CHECK ((accepted_at IS NULL) = (accepted_by IS NULL)),
        CHECK (coalesce(purpose,'') || coalesce(position,'') || coalesce(unresolved,'') || coalesce(alternatives,'') || coalesce(next_work,'') <> '')
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_briefs_version ON case_briefs(case_id, anchor_kind, anchor_id, version);
    CREATE TRIGGER IF NOT EXISTS case_briefs_case BEFORE INSERT ON case_briefs
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_briefs: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_briefs_fixed BEFORE UPDATE ON case_briefs
    WHEN OLD.accepted_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.anchor_kind <> OLD.anchor_kind
      OR NEW.anchor_id <> OLD.anchor_id OR NEW.version <> OLD.version OR NEW.purpose IS NOT OLD.purpose OR NEW.position IS NOT OLD.position
      OR NEW.unresolved IS NOT OLD.unresolved OR NEW.alternatives IS NOT OLD.alternatives OR NEW.next_work IS NOT OLD.next_work
      OR NEW.origin <> OLD.origin OR NEW.generated_by IS NOT OLD.generated_by OR NEW.fence <> OLD.fence OR NEW.written_by <> OLD.written_by
      OR NEW.written_at <> OLD.written_at OR NEW.supersedes_id IS NOT OLD.supersedes_id
    BEGIN SELECT RAISE(ABORT, 'case_briefs: a brief version is accepted once and never edited; write a new version'); END;
    -- BRIEF-05: the investigator sets an item aside from the brief (or keeps it in), with the reason. The item and its
    --   evidence are untouched; withdrawing the decision brings it back.
    CREATE TABLE IF NOT EXISTS case_brief_relevance (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        record_kind      TEXT NOT NULL CHECK (length(trim(record_kind)) > 0),
        record_id        TEXT NOT NULL CHECK (length(trim(record_id)) > 0),
        decision         TEXT NOT NULL CHECK (decision IN ('setAside','keep')),
        reason           TEXT NOT NULL CHECK (length(trim(reason)) > 0),
        decided_by       TEXT NOT NULL CHECK (length(trim(decided_by)) > 0),
        decided_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_brief_relevance_active ON case_brief_relevance(case_id, record_kind, record_id) WHERE withdrawn_at IS NULL;
    CREATE TRIGGER IF NOT EXISTS case_brief_relevance_case BEFORE INSERT ON case_brief_relevance
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_brief_relevance: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_brief_relevance_fixed BEFORE UPDATE ON case_brief_relevance
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.record_kind <> OLD.record_kind
      OR NEW.record_id <> OLD.record_id OR NEW.decision <> OLD.decision OR NEW.reason <> OLD.reason OR NEW.decided_by <> OLD.decided_by
      OR NEW.decided_at <> OLD.decided_at
    BEGIN SELECT RAISE(ABORT, 'case_brief_relevance: a decision is withdrawn with a reason, never edited'); END;
    -- BRIEF-08: a briefing — a curated, ordered path through the case for a handover or review. Its items REFERENCE
    --   canonical records, frames (branches) and saved views (no copy). A live briefing resolves them against the case as it
    --   is now and shows what changed since each was added; freezing records the state of every item at that moment
    --   (frozen_json) with the case fence, after which neither the briefing nor its items change.
    CREATE TABLE IF NOT EXISTS case_briefings (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        title            TEXT NOT NULL CHECK (length(trim(title)) > 0),
        purpose          TEXT,
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        frozen_by        TEXT,
        frozen_at        REAL,
        frozen_fence     TEXT,
        frozen_json      TEXT,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK ((frozen_at IS NULL) = (frozen_by IS NULL) AND (frozen_at IS NULL) = (frozen_fence IS NULL) AND (frozen_at IS NULL) = (frozen_json IS NULL)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE TRIGGER IF NOT EXISTS case_briefings_case BEFORE INSERT ON case_briefings
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_briefings: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_briefings_fixed BEFORE UPDATE ON case_briefings
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.created_by <> OLD.created_by
      OR NEW.created_at <> OLD.created_at
      OR (OLD.frozen_at IS NOT NULL AND (NEW.title <> OLD.title OR NEW.purpose IS NOT OLD.purpose OR NEW.frozen_by IS NOT OLD.frozen_by
          OR NEW.frozen_at IS NOT OLD.frozen_at OR NEW.frozen_fence IS NOT OLD.frozen_fence OR NEW.frozen_json IS NOT OLD.frozen_json))
    BEGIN SELECT RAISE(ABORT, 'case_briefings: a frozen briefing is never edited (it can only be withdrawn with a reason)'); END;
    CREATE TABLE IF NOT EXISTS case_briefing_items (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        briefing_id      TEXT NOT NULL,
        ordinal          INTEGER NOT NULL,
        item_kind        TEXT NOT NULL CHECK (item_kind IN ('record','frame','savedView','note')),
        record_kind      TEXT,
        record_id        TEXT,
        view_id          TEXT,
        note             TEXT,
        revision_at_add  TEXT,
        added_by         TEXT NOT NULL CHECK (length(trim(added_by)) > 0),
        added_at         REAL NOT NULL,
        removed_by       TEXT,
        removed_at       REAL,
        CHECK (item_kind NOT IN ('record','frame') OR (record_kind IS NOT NULL AND record_id IS NOT NULL)),
        CHECK (item_kind <> 'savedView' OR view_id IS NOT NULL),
        CHECK (item_kind <> 'note' OR length(trim(coalesce(note,''))) > 0),
        CHECK ((removed_at IS NULL) = (removed_by IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_case_briefing_items_briefing ON case_briefing_items(briefing_id, ordinal);
    CREATE INDEX IF NOT EXISTS idx_case_briefing_items_record ON case_briefing_items(case_id, record_kind, record_id);
    CREATE TRIGGER IF NOT EXISTS case_briefing_items_insert BEFORE INSERT ON case_briefing_items
    WHEN NOT EXISTS (SELECT 1 FROM case_briefings b WHERE b.id = NEW.briefing_id AND b.case_id = NEW.case_id AND b.frozen_at IS NULL AND b.withdrawn_at IS NULL)
    BEGIN SELECT RAISE(ABORT, 'case_briefing_items: items are added only to an open (not frozen, not withdrawn) briefing of the same case'); END;
    CREATE TRIGGER IF NOT EXISTS case_briefing_items_fixed BEFORE UPDATE ON case_briefing_items
    WHEN OLD.removed_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.briefing_id <> OLD.briefing_id
      OR NEW.item_kind <> OLD.item_kind OR NEW.record_kind IS NOT OLD.record_kind OR NEW.record_id IS NOT OLD.record_id
      OR NEW.view_id IS NOT OLD.view_id OR NEW.note IS NOT OLD.note OR NEW.revision_at_add IS NOT OLD.revision_at_add
      OR NEW.added_by <> OLD.added_by OR NEW.added_at <> OLD.added_at
      OR EXISTS (SELECT 1 FROM case_briefings b WHERE b.id = OLD.briefing_id AND b.frozen_at IS NOT NULL)
    BEGIN SELECT RAISE(ABORT, 'case_briefing_items: an item is removed (not edited), and a frozen briefing keeps every item'); END;
    """
    // MARK: - v180 — search and reports (smart-map S4, 2026-11-08: SEARCH-10, REPORT-02/04/06/07/08/09).
    // Every new table carries case_id (registered in CaseDataInventory), so the generic pass of a case erasure removes it and
    // a backup carries it inside the encrypted ledger. Person erasure removes point uses that name a case-person row.
    private static let v180: String = """
    -- REPORT-04: work opened from a point may be an evidence request, and an action may COMPARE the point with another record.
    --   case_work_links is rebuilt with the wider CHECKs (every row, the update guard and the three indexes kept exactly).
    CREATE TABLE case_work_links__v180 (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        work_kind        TEXT NOT NULL CHECK (work_kind IN ('allegation','task','report','request')),
        work_id          TEXT NOT NULL,
        target_kind      TEXT NOT NULL CHECK (target_kind IN ('point','allegation','hypothesis','report','task')),
        target_id        TEXT NOT NULL,
        role             TEXT NOT NULL CHECK (role IN ('raisedFrom','serves','compares')),
        purpose          TEXT,
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (NOT (work_kind = target_kind AND work_id = target_id)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL))
    );
    INSERT INTO case_work_links__v180 (id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at, withdrawn_by, withdrawn_at, withdrawn_reason)
        SELECT id, case_id, work_kind, work_id, target_kind, target_id, role, purpose, created_by, created_at, withdrawn_by, withdrawn_at, withdrawn_reason FROM case_work_links;
    DROP TABLE case_work_links;
    ALTER TABLE case_work_links__v180 RENAME TO case_work_links;
    CREATE INDEX IF NOT EXISTS idx_case_work_links_case ON case_work_links(case_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_case_work_links_work ON case_work_links(case_id, work_kind, work_id);
    CREATE INDEX IF NOT EXISTS idx_case_work_links_target ON case_work_links(case_id, target_kind, target_id);
    CREATE TRIGGER IF NOT EXISTS case_work_links_fixed BEFORE UPDATE ON case_work_links
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.work_kind <> OLD.work_kind
      OR NEW.work_id <> OLD.work_id OR NEW.target_kind <> OLD.target_kind OR NEW.target_id <> OLD.target_id OR NEW.role <> OLD.role
    BEGIN SELECT RAISE(ABORT, 'case_work_links: a link is withdrawn with a reason, never edited'); END;
    -- REPORT-02: a report's sections (headings as the report numbers them), nested by parent; withdrawn with a reason, never
    --   edited. A point names the section it belongs to and, in the same step, the time it is about (a date and the report's
    --   own wording). An accepted proposal names the point it became.
    CREATE TABLE IF NOT EXISTS case_report_sections (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        report_id         TEXT NOT NULL,
        parent_section_id TEXT,
        ordinal           INTEGER NOT NULL CHECK (ordinal >= 1),
        heading           TEXT NOT NULL CHECK (length(trim(heading)) > 0),
        locator_note      TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (parent_section_id IS NULL OR parent_section_id <> id),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_report_sections_report ON case_report_sections(case_id, report_id, ordinal);
    CREATE TRIGGER IF NOT EXISTS case_report_sections_case BEFORE INSERT ON case_report_sections
    WHEN NOT EXISTS (SELECT 1 FROM case_reports r WHERE r.id = NEW.report_id AND r.case_id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_report_sections: the report is not a report of this case'); END;
    CREATE TRIGGER IF NOT EXISTS case_report_sections_fixed BEFORE UPDATE ON case_report_sections
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.report_id <> OLD.report_id
      OR NEW.parent_section_id IS NOT OLD.parent_section_id OR NEW.ordinal <> OLD.ordinal OR NEW.heading <> OLD.heading
      OR NEW.locator_note IS NOT OLD.locator_note OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_report_sections: a section is withdrawn with a reason, never edited'); END;
    ALTER TABLE case_report_points ADD COLUMN section_id TEXT;
    ALTER TABLE case_report_points ADD COLUMN event_at REAL;
    ALTER TABLE case_report_points ADD COLUMN event_text TEXT;
    ALTER TABLE case_report_points ADD COLUMN proposal_id TEXT;
    CREATE TRIGGER IF NOT EXISTS case_report_points_v180_fixed BEFORE UPDATE ON case_report_points
    WHEN NEW.section_id IS NOT OLD.section_id OR NEW.event_at IS NOT OLD.event_at OR NEW.event_text IS NOT OLD.event_text
      OR NEW.proposal_id IS NOT OLD.proposal_id
    BEGIN SELECT RAISE(ABORT, 'case_report_points: the section, the time and the proposal a point came from are fixed when it is recorded'); END;
    -- REPORT-02 / REPORT-06: suggested points from a rule-based reading of the report's own text (AI off). A suggestion is a
    --   PROPOSAL, never a point: it is accepted (which records a point through the case's verifier) or dismissed by a person.
    --   Reading the report again adds only sentences not proposed before for that source version (the unique index); an
    --   accepted or dismissed proposal is never re-proposed, and nothing here can change a point.
    CREATE TABLE IF NOT EXISTS case_report_point_proposals (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        report_id         TEXT NOT NULL,
        run_id            TEXT NOT NULL,
        source_version_id TEXT NOT NULL,
        block_id          TEXT,
        quote             TEXT NOT NULL CHECK (length(trim(quote)) > 0),
        statement         TEXT NOT NULL CHECK (length(trim(statement)) > 0),
        point_kind        TEXT NOT NULL CHECK (point_kind IN ('claim','finding','recommendation','allegation')),
        section_hint      TEXT,
        rule              TEXT NOT NULL CHECK (length(trim(rule)) > 0),
        rule_version      INTEGER NOT NULL CHECK (rule_version >= 1),
        state             TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed','accepted','dismissed')),
        decided_by        TEXT,
        decided_at        REAL,
        decision_note     TEXT,
        point_id          TEXT,
        recorded_at       REAL NOT NULL,
        CHECK ((decided_at IS NULL) = (state = 'proposed') AND (decided_at IS NULL) = (decided_by IS NULL)),
        CHECK (state <> 'accepted' OR point_id IS NOT NULL),
        CHECK (state <> 'dismissed' OR length(trim(coalesce(decision_note,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_report_point_proposals_quote ON case_report_point_proposals(case_id, report_id, source_version_id, quote);
    CREATE INDEX IF NOT EXISTS idx_case_report_point_proposals_report ON case_report_point_proposals(case_id, report_id, state);
    CREATE TRIGGER IF NOT EXISTS case_report_point_proposals_case BEFORE INSERT ON case_report_point_proposals
    WHEN NOT EXISTS (SELECT 1 FROM case_reports r WHERE r.id = NEW.report_id AND r.case_id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_report_point_proposals: the report is not a report of this case'); END;
    CREATE TRIGGER IF NOT EXISTS case_report_point_proposals_fixed BEFORE UPDATE ON case_report_point_proposals
    WHEN OLD.state <> 'proposed' OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.report_id <> OLD.report_id OR NEW.run_id <> OLD.run_id
      OR NEW.source_version_id <> OLD.source_version_id OR NEW.block_id IS NOT OLD.block_id OR NEW.quote <> OLD.quote
      OR NEW.statement <> OLD.statement OR NEW.point_kind <> OLD.point_kind OR NEW.section_hint IS NOT OLD.section_hint
      OR NEW.rule <> OLD.rule OR NEW.rule_version <> OLD.rule_version OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_report_point_proposals: a proposal is decided once and never edited'); END;
    -- REPORT-07 (and the person/question links of REPORT-02): the SAME point used in another branch — a question, a person,
    --   a chronology entry, a money movement, a hypothesis, a briefing or an output. A use references the point (never a copy)
    --   and records the point's review state and wording digest at the moment it was used, so a later change shows as such.
    CREATE TABLE IF NOT EXISTS case_report_point_uses (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        point_id            TEXT NOT NULL,
        context_kind        TEXT NOT NULL CHECK (context_kind IN ('question','person','chronology','money','hypothesis','briefing','output')),
        context_id          TEXT NOT NULL CHECK (length(trim(context_id)) > 0),
        note                TEXT,
        review_at_use       TEXT NOT NULL CHECK (review_at_use IN ('unreviewed','accepted','rejected')),
        digest_at_use       TEXT NOT NULL CHECK (length(digest_at_use) = 64),
        created_by          TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at          REAL NOT NULL,
        withdrawn_by        TEXT,
        withdrawn_at        REAL,
        withdrawn_reason    TEXT,
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_report_point_uses_active ON case_report_point_uses(case_id, point_id, context_kind, context_id) WHERE withdrawn_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_case_report_point_uses_context ON case_report_point_uses(case_id, context_kind, context_id);
    CREATE TRIGGER IF NOT EXISTS case_report_point_uses_case BEFORE INSERT ON case_report_point_uses
    WHEN NOT EXISTS (SELECT 1 FROM case_report_points p WHERE p.id = NEW.point_id AND p.case_id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_report_point_uses: the point is not a point of this case'); END;
    CREATE TRIGGER IF NOT EXISTS case_report_point_uses_fixed BEFORE UPDATE ON case_report_point_uses
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.point_id <> OLD.point_id
      OR NEW.context_kind <> OLD.context_kind OR NEW.context_id <> OLD.context_id OR NEW.note IS NOT OLD.note
      OR NEW.review_at_use <> OLD.review_at_use OR NEW.digest_at_use <> OLD.digest_at_use OR NEW.created_by <> OLD.created_by
      OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_report_point_uses: a use is withdrawn with a reason, never edited'); END;
    -- REPORT-08: a recorded comparison of two versions of a report (an original and its amendment or supplement) — the
    --   wording, qualification and field changes and the work that depends on a changed point, as computed then (never edited).
    --   Work depending on a changed or removed point gets a review-needed flag; no decision, review or outcome is changed.
    CREATE TABLE IF NOT EXISTS case_report_comparisons (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        earlier_report_id TEXT NOT NULL,
        later_report_id   TEXT NOT NULL,
        result_json       TEXT NOT NULL,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        CHECK (earlier_report_id <> later_report_id)
    );
    CREATE INDEX IF NOT EXISTS idx_case_report_comparisons_case ON case_report_comparisons(case_id, recorded_at);
    CREATE TRIGGER IF NOT EXISTS case_report_comparisons_fixed BEFORE UPDATE ON case_report_comparisons
    BEGIN SELECT RAISE(ABORT, 'case_report_comparisons: a recorded comparison is never edited'); END;
    CREATE TABLE IF NOT EXISTS case_work_review_flags (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        work_kind      TEXT NOT NULL CHECK (work_kind IN ('allegation','task','report','request')),
        work_id        TEXT NOT NULL,
        point_id       TEXT NOT NULL,
        comparison_id  TEXT NOT NULL,
        reason         TEXT NOT NULL CHECK (length(trim(reason)) > 0),
        raised_at      REAL NOT NULL,
        cleared_by     TEXT,
        cleared_at     REAL,
        clear_note     TEXT,
        CHECK ((cleared_at IS NULL) = (cleared_by IS NULL))
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_work_review_flags_once ON case_work_review_flags(case_id, work_kind, work_id, point_id, comparison_id);
    CREATE TRIGGER IF NOT EXISTS case_work_review_flags_fixed BEFORE UPDATE ON case_work_review_flags
    WHEN OLD.cleared_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.work_kind <> OLD.work_kind OR NEW.work_id <> OLD.work_id
      OR NEW.point_id <> OLD.point_id OR NEW.comparison_id <> OLD.comparison_id OR NEW.reason <> OLD.reason OR NEW.raised_at <> OLD.raised_at
    BEGIN SELECT RAISE(ABORT, 'case_work_review_flags: a flag is cleared once by a person, never edited'); END;
    -- REPORT-09: what a specialist report supplied with it (a table, figure, media item, dataset): kept and shown as supplied.
    --   The app did not perform the acquisition or the analysis; nothing here records that it did.
    CREATE TABLE IF NOT EXISTS case_report_artifacts (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        report_id         TEXT NOT NULL,
        artifact_kind     TEXT NOT NULL CHECK (artifact_kind IN ('table','figure','media','dataset','other')),
        label             TEXT NOT NULL CHECK (length(trim(label)) > 0),
        source_version_id TEXT,
        locator           TEXT,
        description       TEXT,
        supplied_by       TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_report_artifacts_report ON case_report_artifacts(case_id, report_id);
    CREATE TRIGGER IF NOT EXISTS case_report_artifacts_case BEFORE INSERT ON case_report_artifacts
    WHEN NOT EXISTS (SELECT 1 FROM case_reports r WHERE r.id = NEW.report_id AND r.case_id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_report_artifacts: the report is not a report of this case'); END;
    CREATE TRIGGER IF NOT EXISTS case_report_artifacts_fixed BEFORE UPDATE ON case_report_artifacts
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.report_id <> OLD.report_id
      OR NEW.artifact_kind <> OLD.artifact_kind OR NEW.label <> OLD.label OR NEW.source_version_id IS NOT OLD.source_version_id
      OR NEW.locator IS NOT OLD.locator OR NEW.description IS NOT OLD.description OR NEW.supplied_by IS NOT OLD.supplied_by
      OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_report_artifacts: a supplied item is withdrawn with a reason, never edited'); END;
    -- SEARCH-10: a live saved search may be re-run when the case's material changes (the person's policy); the digest of the
    --   new matches last reported suppresses the same alert twice. A receipt row is never updated (the v172 guard).
    ALTER TABLE case_saved_searches ADD COLUMN rerun_policy TEXT NOT NULL DEFAULT 'manual' CHECK (rerun_policy IN ('manual','onMaterialChange'));
    ALTER TABLE case_saved_searches ADD COLUMN alerted_digest TEXT;
    ALTER TABLE case_saved_searches ADD COLUMN alerted_at REAL;
    -- SEARCH-09 / SEARCH-10: a reusable relationship pattern (typed path search over the case map), versioned by name: saving
    --   again makes version n+1 and keeps the earlier versions. A 'receipt' row freezes one run's paths and coverage with the
    --   map fence it ran at. No row is ever edited.
    CREATE TABLE IF NOT EXISTS case_saved_patterns (
        id              TEXT PRIMARY KEY NOT NULL,
        case_id         TEXT NOT NULL,
        name            TEXT NOT NULL CHECK (length(trim(name)) > 0),
        version         INTEGER NOT NULL CHECK (version >= 1),
        kind            TEXT NOT NULL CHECK (kind IN ('live','receipt')),
        pattern_version INTEGER NOT NULL CHECK (pattern_version >= 1),
        pattern_json    TEXT NOT NULL,
        result_json     TEXT,
        fence           TEXT,
        created_by      TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at      REAL NOT NULL,
        CHECK (kind <> 'receipt' OR (result_json IS NOT NULL AND fence IS NOT NULL))
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_saved_patterns_version ON case_saved_patterns(case_id, name, version);
    CREATE TRIGGER IF NOT EXISTS case_saved_patterns_case BEFORE INSERT ON case_saved_patterns
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_saved_patterns: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_saved_patterns_fixed BEFORE UPDATE ON case_saved_patterns
    BEGIN SELECT RAISE(ABORT, 'case_saved_patterns: a saved pattern version is never edited; save a new version'); END;
    """

    // MARK: - v181 — reasoning and time (smart-map S5, 2026-11-08: REASON-01/02/05/06/07/10/12, TIME-01/02/03/06/07/08).
    // Every new table carries case_id (registered in CaseDataInventory), so the generic pass of a case erasure removes it and
    // a backup carries it inside the encrypted ledger. Person erasure removes attributions naming a case-person row.
    // Rebuilt tables (case_map_links, investigation_review_decisions, audit_chain) keep every row, index and trigger verbatim;
    // only a CHECK is widened, so every sealed hash stays as it was.
    private static let v181: String = """
    -- REASON-01: who states what. A speaker is recorded only with the basis that attributes the words to them (a speech verb,
    --   "according to", the interview's speaker, the document's author, or the investigator's own decision); a name merely
    --   near the words is never a speaker. Firsthand, reported (with whom the speaker reports it from) and "not stated" are
    --   kept apart, and so is the time the statement applies to. Withdrawn with a reason, never edited.
    CREATE TABLE IF NOT EXISTS case_assertion_attributions (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        source_version_id TEXT,
        block_id          TEXT,
        quote             TEXT NOT NULL CHECK (length(trim(quote)) > 0),
        claim             TEXT NOT NULL CHECK (length(trim(claim)) > 0),
        speaker           TEXT,
        case_person_id    TEXT,
        mode              TEXT NOT NULL CHECK (mode IN ('firsthand','reported','notStated','documentAuthor','unattributed')),
        reported_from     TEXT,
        basis             TEXT NOT NULL CHECK (basis IN ('speechVerb','accordingTo','interviewSpeaker','documentAuthor','investigator','none')),
        basis_detail      TEXT,
        applies_from      REAL,
        applies_to        REAL,
        applies_text      TEXT,
        origin            TEXT NOT NULL CHECK (origin IN ('rule','investigator')),
        rule_version      INTEGER,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK ((speaker IS NULL) = (mode = 'unattributed')),
        CHECK ((mode = 'unattributed') = (basis = 'none')),
        CHECK (applies_to IS NULL OR applies_from IS NULL OR applies_to >= applies_from),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_assertion_attributions_case ON case_assertion_attributions(case_id, recorded_at);
    CREATE TRIGGER IF NOT EXISTS case_assertion_attributions_case BEFORE INSERT ON case_assertion_attributions
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_assertion_attributions: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_assertion_attributions_fixed BEFORE UPDATE ON case_assertion_attributions
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.quote <> OLD.quote OR NEW.claim <> OLD.claim
      OR NEW.speaker IS NOT OLD.speaker OR NEW.case_person_id IS NOT OLD.case_person_id OR NEW.mode <> OLD.mode
      OR NEW.reported_from IS NOT OLD.reported_from OR NEW.basis <> OLD.basis OR NEW.basis_detail IS NOT OLD.basis_detail
      OR NEW.applies_from IS NOT OLD.applies_from OR NEW.applies_to IS NOT OLD.applies_to OR NEW.applies_text IS NOT OLD.applies_text
      OR NEW.source_version_id IS NOT OLD.source_version_id OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_assertion_attributions: an attribution is withdrawn with a reason, never edited'); END;
    -- REASON-02: an evidence-grid row's relation to its question, beyond the stored stance: supports, challenges, mentions,
    --   qualifies, or relevance not assessed. NULL is a row from before v181 (read from its stance; a neutral row is
    --   "relevance not assessed"). Only a verified 'supports' row ever counts as documentary support.
    ALTER TABLE case_allegation_evidence ADD COLUMN relation TEXT CHECK (relation IS NULL OR relation IN ('supports','challenges','mentions','qualifies','unassessed'));
    -- REASON-02 on the map: an investigator may draw a 'qualifies' link. case_map_links is rebuilt with the wider CHECK (every
    --   row, index and both update guards kept exactly).
    CREATE TABLE case_map_links__v181 (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        link_type        TEXT NOT NULL CHECK (link_type IN ('supports','challenges','mentions','qualifies','attributedTo','occurredBefore','occurredAfter','possibleSamePerson','dependsOn','requestsEvidenceFor','receivedInResponseTo','derivedFrom','supersedes','selectedForReport')),
        from_kind        TEXT NOT NULL,
        from_id          TEXT NOT NULL,
        to_kind          TEXT NOT NULL,
        to_id            TEXT NOT NULL,
        rationale        TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        certainty        TEXT CHECK (certainty IS NULL OR certainty IN ('notStated','statedBySource','probable','possible','doubtful')),
        valid_from       REAL,
        valid_to         REAL,
        valid_text       TEXT,
        revises_link_id  TEXT,
        CHECK (NOT (from_kind = to_kind AND from_id = to_id)),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    INSERT INTO case_map_links__v181 (id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at, withdrawn_by, withdrawn_at,
                                      withdrawn_reason, certainty, valid_from, valid_to, valid_text, revises_link_id)
        SELECT id, case_id, link_type, from_kind, from_id, to_kind, to_id, rationale, created_by, created_at, withdrawn_by, withdrawn_at,
               withdrawn_reason, certainty, valid_from, valid_to, valid_text, revises_link_id FROM case_map_links;
    DROP TABLE case_map_links;
    ALTER TABLE case_map_links__v181 RENAME TO case_map_links;
    CREATE INDEX IF NOT EXISTS idx_case_map_links_case ON case_map_links(case_id, created_at);
    CREATE INDEX IF NOT EXISTS idx_case_map_links_from ON case_map_links(case_id, from_kind, from_id);
    CREATE INDEX IF NOT EXISTS idx_case_map_links_to ON case_map_links(case_id, to_kind, to_id);
    CREATE INDEX IF NOT EXISTS idx_case_map_links_revises ON case_map_links(revises_link_id) WHERE revises_link_id IS NOT NULL;
    CREATE TRIGGER IF NOT EXISTS case_map_links_fixed BEFORE UPDATE ON case_map_links
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.link_type <> OLD.link_type
      OR NEW.from_kind <> OLD.from_kind OR NEW.from_id <> OLD.from_id OR NEW.to_kind <> OLD.to_kind OR NEW.to_id <> OLD.to_id
      OR NEW.rationale <> OLD.rationale OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_map_links: a link is withdrawn with a reason, never edited'); END;
    CREATE TRIGGER IF NOT EXISTS case_map_links_v179_fixed BEFORE UPDATE ON case_map_links
    WHEN NEW.certainty IS NOT OLD.certainty OR NEW.valid_from IS NOT OLD.valid_from OR NEW.valid_to IS NOT OLD.valid_to
      OR NEW.valid_text IS NOT OLD.valid_text OR NEW.revises_link_id IS NOT OLD.revises_link_id
    BEGIN SELECT RAISE(ABORT, 'case_map_links: certainty, validity and revision are fixed; revise the link instead'); END;
    -- REASON-05: a person's review of whether two sources are independent. Until reviewed, a detected copy or derivative stays
    --   "independence not assessed" and is never counted as a separate confirmation. Append-only: the latest review holds.
    CREATE TABLE IF NOT EXISTS case_source_dependence_reviews (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        source_a       TEXT NOT NULL,
        source_b       TEXT NOT NULL,
        judgment       TEXT NOT NULL CHECK (judgment IN ('dependent','independent','unassessed')),
        detected_basis TEXT,
        rationale      TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
        reviewed_by    TEXT NOT NULL CHECK (length(trim(reviewed_by)) > 0),
        reviewed_at    REAL NOT NULL,
        CHECK (source_a < source_b)
    );
    CREATE INDEX IF NOT EXISTS idx_case_source_dependence_reviews_pair ON case_source_dependence_reviews(case_id, source_a, source_b, reviewed_at);
    CREATE TRIGGER IF NOT EXISTS case_source_dependence_reviews_fixed BEFORE UPDATE ON case_source_dependence_reviews
    BEGIN SELECT RAISE(ABORT, 'case_source_dependence_reviews: a review is never edited; record a new one'); END;
    -- REASON-06 / REASON-12: a contradiction may also be recorded as EXPLAINED (a real difference with an explanation) or
    --   UNRESOLVED (examined; cannot be resolved on what is in the case), each with its rationale. A decision now keeps the
    --   words of each side it was made on, so a later version of a document reopens it only when those words changed.
    --   investigation_review_decisions is rebuilt with the wider CHECK; every row, the index and both guards are kept exactly.
    CREATE TABLE investigation_review_decisions__v181 (
        id                   TEXT PRIMARY KEY NOT NULL,
        case_id              TEXT NOT NULL,
        item_kind            TEXT NOT NULL CHECK (item_kind IN ('reliability','contradiction','gap')),
        item_id              TEXT NOT NULL CHECK (length(trim(item_id)) > 0),
        decision             TEXT NOT NULL CHECK (decision IN ('confirmed','dismissed','deferred','explained','unresolved')),
        reason               TEXT CHECK (reason IS NULL OR reason IN ('differentEvent','differentPerson','changedEstimate','transcriptionError','insufficientContext','other')),
        note                 TEXT,
        source_versions_json TEXT NOT NULL DEFAULT '{}',
        actor                TEXT NOT NULL CHECK (length(trim(actor)) > 0),
        decided_at           REAL NOT NULL,
        passages_json        TEXT,
        CHECK (decision <> 'dismissed' OR reason IS NOT NULL),
        CHECK (decision NOT IN ('explained','unresolved') OR length(trim(coalesce(note,''))) > 0),
        CHECK (coalesce(reason,'') <> 'other' OR length(trim(coalesce(note,''))) > 0)
    );
    INSERT INTO investigation_review_decisions__v181 (id, case_id, item_kind, item_id, decision, reason, note, source_versions_json, actor, decided_at)
        SELECT id, case_id, item_kind, item_id, decision, reason, note, source_versions_json, actor, decided_at FROM investigation_review_decisions;
    DROP TABLE investigation_review_decisions;
    ALTER TABLE investigation_review_decisions__v181 RENAME TO investigation_review_decisions;
    CREATE INDEX IF NOT EXISTS idx_investigation_review_decisions_item ON investigation_review_decisions(case_id, item_kind, item_id, decided_at);
    CREATE TRIGGER IF NOT EXISTS investigation_review_decisions_fixed BEFORE UPDATE ON investigation_review_decisions
    BEGIN SELECT RAISE(ABORT, 'investigation_review_decisions is append-only'); END;
    CREATE TRIGGER IF NOT EXISTS investigation_review_decisions_kept BEFORE DELETE ON investigation_review_decisions
    WHEN NOT EXISTS (SELECT 1 FROM ledger_full_erase)
     AND NOT EXISTS (SELECT 1 FROM ledger_case_erase m WHERE m.case_id = OLD.case_id)
    BEGIN SELECT RAISE(ABORT, 'investigation_review_decisions is append-only'); END;
    -- REASON-07: a follow-up action raised from a contradiction — the exact question, the result needed and both accounts as
    --   they were quoted. Its outcome is recorded once by a person and may be inconclusive or not obtained.
    CREATE TABLE IF NOT EXISTS case_conflict_followups (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        contradiction_id TEXT NOT NULL,
        task_id          TEXT NOT NULL,
        question         TEXT NOT NULL CHECK (length(trim(question)) > 0),
        needed_result    TEXT NOT NULL CHECK (length(trim(needed_result)) > 0),
        side_a_object    TEXT,
        side_a_version   TEXT,
        side_a_quote     TEXT NOT NULL CHECK (length(trim(side_a_quote)) > 0),
        side_b_object    TEXT,
        side_b_version   TEXT,
        side_b_quote     TEXT NOT NULL CHECK (length(trim(side_b_quote)) > 0),
        outcome          TEXT NOT NULL DEFAULT 'pending' CHECK (outcome IN ('pending','accountAConfirmed','accountBConfirmed','bothExplained','inconclusive','notObtained')),
        outcome_note     TEXT,
        outcome_by       TEXT,
        outcome_at       REAL,
        created_by       TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at       REAL NOT NULL,
        CHECK ((outcome = 'pending') = (outcome_at IS NULL) AND (outcome_at IS NULL) = (outcome_by IS NULL)),
        CHECK (outcome = 'pending' OR length(trim(coalesce(outcome_note,''))) > 0)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_conflict_followups_task ON case_conflict_followups(task_id);
    CREATE INDEX IF NOT EXISTS idx_case_conflict_followups_item ON case_conflict_followups(case_id, contradiction_id);
    CREATE TRIGGER IF NOT EXISTS case_conflict_followups_fixed BEFORE UPDATE ON case_conflict_followups
    WHEN OLD.outcome <> 'pending' OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.contradiction_id <> OLD.contradiction_id
      OR NEW.task_id <> OLD.task_id OR NEW.question <> OLD.question OR NEW.needed_result <> OLD.needed_result
      OR NEW.side_a_quote <> OLD.side_a_quote OR NEW.side_b_quote <> OLD.side_b_quote OR NEW.side_a_version IS NOT OLD.side_a_version
      OR NEW.side_b_version IS NOT OLD.side_b_version OR NEW.created_by <> OLD.created_by OR NEW.created_at <> OLD.created_at
    BEGIN SELECT RAISE(ABORT, 'case_conflict_followups: the question and both accounts are fixed; the outcome is recorded once'); END;
    -- REASON-10: the inputs a question's decision was made on, frozen with the decision: every evidence row (its relation,
    --   verification and the source version and words it cites), the alternative explanations considered (each hypothesis's
    --   statement, status and revision) and the contrary material, with a digest over all of it. Never edited.
    CREATE TABLE IF NOT EXISTS case_decision_inputs (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        allegation_id     TEXT NOT NULL,
        disposition       TEXT NOT NULL,
        rationale         TEXT,
        exception_note    TEXT,
        inputs_json       TEXT NOT NULL,
        alternatives_json TEXT NOT NULL,
        contrary_json     TEXT NOT NULL,
        inputs_digest     TEXT NOT NULL CHECK (length(inputs_digest) = 64),
        decided_by        TEXT NOT NULL CHECK (length(trim(decided_by)) > 0),
        decided_at        REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_decision_inputs_allegation ON case_decision_inputs(case_id, allegation_id, decided_at);
    CREATE TRIGGER IF NOT EXISTS case_decision_inputs_fixed BEFORE UPDATE ON case_decision_inputs
    BEGIN SELECT RAISE(ABORT, 'case_decision_inputs: the inputs of a decision are never edited'); END;
    -- REASON-12: the person's decision on any proposal (a suggested fact, link, gap, point or follow-up), kept against the
    --   proposal's stable key and the digest of its content. An unchanged proposal is not offered again after it was rejected
    --   or deferred; a changed one may be, with the change named. Append-only.
    CREATE TABLE IF NOT EXISTS case_proposal_decisions (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        proposal_kind  TEXT NOT NULL CHECK (proposal_kind IN ('fact','link','gap','reportPoint','followUp','other')),
        proposal_key   TEXT NOT NULL CHECK (length(trim(proposal_key)) > 0),
        content_digest TEXT NOT NULL CHECK (length(content_digest) = 64),
        content_text   TEXT,
        decision       TEXT NOT NULL CHECK (decision IN ('accepted','rejected','deferred')),
        reason         TEXT,
        actor          TEXT NOT NULL CHECK (length(trim(actor)) > 0),
        decided_at     REAL NOT NULL,
        CHECK (decision = 'accepted' OR length(trim(coalesce(reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_proposal_decisions_key ON case_proposal_decisions(case_id, proposal_kind, proposal_key, decided_at);
    CREATE TRIGGER IF NOT EXISTS case_proposal_decisions_fixed BEFORE UPDATE ON case_proposal_decisions
    BEGIN SELECT RAISE(ABORT, 'case_proposal_decisions is append-only'); END;
    -- TIME-01 / TIME-02: typed time assertions about any case record — what kind of time it is (occurrence, creation, signing,
    --   collection, receipt, import, assignment, performance, submission, review, correction, supersession), its value at its
    --   own precision (a range, approximate, not before/after, relative to something, or unknown), its time zone and the
    --   source's own wording, and who asserts it (a source, the investigator or the app). Kinds are never merged.
    CREATE TABLE IF NOT EXISTS case_time_assertions (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        record_kind       TEXT NOT NULL CHECK (length(trim(record_kind)) > 0),
        record_id         TEXT NOT NULL CHECK (length(trim(record_id)) > 0),
        time_kind         TEXT NOT NULL CHECK (time_kind IN ('occurrence','creation','signing','collection','receipt','import','assignment','performance','submission','review','correction','supersession')),
        start_at          REAL,
        end_at            REAL,
        precision         TEXT NOT NULL CHECK (precision IN ('unknown','decade','year','quarter','month','day','minute','instant')),
        qualifier         TEXT NOT NULL CHECK (qualifier IN ('stated','approximate','notBefore','notAfter','between','relative','unknown')),
        relative_text     TEXT,
        time_zone         TEXT,
        original_text     TEXT,
        asserted_by_kind  TEXT NOT NULL CHECK (asserted_by_kind IN ('source','investigator','app')),
        asserted_by       TEXT,
        source_version_id TEXT,
        locator           TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (start_at IS NOT NULL OR qualifier IN ('unknown','relative')),
        CHECK (qualifier <> 'unknown' OR (start_at IS NULL AND end_at IS NULL)),
        CHECK (end_at IS NULL OR (start_at IS NOT NULL AND end_at >= start_at)),
        CHECK (qualifier <> 'between' OR end_at IS NOT NULL),
        CHECK (qualifier <> 'relative' OR length(trim(coalesce(relative_text,''))) > 0),
        CHECK (asserted_by_kind <> 'source' OR source_version_id IS NOT NULL OR length(trim(coalesce(asserted_by,''))) > 0),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_time_assertions_record ON case_time_assertions(case_id, record_kind, record_id, time_kind);
    CREATE TRIGGER IF NOT EXISTS case_time_assertions_case BEFORE INSERT ON case_time_assertions
    WHEN NOT EXISTS (SELECT 1 FROM investigation_cases WHERE id = NEW.case_id)
    BEGIN SELECT RAISE(ABORT, 'case_time_assertions: the case does not exist'); END;
    CREATE TRIGGER IF NOT EXISTS case_time_assertions_fixed BEFORE UPDATE ON case_time_assertions
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.record_kind <> OLD.record_kind
      OR NEW.record_id <> OLD.record_id OR NEW.time_kind <> OLD.time_kind OR NEW.start_at IS NOT OLD.start_at OR NEW.end_at IS NOT OLD.end_at
      OR NEW.precision <> OLD.precision OR NEW.qualifier <> OLD.qualifier OR NEW.relative_text IS NOT OLD.relative_text
      OR NEW.time_zone IS NOT OLD.time_zone OR NEW.original_text IS NOT OLD.original_text OR NEW.asserted_by_kind <> OLD.asserted_by_kind
      OR NEW.asserted_by IS NOT OLD.asserted_by OR NEW.source_version_id IS NOT OLD.source_version_id OR NEW.locator IS NOT OLD.locator
      OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_time_assertions: a time assertion is withdrawn with a reason, never edited'); END;
    -- TIME-03: the investigator's interpretation of a time where assertions compete — the chosen value (or the assertion it
    --   adopts), the rationale and the assertions considered. The assertions themselves are never changed; a later
    --   interpretation replaces an earlier one, which stays (withdrawn with the reason).
    CREATE TABLE IF NOT EXISTS case_time_interpretations (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        record_kind         TEXT NOT NULL,
        record_id           TEXT NOT NULL,
        time_kind           TEXT NOT NULL,
        chosen_assertion_id TEXT,
        start_at            REAL,
        end_at              REAL,
        precision           TEXT NOT NULL CHECK (precision IN ('unknown','decade','year','quarter','month','day','minute','instant')),
        time_zone           TEXT,
        rationale           TEXT NOT NULL CHECK (length(trim(rationale)) > 0),
        considered_json     TEXT NOT NULL,
        decided_by          TEXT NOT NULL CHECK (length(trim(decided_by)) > 0),
        decided_at          REAL NOT NULL,
        withdrawn_by        TEXT,
        withdrawn_at        REAL,
        withdrawn_reason    TEXT,
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_time_interpretations_record ON case_time_interpretations(case_id, record_kind, record_id, time_kind);
    CREATE TRIGGER IF NOT EXISTS case_time_interpretations_fixed BEFORE UPDATE ON case_time_interpretations
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.chosen_assertion_id IS NOT OLD.chosen_assertion_id
      OR NEW.start_at IS NOT OLD.start_at OR NEW.end_at IS NOT OLD.end_at OR NEW.precision <> OLD.precision OR NEW.time_zone IS NOT OLD.time_zone
      OR NEW.rationale <> OLD.rationale OR NEW.considered_json <> OLD.considered_json OR NEW.decided_by <> OLD.decided_by OR NEW.decided_at <> OLD.decided_at
    BEGIN SELECT RAISE(ABORT, 'case_time_interpretations: an interpretation is withdrawn with a reason, never edited'); END;
    -- TIME-02: a chronology entry's date may be a range, approximate, "not before"/"not after" or relative, and names the time
    --   zone it was read in. NULL qualifier: a date recorded before v181 (shown as stated, at its recorded precision).
    ALTER TABLE case_journal ADD COLUMN date_end REAL;
    ALTER TABLE case_journal ADD COLUMN date_qualifier TEXT CHECK (date_qualifier IS NULL OR date_qualifier IN ('stated','approximate','notBefore','notAfter','between','relative','unknown'));
    ALTER TABLE case_journal ADD COLUMN date_time_zone TEXT;
    -- TIME-06 / TIME-08: an action's attribution in separate parts — the name it was recorded under (actor, unchanged), the
    --   signed-in account of this Mac (not an identity check), the person who reported doing the work, the software that did
    --   it and what triggered it — and its place in this device's own recording order (device id, a monotonic sequence, the
    --   action it was caused by, and when a copy received from elsewhere arrived). NULL for actions before v181.
    ALTER TABLE case_actions ADD COLUMN session_account TEXT;
    ALTER TABLE case_actions ADD COLUMN performed_by TEXT;
    ALTER TABLE case_actions ADD COLUMN software_actor TEXT;
    ALTER TABLE case_actions ADD COLUMN trigger_context TEXT;
    ALTER TABLE case_actions ADD COLUMN device_id TEXT;
    ALTER TABLE case_actions ADD COLUMN device_seq INTEGER;
    ALTER TABLE case_actions ADD COLUMN caused_by TEXT;
    ALTER TABLE case_actions ADD COLUMN received_at REAL;
    CREATE INDEX IF NOT EXISTS idx_case_actions_device ON case_actions(device_id, device_seq) WHERE device_id IS NOT NULL;
    CREATE TABLE IF NOT EXISTS ledger_recording_device (
        id         INTEGER PRIMARY KEY CHECK (id = 1),
        device_id  TEXT NOT NULL CHECK (length(trim(device_id)) > 0),
        created_at REAL NOT NULL
    );
    -- TIME-07: the audit chain also seals investigator-drawn map links, review decisions and produced outputs. audit_chain is
    --   rebuilt with the wider CHECK and every sealed row copied VERBATIM (as v111 and v157 did), so the chain stays intact.
    CREATE TABLE audit_chain__v181 (
        seq          INTEGER PRIMARY KEY,
        source       TEXT NOT NULL,
        event_id     TEXT NOT NULL,
        occurred_at  REAL NOT NULL,
        payload_hash TEXT NOT NULL,
        prev_hash    TEXT NOT NULL,
        entry_hash   TEXT NOT NULL,
        sealed_at    REAL NOT NULL,
        public_prev  TEXT,
        public_hash  TEXT,
        CHECK(source IN ('custody','review','governance','caseAction','caseEvent','findingsApproval','hypothesisDecision','mapLink','reviewDecision','caseOutput')),
        CHECK(seq >= 1),
        CHECK(length(entry_hash) > 0),
        CHECK(length(prev_hash) > 0)
    );
    INSERT INTO audit_chain__v181 (seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at, public_prev, public_hash)
        SELECT seq, source, event_id, occurred_at, payload_hash, prev_hash, entry_hash, sealed_at, public_prev, public_hash FROM audit_chain;
    DROP TABLE audit_chain;
    ALTER TABLE audit_chain__v181 RENAME TO audit_chain;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_chain_event ON audit_chain(source, event_id);
    """

    // MARK: - v182 — smart-map S6 (CHANGE / PEOPLE)

    private static let v182: String = """
    -- CHANGE-05: each person's own seen position in a case (the v173 case-level row stays as the fallback). Moving it reviews
    --   nothing.
    CREATE TABLE IF NOT EXISTS case_change_seen_people (
        case_id      TEXT NOT NULL,
        person       TEXT NOT NULL CHECK (length(trim(person)) > 0),
        seen_through REAL NOT NULL,
        state_json   TEXT NOT NULL DEFAULT '{}',
        seen_at      REAL NOT NULL,
        PRIMARY KEY (case_id, person)
    );
    -- CHANGE-05: a substantive acknowledgement of one change — the person says what they checked. Seeing a change is not
    --   acknowledging it, and acknowledging it decides nothing about the records it touches. Append-only.
    CREATE TABLE IF NOT EXISTS case_change_acknowledgements (
        id              TEXT PRIMARY KEY NOT NULL,
        case_id         TEXT NOT NULL,
        change_id       TEXT NOT NULL CHECK (length(trim(change_id)) > 0),
        record_kind     TEXT,
        record_id       TEXT,
        note            TEXT NOT NULL CHECK (length(trim(note)) > 0),
        acknowledged_by TEXT NOT NULL CHECK (length(trim(acknowledged_by)) > 0),
        acknowledged_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_change_ack_case ON case_change_acknowledgements(case_id, change_id);
    CREATE TRIGGER IF NOT EXISTS case_change_ack_fixed BEFORE UPDATE ON case_change_acknowledgements
    BEGIN SELECT RAISE(ABORT, 'case_change_acknowledgements: an acknowledgement is never edited'); END;
    -- CHANGE-02: what a summary, comparison, finding or output was derived from — each input with the revision and a
    --   fingerprint of the input as it was. One binding (bind_id) per derivation; a later binding of the same item replaces
    --   it for staleness, the earlier rows stay. Append-only.
    CREATE TABLE IF NOT EXISTS case_derivation_inputs (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        bind_id             TEXT NOT NULL,
        derived_kind        TEXT NOT NULL CHECK (derived_kind IN ('brief','comparison','finding','output','summary','reportPoint','decision')),
        derived_id          TEXT NOT NULL CHECK (length(trim(derived_id)) > 0),
        derived_label       TEXT NOT NULL CHECK (length(trim(derived_label)) > 0),
        input_kind          TEXT NOT NULL CHECK (length(trim(input_kind)) > 0),
        input_id            TEXT NOT NULL CHECK (length(trim(input_id)) > 0),
        input_revision      TEXT,
        input_fingerprint   TEXT NOT NULL CHECK (length(input_fingerprint) > 0),
        input_snapshot_json TEXT NOT NULL DEFAULT '{}',
        bound_by            TEXT NOT NULL CHECK (length(trim(bound_by)) > 0),
        bound_at            REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_derivation_inputs_derived ON case_derivation_inputs(case_id, derived_kind, derived_id, bound_at);
    CREATE INDEX IF NOT EXISTS idx_case_derivation_inputs_input ON case_derivation_inputs(case_id, input_kind, input_id);
    CREATE TRIGGER IF NOT EXISTS case_derivation_inputs_fixed BEFORE UPDATE ON case_derivation_inputs
    BEGIN SELECT RAISE(ABORT, 'case_derivation_inputs: a binding is never edited; bind again'); END;
    -- CHANGE-09: impact notifications derived from changed evidence, one row per (change, dependent) — reconciling twice, or
    --   after a crash, adds nothing twice and loses nothing. Acknowledged, never deleted (except by erasure).
    CREATE TABLE IF NOT EXISTS case_impact_notifications (
        id              TEXT PRIMARY KEY NOT NULL,
        case_id         TEXT NOT NULL,
        change_id       TEXT NOT NULL,
        changed_kind    TEXT NOT NULL,
        changed_id      TEXT NOT NULL,
        dependent_kind  TEXT NOT NULL,
        dependent_id    TEXT NOT NULL,
        depth           INTEGER NOT NULL CHECK (depth >= 1),
        path_text       TEXT NOT NULL,
        created_at      REAL NOT NULL,
        acknowledged_by TEXT,
        acknowledged_at REAL,
        UNIQUE (case_id, change_id, dependent_kind, dependent_id),
        CHECK ((acknowledged_at IS NULL) = (acknowledged_by IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_case_impact_notifications_case ON case_impact_notifications(case_id, acknowledged_at);
    CREATE TRIGGER IF NOT EXISTS case_impact_notifications_fixed BEFORE UPDATE ON case_impact_notifications
    WHEN OLD.acknowledged_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.change_id <> OLD.change_id
      OR NEW.dependent_kind <> OLD.dependent_kind OR NEW.dependent_id <> OLD.dependent_id OR NEW.path_text <> OLD.path_text
    BEGIN SELECT RAISE(ABORT, 'case_impact_notifications: a notification is acknowledged once and never edited'); END;
    -- CHANGE-09: the durable reconciliation checkpoint of a case (how far its changes were reconciled, how many runs).
    CREATE TABLE IF NOT EXISTS case_change_checkpoints (
        case_id            TEXT PRIMARY KEY NOT NULL,
        reconciled_through REAL NOT NULL,
        last_run_id        TEXT NOT NULL,
        runs               INTEGER NOT NULL CHECK (runs >= 1),
        updated_at         REAL NOT NULL
    );
    -- CHANGE-07: material or results that arrive for a CLOSED case are queued here, never applied to it and never dropped.
    --   A person admits (after reopening), declines with a reason, or asks for the case to be reopened.
    CREATE TABLE IF NOT EXISTS case_late_contributions (
        id              TEXT PRIMARY KEY NOT NULL,
        case_id         TEXT NOT NULL,
        kind            TEXT NOT NULL CHECK (kind IN ('document','result','note','request','other')),
        source_ref      TEXT,
        description     TEXT NOT NULL CHECK (length(trim(description)) > 0),
        contributed_by  TEXT NOT NULL CHECK (length(trim(contributed_by)) > 0),
        software_actor  TEXT,
        received_at     REAL NOT NULL,
        state           TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','reopenRequested','admitted','declined')),
        decided_by      TEXT,
        decided_at      REAL,
        decision_reason TEXT,
        CHECK (state = 'queued' OR (decided_by IS NOT NULL AND decided_at IS NOT NULL AND length(trim(coalesce(decision_reason,''))) > 0))
    );
    CREATE INDEX IF NOT EXISTS idx_case_late_contributions_case ON case_late_contributions(case_id, state);
    CREATE TRIGGER IF NOT EXISTS case_late_contributions_fixed BEFORE UPDATE ON case_late_contributions
    WHEN OLD.state IN ('admitted','declined') OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.kind <> OLD.kind
      OR NEW.source_ref IS NOT OLD.source_ref OR NEW.description <> OLD.description OR NEW.contributed_by <> OLD.contributed_by
      OR NEW.received_at <> OLD.received_at
    BEGIN SELECT RAISE(ABORT, 'case_late_contributions: a contribution keeps what arrived; a decided one is final'); END;
    -- CHANGE-08: every attempt to apply an automated result, with the fences it was produced against and the outcome — a
    --   late result refused because a person edited meanwhile, the inputs changed or the policy changed is recorded, not lost.
    CREATE TABLE IF NOT EXISTS case_result_applications (
        id              TEXT PRIMARY KEY NOT NULL,
        case_id         TEXT NOT NULL,
        target_kind     TEXT NOT NULL,
        target_id       TEXT NOT NULL,
        base_version    INTEGER NOT NULL,
        base_fence      TEXT NOT NULL,
        policy_at_start TEXT NOT NULL,
        generation      INTEGER NOT NULL DEFAULT 0,
        outcome         TEXT NOT NULL CHECK (outcome IN ('applied','refusedNewerEdit','refusedInputsChanged','refusedPolicyChanged','refusedClosed','superseded')),
        detail          TEXT NOT NULL,
        produced_by     TEXT NOT NULL CHECK (length(trim(produced_by)) > 0),
        applied_id      TEXT,
        at              REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_case_result_applications_target ON case_result_applications(case_id, target_kind, target_id, at);
    CREATE TRIGGER IF NOT EXISTS case_result_applications_fixed BEFORE UPDATE ON case_result_applications
    BEGIN SELECT RAISE(ABORT, 'case_result_applications: an application record is never edited'); END;
    -- PEOPLE-01: a person's roles in the case, each with its context and period — one canonical case-person row may be a
    --   witness, a source, an account holder or an investigator in different contexts. A role implies nothing about conduct.
    CREATE TABLE IF NOT EXISTS case_person_roles (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        case_person_id TEXT NOT NULL,
        role           TEXT NOT NULL CHECK (role IN ('subject','witness','complainant','custodian','source','accountHolder','investigator','reporter','other')),
        context        TEXT,
        valid_from     REAL,
        valid_to       REAL,
        recorded_by    TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at    REAL NOT NULL,
        ended_by       TEXT,
        ended_at       REAL,
        ended_reason   TEXT,
        CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
        CHECK ((ended_at IS NULL) = (ended_by IS NULL)),
        CHECK (ended_at IS NULL OR length(trim(coalesce(ended_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_person_roles_person ON case_person_roles(case_id, case_person_id);
    CREATE TRIGGER IF NOT EXISTS case_person_roles_fixed BEFORE UPDATE ON case_person_roles
    WHEN OLD.ended_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.case_person_id <> OLD.case_person_id
      OR NEW.role <> OLD.role OR NEW.context IS NOT OLD.context OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_person_roles: a role is ended with a reason, never edited'); END;
    -- PEOPLE-02: one sourced profile attribute (alias, organisation, contact, background, relationship) with its origin and
    --   period. origin 'unsourced' is a note nobody tied to a source — it stays identifiable as such.
    CREATE TABLE IF NOT EXISTS case_person_attributes (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        case_person_id    TEXT NOT NULL,
        attribute         TEXT NOT NULL CHECK (attribute IN ('alias','organisation','contact','identifier','background','relationship')),
        value             TEXT NOT NULL CHECK (length(trim(value)) > 0),
        origin            TEXT NOT NULL CHECK (origin IN ('source','supplied','investigatorNote','unsourced')),
        source_version_id TEXT,
        block_id          TEXT,
        quote             TEXT,
        supplied_by       TEXT,
        valid_from        REAL,
        valid_to          REAL,
        valid_text        TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (origin <> 'source' OR source_version_id IS NOT NULL),
        CHECK (origin <> 'supplied' OR length(trim(coalesce(supplied_by,''))) > 0),
        CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_person_attributes_person ON case_person_attributes(case_id, case_person_id);
    CREATE TRIGGER IF NOT EXISTS case_person_attributes_fixed BEFORE UPDATE ON case_person_attributes
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.case_person_id <> OLD.case_person_id
      OR NEW.attribute <> OLD.attribute OR NEW.value <> OLD.value OR NEW.origin <> OLD.origin OR NEW.source_version_id IS NOT OLD.source_version_id
      OR NEW.quote IS NOT OLD.quote OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_person_attributes: an attribute is withdrawn with a reason, never edited'); END;
    -- PEOPLE-03: a supplied or authorised observation of where a person was — with its time, precision, source and
    --   uncertainty. Always a PAST observation; there is no "current location" column.
    CREATE TABLE IF NOT EXISTS case_person_locations (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        case_person_id    TEXT NOT NULL,
        place             TEXT NOT NULL CHECK (length(trim(place)) > 0),
        observed_from     REAL,
        observed_to       REAL,
        time_precision    TEXT NOT NULL CHECK (time_precision IN ('instant','minute','day','month','year','unknown')),
        place_precision   TEXT NOT NULL CHECK (place_precision IN ('exact','street','area','city','region','country','unknown')),
        basis             TEXT NOT NULL CHECK (basis IN ('supplied','authorisedRecord','source','investigatorObservation')),
        source_version_id TEXT,
        quote             TEXT,
        authority         TEXT,
        uncertainty       TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (observed_to IS NULL OR observed_from IS NULL OR observed_to >= observed_from),
        CHECK (basis <> 'source' OR source_version_id IS NOT NULL),
        CHECK (basis <> 'authorisedRecord' OR length(trim(coalesce(authority,''))) > 0),
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
        CHECK (withdrawn_at IS NULL OR length(trim(coalesce(withdrawn_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_person_locations_person ON case_person_locations(case_id, case_person_id);
    CREATE TRIGGER IF NOT EXISTS case_person_locations_fixed BEFORE UPDATE ON case_person_locations
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.case_person_id <> OLD.case_person_id
      OR NEW.place <> OLD.place OR NEW.observed_from IS NOT OLD.observed_from OR NEW.observed_to IS NOT OLD.observed_to OR NEW.basis <> OLD.basis
    BEGIN SELECT RAISE(ABORT, 'case_person_locations: an observation is withdrawn with a reason, never edited'); END;
    -- PEOPLE-04: an interview's individual questions and responses, each with its recording/transcript locator. Once the
    --   statement is confirmed an item changes only by a recorded correction (a new item that corrects the old, with a
    --   reason and the addendum it belongs to); the old item stays.
    CREATE TABLE IF NOT EXISTS case_interview_items (
        id                  TEXT PRIMARY KEY NOT NULL,
        case_id             TEXT NOT NULL,
        interview_id        TEXT NOT NULL,
        ordinal             INTEGER NOT NULL CHECK (ordinal >= 1),
        question            TEXT NOT NULL CHECK (length(trim(question)) > 0),
        response            TEXT,
        recording_ref       TEXT,
        recording_offset    REAL,
        transcript_ref      TEXT,
        transcript_locator  TEXT,
        corrects_id         TEXT,
        correction_reason   TEXT,
        addendum_id         TEXT,
        recorded_by         TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at         REAL NOT NULL,
        superseded_by       TEXT,
        CHECK (corrects_id IS NULL OR length(trim(coalesce(correction_reason,''))) > 0),
        CHECK (recording_offset IS NULL OR recording_offset >= 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_interview_items_interview ON case_interview_items(case_id, interview_id, ordinal);
    CREATE TRIGGER IF NOT EXISTS case_interview_items_confirmed BEFORE UPDATE ON case_interview_items
    WHEN (NEW.question <> OLD.question OR NEW.response IS NOT OLD.response OR NEW.ordinal <> OLD.ordinal OR NEW.interview_id <> OLD.interview_id
          OR NEW.recording_ref IS NOT OLD.recording_ref OR NEW.transcript_ref IS NOT OLD.transcript_ref OR NEW.corrects_id IS NOT OLD.corrects_id)
      AND EXISTS (SELECT 1 FROM case_interviews i WHERE i.id = OLD.interview_id AND i.status = 'attested')
    BEGIN SELECT RAISE(ABORT, 'case_interview_items: the statement is confirmed; record a correction instead of changing it'); END;
    CREATE TRIGGER IF NOT EXISTS case_interview_items_superseded BEFORE UPDATE ON case_interview_items
    WHEN OLD.superseded_by IS NOT NULL
    BEGIN SELECT RAISE(ABORT, 'case_interview_items: a corrected item is kept as it was'); END;
    CREATE TRIGGER IF NOT EXISTS case_interview_items_nodelete BEFORE DELETE ON case_interview_items
    WHEN EXISTS (SELECT 1 FROM case_interviews i WHERE i.id = OLD.interview_id AND i.status = 'attested')
      AND NOT EXISTS (SELECT 1 FROM ledger_case_erase e WHERE e.case_id = OLD.case_id)
      AND NOT EXISTS (SELECT 1 FROM ledger_person_erase)
    BEGIN SELECT RAISE(ABORT, 'case_interview_items: a confirmed statement item is never deleted'); END;
    -- PEOPLE-07: a versioned same-person assessment of two case-person rows — the rule version, the verdict, and every
    --   reason it matched or stayed separate. It decides nothing; only a person's identity decision does.
    CREATE TABLE IF NOT EXISTS case_person_match_assessments (
        id           TEXT PRIMARY KEY NOT NULL,
        case_id      TEXT NOT NULL,
        person_a     TEXT NOT NULL,
        person_b     TEXT NOT NULL,
        rule_version INTEGER NOT NULL CHECK (rule_version >= 1),
        verdict      TEXT NOT NULL CHECK (verdict IN ('strongCandidate','weakCandidate','keepSeparate','insufficient')),
        reasons_json TEXT NOT NULL,
        assessed_by  TEXT NOT NULL CHECK (length(trim(assessed_by)) > 0),
        assessed_at  REAL NOT NULL,
        decision_id  TEXT,
        CHECK (person_a < person_b)
    );
    CREATE INDEX IF NOT EXISTS idx_case_person_match_pair ON case_person_match_assessments(case_id, person_a, person_b, assessed_at);
    CREATE TRIGGER IF NOT EXISTS case_person_match_fixed BEFORE UPDATE ON case_person_match_assessments
    BEGIN SELECT RAISE(ABORT, 'case_person_match_assessments: an assessment is never edited; assess again'); END;
    -- PEOPLE-06 / PEOPLE-09: who is assigned to a piece of work, from when to when, and how it ended (completed, released,
    --   reassigned to whom, transferred on a departure). Attribution is never rewritten.
    CREATE TABLE IF NOT EXISTS case_work_assignments (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        work_kind      TEXT NOT NULL CHECK (work_kind IN ('task','request','allegation','interview','report','other')),
        work_id        TEXT NOT NULL CHECK (length(trim(work_id)) > 0),
        assignee       TEXT NOT NULL CHECK (length(trim(assignee)) > 0),
        capability     TEXT,
        assigned_by    TEXT NOT NULL CHECK (length(trim(assigned_by)) > 0),
        assigned_at    REAL NOT NULL,
        note           TEXT,
        ended_at       REAL,
        ended_by       TEXT,
        end_reason     TEXT CHECK (end_reason IS NULL OR end_reason IN ('completed','released','reassigned','transferred')),
        reassigned_to  TEXT,
        CHECK ((ended_at IS NULL) = (end_reason IS NULL)),
        CHECK ((ended_at IS NULL) = (ended_by IS NULL)),
        CHECK (end_reason NOT IN ('reassigned','transferred') OR length(trim(coalesce(reassigned_to,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_work_assignments_case ON case_work_assignments(case_id, assignee, assigned_at);
    CREATE INDEX IF NOT EXISTS idx_case_work_assignments_work ON case_work_assignments(case_id, work_kind, work_id);
    CREATE TRIGGER IF NOT EXISTS case_work_assignments_fixed BEFORE UPDATE ON case_work_assignments
    WHEN OLD.ended_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.work_kind <> OLD.work_kind OR NEW.work_id <> OLD.work_id
      OR NEW.assignee <> OLD.assignee OR NEW.assigned_by <> OLD.assigned_by OR NEW.assigned_at <> OLD.assigned_at
    BEGIN SELECT RAISE(ABORT, 'case_work_assignments: an assignment is ended, never edited'); END;
    -- PEOPLE-09: a person's membership of the case team (a local name — not an account) and when it ended.
    CREATE TABLE IF NOT EXISTS case_team_memberships (
        id           TEXT PRIMARY KEY NOT NULL,
        case_id      TEXT NOT NULL,
        member       TEXT NOT NULL CHECK (length(trim(member)) > 0),
        role         TEXT NOT NULL CHECK (role IN ('lead','investigator','reviewer','contributor')),
        started_by   TEXT NOT NULL CHECK (length(trim(started_by)) > 0),
        started_at   REAL NOT NULL,
        ended_by     TEXT,
        ended_at     REAL,
        end_reason   TEXT,
        transferred_to TEXT,
        CHECK ((ended_at IS NULL) = (ended_by IS NULL)),
        CHECK (ended_at IS NULL OR length(trim(coalesce(end_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_team_memberships_case ON case_team_memberships(case_id, member);
    CREATE TRIGGER IF NOT EXISTS case_team_memberships_fixed BEFORE UPDATE ON case_team_memberships
    WHEN OLD.ended_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.member <> OLD.member OR NEW.role <> OLD.role
      OR NEW.started_at <> OLD.started_at
    BEGIN SELECT RAISE(ABORT, 'case_team_memberships: a membership is ended, never edited'); END;
    -- PEOPLE-10: a restriction on a case person's profile — while active, the profile's sourced attributes, observations and
    --   statement items are withheld from reads, briefs and exports (named as restricted, never shown as absent).
    CREATE TABLE IF NOT EXISTS case_person_restrictions (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        case_person_id TEXT NOT NULL,
        reason         TEXT NOT NULL CHECK (length(trim(reason)) > 0),
        set_by         TEXT NOT NULL CHECK (length(trim(set_by)) > 0),
        set_at         REAL NOT NULL,
        lifted_by      TEXT,
        lifted_at      REAL,
        lifted_reason  TEXT,
        CHECK ((lifted_at IS NULL) = (lifted_by IS NULL)),
        CHECK (lifted_at IS NULL OR length(trim(coalesce(lifted_reason,''))) > 0)
    );
    CREATE INDEX IF NOT EXISTS idx_case_person_restrictions_person ON case_person_restrictions(case_id, case_person_id);
    CREATE TRIGGER IF NOT EXISTS case_person_restrictions_fixed BEFORE UPDATE ON case_person_restrictions
    WHEN OLD.lifted_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.case_person_id <> OLD.case_person_id
      OR NEW.reason <> OLD.reason OR NEW.set_by <> OLD.set_by OR NEW.set_at <> OLD.set_at
    BEGIN SELECT RAISE(ABORT, 'case_person_restrictions: a restriction is lifted with a reason, never edited'); END;
    -- PEOPLE-08: an investigator's DECLARED capabilities and availability (a local name, not an account). Routing lists only
    --   declared capabilities; nothing infers expertise or scores a person. Not case data: kept across cases, withdrawn or
    --   removed with the investigator's profile.
    CREATE TABLE IF NOT EXISTS investigator_capabilities (
        id               TEXT PRIMARY KEY NOT NULL,
        investigator     TEXT NOT NULL CHECK (length(trim(investigator)) > 0),
        capability       TEXT NOT NULL CHECK (length(trim(capability)) > 0),
        basis            TEXT NOT NULL CHECK (length(trim(basis)) > 0),
        declared_by      TEXT NOT NULL CHECK (length(trim(declared_by)) > 0),
        declared_at      REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        CHECK ((withdrawn_at IS NULL) = (withdrawn_by IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_investigator_capabilities_name ON investigator_capabilities(investigator, capability);
    CREATE TABLE IF NOT EXISTS investigator_availability (
        id           TEXT PRIMARY KEY NOT NULL,
        investigator TEXT NOT NULL CHECK (length(trim(investigator)) > 0),
        unavailable_from REAL NOT NULL,
        unavailable_to   REAL NOT NULL,
        note         TEXT,
        declared_by  TEXT NOT NULL CHECK (length(trim(declared_by)) > 0),
        declared_at  REAL NOT NULL,
        CHECK (unavailable_to >= unavailable_from)
    );
    CREATE INDEX IF NOT EXISTS idx_investigator_availability_name ON investigator_availability(investigator, unavailable_from);
    """

    // MARK: - v183 — smart-map S7 (MONEY / HISTORY)

    private static let v183: String = """
    -- MONEY-01: the case's accounts (identifier as written + a normalised key; one active row per key and institution).
    CREATE TABLE IF NOT EXISTS case_money_accounts (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        identifier        TEXT NOT NULL CHECK (length(trim(identifier)) > 0),
        identifier_key    TEXT NOT NULL CHECK (length(identifier_key) > 0),
        institution       TEXT,
        label             TEXT,
        currency          TEXT,
        source_version_id TEXT,
        quote             TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_money_accounts_key ON case_money_accounts(case_id, identifier_key) WHERE withdrawn_at IS NULL;
    -- MONEY-09: dated, sourced holder / signatory / owner / controller / beneficial-owner assertions. A relationship, never an
    --   authorisation or a liability.
    CREATE TABLE IF NOT EXISTS case_money_ownership (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        account_id        TEXT NOT NULL,
        holder_person_id  TEXT,
        holder_name       TEXT NOT NULL CHECK (length(trim(holder_name)) > 0),
        relation          TEXT NOT NULL CHECK (relation IN ('holder','jointHolder','signatory','directOwner','indirectOwner','controller','beneficialOwner')),
        share_text        TEXT,
        via_text          TEXT,
        valid_from        REAL,
        valid_to          REAL,
        valid_text        TEXT,
        basis             TEXT NOT NULL CHECK (basis IN ('source','supplied','investigatorNote')),
        source_version_id TEXT,
        quote             TEXT,
        supplied_by       TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (basis <> 'source' OR source_version_id IS NOT NULL),
        CHECK (basis <> 'supplied' OR length(trim(coalesce(supplied_by,''))) > 0),
        CHECK (valid_from IS NULL OR valid_to IS NULL OR valid_to >= valid_from)
    );
    CREATE INDEX IF NOT EXISTS idx_case_money_ownership_account ON case_money_ownership(case_id, account_id);
    -- MONEY-07: a statement of one account for one period (balances as written).
    CREATE TABLE IF NOT EXISTS case_money_statements (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        account_id        TEXT NOT NULL,
        period_start      TEXT NOT NULL,
        period_end        TEXT NOT NULL,
        opening_text      TEXT,
        closing_text      TEXT,
        currency          TEXT NOT NULL DEFAULT '',
        source_version_id TEXT,
        source_name       TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (period_end >= period_start)
    );
    -- MONEY-01..05: one money record — a movement, an invoice/claim, a balance, an allegation, an estimate, an asset, or a statement
    --   row — with the amount exactly as written, its exact value (NULL: not readable), how it was read and its currency. The kind
    --   changes only from 'unclassified'; the amount and currency never change (an amendment is a new row that replaces it).
    CREATE TABLE IF NOT EXISTS case_money_records (
        id                TEXT PRIMARY KEY NOT NULL,
        case_id           TEXT NOT NULL,
        kind              TEXT NOT NULL CHECK (kind IN ('unclassified','payment','receipt','transfer','refund','reversal','fee','invoice','claim','reserve',
                                                        'balance','quotation','allegation','estimate','asset')),
        amount_text       TEXT NOT NULL CHECK (length(trim(amount_text)) > 0),
        amount            TEXT,
        amount_basis      TEXT NOT NULL,
        currency          TEXT NOT NULL DEFAULT '',
        record_date       TEXT,
        date_text         TEXT,
        reference         TEXT,
        payer_account_id  TEXT,
        payee_account_id  TEXT,
        payer_name        TEXT,
        payee_name        TEXT,
        description       TEXT,
        settles_record_id TEXT,
        statement_id      TEXT,
        statement_row     INTEGER,
        amends_record_id  TEXT,
        amend_reason      TEXT,
        source_version_id TEXT,
        block_id          TEXT,
        quote             TEXT,
        source_name       TEXT,
        disputed_by       TEXT,
        disputed_at       REAL,
        dispute_note      TEXT,
        recorded_by       TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at       REAL NOT NULL,
        withdrawn_by      TEXT,
        withdrawn_at      REAL,
        withdrawn_reason  TEXT,
        CHECK (amends_record_id IS NULL OR length(trim(coalesce(amend_reason,''))) > 0),
        CHECK ((disputed_at IS NULL) = (disputed_by IS NULL))
    );
    CREATE INDEX IF NOT EXISTS idx_case_money_records_case ON case_money_records(case_id, record_date);
    CREATE INDEX IF NOT EXISTS idx_case_money_records_statement ON case_money_records(statement_id);
    CREATE TRIGGER IF NOT EXISTS case_money_records_fixed BEFORE UPDATE ON case_money_records
    WHEN NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.amount_text <> OLD.amount_text OR NEW.amount IS NOT OLD.amount
      OR NEW.currency <> OLD.currency OR NEW.amount_basis <> OLD.amount_basis OR NEW.record_date IS NOT OLD.record_date
      OR NEW.reference IS NOT OLD.reference OR NEW.amends_record_id IS NOT OLD.amends_record_id
      OR (NEW.kind <> OLD.kind AND OLD.kind <> 'unclassified')
    BEGIN SELECT RAISE(ABORT, 'case_money_records: an amount, its currency, day and reference are never edited; record an amendment'); END;
    -- MONEY-04: a person's confirm (same payment) / split (two payments) of two records. Append-only; the latest counts.
    CREATE TABLE IF NOT EXISTS case_money_identity_decisions (
        id         TEXT PRIMARY KEY NOT NULL,
        case_id    TEXT NOT NULL,
        record_a   TEXT NOT NULL,
        record_b   TEXT NOT NULL,
        decision   TEXT NOT NULL CHECK (decision IN ('sameTransaction','distinct')),
        reason     TEXT NOT NULL CHECK (length(trim(reason)) > 0),
        decided_by TEXT NOT NULL CHECK (length(trim(decided_by)) > 0),
        decided_at REAL NOT NULL,
        CHECK (record_a <> record_b)
    );
    CREATE TRIGGER IF NOT EXISTS case_money_identity_fixed BEFORE UPDATE ON case_money_identity_decisions
    BEGIN SELECT RAISE(ABORT, 'case_money_identity_decisions: a decision is never edited; record another'); END;
    -- MONEY-08: a recorded exchange rate with its source, date and method (withdraw-only).
    CREATE TABLE IF NOT EXISTS case_money_conversions (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        from_currency    TEXT NOT NULL CHECK (length(trim(from_currency)) > 0),
        to_currency      TEXT NOT NULL CHECK (length(trim(to_currency)) > 0),
        rate             TEXT NOT NULL CHECK (length(trim(rate)) > 0),
        rate_date        TEXT NOT NULL,
        rate_source      TEXT NOT NULL CHECK (length(trim(rate_source)) > 0),
        method           TEXT NOT NULL CHECK (length(trim(method)) > 0),
        recorded_by      TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at      REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (from_currency <> to_currency)
    );
    -- MONEY-11: proposed requests for missing financial material, one per (case, key) — re-running never adds a second.
    CREATE TABLE IF NOT EXISTS case_money_gap_proposals (
        id              TEXT PRIMARY KEY NOT NULL,
        case_id         TEXT NOT NULL,
        dedupe_key      TEXT NOT NULL,
        kind            TEXT NOT NULL CHECK (kind IN ('missingStatement','uncoveredMovements','unreconciledStatement')),
        account_id      TEXT,
        period_start    TEXT NOT NULL,
        period_end      TEXT NOT NULL,
        deliverable     TEXT NOT NULL CHECK (length(trim(deliverable)) > 0),
        reason          TEXT NOT NULL,
        state           TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed','accepted','dismissed')),
        task_id         TEXT,
        created_by      TEXT NOT NULL,
        created_at      REAL NOT NULL,
        decided_by      TEXT,
        decided_at      REAL,
        decision_reason TEXT,
        UNIQUE (case_id, dedupe_key),
        CHECK (state = 'proposed' OR (decided_by IS NOT NULL AND decided_at IS NOT NULL AND length(trim(coalesce(decision_reason,''))) > 0))
    );
    -- HISTORY-01: identifiers and patterns the investigator chose to look for in other cases (exact; a pattern is a candidate).
    CREATE TABLE IF NOT EXISTS case_overlap_identifiers (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        kind             TEXT NOT NULL CHECK (kind IN ('accountNumber','reference','phone','email','identifier','pattern')),
        value            TEXT NOT NULL CHECK (length(trim(value)) > 0),
        chosen_by        TEXT NOT NULL CHECK (length(trim(chosen_by)) > 0),
        chosen_at        REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT
    );
    -- HISTORY-02: the history set of a case — other cases, imported collections or configured external sources chosen for it,
    --   each with a purpose and a permitted scope. There is no kind for AI memory: it is not a documentary source.
    CREATE TABLE IF NOT EXISTS case_history_sources (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        source_kind      TEXT NOT NULL CHECK (source_kind IN ('case','collection','external')),
        origin_case_id   TEXT,
        collection_ref   TEXT,
        external_name    TEXT,
        purpose          TEXT NOT NULL CHECK (length(trim(purpose)) > 0),
        permitted_scope  TEXT NOT NULL CHECK (permitted_scope IN ('identifiersOnly','records','recordsAndSources')),
        selected_by      TEXT NOT NULL CHECK (length(trim(selected_by)) > 0),
        selected_at      REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT,
        CHECK (source_kind <> 'case' OR (origin_case_id IS NOT NULL AND origin_case_id <> case_id)),
        CHECK (source_kind <> 'collection' OR length(trim(coalesce(collection_ref,''))) > 0),
        CHECK (source_kind <> 'external' OR length(trim(coalesce(external_name,''))) > 0)
    );
    -- HISTORY-03: an explicit reference from this case to one record of another case: origin case, record, the pinned
    --   recorded state (snapshot) or the live record, the permitted scope (from its history source) and the purpose. It holds
    --   NO copy of the record: reading it re-reads the origin under today's restrictions. Withdraw-only.
    CREATE TABLE IF NOT EXISTS case_cross_references (
        id                   TEXT PRIMARY KEY NOT NULL,
        case_id              TEXT NOT NULL,
        history_source_id    TEXT NOT NULL,
        origin_case_id       TEXT NOT NULL,
        origin_kind          TEXT NOT NULL,
        origin_record_id     TEXT NOT NULL,
        mode                 TEXT NOT NULL CHECK (mode IN ('snapshot','live')),
        pinned_checkpoint_id TEXT,
        pinned_revision      TEXT,
        purpose              TEXT NOT NULL CHECK (length(trim(purpose)) > 0),
        created_by           TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at           REAL NOT NULL,
        withdrawn_by         TEXT,
        withdrawn_at         REAL,
        withdrawn_reason     TEXT,
        CHECK (origin_case_id <> case_id),
        CHECK (mode <> 'snapshot' OR pinned_checkpoint_id IS NOT NULL)
    );
    CREATE INDEX IF NOT EXISTS idx_case_cross_references_origin ON case_cross_references(origin_case_id, origin_kind, origin_record_id);
    CREATE TRIGGER IF NOT EXISTS case_cross_references_fixed BEFORE UPDATE ON case_cross_references
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.origin_case_id <> OLD.origin_case_id
      OR NEW.origin_kind <> OLD.origin_kind OR NEW.origin_record_id <> OLD.origin_record_id OR NEW.mode <> OLD.mode
      OR NEW.pinned_checkpoint_id IS NOT OLD.pinned_checkpoint_id OR NEW.pinned_revision IS NOT OLD.pinned_revision
    BEGIN SELECT RAISE(ABORT, 'case_cross_references: a reference is never edited; withdraw it and pin another'); END;
    -- HISTORY-05: this case reviews another investigation (a separate mother case; the origin is never written by the review).
    CREATE TABLE IF NOT EXISTS case_review_of (
        id             TEXT PRIMARY KEY NOT NULL,
        case_id        TEXT NOT NULL,
        origin_case_id TEXT NOT NULL,
        purpose        TEXT NOT NULL CHECK (length(trim(purpose)) > 0),
        created_by     TEXT NOT NULL CHECK (length(trim(created_by)) > 0),
        created_at     REAL NOT NULL,
        ended_by       TEXT,
        ended_at       REAL,
        ended_reason   TEXT,
        CHECK (origin_case_id <> case_id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_case_review_of_active ON case_review_of(case_id, origin_case_id) WHERE ended_at IS NULL;
    -- HISTORY-05/08: the review's own findings about referenced records (its conclusions, authorship and time). Withdraw-only.
    CREATE TABLE IF NOT EXISTS case_review_findings (
        id               TEXT PRIMARY KEY NOT NULL,
        case_id          TEXT NOT NULL,
        reference_id     TEXT NOT NULL,
        assessment       TEXT NOT NULL CHECK (assessment IN ('agrees','disagrees','incomplete','notAssessable','observation')),
        finding_text     TEXT NOT NULL CHECK (length(trim(finding_text)) > 0),
        recorded_by      TEXT NOT NULL CHECK (length(trim(recorded_by)) > 0),
        recorded_at      REAL NOT NULL,
        withdrawn_by     TEXT,
        withdrawn_at     REAL,
        withdrawn_reason TEXT
    );
    CREATE TRIGGER IF NOT EXISTS case_review_findings_fixed BEFORE UPDATE ON case_review_findings
    WHEN OLD.withdrawn_at IS NOT NULL OR NEW.id <> OLD.id OR NEW.case_id <> OLD.case_id OR NEW.reference_id <> OLD.reference_id
      OR NEW.assessment <> OLD.assessment OR NEW.recorded_by <> OLD.recorded_by OR NEW.recorded_at <> OLD.recorded_at
    BEGIN SELECT RAISE(ABORT, 'case_review_findings: a finding is never edited; withdraw it and record another'); END;
    """
}
