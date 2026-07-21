> **DOC STATUS: PARTIALLY SUPERSEDED** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Task IDs are reference-only; live status is in PRODUCTION_STATUS.md. _(bannered 2026-07-22, GOV-002.)_

# Kalsmritikosh — Project Completion Instructions (Authoritative Tracker)

Single source of truth for v1 completion. Consolidates
`Kalsmritikosh_Repo_Verified_Remaining_Work_Instructions.md` (dependency order) and
`Kalsmritikosh_Improved_PROJECT_TODOS_with_AI_Help.md` (task IDs), verified against
`origin/main`. Supersedes `PROJECT_TODOS.md`, `REMAINING_WORK.md`, `COMPLETION_STATUS.md`
for planning. Older roadmaps are historical.

## Authority precedence
1. `SHIP_DECISIONS.md` 2. this file 3. committed production code 4. verified tests
5. `COMPLETION_STATUS.md` 6. older roadmaps.

## Status legend (a build passing is NOT "done")
`[ ]` NOT_STARTED · `[~]` IMPLEMENTED (builds, not verified) · `[T]` TEST_VERIFIED ·
`[R]` REAL_DATA_VERIFIED · `[X]` RELEASE_VERIFIED · `[D]` DEFERRED · `[B]` BLOCKED

## Blocker legend
**CODE** = a coding agent can do it now · **OWNER** = product decision · **ENV** = Xcode/Apple/hardware
· **RESEARCH** = web research first.

## High-cost / high-conflict files (coordinate; don't edit in parallel)
`AppState.swift` · `SchemaMigrations.swift` · `IngestCoordinator.swift` · `MasterBrain.swift`
· `HybridRetriever.swift` · `project.pbxproj`

---

# ✅ Already completed this program (do not redo unless a test regresses)
- Minimum-LLM budget system: request context/budget/query-class, provider-boundary
  enforcement, expert caps, adaptive synthesis + renamed depths, investigation cap,
  deterministic fallback, request-scoped counting, sentence-citation reject, derived-objects
  ledger (v35). `[~]` all — need `[T]` via the test target.
- P0.3 ReleaseCapabilityProfile · P0.4 zero-LLM ingest (engine `firstChunkCard:false`) +
  gate check · P0.5 mode-chooser compile-gated. `[~]`
- ZIP security (bomb/flood/slip) `[~]` · contradiction-kind taxonomy + v36 `[~]` ·
  privilege filter across chunks/events/entities/relations `[~]` · CommunitySummarizer daily
  sweep disabled `[~]` · prompt-injection discipline `[~]` · Core ML reranker default `[~]`.

---

# TRACK A — Product correctness (critical path)

## Phase A0 — Governance, CI, test foundation (start now)
- [~] A0.1 — Add this authoritative file; point CLAUDE.md + trackers here. **CODE**
- [ ] A0.2 — Correct tracker inaccuracies (ModelDownloader=stub not absent; synthetic-Q outstanding; test-target=CODE+Xcode; depth already renamed). **CODE**
- [ ] A0.3 — Add `SUPPORTED_FORMATS_V1.md`, `FULL_REPOSITORY_STATIC_AUDIT.md`, `FILE_BY_FILE_AUDIT.csv`. **CODE**
- [ ] A0.4 — Governance banners (current/superseded/historical) on old docs; rewrite SHIPPING.md around Mac-App-Store-only. **CODE**
- [ ] A0.5 — Fix CI `build-and-guard.yml` project path (`Kalsmritikosh.xcodeproj`, not nested) + `set -o pipefail`; fail on xcodebuild error. **CODE**
- [ ] A0.6 — Create the Xcode unit-test target; wire `LLMBudgetTests.swift` + `SessionFeatureTests.swift`; `xcodebuild test` runs. **ENV (Xcode)**
- [ ] A0.7 — CI runs real `xcodebuild test`; a GitHub status check appears on every push/PR; upload logs on failure. **CODE (after A0.6)**
- [ ] A0.8 — 20–25 regression baseline questions vs current fixture (catch catastrophic regressions during A1–A5; NOT the final 60). **CODE**

