# PIPELINE_MATRIX — generated, do not hand-edit

Regenerate with `python3 scripts/pipeline-matrix.py`.


> **This is a WIRING map, not a correctness verdict.** It reports whether
> anything writes a table, anything reads it, and any test mentions it. It
> says nothing about whether the values written are correct. A table can be
> fully wired and fully wrong. Use it to decide where to look.


## Summary

| metric | count |
|---|---|
| tables declared | 209 |
| migration-scratch (legitimately write-only) | 14 |
| real tables | 195 |
| **no producer** (nothing writes it) | **6** |
| **written but never read** | **1** |
| **has a producer but NO test mentions it** | **17** |

## No producer — nothing writes these (6)

_Dead schema, or a feature whose persistence was never wired._

| table | lane | producer |
|---|---|---|
| `companies` | — | — |
| `evidence_block_edges` | — | — |
| `people` | — | — |
| `projects` | — | — |
| `timelines` | — | — |
| `vectors` | — | — |

## Written but never read (1)

_The write costs time on the hot path and influences nothing._

| table | lane | producer |
|---|---|---|
| `knowledge_objects_history` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/FilesRepository.swift |

## Produced but no test mentions the table (17)

_The verification gap. Highest-value list in this file._

| table | lane | producer |
|---|---|---|
| `boilerplate_templates` | Knowledge/Boilerplate | Kalsmritikosh/Knowledge/Boilerplate/BoilerplateRegistry.swift |
| `boilerplate_uses` | Knowledge/Boilerplate | Kalsmritikosh/Knowledge/Boilerplate/BoilerplateRegistry.swift |
| `derived_objects` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/DerivedObjectsRepository.swift |
| `embedding_cache` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/EmbeddingCacheRepository.swift |
| `enrichment_status` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/EnrichmentStatusRepository.swift |
| `entity_cooccurrences` | Knowledge/Topics | Kalsmritikosh/Knowledge/Topics/CooccurrenceGraphBuilder.swift |
| `event_versions` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/EventVersionsRepository.swift |
| `investigation_steps` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/InvestigationsRepository.swift |
| `investigations` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/InvestigationsRepository.swift |
| `monitor_snapshots` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/MonitorSnapshotRepository.swift |
| `review_decisions` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/ReviewRepository.swift |
| `review_tags` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/ReviewRepository.swift |
| `saved_queries` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/SavedQueriesRepository.swift |
| `saved_view_filters` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/ReviewRepository.swift |
| `saved_views` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/ReviewRepository.swift |
| `screening_protocols` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/ScreeningRepository.swift |
| `screening_records` | Storage/Repositories | Kalsmritikosh/Storage/Repositories/ScreeningRepository.swift |

## Full matrix

