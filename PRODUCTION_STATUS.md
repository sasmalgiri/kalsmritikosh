# PRODUCTION_STATUS

**Generated:** 2026-07-22 (GOV-003), from committed code + this session's real-data runs.
**Baseline:** `main` at the GOV-002 commit. **Authority:** `SHIP_DECISIONS.md` (CURRENT).

Status vocabulary: `NOT_STARTED` · `IMPLEMENTED` (code compiles, no independent proof) ·
`UNIT_VERIFIED` · `INTEGRATION_VERIFIED` (runnable gate/in-app) · `REAL_DATA_VERIFIED`
(owner corpus this session) · `RELEASE_VERIFIED` · `DEFERRED` · `BLOCKED`.

> **Promotion rule (pack §19.5):** a status here is *proposed* unless it names verification
> evidence. Anything marked **⚠proposed** is inferred from commits/task manifest and has
> **not** been re-verified in code this session — treat as unverified until checked.
> No `UNIT_VERIFIED` is reachable until the test target exists (TST-001, BLOCKED).

## 1. Workstream summary

| Phase | Workstream | Net status | Evidence |
|---|---|---|---|
| P0 | Governance | **DONE** | commits `d785e09`, `75f7f62`, this commit |
| P0 | Audit | AUD-001 DONE; AUD-002/003 NOT_STARTED | `778f8f4`; `FULL_REPOSITORY_STATIC_AUDIT.md` |
| P0 | Testing | **BLOCKED** | 49 test files exist, 0 in target (`grep -c KalsmritikoshTests project.pbxproj` = 0) |
| P0 | CI | BLOCKED (depends TST) | no mandatory test job |
| P0 | Evaluation | INTEGRATION_VERIFIED (fixture) | ProjectDelta gold gate recall/precision 1.00 |
| P1 | Evidence authority | IMPLEMENTED-partial | `source_documents`/`source_versions`/`evidence_blocks` in schema v54; not yet sole authority |
| P2 | Ingestion durability | IMPLEMENTED-partial | PI.1 done; PI.2/PI.3 pending; ingest itself REAL_DATA_VERIFIED |
| P3 | Parsers | REAL_DATA_VERIFIED (fidelity) / IMPLEMENTED (coverage report) | 17 parsers; 526/526 msgs this session |
| P4 | Semantics/domain packs | mostly NOT_STARTED | `SourceType` exists; `DocumentRole` split not done |
| P5 | Retrieval authority | **IMPLEMENTED-heuristic — not release-ready** | `HybridRetriever` density boost; RET-001/003 open |
| P6 | Claims/Reconstruction | IMPLEMENTED | detectors + outline exist; verification incomplete |
| P7 | Personas/Exports | IMPLEMENTED | F1–F6, F8 complete; end-to-end jobs unverified |
| P8 | Workbench/DataLab | **NOT_STARTED** | greenfield subsystem |
| P8 | UX/IA | IMPLEMENTED-partial | 30 destinations; dev surfaces hidden; a11y unverified |
| P9 | Security/Redaction | IMPLEMENTED (privacy) / DEFERRED (redaction) | PrivacyGate; F7 safety-gated |
| P10 | Models | MOD-001 DONE; runtime DEFERRED | GOV-001 locked Apple FM + BGE, no GGUF in v1 |
| P11 | Scale | NOT_STARTED / owner-gated | in-memory HNSW only; no recorded large run |
| P12 | Release | BLOCKED / owner-gated | no signed clean-machine run |

## 2. P0 — verified this session

