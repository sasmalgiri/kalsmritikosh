# PRODUCTION_STATUS

```
Audit date:            2026-08-07 (release-closure program refresh)
Current audited HEAD:  main after PRs #70-#73 (macros B-E merged; macro F on PR #74)
Latest schema version: 102 (SchemaMigrations.latestVersion)
Whole-suite floor:     3389 (ci/test-baseline.json; the LIVE authority — updated every evidence commit)
Migration-group floor: 375 (ci/test-groups/migration-matrix.json)
Parser-fixtures floor: 126 (ci/test-groups/parser-fixtures.json; raised 78 -> 126 in macro E)
Verified hosted run:   PR #73 build-and-test — xcresult total=3389, passed=3387, failed=0, skipped=2
Architecture guards:   8 green (capability-discipline, no-try-fatalerror, no-network-evidence-layers,
                       no-synthetic-questions, sensitive-scope-mutation-bypass, release-configuration,
                       persona-neutral-truth [PR #74], + run-all aggregation)
CI:                    7 named jobs green on every PR head + main (the original 6 + release-build,
                       which compiles the TRUE Release configuration on every push)
Release configuration: GOV-004 — macOS 15.6 capability-adaptive floor; Release build offline
                       (outgoing network entitlement OFF); Ollama/cloud DEBUG-internal only;
                       Release configuration compiles (first proven in macro B, then CI-gated)
Branch ruleset:        main branch-protected; per-PR CI required to merge (owner: add release-build
                       to the required-checks list)
```

> **2026-08-06 refresh note.** The header above supersedes the 2026-07-24 snapshot (which predated ~35
> migrations). This block is now accurate to `main`; the LIVE test-count authority is `ci/test-baseline.json`,
> not this file. The detailed evidence matrix in the sections below is historical (persona-v2 pipeline era)
> and is retained as-is — newer subsystems are summarized in "Current status" immediately below rather than
> back-filled row-by-row.

## Current status (2026-08-07)

- **Release-closure program (macros B-F)**: release configuration corrected + CI-enforced (GOV-004
  15.6 adaptive floor, offline Release, Ollama DEBUG-only; the Release configuration COMPILES —
  it never had before macro B — and a `release-build` CI check keeps it that way); citation-integrity
  P1 closed (`CitationResolver` authority union across chunk/event/relationship/deterministic-
  evaluation/authority layers, gate F3); security gates S3/S4/S6 closed at the output-representation
  level; advertised-format matrix fully fixture-backed (F1); five-persona coverage + live routing
  proven (F2, 71 launchable jobs pinned against the 75-row matrix); truth gates T1 (persona-neutral
  truth, guard-enforced) and T3 (duplicate-source independence) closed; §19 deterministic 60-question
  retrieval eval hosted with measured floors (PR #74).
- **All five personas live** — 71 launchable jobs over the shared engines via `PersonaJobService` +
  `PersonaJobCatalogComposer.composeProduction()`, booted in AppState; live routing proven for all
  five personas (PersonaJobMatrixCoverageTests).
- **Cross-persona UI** (`PersonaJobsView`, `Destination.work`); **Handoff & Review**
  (`WorkProductHandoffView`, `Destination.handoff`); **Exports** (markdown/html/csv/json/rtf +
  native PDF + pure-Swift OOXML DOCX/XLSX) with redaction verified fail-closed at the
  output-representation level (ReleaseSecurityGateTests, incl. PDFKit page-text inspection).
- **Professional Method Engine**: MET-01..16 all registered with validators, MethodRun persistence,
  pause/resume/reopen proven. **Evidence Workbench**: LAB-001..006 capabilities present
  (datasets/fields/rows/bindings/lineage/safe formulas/presets/scenarios/undo-redo/quality
  warnings/saved views). **Shared shell**: Fast / Full Evidence modes (locked names shipped);
  LLM call budgets pinned 8/8 with one budget spanning the whole request (LLMBudgetTests).
- **Schema at v102**; migrations SAVEPOINT-wrapped with self-heal markers; no shipped migration edited.
- **Gate scoreboard** (RELEASE_EVIDENCE_INDEX.md): F1 F2 F3 S3 S4 S6 at INTEGRATION with hosted run
  ids; T1 T3 land with PR #74. Remaining PENDING gates are owner-run (persona acceptance journeys,
  scale run SC1/SC2, clean-machine, App Store AS1-11) or documentation refresh in flight.

**Authority:** `SHIP_DECISIONS.md` (CURRENT) → `WHOLE_PROJECT_COMPLETION_PROGRAM.md` →
`PERSONA_JOB_COVERAGE_MATRIX.csv` → code → tests → recorded acceptance. This file is regenerated
from the current code + the recorded hosted CI run; it replaces the 2026-07-22 status document,
which predated the Claim engine, workspace, receipt, composer and CI work.

> **Evidence honesty.** The independently recorded full hosted test evidence is for `fbd12435`.
> `41ca3611` is the current docs-only HEAD; its rerun (docs-only, workflow unchanged) is expected
> green — if/when it finishes, record its own run ID here rather than implying run `30107577371`
> tested `41ca3611`.

