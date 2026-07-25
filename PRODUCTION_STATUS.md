# PRODUCTION_STATUS

```
Audit date:            2026-07-24 (STATUS-001)
Current audited HEAD:  41ca36114fa4327dbe136f14a79731be37549908
Latest schema version: 67  (SchemaMigrations.latestVersion; highest migration v67)
Local full-suite:      781/781 green (this machine, Xcode 26.6)
Verified hosted run:   30107577371
Hosted tested SHA:     fbd124358f5cf01583800b91a4a6ac1486e0eb1a
Hosted result:         Passed — 781 executed, 781 passed, 0 failed
Architecture guards:   Passed (ci/guards/run-all.sh on ubuntu-latest)
Branch ruleset:        Pending owner configuration
```

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

## 2. Whole-project status (master stages)

| Program area | Status | Verification | Remaining work |
|---|---|---|---|
| Evidence and Claim engine | Near complete | Tests + hosted CI + real fixtures | Quality-depth items (QUALITY-001…009) |
| Work-product / export engine | Complete for the four templates | Tests + GUI witness | Work-product run persistence (OPS-004) |
| Stage 1 production verification | In progress | CI-001A green (run 30107577371) | STATUS (this), migrations, specialized CI jobs, branch ruleset |
| Shared professional objects | Pending | — | OPS-001…006 |
| Persona Job Engine | Pending | — | Stage 3 |
| Professional Method Engine | Pending | — | 16-method first pack |
| Evidence Workbench | Pending | — | LAB-001…006 |
| Shared persona shell | Pending | — | Stage 6 |
| Investigator application | Mostly pending | Findings/report + chronology + custody partial | Full 20-screen guided workflow |
| Other four personas | Pending / partial | Current shared report capabilities only | Complete per-persona job packs |
| Quality track | Partial | Existing evidence-integrity + fail-closed gate | QUALITY-001…009 |
| Release | Pending | No signed release acceptance | Full release gates (SHIP_DECISIONS §3) |

**Whole-project engineering estimate: ~50–55% complete.** This percentage is an *estimate*; the
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

## 5. Known limitations (honest)

- Hosted tests execute with a documented **macOS 26.4 compatibility deployment target** (the
  runner's OS), not proof of the pinned macOS **26.5** point release; the locked floor is macOS 26.
- Specialized CI jobs (migration-matrix, parser-fixtures, report-receipt-integrity) are **not yet
  separated** (CI-001B).
- Branch ruleset is **not configured**.
- Migration matrix is **incomplete** (MIG-001A/B).
- `SensitiveScope` is **not implemented** (OPS-003).
- Work-product runs are **not persisted** (OPS-004).
- Explicit email participant roles are **not persisted** (OPS-005; directional "X emailed Y"
  phrasing intentionally withheld until then).
- Persona Job Engine, Professional Method Engine and Evidence Workbench are **not implemented**.
- Complete five-persona professional workflows are **not implemented**.
- Scale and release claims remain **unverified** (market only the tested corpus per SHIP_DECISIONS).
- `actions/checkout@v4` runs on Node 24 (GitHub deprecation notice only — not a failure).

---

## 6. Next tasks (Stage 1 close, then Stage 2)

```
MIG-001A  migration inventory + fixtures + MigrationMatrixTests
→ MIG-001B interruption / rollback / real-archive proof
→ CI-001B  specialized named jobs (migration-matrix, parser-fixtures, report-receipt-integrity)
→ close Stage 1 (all named checks green + fresh/upgraded/real-archive DBs pass + ruleset recorded)
→ OPS-001 Issue engine
```