| ID | Task | Status | Evidence |
|---|---|---|---|
| GOV-001 | Resolve SHIP_DECISIONS | **DONE** | `d785e09` — one locked model/OS/network/scale contract |
| GOV-002 | Banner stale trackers + SHIPPING runbook | **DONE** | `75f7f62` — 11 docs bannered, SHIPPING→App Store |
| GOV-003 | Generate PRODUCTION_STATUS | **DONE** | this file |
| GOV-004 | Root agent instructions point to pack | **DONE** | CLAUDE.md Authority-chain banner (`75f7f62`) |
| AUD-001 | Full static repository audit | **DONE** | `778f8f4` — `FULL_REPOSITORY_STATIC_AUDIT.md` |
| AUD-002 | File ownership/authority/test map CSV | NOT_STARTED | — |
| AUD-003 | Schema authority/rebuildability map | NOT_STARTED | — |
| TST-001 | Create test target + test plan | **BLOCKED** | needs Xcode closed to edit `project.pbxproj` |
| TST-002 | Add test files to target | BLOCKED | depends TST-001 |
| CI-001 | Mandatory build+unit tests | BLOCKED | depends TST-001/002 |
| CI-002 | Migration/parser/security/export jobs | BLOCKED | depends CI-001 |
| EVAL-001 | Record 60Q baseline | INTEGRATION_VERIFIED (fixture) / ⚠proposed (60Q) | gold gate runs; 60Q recording not re-run this session |
| EVAL-002 | Private real-data owner question pack | REAL_DATA_VERIFIED-partial | 3 real questions probed this session (2 still wrong — RET-003) |

## 3. P1 Evidence & P2 Ingestion (near-term active)

| ID | Status | Evidence / note |
|---|---|---|
| EV-001 canonical authority | IMPLEMENTED-partial | structural tables exist; KO/chunks not yet demoted to projections. **Next actionable code task.** |
| EV-002 lossless SourceLocator citations | ⚠proposed IMPLEMENTED | `SourceLocator` model present; unify not proven |
| EV-003 KO/chunk → version+blocks | IMPLEMENTED-partial | `chunks.evidence_block_id` written+read (this session fix `70bea2c`) |
| EV-004 corpus/processing snapshots | IMPLEMENTED | v58 EXTENDS the existing v28 corpus_snapshots (ALTER) with scope + embedding/retrieval/persona/parser versions + readiness, adds snapshot_sources pinning source-version IDs + hashes; repo `snapshot(id:)` gives the full reproducibility view. Verified on fresh DB (`51f8d6f`). |
| EV-005 managed evidence vault | IMPLEMENTED | `EvidenceVault` content-addressed immutable copy store (SHA-256, sharded, dedup, read-only, storage accounting, explicit audited delete). Disk-only, no migration (`5e8e5b0`). Wiring the mode toggle into ingest is the remaining UI/settings step. |
| EV-006 consolidate version mechanisms | IMPLEMENTED (model half) | `SourceVersionView` + pure `VersionModelConsolidator` present ONE version model (canonical wins, legacy flagged lower-confidence + never current, no double-count, exactly one current). Zero data movement (`5c5dc85`). The physical table merge is a separate OWNER-GATED, throwaway-DB-proven migration — not run blind over the live archive. |
| ING-001 durable ingest state machine | NOT_STARTED (PI.3) | IngestAttempts exists; no persisted transitions |
| ING-002 atomic queryable-core commit + collected failures | IMPLEMENTED | atomic core WAS already done (v54: KO+chunks commit-or-rollback via cascade-delete on chunk-insert failure, `IngestCoordinator.processKnowledgeObject`). Collected-failures half added this session (`IngestFailureLog` → `IngestBatchSummary` → `SourcesView` banner, `6aee055`/`45e9e8f`). NOTE: a write-txn across the pipeline's mid-write LLM calls stays deliberately unimplemented (SQLITE_BUSY) — that is NOT part of ING-002. |
| ING-003 idempotent deferred-job queue | IMPLEMENTED (ledger) | PERF.2 `enrichment_jobs` ledger (v59): idempotent enqueue per (subject, kind), claim/done/fail, boot-recovery requeue, per-kind pending counts (`6f749a2`). Generalizes the PERF.1 embedding LEFT-JOIN drain to all Pass-2 kinds. Per-kind drainers + coordinator enqueue wire on top. |
| ING-004 resume/rollback | NOT_STARTED | crash-recovery tests need TST-001 |
| ING-005 typed errors for required writes | IMPLEMENTED (as designed) | verified: the REQUIRED writes (file record, KO, chunks) already `try`/throw with rollback; the remaining `try?` are on the DELIBERATELY best-effort derived writes (entities/events/relationships/custody/attempts) — throwing there would violate the "derived enrichment is re-derivable, not part of the atomic core" decision. No change needed. |
| ING-006 query-priority scheduler | IMPLEMENTED | `QueryPriorityGate` — interactive queries pre-empt background: `MasterBrain` holds it for the whole answer, the embedding drain yields between batches (`5622555`). Gate logic unit-tested. |
| ING-007 multi-dim readiness UX | IMPLEMENTED-partial | LiveActivityPanel stage chips (`f9efdf2`) |