Evidence-state vocabulary (an item may hold several):
`Implemented` · `Unit verified` · `Integration verified` · `Real-data verified` ·
`GUI witnessed` · `Hosted-CI verified` · `Release verified` · `Pending`.

---

## 1. Completed evidence → report foundation

> The **persona-v2 evidence-to-report pipeline is complete**. The **five persona professional
> applications remain under the whole-project program** (Stages 2–6 + per-persona packs).

| Item | State | Evidence |
|---|---|---|
| Canonical Claim model + repositories (`Claim`, ClaimRepository/Review/Usage/Contradiction, `ClaimResolver`) | Implemented · Integration verified · Hosted-CI verified | ClaimProducerTests, ClaimEvidenceIdentityTests; schema ≤v67 |
| Multidimensional assessment (basis/review/origin/availability/conflict) + `AssertabilityPolicy` fail-closed export | Implemented · Integration verified · Hosted-CI verified | EvidenceExportGateTests |
| Production Claim projection + durable backfill + incremental ingest hook (`ClaimProducer` = `claim-producer-3`, `ClaimProjectionBackfill`) | Implemented · Integration verified · Hosted-CI verified | ClaimProducerTests, ClaimProjectionBackfillTests |
| Exact EvidenceBlock → KnowledgeObject ownership (`evidence_block_objects`, resolveCanonicalBlocks) | Implemented · Integration verified · Real-data verified | ClaimProducerRealIngestTests |
| Workspace B4 evidence-source boundary | Implemented · Integration verified | WorkProductAssemblyServiceTests |
| Source-scoped Claims for plain documents (`ClaimScope.knowledgeObject`) | Implemented · Integration verified · Real-data verified | SourceScopedClaimTests |
| Workspace source-management UI (`WorkspaceSourceCoordinator`, WorkspacesView) | Implemented · Integration verified · GUI witnessed | WorkspaceSourceCoordinatorTests; owner GUI run |
| General Summary template | Implemented · Integration verified | WorkProductAssemblyServiceTests |
| Chronology template | Implemented · Integration verified | WorkProductAssemblyServiceTests |
| Investigation Findings template (registry) | Implemented · Integration verified | InvestigationReportTests |
| Fact Memo template (registry) | Implemented · Integration verified | FactMemoReportTests |
| Registry-only production assembly; legacy production route removed; `plan(for:)` total | Implemented · Integration verified | WorkProductAssemblyServiceTests (noTemplateRoutesLegacy) |
| Exact source-version custody hashes on receipts | Implemented · Integration verified · Real-data verified | WorkProductReceiptCustodyTests |
| Report/receipt identity | Implemented · Integration verified | report==receipt tests across templates |
| Rich Event Claim rendering (`EventClaimStatementRenderer`) | Implemented · Integration verified · Real-data verified | EventClaimStatementTests |
| Subjectless-email topic recovery (`EmailTopicExtractor`) | Implemented · Unit verified · Real-data verified | EmailTopicExtractorTests |
| Real EML + multi-message MBOX isolation | Real-data verified | EmailTopicExtractorTests |
| PA-PROD manual acceptance (VALID/BLOCKED workspaces, sealed receipt) | GUI witnessed | owner `--pa-prod-gui-smoke` run; PAProdGUIAcceptanceTests |

---

## 2. Whole-project status (master stages) — HISTORICAL (2026-07 era; superseded by "Current status" above)

| Program area | Status | Verification | Remaining work |
|---|---|---|---|
| Evidence and Claim engine | Near complete | Tests + hosted CI + real fixtures | Quality-depth items (QUALITY-001…009) |
| Work-product / export engine | Complete for the four templates | Tests + GUI witness | Work-product run persistence (OPS-004) |
| Stage 1 production verification | In progress | CI-001A green (run 30107577371) | STATUS (this), migrations, specialized CI jobs, branch ruleset |
| Shared professional objects | In progress (2 of 6) | OPS-001 run 30148706330; OPS-002 runs 30156183281 + 30160395578 (OPS-002.1 accepted) | OPS-003…006 |
| Persona Job Engine | Complete (Stage 3) | PJE-001..012 accepted; hosted-green; schema v78; floor 1851 — see `STAGE3_ACCEPTANCE.md` | Consumed by Stage 4/5/6 |
| Professional Method Engine | Pending | — | 16-method first pack |
| Evidence Workbench | Pending | — | LAB-001…006 |
| Shared persona shell | Pending | — | Stage 6 |
| Investigator application | Mostly pending | Findings/report + chronology + custody partial | Full 20-screen guided workflow |
| Other four personas | Pending / partial | Current shared report capabilities only | Complete per-persona job packs |
| Quality track | Partial | Existing evidence-integrity + fail-closed gate | QUALITY-001…009 |
| Release | Pending | No signed release acceptance | Full release gates (SHIP_DECISIONS §3) |

**Whole-project engineering estimate (HISTORICAL, 2026-08-06): ~50–55%.** After the release-closure macros (B-F) the agent-completable engineering remainder is tracked in RELEASE_EVIDENCE_INDEX.md gate states, not a percentage. This percentage is an *estimate*; the
implementation states and release gates above are *evidence-backed*.

