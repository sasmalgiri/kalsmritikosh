# PRODUCTION_STATUS

```
Audit date:            2026-10-26 (Implementation Brief execution — ~/Downloads/Investigations_Made_Easy_Complete_Implementation_Brief.md)
Current branch:        investigations-next (PR #169 open; unpushed commits after 3bef103c — see git log)
Latest schema version: 157
Verification state:    every item below is UNIT VERIFIED at most (its suites pass locally on the stated
                       commit). Nothing here is integration-verified in the GUI, runtime-witnessed by the
                       owner, or release-verified. Exact-commit CI has not run on these commits yet.
```

## Implementation brief — execution record (2026-10-26)

Status vocabulary from brief §2: implemented · statically reviewed · unit verified · integration verified ·
runtime witnessed · release verified.

| Brief | What changed | Commit | Evidence | Status |
|---|---|---|---|---|
| §3 | Every case-file mutation checks the child record belongs to the case; a closed case takes no new work; an attestation of a statement changed in between is refused | 3e96919a | CaseOwnershipTests | unit verified |
| §5 | case_actions append-only (v153) and in the audit chain; case events, findings approvals, hypothesis decisions sealed too (v157); **bug fixed**: audit_chain's CHECK refused every source but three, so from v153 any case action made every seal() fail — never reached main | a1da4bc9, 6c6970dc | CaseActionSealTests (seals + verifies, deletion detected), AuditChainTests, MigrationMatrixTests | unit verified |
| §5/§6 | Exports logged only when the file is written (with its SHA-256); a failed custody read is never an empty custody record — custody report refused, others marked INCOMPLETE/DRAFT | c1160374 | build + code review; no GUI run | implemented |
| §7 | Contradictions and gaps: scope before limit (keyset paging) | dfd41a8f | InvestigationReviewDeskServiceTests.scopeBeforeLimit | unit verified |
| §7 | Email counts read every message found; a capped lookup says "at least N" | 3a2f9008 | EmailHeaderAnswererTests | unit verified |
| §4 | Case evidence references are typed (in-scope source version · case exhibit · labelled investigator note); free text refused at attach; unresolved stored references listed in "References to repair" | b74e779c | CaseOwnershipTests.referencesResolve, CaseFileTests | unit verified (UI list not GUI-run) |
| §6 | One FindingsDecisionPolicy (named standard, or justified not-applicable); swapped-case, stale-scope and tampered-receipt findings refused on both approval paths | e5f93bdb | InvestigationFindingsServiceTests.approvalPolicyAndCurrency, WorkProductHandoffModelTests | unit verified |
| §8 | Hypothesis confirmation needs rationale + contrary evidence + alternatives (no count majority); lineages = distinct sources; reliability/relevance per link (v154) | 1b487a00 | InvestigationAnalysisServiceTests | unit verified (no UI for assessments yet) |
| §9 | Confirmed statement's provenance locked; corrections are append-only addenda, confirmed once, exported with the statement (v156) | 68129b50 | StatementCorrectionTests | unit verified |
| §11 | Schema conformance marked per ledger (version + schema SHA-256), incomplete repair recorded (v155) | 6eec984f | SchemaRepairTests | unit verified |
| §17 | Scorer: negated mentions are not answers; snippets not credited. Enron count truth: any To recipient, one email per subject+date (31 rows corrected) | 9553e814, a3566d85 | re-scored sets below | implemented |
| §1 | Onboarding subtitle "From evidence to findings" (was "knowledge operating system") | this commit | — | implemented |

### Measured (repaired scorer, Fully private unless stated; "right" includes proper refusals)

| Set | Build | n | Right | Wrong |
|---|---|---|---|---|
| Chronology, fresh draw (never tuned on) | 9b1914bb | 751 | 87.9 % | 7.2 % |
| NTSB conclusion withheld, fresh | 9b1914bb | 360 | 98.3 % | 1.1 % |
| Enron, fresh (corrected count truth) | 9b1914bb | 540 | 95.7 % | 1.7 % |
| NTSB, Claude-reworded, rules only / rules→Claude | 18:44 build ≈ 9553e814 | 720 | 88.8 % / 96.7 % | 6.8 % / 1.9 % |
| Chronology, Claude-reworded, rules only / rules→Claude | same | 1,502 | 49.4 % / 79.3 % | 25.9 % / 11.1 % |
| Enron, Claude-reworded, rules→Claude (corrected truth) | 36afa942 | 1,080 | 85.8 % | 9.4 % |