| table | lane | producers | consumers | tests |
|---|---|---|---|---|
| `files` | App, EvalKit, Ingestion/Intake, Storage/Repositories | 4 | 14 | 160 |
| `knowledge_objects` | App, EvalKit, Knowledge/Boilerplate, Storage/Repositories, Storage/Schema | 6 | 29 | 251 |
| `chunk_embeddings` | App, EvalKit, Storage/Schema, Storage/Vector | 4 | 11 | 250 |
| `source_versions` | App, Ingestion/Intake, Storage/Repositories, Storage/Schema | 4 | 20 | 249 |
| `entities` | App, Knowledge/Backfill, Storage/Repositories | 5 | 23 | 82 |
| `entity_mentions` | App, Storage/Repositories, Storage/Schema | 3 | 6 | 233 |
| `chunks` | EvalKit, Knowledge/Backfill, Storage/Repositories, Storage/Schema | 5 | 11 | 267 |
| `chunks_fts` | EvalKit, Storage/Schema | 2 | 3 | 242 |
| `audit_chain` | Forensics, Storage/Schema | 2 | 2 | 249 |
| `container_manifests` | Ingestion/Container | 1 | 2 | 12 |
| `container_members` | Ingestion/Container | 1 | 1 | 12 |
| `source_intake_receipts` | Ingestion/Intake | 1 | 1 | 32 |
| `source_version_relations` | Ingestion/Intake | 1 | 2 | 30 |
| `source_readiness_aggregates` | Ingestion/Readiness, Storage/Schema | 2 | 2 | 231 |
| `source_readiness_dimensions` | Ingestion/Readiness, Storage/Schema | 2 | 3 | 231 |
| `source_readiness_events` | Ingestion/Readiness, Storage/Schema | 2 | 1 | 231 |
| `enrichment_job_events` | Ingestion/Upgrade | 1 | 1 | 4 |
| `enrichment_jobs` | Ingestion/Upgrade, Storage/Repositories | 2 | 3 | 7 |
| `job_events` | Jobs | 1 | 1 | 5 |
| `job_objectives` | Jobs | 1 | 1 | 5 |
| `job_plan_references` | Jobs | 1 | 1 | 5 |
| `generic_facts` | Knowledge/Backfill, Storage/Repositories | 2 | 5 | 47 |
| `boilerplate_templates` | Knowledge/Boilerplate | 1 | 1 | 0 |
| `boilerplate_uses` | Knowledge/Boilerplate | 1 | 1 | 0 |
| `community_summaries` | Knowledge/Topics | 2 | 5 | 22 |
| `document_terms` | Knowledge/Topics | 1 | 3 | 2 |
| `entity_communities` | Knowledge/Topics | 2 | 7 | 8 |
| `entity_cooccurrences` | Knowledge/Topics | 1 | 3 | 0 |
| `fact_reviews` | Knowledge/Twins, Storage/Repositories | 4 | 3 | 5 |
| `case_method_runs` | Method | 1 | 1 | 28 |
| `method_assumptions` | Method | 1 | 2 | 30 |
| `method_edges` | Method | 1 | 2 | 30 |
| `method_evidence_links` | Method | 1 | 2 | 30 |
| `method_findings` | Method | 1 | 2 | 31 |
| `method_nodes` | Method | 1 | 2 | 30 |
| `method_reviews` | Method | 2 | 3 | 32 |
| `method_run_events` | Method | 1 | 2 | 6 |
| `method_runs` | Method | 2 | 3 | 35 |
| `method_validation_results` | Method | 2 | 3 | 32 |
| `investigation_case_closures` | Personas | 1 | 1 | 8 |
| `investigation_case_events` | Personas | 1 | 1 | 31 |
| `investigation_case_sources` | Personas | 1 | 1 | 31 |
| `investigation_cases` | Personas | 2 | 7 | 38 |
| `investigation_desk_reviews` | Personas | 1 | 1 | 8 |
| `investigation_evidence_requests` | Personas | 1 | 1 | 5 |
| `investigation_hypotheses` | Personas | 1 | 1 | 5 |
| `investigation_hypothesis_evidence` | Personas | 1 | 1 | 5 |
| `investigation_identity_decisions` | Personas | 1 | 1 | 6 |
| `investigation_scope_artifacts` | Personas | 1 | 1 | 3 |
| `investigation_subjects` | Personas | 1 | 1 | 12 |
| `investigation_worksheet_cells` | Personas | 1 | 1 | 5 |
| `investigation_findings_approvals` | Personas, Storage/Repositories | 2 | 2 | 9 |
| `app_navigation_entries` | Shell | 1 | 1 | 3 |
| `app_navigation_sessions` | Shell | 1 | 1 | 4 |
| `ann_cells` | Storage/Repositories | 1 | 1 | 4 |
| `ann_index_meta` | Storage/Repositories | 1 | 2 | 4 |
| `ann_postings` | Storage/Repositories | 1 | 2 | 4 |
| `answer_claims` | Storage/Repositories | 2 | 2 | 9 |
| `answer_revision_events` | Storage/Repositories | 1 | 2 | 6 |
| `answer_revisions` | Storage/Repositories | 1 | 1 | 6 |
| `answers` | Storage/Repositories | 2 | 3 | 40 |
| `assertions` | Storage/Repositories | 1 | 1 | 43 |
| `claim_contradictions` | Storage/Repositories | 1 | 1 | 43 |
| `claim_evidence` | Storage/Repositories | 2 | 2 | 8 |
| `claim_evidence_ref` | Storage/Repositories | 1 | 5 | 51 |
| `claim_lineage` | Storage/Repositories | 1 | 1 | 43 |
| `claim_projection_progress` | Storage/Repositories | 1 | 1 | 5 |
| `claim_reviews` | Storage/Repositories | 1 | 1 | 45 |
| `claim_usage` | Storage/Repositories | 1 | 1 | 45 |
| `claims` | Storage/Repositories | 1 | 1 | 134 |
| `conformance_assessments` | Storage/Repositories | 2 | 3 | 6 |
| `contradictions` | Storage/Repositories | 1 | 1 | 50 |
| `conversation_turns` | Storage/Repositories | 1 | 1 | 8 |
| `conversations` | Storage/Repositories | 1 | 1 | 8 |
| `corpus_snapshots` | Storage/Repositories | 1 | 1 | 1 |
| `custody_events` | Storage/Repositories | 1 | 1 | 8 |
| `dataset_rows` | Storage/Repositories | 1 | 1 | 3 |
| `deadline_candidate_reviews` | Storage/Repositories | 1 | 1 | 13 |
| `deadline_candidates` | Storage/Repositories | 1 | 2 | 16 |
| `deadline_reviews` | Storage/Repositories | 1 | 1 | 13 |
| `deadlines` | Storage/Repositories | 1 | 4 | 16 |
| `derivation_failures` | Storage/Repositories | 1 | 2 | 1 |
| `derived_objects` | Storage/Repositories | 1 | 1 | 0 |
| `document_profiles` | Storage/Repositories | 1 | 3 | 69 |
| `email_participant_occurrences` | Storage/Repositories | 1 | 2 | 3 |
| `embedding_cache` | Storage/Repositories | 1 | 1 | 0 |
| `enrichment_status` | Storage/Repositories | 1 | 1 | 0 |
| `entity_aliases` | Storage/Repositories | 1 | 2 | 35 |
| `event_links` | Storage/Repositories | 2 | 2 | 2 |
| `event_links_hypothetical` | Storage/Repositories | 1 | 1 | 2 |
| `event_versions` | Storage/Repositories | 1 | 2 | 0 |
| `evidence_block_objects` | Storage/Repositories | 1 | 3 | 75 |
| `evidence_datasets` | Storage/Repositories | 1 | 1 | 3 |
| `fact_bonds` | Storage/Repositories | 1 | 3 | 1 |
| `file_versions` | Storage/Repositories | 1 | 1 | 27 |
| `gap_nodes` | Storage/Repositories | 1 | 1 | 42 |
| `governance_events` | Storage/Repositories | 2 | 1 | 4 |
| `history_alternative_accounts` | Storage/Repositories | 1 | 1 | 16 |
| `history_artifacts` | Storage/Repositories | 1 | 1 | 17 |
| `history_chapters` | Storage/Repositories | 1 | 1 | 16 |
| `history_gaps` | Storage/Repositories | 1 | 1 | 16 |
| `history_item_evidence` | Storage/Repositories | 1 | 1 | 16 |
| `induced_schema_attempts` | Storage/Repositories | 1 | 2 | 1 |
| `ingest_file_attempts` | Storage/Repositories | 1 | 2 | 27 |
| `ingest_run_files` | Storage/Repositories | 1 | 1 | 1 |
| `ingest_runs` | Storage/Repositories | 1 | 1 | 1 |
| `investigation_steps` | Storage/Repositories | 1 | 1 | 0 |
| `investigations` | Storage/Repositories | 1 | 1 | 0 |
| `knowledge_objects_history` | Storage/Repositories | 1 | 0 | 27 |
| `memory_changes` | Storage/Repositories | 1 | 1 | 7 |
| `memory_objects` | Storage/Repositories | 1 | 2 | 8 |
| `monitor_snapshots` | Storage/Repositories | 1 | 1 | 0 |
| `parser_runs` | Storage/Repositories | 1 | 1 | 69 |
| `professional_issue_links` | Storage/Repositories | 1 | 1 | 5 |
| `professional_issue_reviews` | Storage/Repositories | 1 | 1 | 5 |
| `professional_issues` | Storage/Repositories | 1 | 4 | 9 |
| `professional_task_dependencies` | Storage/Repositories | 1 | 1 | 13 |
| `professional_task_evidence_links` | Storage/Repositories | 1 | 2 | 13 |
| `professional_task_reviews` | Storage/Repositories | 1 | 1 | 14 |
| `professional_tasks` | Storage/Repositories | 1 | 3 | 16 |
| `protocol_registry` | Storage/Repositories | 1 | 1 | 4 |
| `protocol_review_records` | Storage/Repositories | 1 | 1 | 4 |
| `qa_pairs` | Storage/Repositories | 1 | 2 | 10 |
| `qa_pairs_fts` | Storage/Repositories | 1 | 1 | 10 |
| `review_decisions` | Storage/Repositories | 1 | 1 | 0 |
| `review_tags` | Storage/Repositories | 1 | 1 | 0 |
| `saved_queries` | Storage/Repositories | 1 | 1 | 0 |
| `saved_view_filters` | Storage/Repositories | 1 | 1 | 0 |
| `saved_views` | Storage/Repositories | 1 | 1 | 0 |
| `screening_protocols` | Storage/Repositories | 1 | 1 | 0 |
| `screening_records` | Storage/Repositories | 1 | 1 | 0 |
| `sensitive_scope_reviews` | Storage/Repositories | 1 | 1 | 43 |
| `snapshot_sources` | Storage/Repositories | 1 | 1 | 1 |
| `source_documents` | Storage/Repositories | 1 | 3 | 72 |
| `source_relations` | Storage/Repositories | 1 | 2 | 19 |
| `source_reliability_assessments` | Storage/Repositories | 1 | 1 | 7 |
| `summaries` | Storage/Repositories | 1 | 2 | 9 |
| `synthetic_questions` | Storage/Repositories | 1 | 3 | 10 |
| `synthetic_questions_fts` | Storage/Repositories | 1 | 1 | 10 |
| `temporal_claims` | Storage/Repositories | 1 | 1 | 29 |
| `typed_fields` | Storage/Repositories | 1 | 1 | 5 |
| `workflow_artifacts` | Storage/Repositories | 2 | 3 | 38 |
| `workflow_attachment_bindings` | Storage/Repositories | 1 | 1 | 13 |
| `workflow_attention_items` | Storage/Repositories | 1 | 1 | 25 |
| `workflow_automation_executions` | Storage/Repositories | 1 | 1 | 7 |
| `workflow_checkpoints` | Storage/Repositories | 1 | 1 | 24 |
| `workflow_decisions` | Storage/Repositories | 1 | 1 | 25 |
| `workflow_provenance_references` | Storage/Repositories | 1 | 1 | 13 |
| `workflow_provenance_snapshots` | Storage/Repositories | 1 | 1 | 16 |
| `workflow_run_events` | Storage/Repositories | 2 | 2 | 34 |
| `workflow_runs` | Storage/Repositories | 2 | 4 | 37 |
| `workflow_step_runs` | Storage/Repositories | 1 | 3 | 28 |
| `workspace_derived_entities` | Storage/Repositories | 1 | 2 | 27 |
| `workspace_entities` | Storage/Repositories | 1 | 2 | 34 |
| `workspace_sources` | Storage/Repositories | 1 | 3 | 36 |
| `workspaces` | Storage/Repositories | 1 | 4 | 100 |
| `event_entities` | Storage/Repositories, Storage/Schema | 3 | 7 | 232 |
| `events` | Storage/Repositories, Storage/Schema | 2 | 13 | 287 |
| `evidence_blocks` | Storage/Repositories, Storage/Schema | 2 | 8 | 243 |
| `history_items` | Storage/Repositories, Storage/Schema | 2 | 2 | 239 |
| `relationships` | Storage/Repositories, Storage/Schema | 2 | 1 | 242 |
| `sensitive_scope_assignments` | Storage/Repositories, Storage/Schema | 2 | 1 | 241 |
| `transcript_segments` | Storage/Repositories, Storage/Schema | 2 | 1 | 230 |
| `audit_chain_v111` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `claim_evidence_ref_v2` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `conformance_assessments_v110` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `enrichment_jobs__v88` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `entities_new` | Storage/Schema | 1 | 1 | 230 |
| `evidence_blocks_fts` | Storage/Schema | 1 | 2 | 230 |
| `ingest_file_attempts__v83` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `knowledge_objects_fts` | Storage/Schema | 1 | 1 | 230 |
| `method_reviews__v81` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `method_runs__v80` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `method_runs__v81` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `method_validation_results__v81` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `source_intake_receipts__v83` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `source_versions__v82` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `source_versions__v83` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `source_versions__v84` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `transcript_segments_fts` | Storage/Schema | 1 | 1 | 230 |
| `workbench_dataset_events_v93` _(scratch)_ | Storage/Schema | 1 | 0 | 230 |
| `case_phase_artifacts` | Sutra | 1 | 1 | 2 |
| `work_center_counters` | WorkCenter | 1 | 1 | 2 |
| `work_center_documents` | WorkCenter | 1 | 1 | 2 |
| `work_center_record_edits` | WorkCenter | 1 | 1 | 2 |
| `workbench_cells` | Workbench | 2 | 3 | 24 |
| `workbench_dataset_events` | Workbench | 2 | 3 | 21 |
| `workbench_datasets` | Workbench | 2 | 4 | 24 |
| `workbench_derivation_inputs` | Workbench | 1 | 1 | 4 |
| `workbench_derivations` | Workbench | 1 | 1 | 5 |
| `workbench_fields` | Workbench | 2 | 3 | 22 |
| `workbench_rows` | Workbench | 1 | 3 | 21 |
| `workbench_saved_views` | Workbench | 1 | 1 | 19 |
| `workbench_scenario_events` | Workbench | 1 | 1 | 7 |
| `workbench_scenario_operations` | Workbench | 1 | 1 | 8 |
| `workbench_scenario_reviews` | Workbench | 1 | 1 | 7 |
| `workbench_scenarios` | Workbench | 1 | 1 | 9 |
| `workbench_source_bindings` | Workbench | 1 | 2 | 19 |
| `workbench_transformations` | Workbench | 1 | 1 | 6 |
| `work_product_claim_occurrences` | Workflow | 1 | 1 | 5 |
| `work_product_manifests` | Workflow | 1 | 1 | 5 |
| `work_product_runs` | Workflow | 1 | 3 | 8 |
| `work_product_sections` | Workflow | 1 | 1 | 5 |
| `companies` | — | 0 | 0 | 1 |
| `evidence_block_edges` | — | 0 | 0 | 0 |
| `people` | — | 0 | 0 | 13 |
| `projects` | — | 0 | 0 | 9 |
| `timelines` | — | 0 | 0 | 1 |
| `vectors` | — | 0 | 1 | 13 |
