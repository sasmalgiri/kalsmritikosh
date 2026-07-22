# SCHEMA_AUTHORITY_MAP

**Task:** AUD-003. **Baseline:** schema v54, 74 tables (`SchemaMigrations.latestVersion = 54`).
**Generated:** 2026-07-22 from `Kalsmritikosh/Storage/Schema/`.

Every table is classified by its role in the evidence contract:

- **AUTHORITY** — canonical truth. Carries source identity/version, structural evidence,
  human decisions, or user intent. **Never silently lost; never rebuilt from a projection.**
- **PROJECTION** — derived from authority; safe to drop and recompute. Includes generated
  text (never primary evidence per the pack), graph derivations, detections.
- **CACHE/INDEX** — pure acceleration (FTS, embeddings, hashes); always rebuildable.

Rebuildability: PROJECTION and CACHE rows can be regenerated from AUTHORITY rows + the
parsers/extractors. If every AUTHORITY table survives, the ledger is fully reconstructible.

## Authority tables (canonical — protect)

| Table | Role |
|---|---|
| `source_documents` | Canonical source identity. **Root authority.** |
| `source_versions` | Source version history (bytes/hash/provenance per version). |
| `source_relations` | Relationships between sources (attachment/thread/derivation). |
| `evidence_blocks` | Typed structural evidence with exact `SourceLocator`. **Sole evidence authority (target of EV-001).** |
| `files` | Legacy file path/identity. *(Demote to projection of source_documents — EV-006.)* |
| `file_versions` | Legacy per-file version log. *(Consolidate with source_versions — EV-006.)* |
| `knowledge_objects` | Legacy normalized unit. *(Becomes a projection of source+blocks — EV-003.)* |
| `knowledge_objects_history` | Legacy KO version log. *(Consolidate — EV-006.)* |
| `entities`, `entities_new`, `entity_aliases` | Canonical entities + aliases (real-world things). `entities_new` is a migration-in-progress table — reconcile. |
| `entity_mentions` | Mentions (name occurrences) linked to source — evidence-derived but source-anchored. |
| `people`, `companies`, `projects` | Entity subtype tables. *(Verify vs `entities` — likely legacy/partial projection.)* |
| `events`, `event_versions`, `event_entities`, `event_links` | Dated events + actors + links. User-reviewable; source-backed. |
| `relationships` | Canonical relationships. |
| `assertions` | Attributed statements (who claimed what — SOURCE_ASSERTED). |
| `custody_events` | Chain-of-custody records. |
| `transcript_segments` | Timed transcript evidence (authority for audio/video). |
| `document_profiles` | Per-source profile. |
| `fact_reviews`, `review_decisions`, `review_tags` | **Human review layer** (HUMAN_CONFIRMED/CORRECTED/REJECTED). Never mutates source. |
| `memory_changes` | MemoryChange log — authority for *how memory changed* (audit trail). |
| `workspaces`, `workspace_entities`, `workspace_sources` | User-created workspaces (user intent). |
| `saved_views`, `saved_view_filters`, `saved_queries` | User configuration. |
| `answers`, `answer_claims`, `claim_evidence` | Answer ledger — authority for issued answers + their evidence receipts (replay). |
| `investigations`, `investigation_steps` | Investigation records. |
| `screening_protocols`, `screening_records` | Screening configuration + outcomes. |
| `ingest_file_attempts`, `parser_runs` | Ingest/parse provenance (authority for what was attempted + failures). |
| `corpus_snapshots` | Corpus/processing snapshots for reproducible replay (EV-004). |
| `boilerplate_templates`, `boilerplate_uses` | Work-product templates + usage (config). |

## Projection tables (derived — rebuildable)

| Table | Derived from |
|---|---|
| `chunks` | `evidence_blocks` (retrieval unit; `evidence_block_id` link). |
| `summaries`, `community_summaries` | Generated text over sources/entities — **never primary evidence**. |
| `memory_objects` | Distilled memory (a projection; **memory never outranks source evidence**). |
| `entity_communities`, `entity_cooccurrences` | Graph derivations over entities/mentions. |
| `evidence_block_edges` | Block adjacency/graph. |
| `event_links_hypothetical` | Derived hypotheses (clearly non-authoritative). |
| `timelines` | Ordered events. |
| `contradictions`, `gap_nodes` | Detections (recomputable from evidence). |
| `derived_objects` | Explicitly derived. |
| `fact_bonds` | Derived fact links. |
| `qa_pairs` | Derived Q/A. |
| `enrichment_status` | Per-object process state. |
| `monitor_snapshots` | Telemetry snapshots. |
| `conversations`, `conversation_turns` | Session chat history (not evidence). |

## Cache / index tables (acceleration — always rebuildable)

| Table | Kind |
|---|---|
| `knowledge_objects_fts`, `chunks_fts`, `evidence_blocks_fts`, `transcript_segments_fts`, `qa_pairs_fts`, `synthetic_questions_fts` | FTS5 indexes. |
| `vectors`, `chunk_embeddings` | Embeddings — rebuildable by re-embedding (model-aware; `chunk_embeddings` carries `model_id`/`dim`). |
| `embedding_cache` | Text-hash → vector cache. |

## Release-gated / non-release tables

| Table | Note |
|---|---|
| `synthetic_questions`, `synthetic_questions_fts` | Synthetic-question path is `#if DEBUG` only — **not populated in release** (PI.4). |

## Findings for EV-001 (canonical authority declaration)

1. **Duplicate version mechanisms coexist:** `source_versions` + `file_versions` +
   `knowledge_objects_history`. EV-006 must consolidate to one active model
   (`source_versions`), with the others migrated/retired.
2. **`entities` vs `entities_new` vs `people`/`companies`/`projects`:** more than one entity
   representation. Reconcile to a single canonical entity model (SEM-009 territory).
3. **KO/chunks not yet demoted:** `knowledge_objects` and `chunks` are still treated as
   near-authority in places; EV-001/EV-003 must make them explicit projections of
   `source_documents`/`source_versions`/`evidence_blocks` with an invariant test.
4. **Rebuildability holds** if all AUTHORITY tables + parsers survive: every PROJECTION and
   CACHE table is recomputable. This is the property EV-004 snapshots must preserve.