Reworded chronology is the weakest category; its two biggest failure shapes (noun-form sentencing dates,
"count of press releases about X") were fixed in 66da52c9/26dea109 and are being re-measured (v3 runs).
Against the brief's proposed thresholds (≥ 90 % answerable correctness, ≥ 99 % precision among answered
factual questions) **no category is yet shown to meet the precision bar**; claims must stay restricted.

### Not done in this pass (brief items still open)

- §4 click-through to the cited location for PDF/email/DOCX/spreadsheet/transcript; revalidation at review/approval/reopen.
- §6 one authorised export request object feeding every export path; one lifecycle service across stage/findings/closure.
- §10 per-source/per-child ingestion dispositions; real PST/OST/MSG/NSF fixtures.
- §11 complete case/archive backup (originals, source maps, work products, checkpoints) with staged restore.
- §12 signed-release privacy tests; online payload preview/consent review.
- §13 measured memory/disk envelope at the declared supported volume.
- §14 Cases as default home with next action; usability sessions (owner).
- §17 structured gold tuples, independent human adjudication, per-mode reporting with confidence intervals.
- §18 StoreKit/TestFlight flows, signed-binary checks, exact-commit CI, beta, legal/name review (owner).

## Earlier status (2026-10-23)

```
Audit date:            2026-10-23 (Investigations Made Easy — main-app program)
Current branch:        investigation-docs (from main af956108, PR #165 merged; NOT yet pushed)
Latest schema version: 152 (SchemaMigrations.latestVersion; v151 case file, v152 ACH in the ledger)
Product name:          Investigations Made Easy (display); bundle ids / schemes / kalsmritikosh:// unchanged
Languages:             English only for v1 (owner 2026-10-23)
Whole-suite floor:     ci/test-baseline.json is the LIVE authority (hosted count; see memory ci-hosted-test-floor)
Verification state:    everything on investigation-docs COMPILES (app + all test targets, build-for-testing
                       green 2026-10-23); the test phase (T-1…T-4 in docs/INVESTIGATIONS_MADE_EASY_TODO.md)
                       has NOT run yet — owner rule "implement all, then test". Nothing here is release-verified.
```

## Current status (2026-10-23)

- **Governing todo:** `docs/INVESTIGATIONS_MADE_EASY_TODO.md` (phases T N C E P A Q S U R). Built and committed on
  `investigation-docs`: N-1 rename; C-1…C-12 case file (v151) + Cases screen; E-1…E-6 exhibits, custody report,
  hold notices, redaction log, review batches with QC, Teams + Cellebrite UFDR import; P-1…P-3 people, contact log,
  interviews to confirmed statements, credibility factors; A-6…A-9 hypotheses in the ledger (v152), manual
  chronology, amount-weighted money tracing, pair timelines; S-1/S-2/S-3/S-4/S-5 retention review (never a purge),
  personal-data export, investigator profile, case action log, encryption wording; U-1 scaling text + labels,
  U-3 walkthroughs, U-4 on-device diagnostics, U-5 move-to-new-Mac guide, U-6 viewer privacy manifest.
- **Schema self-heal fix (2026-10-23):** the stale-counter check stopped tracking new migrations after v118, so an
  upgrade could skip the newest migration. The check now derives its sentinel from the newest migration and a
  repair pass re-runs create-if-missing migrations from v119. Owner ledgers upgraded before this may lack objects
  from the non-idempotent v119–v141 migrations — to be checked in the test phase.
- **Open:** the whole test phase; answer-quality work Q-2…Q-5 (civil court, press-release office, lead details,
  scale runs); owner steps (name in App Store Connect, HOLD 1 walk-through, clean-machine install, lawyer review,
  archive/sign/submit). SHIP_DECISIONS §3 gates are all still unchecked.

> The 2026-08-07 snapshot below is historical and kept as-is.

## Snapshot 2026-08-07 (historical)

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