## Phase A1 — Canonical structural evidence model (THE linchpin; must precede A6)
- [ ] A1.1 — Add models `ParsedDocument`, `EvidenceBlock`, `EvidenceBlockKind` (~30 kinds), `ParserWarning`, `ExtractionStatus`. Models only + unit tests. **CODE**
- [ ] A1.2 — Add `SourceLocator` (page/line/char/bbox/section-path/para-idx/table/row/col/cell/sheet/slide/shape/message-id/header-field/attachment/archive-path/transcript-start-end/speaker/db-row); backward-decode old `SourceRange`. **CODE**
- [ ] A1.3 — Add `DocumentProfile` (deterministic, NOT an LLM summary): filename/type/hash/parser/lang/outline/first-meaningful-block/date-range/principal-entities/counts/children/warnings/readiness. **CODE**
- [ ] A1.4 — Additive migration (v37): `source_documents`, `source_versions`, `evidence_blocks`, `evidence_block_edges`, `document_profiles`, `parser_runs` (+ indices). Do not edit shipped migrations. **CODE**
- [ ] A1.5 — Repositories for the above (append-only where applicable, raw sqlite C-API style). **CODE**
- [ ] A1.6 — Compatibility projection: derive legacy `KnowledgeObject`+`Chunk` from blocks; block store becomes authority; no flag-day switch. **CODE**
- [ ] A1.7 — Chunker persists ordered source block IDs + section path; a chunk may NOT cross email/attachment/slide/table/transcript/archive-member boundaries. **CODE**
- [ ] A1.8 — Boilerplate handling: repeated headers/footers/signatures/disclaimers reversible but down-ranked; page numbers never become event/entity evidence. **CODE**
- [ ] A1.9 — Acceptance: fixture doc → reconstruct original order; every block has a valid locator; heading/body/footer survive restart; old SourceRange answers still decode. **CODE/T**

## Phase A2 — Transactional, parse-once, versioned ingestion
- [ ] A2.1 — Parse-once refactor: probe/hash → identity/version decision → select parser → parse ONCE → validate → transactional persist. Kill double `ingest`/`ingestMany`. **CODE (IngestCoordinator)**
- [ ] A2.2 — MBOX/multi-message: one parse → one container + message blocks (no reparse). **CODE**
- [ ] A2.3 — Version-not-delete: on changed bytes, keep old `source_version`, add new, mark superseded, preserve old derived provenance; explicit current-version selection. **CODE (migration)**
- [ ] A2.4 — Ingest state machine: `ingest_runs`/`ingest_file_attempts`/`parser_runs`/`deferred_jobs`; statuses discovered→hashed→parsing→parsed→persisting→queryable→deferred→failed→superseded. **CODE (migration)**
- [ ] A2.5 — Per-document atomic transaction (source/version + parsed doc + blocks + legacy projection + chunks + FTS + structured rows + entities + assertions/events + relations + custody). Roll back + record on failure. **CODE**
- [ ] A2.6 — Embeddings/ANN insertion OUTSIDE the core txn: persist `embedding_pending`/`index_pending`, run idempotently post-commit. **CODE**
- [ ] A2.7 — Replace silent `try?` in required writes with explicit errors; optional writes record skipped/pending/failed/retryable. **CODE**
- [ ] A2.8 — Parent-child provenance rows (archive→member, email→attachment, mbox→message, doc→embedded, alias→canonical). Dedup must not remove parent link. **CODE**
- [ ] A2.9 — Resume/recovery: on restart detect incomplete runs, resume safe stages, roll back invalid partial state, no dup evidence/vectors, show failures in Sources. **CODE**
- [ ] A2.10 — Fault-injection tests after every stage (no dup blocks / no orphans / old versions queryable / current selected / failure visible+retryable). **CODE/T**