## 4. P5 Retrieval — decisive gap, now largely closed in code

| ID | Status | Evidence / note |
|---|---|---|
| RET-001 QueryPlan compiler | **IMPLEMENTED + UNIT_VERIFIED** | `73f0bda`; `Retrieval/QueryPlan.swift` + tests; snippet-verified |
| RET-003 DocumentFitness channel | **IMPLEMENTED + UNIT_VERIFIED** | `62510c3`; role+field match; density log-damped |
| RET-009 wire fitness / demote density | **IMPLEMENTED + UNIT_VERIFIED (real signals)** | `bc5b3f6`,`f36b124`; résumé 1.855 > mbox 0.380 on real DB |
| RET-008 duplicates≠corroboration | **IMPLEMENTED + UNIT_VERIFIED (real)** | `1f6f9ff`; 8 copies→4 sources |
| RET-006 evidence sufficiency | **IMPLEMENTED + UNIT_VERIFIED, WIRED** | `35569b6`,`e381cca`; honest missing-field footer |
| RET-002/004/005/007 | NOT_STARTED / partial | reranker ladder + RRF exist; fielded FTS/hierarchy/corrective not built |

Root cause was ranking **authority**, not data (all present + FTS-findable). The density
heuristic (pack §7 prohibited) is superseded by question-conditioned fitness. **Remaining:
real-app end-to-end confirmation** (needs a live run) and **entity de-fragmentation** (needs
a user-triggered re-ingest).

## 4b. P6 Claims — partial

| ID | Status | Evidence / note |
|---|---|---|
| CLM-002 causal-language guard | **IMPLEMENTED + UNIT_VERIFIED, WIRED** | `c3247e2`; adjacency≠causation caution in footer |
| CLM-001 full claim verifier | NOT_STARTED | entity/date/amount/status grounding — next in this workstream |
| CLM-003/004 | IMPLEMENTED-partial (detectors exist) | contradiction/gap detectors present; canonical comparison pending |

## 5. Models (P10) — resolved by GOV-001

| ID | Status | Evidence |
|---|---|---|
| MOD-001 model/OS strategy | **DONE** | `SHIP_DECISIONS.md` 2026-07-22 — Apple FM + BGE, macOS 26, no GGUF/cloud in v1 |
| MOD-002 budget-guarded generation | IMPLEMENTED | `LLMCallBudget` / `LLMRequestContext`; per-class maxima |
| MOD-003 native GGUF runtime | **DEFERRED** | not in v1 (optional v1.x) |
| MOD-004 resumable downloader | DEFERRED | tied to optional GGUF |
| MOD-005 model approval record | DEFERRED (GGUF) / N/A for BGE-only v1 | BGE record in MODEL_ATTRIBUTIONS.md |

## 6. Phases P3–P12 — proposed from manifest (⚠ NOT re-verified in code this session)

These reflect prior commits and the task manifest; per the promotion rule they are
**unverified** until a code/test check promotes them. Highlights:

