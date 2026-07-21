> **DOC STATUS: HISTORICAL** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Superseded by PRODUCTION_BACKLOG.csv. _(bannered 2026-07-22, GOV-002.)_

# Kalsmritikosh — Full Project TODOs (v1 completion)

> **SUPERSEDED for planning by `PROJECT_COMPLETION_INSTRUCTIONS.md`** (authoritative,
> dependency-ordered, verified against main). This file is retained for history.

Actionable checklist for the whole remaining v1 program, derived from
`Kalsmritikosh_Definitive_Full_Project_Instructions.md`. Checked = done & pushed on
`main`. Each open item notes its blocker: **[OWNER]** decision, **[ENV]** account/hardware,
**[CODE]** a coding agent can do it, **[RESEARCH]** web research needed.

Companion trackers: `COMPLETION_STATUS.md` (state), `REMAINING_WORK.md` (who unblocks).

Note on model selection: the app ALREADY has dynamic, hardware-tier model selection
(`HardwareProbe` RAM→tier, `ModelChoiceAdvisor`/`AutoRecommendation` fit-by-RAM,
`ModelManifest.Tier`, `GGUFRegistry`). So P2 is not "design selection" — it's implement
real `LlamaCppProvider` inference + ship bundled default GGUF(s) the advisor can pick from.

---

## P0 — Truthful shipping config
- [x] P0.3 `ReleaseCapabilityProfile.v1` + `violations()`
- [x] P0.4 zero-LLM ingest policy (engine `firstChunkCard:false`) + release gate check
- [x] P0.5 mode chooser compile-gated out of release
- [x] P0.1 (partial) `COMPLETION_STATUS.md` tracker
- [ ] P0.1 add `FULL_REPOSITORY_STATIC_AUDIT.md`, `FILE_BY_FILE_AUDIT.csv`, `SUPPORTED_FORMATS_V1.md` **[CODE]**
- [ ] P0.2 governance banners (current/superseded/historical) on old docs; point CLAUDE.md here; rewrite SHIPPING.md around App-Store-only **[CODE]**

## P1 — Hard minimum-LLM query
- [x] P1.1 request context + `LLMCallBudget` + `LLMQueryClass`
- [x] P1.2 provider-boundary enforcement (scoped `generate(...purpose:context:)`)
- [x] P1.3 remove ungrounded Ask preview
- [x] P1.4 cap experts by query class
- [x] P1.6 budget synthesis/council + renamed depth cases
- [x] P1.7 budget history (shared budget, chapters + fallback)
- [x] P1.8 budget investigation (maxSteps=2, nested share parent budget)
- [x] P1.9 request-scoped diagnostics (`answerWithDiagnostics`, RealDataProbe)
- [ ] P1.5 tighten query classification: never classify "invoice 14 / when sent / how much / clause 7" as reconstruction; require strong reconstruction signals **[CODE]**

## P2 — Bundled local model (#1 SHIP BLOCKER)
- [ ] P2.1 choose default + optional-larger GGUF models; record licence/redistribution/attribution/RAM/tokens-per-sec on 8 GB M1 **[OWNER + RESEARCH]**
- [ ] P2.2 implement real `LlamaCppProvider` (load/unload, mmap, streaming, cancel, context-window, stop seqs, structured JSON, memory-pressure, health, budget integration, no network) **[CODE, after P2.1]**
- [ ] P2.3 package the default model (bundle vs On-Demand-Resource vs first-launch download); honest offline copy **[OWNER + ENV]**
- [ ] P2.4 `ModelDownloader.swift` (consent, resumable, progress, free-space, SHA-256, atomic install, cancel, cleanup, delete, rollback) **[CODE]**
- [ ] P2.5 AppState release wiring: register bundled llama.cpp + FoundationModels(if compatible) + local embed/rerank ONLY; keep the existing RAM-tier advisor picking among them **[CODE]**
- [ ] P2.6 hide non-v1 providers (cloud/Ollama/MLX/GGUF-picker) from release UI **[CODE]**