## Phase A3 — Parser migration & real format matrix (parallelizable per format)
- [ ] A3.1 — `SUPPORTED_FORMATS_V1.md`: per SourceType status (advertised/limited/experimental/deferred/unsupported) + parser/structure/locators/OCR/encrypted/fixtures/max-size/limits. **CODE + OWNER sign-off**
- [ ] A3.2 — MIME/magic-byte probing (don't trust extensions). **CODE**
- [ ] A3.3 — TXT/Markdown/HTML → typed blocks. **CODE**
- [ ] A3.4 — DOCX/ODT → typed blocks (part identity, heading level+section path, para ordinal, table/row/cell, header/footer, footnote/endnote, embedded media, OOXML relation). **CODE**
- [ ] A3.5 — PDF → page blocks, native/OCR method per block, bboxes, OCR confidence, repeated header/footer classification, table/figure warnings, encrypted/corrupt/zero-text states. **CODE**
- [ ] A3.6 — XLSX/CSV → structured workbook/sheet/table/row/cell (raw+displayed+formula+format+merged+hidden+named-range). No Markdown-only flatten. **CODE**
- [ ] A3.7 — Deterministic spreadsheet handlers: exact cell, row filter, sum, count, date-range, formula-vs-result (answerable with NO LLM). **CODE**
- [ ] A3.8 — EML/EMLX/MBOX → message block + sender/recipients/cc/bcc, sent+received time, timezone, Message-ID, References/In-Reply-To, body, quoted body, signature, disclaimer, attachment relation, folder/label, malformed-MIME warning. **CODE**
- [ ] A3.9 — Images/OCR → block/line boxes + confidence; preserve unreadable regions as uncertainty, not guessed text. **CODE**
- [ ] A3.10 — PPTX → slide/shape/notes/labels + locator; disclose chart/table gaps. **CODE**
- [ ] A3.11 — EPUB → chapters/sections/paras/footnotes/refs + locators. **CODE**
- [ ] A3.12 — ZIP container relationships persisted (member provenance) + reuse existing security guards. **CODE**
- [ ] A3.13 — Audio/video: add timestamped+diarized segment anchors, OR mark experimental/deferred and remove "video understanding" copy. **OWNER + CODE**
- [ ] A3.14 — Parser acceptance matrix per advertised format (normal/empty/corrupt/encrypted/huge/dup/renamed/nested/interrupted/encoding/exact-reopen) + fixtures. **CODE/T**

## Phase A4 — Remove synthetic questions & hidden enrichment (self-contained early win)
- [ ] A4.1 — AppState: do NOT construct `SyntheticQuestionQueue` / `HeuristicSyntheticQuestionGenerator` in the release path. **CODE (AppState)**
- [ ] A4.2 — IngestCoordinator: synthetic-Q deps internal/debug-only; do not enqueue per-chunk synthetic questions. **CODE**
- [ ] A4.3 — HybridRetriever: do not search synthetic-question projections in v1 retrieval. **CODE**
- [ ] A4.4 — Settings: remove consumer rebuild controls (synthetic Qs / bonds / schema). **CODE**
- [ ] A4.5 — Keep old tables readable for migration; add NO new rows on normal ingest. **CODE**
- [ ] A4.6 — Release test: normal ingest does not increase synthetic-question row count. **CODE/T**
- [ ] A4.7 — Audit every BackgroundService; prove release default runs zero silent generative work (context-prefix/first-chunk/distillation/community/ontology/synthetic/QA all off). **CODE**
- [ ] A4.8 — Deterministic `DocumentProfile` first-meaningful-block excludes blanks/page-numbers/running-headers/signatures/disclaimers/boilerplate/empty-TOC. **CODE (with A1.3)**

## Phase A5 — Evidence-ledger semantics
- [ ] A5.1 — Wire existing `Assertion` substrate into normal extraction: EvidenceBlock → Assertion → Event/Relationship. **CODE**
- [ ] A5.2 — Assertion fields: subject/predicate/object/asserting-source/evidence-block/direct-quote/confidence/asserted-vs-derived/extractor-version. **CODE (migration)**
- [ ] A5.3 — Event extraction fixes: event-specific entities (not all doc entities), event-specific date, sent-vs-received, commitment-vs-completion, doc-version relation, dedup, source blocks, date precision, observed/asserted/derived/inferred status. **CODE**
- [ ] A5.4 — Entities: preserve mention spans + source blocks; alias resolution + merge/split review; language detect + disclose unsupported NER. **CODE**
- [ ] A5.5 — Full epistemic vocabulary persisted+displayed (DIRECTLY_OBSERVED/SOURCE_ASSERTED/DETERMINISTICALLY_DERIVED/INFERRED/CONTRADICTED/UNSUPPORTED/MISSING_EVIDENCE/HUMAN_CONFIRMED/CORRECTED/REJECTED). Human-confirmed ≠ "Proven". **CODE**
- [ ] A5.6 — Contradiction detectors for the 12 non-date kinds (amount/identity/location/status/occurrence/sequence/version/testimony/sent-received/payment/signature/causation); link assertion/event/block IDs both sides. **CODE**
- [ ] A5.7 — Missing-evidence taxonomy: referenced-attachment/final-version/expected-response/payment-proof/source-absence/cadence-window/unreadable-region/custody-break; each states why it matters. Absence ≠ wrongdoing. **CODE**
- [ ] A5.8 — Reversible append-only human review (accept/reject/correct/merge/split/precision-change/resolve-contradiction/dismiss-reopen-gap/mark-authority). **CODE**
- [ ] A5.9 — Atomic per-claim answer ledger (claim text/epistemic-state/evidence-block-ids/role/request-id/versions/purposes/confidence/verifier-result/supersession/review) — extend `derived_objects`. **CODE (migration)**
- [ ] A5.10 — Acceptance: a claim replays answer-sentence→claim→assertion/event→block→locator→source-version/hash. **CODE/T**

## Phase A6 — Retrieval correction (ONLY after A1–A5 stable + gold corpus)
- [ ] A6.1 — Direct-evidence-first authority order (exact structured value → metadata/profile → blocks/assertions → events → FTS → tables → entities/graph → independent vector → memory/summary as navigation). Memory NOT top. **CODE (HybridRetriever)**
- [ ] A6.2 — Independent ANN discovery (don't restrict vectors to already-found chunks); then fuse+rerank. **CODE**
- [ ] A6.3 — Remove generic/global entity top-ups for targeted queries; candidates from exact mention/alias/identifier/explicit-broad only. **CODE**
- [ ] A6.4 — Structured table query path uses persisted cells/rows (deterministic). **CODE**
- [ ] A6.5 — Corroboration counts independent source versions/custodians, not multiple citations to one object. **CODE**
- [ ] A6.6 — Approve + bundle a sentence-level embedding model; versioned cache + re-embedding migration. **RESEARCH + OWNER + CODE**
- [ ] A6.7 — Extend privilege filtering to blocks/assertions/summaries/memory/topics/narrative-plans/answer-ledger/exports; derived inherits source privilege. **CODE**
- [ ] A6.8 — Acceptance on final 60+ corpus: lookup precision ≥0.8, aggregation hit ≥0.8, multihop recall ≥0.6, exact table correct, zero privileged leak, works with memory/summaries disabled. **CODE/T**

## Phase A7 — Historical reconstruction
- [ ] A7.1 — Deterministic reconstruction outline before any narrative call (scope/window/events/status/actors/relations/evidence/contradictions/gaps/causal-candidates/alternatives/coverage). **CODE**
- [ ] A7.2 — Causal-link states (SOURCE_STATED/RULE_SUPPORTED/MODEL_PROPOSED/HUMAN_CONFIRMED/REJECTED); adjacency ≠ causation. **CODE (migration)**
- [ ] A7.3 — Alternative histories (leading + alternative + evidence-each + assumptions + unresolved conflict + decisive missing evidence). **CODE**
- [ ] A7.4 — Sentence-level verification (label exists / entity in evidence / date+amount match / precision not exaggerated / causal language supported / inference labelled). Extends existing check. **CODE**
- [ ] A7.5 — Five gold reconstruction cases (contract-amendment-email / payment dispute / project delay chain / scanned archive / conflicting accounts) with gold events/evidence/contradictions/gaps/alternatives. **CODE + OWNER review**
- [ ] A7.6 — Acceptance: critical-event recall, citation precision, date precision, contradiction recall, missing-evidence usefulness meet thresholds; no-LLM timeline still useful. **CODE/T**

## Phase A8 — Consumer UI consolidation (after core contracts stable)
- [ ] A8.1 — Primary nav: Sources / Ask / History / Findings / Explore / Search / Settings. Fold Timeline→History, FactStatus+Insights→Findings, Knowledge/Dossier/Explorer/Library→Explore, Completeness→Sources; remove ModeChooser + "Killer" naming. **CODE + OWNER taste**
- [ ] A8.2 — Sources: support/ingest-stage/queryable/version/dup-alias/moved-offline/warning/OCR-deferred/count/retry/forget. **CODE**
- [ ] A8.3 — Ask: blank first state (no suggestion grid, no ungrounded preview); every answer shows answer/epistemic-state/citations/confidence/coverage/contradictions/missing/verified/source-open. **CODE**
- [ ] A8.4 — History: event cards (precision/status/actor-action-object/evidence-count/contradiction-gap/source-open/review); inline evidence in prose (no UUID lists). **CODE**
- [ ] A8.5 — Findings: promote FactStatusView; tabs = Direct/Asserted/Derived/Inferred/Contradicted/Missing/Unsupported/Reviewed. **CODE**
- [ ] A8.6 — Explore: label navigation summaries + user notes; every item opens source. **CODE**
- [ ] A8.7 — Settings: consumer set only (privacy/model-storage/permissions/background-deterministic/export-delete/legal-support); provider/eval/schema controls → internal builds. **CODE**
- [ ] A8.8 — Onboarding derives format claims from SUPPORTED_FORMATS_V1.md; states local/stored/model-size/network/delete/limits. **CODE**
- [ ] A8.9 — Accessibility (VoiceOver/keyboard/reduced-motion/scaling/contrast/labels/no-color-only). **CODE**
- [D] A8.10 — Convert deferred/hidden for v1 unless separately approved + verified-formats-only + AI-proofread off. **OWNER**

---

# TRACK B — Local model runtime (parallel; mostly unblocked)
- [ ] B1 — Generic model-independent `LlamaCppProvider` runtime (GGUF load/unload, mmap, streaming, cancel, context limit, stop seqs, structured JSON, memory-pressure unload, bounded concurrency, health, budget integration, no network). Don't bundle weights yet. **CODE — start now**
- [ ] B2 — Finish `ModelDownloader` (currently a stub): URLSession resume, progress, consent, free-space, expected-size, SHA-256, atomic install, cancel, cleanup, update/rollback, delete. **CODE — start now**
- [B] B3 — Verify + approve default GGUF: exact model/quant/licence/redistribution/App-Store rights/attribution/size/RAM-on-8GB-M1/tokens-sec/context/quality. **RESEARCH → OWNER**
- [B] B4 — Select optional 7–8B model for 16 GB+ (the dynamic advisor already picks by RAM tier). **RESEARCH → OWNER**
- [B] B5 — Packaging decision (bundle / Apple ODR / first-launch download) + honest offline copy. **OWNER + ENV**
- [ ] B6 — Bind approved manifests to the runtime; package + checksum default model. **CODE (after B3/B5)**
- [ ] B7 — `ReleaseServiceContainer` vs `InternalServiceContainer`: release registers ONLY approved on-device reasoning/embedding/rerank; hide Cloud/Ollama/MLX/user-GGUF-picker. **CODE**
- [ ] B8 — Release readiness inspects the ACTUAL registry + active engine, not just static profile booleans. **CODE**
- [ ] B9 — Clean 8 GB Mac offline workflow test (launch→ingest→ordinary→history→cite→fallback→export→relaunch). **ENV**

---

# TRACK C — Release, scale, privacy (last)
- [ ] C0 — pbxproj (Xcode closed): macOS `SDKROOT`, drop iOS from `SUPPORTED_PLATFORMS`, fix `productName`, add test target, Release config, model resources, signing, version/build, privacy manifest, entitlements. **ENV**
- [ ] C1 — CI migration matrix (every plausible installed schema, interrupted, low-disk) + ingest fault injection + fast gate. **CODE + ENV**
- [B] C2 — 1 TB decision: build disk-backed/sharded ANN OR revise the locked gate in SHIP_DECISIONS.md. Don't market 1 TB untested. **OWNER**
- [ ] C2a — (if retained) disk-backed/sharded ANN (persistent index, bounded working set, lazy shards, compact vectors, rebuild/recovery). **CODE (large)**
- [ ] C3 — Priority scheduling: active query outranks OCR/embeddings/graph/summaries/downloads (resource lanes + memory-pressure cancel). **CODE**
- [ ] C4 — DB durability tests (WAL/checkpoint/abrupt-term/disk-full/corrupt-index/rebuild/pre-migration-backup/restore/volume-disconnect). **CODE + ENV**
- [ ] C5 — Privacy/security: remove cloud from release registry; release test "cloud cannot resolve"; align PrivacyInfo; security tests (traversal/bomb/symlink/mime/filename/metadata/malformed-db/SQL-FTS/stale-bookmark/temp-cleanup). **CODE**
- [ ] C6 — Privacy outputs: inventory/eval exports require explicit action + warning + private default location; never auto-upload. **CODE**
- [B] C7 — Host Privacy Policy / Terms-EULA / support / model licences / third-party notices. **OWNER**
- [B] C8 — Scale/hardware runs (1/10/100 GB + gate) on 8/16 GB Apple Silicon; capture throughput/RAM/DB-size/latency/resume/thermal. **ENV**
- [B] C9 — App Store: signed archive, clean-machine install, owner 100 GB test, screenshots (no PII), metadata, privacy labels, review notes. **ENV + OWNER**
- [ ] C10 — `OWNER_ACCEPTANCE_v1.md` + `RELEASE_EVIDENCE_v1.md` (SHA/build/schema/model/machines/corpus/metrics/limitations/decision). **CODE + OWNER**

---

# Recommended execution order (dependency-correct)
1. **A0** governance + CI fix + baseline (+ A0.6 test target when you're at Xcode).
2. **A4** remove synthetic questions (self-contained win).
3. **A1** structural evidence models + migration (unblocks everything downstream).
4. **B1 + B2** llama runtime + downloader — in parallel (no owner decision needed).
5. **A2** transactional/versioned ingest → **A3** parsers → **A5** ledger.
6. **B3/B5** model licence + packaging (owner) → **B6/B7/B8** integrate.
7. **A0.3/A8.8** format matrix → **A6** retrieval → **A7** reconstruction → **A8** UI.
8. **C0–C10** project/scale/privacy/App Store.

# Suggested parallel branches (avoid the high-conflict files simultaneously)
`agent/governance-ci` · `agent/structural-evidence` (A1) · `agent/llamacpp-runtime` (B1/B2)
· `agent/remove-synthetic` (A4) · `agent/model-research` (B3/B4). Merge order: governance →
structural → the rest.

# Do-not-do list
No retrieval rewrite before A1–A3 · no deleting old source versions on change · no single
flattened string as the only evidence · no synthetic questions on normal ingest · no hidden
generative backfills · no "proven" for human-confirmed · no corroboration from one source ·
no cloud/Ollama in consumer release · no "CI green"/"tests pass"/"1 TB"/"format supported"
claims without the actual check.