- **Parsers (P3):** 17 parsers REAL_DATA_VERIFIED for fidelity; PAR-001 capability manifest,
  PAR-002 coverage report (FULL/PARTIAL/PRESERVED surfaced). **PAR-005 formula-vs-value model
  IMPLEMENTED** (XLSX `cellFormulas` + `cellFormats` attributes, additive — text path
  unchanged; `6c67e0e`/`e257f97`). **PAR-008 IMPLEMENTED** — HTML/JSON/XML/log structural
  adapters (new SourceTypes + `StructuredTextStructuralParser`; JSON leaf blocks, HTML/XML
  element-path blocks, log records; `30e5af1`). **PAR-009 IMPLEMENTED** — read-only SQLite
  table adapter (`SQLiteStructuralParser` on `ExternalSQLiteSource`; rows cite db/table/key;
  `8064802`). **PAR-004 IMPLEMENTED** — PDF paragraph region boxes (`[x,y,w,h]` via PDFKit
  characterBounds + pure `PDFBoxMath`; exact-highlight citations; `1c0d68a`). **PAR-010
  IMPLEMENTED** — advertised-matrix guard (`1515ee8`). Only PAR-006 (email-thread-fidelity
  limitation) + PAR-007 (audio deferred by design) remain, both intentional.
- **Semantics (P4):** SEM-001 DocumentRole split, SEM-002 BlockSemantics, SEM-003 GenericFact — NOT_STARTED; SEM-009 reversible entity merge/split IMPLEMENTED (schema v49 human-in-loop).
- **Claims/Reconstruction (P6):** contradiction/gap detectors + reconstruction outline + alternatives IMPLEMENTED; CLM-001 full verifier, CLM-002 causal-language, REC-001 outline-gates-generation — incomplete.
- **Personas/Exports (P7):** F1–F6, F8 DONE (workspaces, tags/views, citation+export, composer, contradiction workflow, persona templates, transcripts); PER-003..007 end-to-end jobs unverified.
- **Workbench/DataLab (P8):** NOT_STARTED (greenfield).
- **UX (P8):** dev surfaces hidden from release nav; UX-004 accessibility NOT verified.
- **Security/Redaction (P9):** PrivacyGate + release provider gating IMPLEMENTED; SEC-003 security fixtures exist but unwired. RED-001 text redaction (`PIIRedactor`) IMPLEMENTED; **RED-002 verification gate IMPLEMENTED** (`RedactionVerifier` — protected values proven unrecoverable via exact/case/whitespace/markup channels + package check; `0d5506d`). Remaining redaction gap: format-specific burn-in for PDF/image exports (needs real-artifact verification).
- **Perf/Ingest (PERF.2/ING-006):** `enrichment_jobs` ledger (v59) + boot recovery wired into AppState (`e0f525d`); `QueryPriorityGate` (ING-006) wired — interactive pre-empts background (`5622555`). Per-kind enrichment drainers remain (app-run-gated to avoid duplicating existing passes).
- **Scale (P11):** in-memory HNSW only; SCL-002 disk-backed ANN + SCL-004 advertised-max run NOT_STARTED/owner-gated.
- **Release (P12):** REL-001 project/signing config, REL-002 clean-machine, REL-003 owner acceptance, REL-006 sign-off — BLOCKED/owner-gated.

## 7. Immediate critical path (unblocked-now, in order)

1. **EV-001** — declare canonical source/version/block authority (code, build-verifiable now).
2. **ING-001/002** — durable+atomic ingest state machine (code; tests written as source, wired at TST-001).
3. **RET-001 → RET-003** — QueryPlan compiler then DocumentFitness channel (replaces density boost).
4. **When Xcode is closed:** TST-001/TST-002 (test target) → CI-001/002 → promote statuses to `UNIT_VERIFIED`.
5. **Owner-gated:** SCL-004 scale run, REL-* release operations.