## P3 — Transactional / versioned ingest
- [ ] P3.1 parse-once: probe/hash → idempotency → ONE parse → validate → transactional persist **[CODE]**
- [ ] P3.2 durable runs: `ingest_runs`, `ingest_file_attempts`, `parser_runs` (schema + repo) **[CODE, migration]**
- [ ] P3.3 per-file transaction: file/KO/chunks/FTS/entities/events/relations/vectors/custody commit-or-rollback together; replace silent `try?` in required writes **[CODE]**
- [ ] P3.4 file versioning: supersedes / valid_from / valid_to / current / original hash; don't cascade-delete on change **[CODE, migration]**
- [ ] P3.5 universal evidence locator (chunk/char/page/line/bbox/sheet/cell/slide/shape/message-id/header/attachment/av-time/archive-path/db-row) **[CODE]**
- [ ] P3.6 parent-child provenance (archive→member, email→attachment, mbox→message, doc→embedded) **[CODE]**
- [ ] P3.7 unsupported/encrypted/corrupt/partial/deferred source-health states (stop using TextLoader as universal binary fallback) **[CODE]**
- [ ] P3.8 resume/recovery — persist pipeline stages **[CODE]**

## P4 — Parser support matrix
- [x] P4.11 ZIP security (zip-bomb / entry-flood / zip-slip)
- [ ] P4.1 `SUPPORTED_FORMATS_V1.md` (advertised/limited/experimental/deferred/unsupported per SourceType) **[CODE + OWNER sign-off]**
- [ ] P4.4 PDF: page blocks, native/OCR per block, OCR confidence, bboxes, encrypted/corrupt, zero-text failure, table warnings **[CODE]**
- [ ] P4.5 DOCX: heading path, paragraph index, table row/cell, comments/footnotes, tracked-change policy, exact locator **[CODE]**
- [ ] P4.6 XLSX/CSV: structured cells (sheet/row/col/raw/displayed/formula/format/merged/hidden/header) + deterministic numeric/date/table handlers **[CODE]**
- [ ] P4.7 PPTX: slide/shape/notes/labels + locator; disclose chart/table gaps **[CODE]**
- [ ] P4.8 Email: robust MIME, sent/received, message-id/thread parent, timezone, labels, quote-strip metrics, attachment parent, malformed recovery **[CODE]**
- [ ] P4.9 Images: block/line boxes + confidence; preserve unreadable regions as uncertainty **[CODE]**
- [ ] P4.10 Audio/video: add timestamped/diarized anchors OR remove from v1 copy (no "full video understanding") **[OWNER decision + CODE]**
- [ ] Parser acceptance matrix (normal/empty/corrupt/encrypted/huge/dup/renamed/nested/interrupted/encoding/reopen) **[CODE + fixtures]**

## P5 — Ledger semantics
- [x] P5.5 (partial) contradiction taxonomy `Kind` + v36 persistence
- [ ] P5.1 surface full epistemic vocabulary in UI (Direct/Asserted/Derived/Inferred/Contradicted/Unsupported/Missing/HumanConfirmed/Corrected/Rejected — not "Proven") **[CODE]**
- [ ] P5.2 assertions first-class (`Assertion` + repo; events/relations derive from assertions) **[CODE, migration]**
- [ ] P5.3 event extraction fixes: sent vs received, event-specific entities/dates, dedup, doc-version relation, temporal precision, commitments-as-assertions **[CODE]**
- [ ] P5.4 entities: preserve mention spans/sources, alias resolution + merge/split review, language detect + disclose unsupported NER **[CODE]**
- [ ] P5.5 (finish) detectors for non-date kinds (amount/identity/location/status/payment/signature/causation/…) + link to assertion/event IDs **[CODE]**
- [ ] P5.6 missing-evidence taxonomy (attachment/source/reply/payment-proof/final-version/sequence-hole/cadence/window-gap/parent-msg/custody-break/unreadable) — each states why it matters **[CODE]**
- [ ] P5.7 human review: append-only, correct/merge/split/resolve/dismiss/mark-authority/reverse; never deletes **[CODE]**
- [ ] P5.8 answer ledger: atomic per-claim (not whole-answer) with request id/class/snapshot/versions/purposes/selected+rejected evidence/status/contradictions/gaps/review/supersession **[CODE, extends derived_objects]**
- [ ] P5.9 custody: optional hash chaining/signing for tamper evidence (no blockchain) **[CODE]**

