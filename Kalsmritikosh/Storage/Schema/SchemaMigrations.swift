//
//  SchemaMigrations.swift
//  Kalsmritikosh
//
//  Versioned DDL for the 11 SQLite tables. Each migration bumps
//  PRAGMA user_version and is applied exactly once. Adding a new
//  migration is a pure append — never edit an existing one.
//

import Foundation

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

    public static let latestVersion = 112

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
        // Self-heal a stale counter. Observed in the field: some databases carry
        // a fully-applied latest schema while `user_version` is stuck at an early
        // value. Blindly re-running the pending migrations would fail (bare CREATE
        // TABLE would raise "table already exists"). So: if the counter looks stale
        // BUT the full latest schema is already present, reconcile and return. Only
        // when migrating all the way to latest (not a targeted partial migration).
        if targetVersion == latestVersion, current < latestVersion,
           try await isSchemaFullyApplied(database) {
            try await database.setUserVersion(latestVersion)
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
                         "mission_deliverable", "is_terminal", "updated_at"],
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
            "workbench_datasets": ["id", "workspace_id", "title", "mode", "revision", "created_at", "updated_at"],
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
            // v104 — AUD-CHAIN tamper-evident audit hash chain sealing the existing append-only
            // ledgers (one NEW table; its presence distinguishes v104 from v103).
            "audit_chain": ["seq", "source", "event_id", "occurred_at", "payload_hash",
                            "prev_hash", "entry_hash", "sealed_at"],
            // v105 — WORK-CENTER numbered documents + number-range counters (two NEW tables;
            // work_center_documents' presence distinguishes v105 from v104). NEWEST marker.
            "work_center_documents": ["id", "doc_number", "doc_type", "run_id", "def_id", "step_seq",
                                      "title", "status", "fields_json", "confirmed_seqs", "actor",
                                      "created_at", "updated_at"],
            "work_center_counters": ["doc_type", "year", "next_seq"],
            // v106 — REGISTERS: append-only edit log making captured documents editable
            // WITH HISTORY (one NEW table; its presence distinguishes v106 from v105). NEWEST marker.
            "work_center_record_edits": ["id", "doc_id", "field_key", "old_value", "new_value",
                                         "editor", "note", "edited_at"]
        ]
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
        (112, v112)
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
}