---

## 3. Corrections to the prior status document

The following prior statements are **obsolete** and are corrected here:

- ~~Canonical Claim engine is absent / P6 verification incomplete~~ → Implemented + hosted-CI verified.
- ~~Work-product composers mostly absent (P7 unverified)~~ → four registry composers integration-verified; legacy route removed.
- ~~Source-scoped document reporting absent~~ → implemented (PA-DOC-001), real-data verified.
- ~~Workspace source management absent~~ → implemented (PA-UI-001), GUI witnessed.
- ~~Receipt custody hashing absent~~ → implemented (PA-REC-001), exact source-version hashes.
- ~~Investigation and Fact Memo use a legacy route~~ → both are registry-backed; the legacy production route is deleted (PA-CUT-FINAL).
- ~~Testing BLOCKED: 0 tests in target~~ → 781 tests execute; hosted-CI verified.
- ~~persona-v2 ≈ 5–8% complete~~ → that number described an earlier snapshot before the foundation work; the evidence-to-report pipeline is complete and whole-project is ~50–55%.

---

## 4. CI status (three distinct concepts — do not merge)

**Local:** 781/781 green (this machine, Xcode 26.6, native macOS 26.5 target).

**Hosted:** run **30107577371** · SHA `fbd12435` · macOS 26.4 · Xcode 26.6 · 781 executed ·
0 failed · verifier read from `.xcresult` (`result=Passed total=781 failed=0`, floor 781) ·
`architecture-guards` green. Named checks `build-and-test` + `architecture-guards` exist on HEAD.

**Repository enforcement:** branch ruleset **Pending** (owner repo-settings step).

---

## 5. Known limitations (honest, 2026-08-07)

- Owner-run gates are genuinely pending: five persona acceptance journeys, sanitized-archive
  migration run, owner-hardware scale run (SC1/SC2 — market only the tested figure), clean-machine
  offline install, App Store archive/signing/metadata (AS1-11), branch-ruleset update to require
  `release-build`.
- The deterministic-only experience on a real macOS 15.6-25 Mac (GOV-004) cannot be executed on
  hosted runners (macOS 26 SDK required to build); it is an owner acceptance item.
- The hosted 60-question retrieval eval measures the DETERMINISTIC-LAYER floor of a fresh
  Tier-0/1 ingest (overall 0.339); full-pipeline (Tier-2 enriched) in-app numbers are far higher
  (see release/RELEASE_EVIDENCE_v1.md) and the answer-level eval on target hardware is owner-run.
- Scale-strategy engineering (P9.3 disk-backed/sharded ANN + strategy selector) is NOT implemented;
  v1 ships the in-memory HNSW index only — an explicit owner decision on Gate 8 scope is pending
  (implement vs. supersede with tested-figure-only marketing).
- Audio/video remain recognized-but-deferred; PPT/PST/OST/MSG/NSF/RAR/7z remain honestly
  unsupported (RAR/7z custody-preserved with an explicit unsupported manifest).
- Superseded 2026-08-07 (previously listed here, now closed): SensitiveScope (OPS-003 complete,
  S2 PASS), work-product run persistence (OPS-004 PASS), specialized CI jobs (all separated),
  migration matrix (375-test group), Method Engine + Evidence Workbench + shared shell (complete),
  the macOS 26.5 deployment-target note (GOV-004 floor is 15.6 uniform).

---

## 6. Formal stage state — HISTORICAL (2026-07-26, after OPS-002.2; superseded by "Current status" above)

```
Stage 1 implementation:    complete   (CI-001A/A.1/A.2/B, STATUS-001, MIG-001A/B/B.1/C —
                                       five named hosted checks green on SHA 7f64972,
                                       run 30147726825)
Stage 1 owner acceptance:  pending    (main branch ruleset requiring all five checks;
                                       sanitized owner-archive run via
                                       ci/migrations/verify-real-archive.sh)
Stage 2 engineering:       in progress (OPS-001 Issue Engine complete, run 30148706330;
                                       OPS-002 Task/Deadline Engine complete — final
                                       acceptance closed by OPS-002.2 run 30182173679
                                       (SHA 58e9f36a, schema v70, 845 total / 843 passed /
                                       2 skipped / 0 failed); next OPS-003 SensitiveScope)
```

RECORD OF CORRECTION (retained): the OPS-002 evidence commit (`db59e12`) was pushed before the
reviewer's NO-GO arrived and prematurely recorded OPS-002 as complete. OPS-002.1 (`b84b11f`,
run 30160395578) corrected the four semantic gaps. OPS-002.2 (`58e9f36`, run 30182173679)
corrected two further gaps (evidence-pair binding + confirmation race). OPS-002 acceptance is
now fully closed. History was not rewritten.

Stage 1 is NOT marked PASS/Closed until both owner items are recorded here and in
`RELEASE_EVIDENCE_INDEX.md`. The two items are genuinely owner-only and do not affect Stage 2
design, so the codebase does not idle on them.