## P6 — Retrieval
- [x] P6.4 privilege filtering across all layers
- [x] P6.5 disable daily CommunitySummarizer default
- [x] P6.7 deterministic reranker default (Core ML ladder)
- [ ] P6.1 direct-evidence-first fusion (generated memory NOT top authority) **[CODE]**
- [ ] P6.2 remove generic entity pollution (no global top-entities for targeted queries) **[CODE]**
- [ ] P6.3 independent ANN candidate discovery (don't restrict vector search to already-found chunks) **[CODE]**
- [ ] P6.5 (finish) lazy community summaries on topic open + cache/version by source hash **[CODE]**
- [ ] P6.6 bundle sentence-level embedding model (licence, dimension, batch, cache key, re-embed migration) **[OWNER + RESEARCH + CODE]**
- [ ] P6.8 structured table query path (exact cells/sums/filters, deterministic) **[CODE]**
- [ ] P6.9 corroboration = independent sources (not multiple citations to same object/event) **[CODE]**

## P7 — Historical reconstruction
- [x] P7.4 sentence-level citation (composer + expert synthesis reject-uncited)
- [x] P7.5 deterministic no-LLM fallback (`DeterministicEvidenceFallback`)
- [ ] P7.1 deterministic reconstruction outline before narrative (topic/window/events/status/actors/relations/evidence/contradictions/gaps/causal/alternatives/coverage) **[CODE]**
- [ ] P7.2 causality discipline (directly-stated / rule-supported / model-proposed / human-confirmed / rejected; adjacency ≠ causation) **[CODE]**
- [ ] P7.3 alternative histories (leading + alternative + evidence-for-each + assumptions + unresolved conflict + missing decisive evidence) **[CODE]**
- [ ] P7.6 five mixed-source gold reconstruction cases with gold events/evidence/contradictions/gaps/alternatives **[CODE + OWNER review]**

## P8 — Consumer UI consolidation
- [ ] P8.1 primary nav (Home/Sources/Ask/History/Findings/Explore/Search/Settings); fold Timeline→History, FactStatus+Insights→Findings, Knowledge/Dossier/Explorer/Library→Explore, Completeness→Sources; remove ModeChooser/KillerFeatures naming **[CODE + OWNER taste]**
- [ ] P8.2 Sources: support/ingest/queryable/version/dup/moved/offline/missing/warning/OCR/count/forget states **[CODE]**
- [ ] P8.3 Ask: blank first state (no suggestion grid); every answer shows answer/epistemic-state/citations/confidence/coverage/contradictions/missing/verified/source-open **[CODE]**
- [ ] P8.4 History: event cards (date precision/status/actors/evidence count/contradiction/gap/source open/review); inline evidence in prose (not UUID lists) **[CODE]**
- [ ] P8.5 Findings: promote `FactStatusView`; tabs = real vocabulary (Direct/Asserted/Derived/Inferred/Contradicted/Missing/Unsupported/Reviewed) **[CODE]**
- [ ] P8.6 Explore: label navigation summaries + user notes; every item opens source **[CODE]**
- [ ] P8.7 Settings: consumer set (privacy/background/model storage/permissions/data/support/diagnostics); move provider-pinning/cloud/Ollama/schema-rebuild/eval to internal builds **[CODE]**
- [ ] P8.8 Onboarding: generate format list from `SUPPORTED_FORMATS_V1.md`; state local/stored/model-size/network/delete/limits **[CODE]**
- [ ] P8.9 Convert: defer/hide for v1 (or verified-formats-only + AI proofread off) **[CODE + OWNER]**
- [ ] P8.10 accessibility (VoiceOver/keyboard/reduced-motion/scaling/contrast/labels/no color-only) **[CODE]**

## P9 — Testing / CI / eval
- [ ] P9.1 create + commit Xcode unit-test target; wire `LLMBudgetTests.swift` + `SessionFeatureTests.swift` **[ENV — owner in Xcode]**
- [ ] P9.2 CI `build-and-guard.yml`: build + test + grep guard + migration fixtures + fast gate; upload artifacts **[CODE + ENV]**
- [ ] P9.3 unit suites (date/intent/budget/expert-caps/retries/event-status/fact-status/contradiction/gap/entity/locator/chunk/archive/email/tables/privilege/fallback) **[CODE]**
- [ ] P9.4 integration tests on temp DBs (fresh schema/every migration/interrupted/rollback/versioning/move/delete/incomplete/replay) **[CODE]**
- [ ] P9.5 expand eval 16 → 60+ gold questions (10 lookup/8 semantic/8 aggregation/8 temporal/8 multihop/5 contradiction/5 missing/4 table/4 unsupported) + reconstruction gold **[CODE + OWNER gold answers]**
- [ ] P9.6 rename Release Readiness accurately (software gate ≠ App-Store-ready) **[CODE]**

## P10 — Scale & performance
- [ ] P10.1 decide: build disk-backed/sharded ANN for 1 TB, OR revise the locked gate to a tested size **[OWNER]**
- [ ] P10.1a (if retain 1 TB) implement persistent/segmented ANN, bounded working set, lazy shards, compact vectors, rebuild/recovery **[CODE, large]**
- [ ] P10.2 stress tiers 1/10/100 GB / gate: files-hr, chunks-s, time-to-queryable, RAM peak/sustained, DB size, startup, p50/p95, resume, thermal **[ENV — hardware]**
- [ ] P10.3 priority scheduling (active query outranks OCR/embeddings/graph/summaries/download) via resource lanes + memory-pressure cancel **[CODE]**
- [ ] P10.4 DB durability tests (WAL growth/checkpoint/abrupt term/disk full/corrupt index/rebuild/pre-migration backup/restore/volume disconnect) **[CODE + ENV]**

## P11 — Privacy / security
- [x] P11.3 prompt-injection defense (evidence delimited as untrusted)
- [ ] P11.1 remove cloud from release path: no registration/UI/nutrition-label; release test asserts cloud cannot resolve **[CODE]**
- [ ] P11.2 network entitlement docs (endpoint/use, no content, no telemetry, no arbitrary URLs, App Review notes) **[CODE + OWNER]**
- [ ] P11.4 archive/file security tests (traversal/bomb/symlink/malformed-mime/malicious-name/huge-metadata/malformed-db/SQL-FTS-syntax/stale-bookmark/temp-cleanup) **[CODE]**
- [ ] P11.5 privacy outputs: inventory/eval reports require explicit action + warning + private default location; never auto-upload **[CODE]**
- [ ] P11.6 host Privacy Policy / Terms/EULA / support URL / model licences / third-party notices; align `PrivacyInfo.xcprivacy` **[OWNER + CODE]**

## P12 — App Store & owner acceptance
- [ ] P12.1 pbxproj: macOS-only SDK, release signing, test target, model resources, privacy manifest, entitlements, version/build, archive config; fix `productName` **[ENV — Xcode/owner]**
- [ ] P12.2 migration matrix from every deployed schema + pre-migration backup **[ENV]**
- [ ] P12.3 clean-machine test on 8 GB Mac (install→onboard→ingest→ask→reconstruct→cite→review→export→relaunch→reconnect→delete) **[ENV]**
- [ ] P12.4 owner 100 GB test: 20+ reviewed questions across all classes **[ENV — owner]**
- [ ] P12.5 App Store materials (name/subtitle/description/keywords/category/rating/privacy-labels/URLs/screenshots/review-notes) **[OWNER]**
- [ ] P12.6 `OWNER_ACCEPTANCE_v1.md` + `RELEASE_EVIDENCE_v1.md` (SHA/build/schema/model/machines/corpus/metrics/limitations/decision) **[OWNER]**

---

## Recommended execution order
1. **P2.1 model decision** (unblocks shipping) → **P2.2 LlamaCppProvider** → P2.5/P2.6 wiring.
2. **P9.5 60-question gold set** (needed to prove P6 doesn't regress) → **P9.1/9.2 test target + CI**.
3. **P6** retrieval quality → **P3** transactional ingest → **P5** ledger semantics.
4. **P4** parser matrix (parallelizable per format) → **P7** reconstruction → **P8** UI.
5. **P10** scale → **P11/P12** release.

Testing runs in every phase; P9 formalizes it.
