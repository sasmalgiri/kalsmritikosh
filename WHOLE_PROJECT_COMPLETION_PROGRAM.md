# WHOLE_PROJECT_COMPLETION_PROGRAM

**Status: CURRENT.** Created 2026-07-24 (MASTER-001). This is the single whole-project
authority that supersedes the fragmented roadmaps for *scope and sequencing*. It sits directly
under the locked ship contract.

## Authority order (binding)

```
SHIP_DECISIONS.md                       (locked product contract — truth/privacy/scale/personas)
→ WHOLE_PROJECT_COMPLETION_PROGRAM.md   (this file — whole-project scope + stage order)
→ PERSONA_JOB_COVERAGE_MATRIX.csv       (per-job completion ledger)
→ committed code
→ executable tests
→ recorded manual acceptance
```

When this file conflicts with any older roadmap, this file wins. When this file conflicts with
`SHIP_DECISIONS.md`, `SHIP_DECISIONS.md` wins. Nothing here may weaken a `SHIP_DECISIONS.md`
locked decision (Apple FM-or-deterministic, bundled BGE, macOS 26, no release network provider,
tested-scale-only marketing, five personas over one engine, the evidence vocabulary).

---

## 1. Final product definition

Kalsmritikosh is **a private, local, evidence-preserving professional work-assistance platform
that helps five kinds of users complete their real jobs without replacing their judgement.**

Five persona applications over **one** canonical engine:

1. Investigator
2. Researcher / Historian
3. Journalist
4. Individual
5. Lawyer

All five share the SAME canonical: sources & source versions; EvidenceBlocks & locators;
entities & events; Claims & assessments; contradictions & gaps; reviews; custody records;
work-product validation. Personas may change **terminology, workflows, dashboards, tools**.
They may **never** change **truth, evidence status, citation scope, source independence, or
export integrity**.

The persona-v2 **evidence-to-report pipeline is complete** (Claim engine → selection →
composers → assembly → receipts, all four templates registry-backed, rich Event Claim
statements). The remaining program builds the **professional working environment** around that
engine. It is a workflow / analytical-workbench / persona-application / release-validation
program — **not** another evidence-architecture rewrite.

---

## 2. Non-negotiable architecture rules (apply to every task)

1. **Canonical truth remains outside persona objects.** Persona-specific objects (hypotheses,
   legal facts, story claims, historical interpretations) *reference* canonical Claim /
   Event / Entity / Evidence / HistoryItem IDs. They never copy them.
2. **Brainstorming is never evidence.** Ideas, hypotheses, assumptions, suspected causes and
   model suggestions live in a proposal layer. They become canonical Claims / confirmed events /
   established root causes / legal conclusions / publication facts / historical facts ONLY
   through an explicit review action plus qualifying evidence.
3. **Every transformation retains provenance:** `source objects → exact evidence →
   transformation/method → result → review status`. Every calculated field, graph edge, method
   conclusion, filtered dataset and work-product sentence carries this chain.
4. **Scenario work never silently mutates the ledger.** What-if edits, alternative timelines,
   proposed causal links and corrected cells are scenario overlays until explicitly promoted
   through a reviewed action.
5. **Human decisions remain human.** The app may organize, calculate, compare, find gaps,
   propose questions, draft actions, build checklists, prepare reports. It must NOT autonomously
   decide guilt/misconduct, legal liability, privilege, medical diagnosis, publication
   readiness, historical certainty, root-cause confirmation, or CAPA effectiveness.

Automations may create **suggestions, candidate tasks, candidate deadlines, review-queue items,
missing-evidence requests** only. They may never autonomously confirm facts, resolve
contradictions, confirm root causes, close investigations, mark privilege, approve publication,
or finalize historical interpretation.

---

## 3. Dependency-ordered construction program

Stages are gated: a stage is not "done" until its gate passes. Do not start a later stage's UI
before its foundation gate is green.

### Stage 1 — Production & verification foundation
- **CI-001** — mandatory GitHub workflows: macOS build; full unit suite; migration tests;
  architecture guards; parser fixtures; report/receipt identity; sensitive-export tests. Red ⇒
  merge prohibited.
- **STATUS-001** — regenerate `PRODUCTION_STATUS.md` from current code (the 2026-07-22 doc
  predates the Claim/workspace/receipt/composer work).
- **MIG-001** — migration matrix: fresh DB; representative older schema versions; interrupted
  migration; repeated launch; low-disk failure; rollback; reopen an existing real archive.
- **Gate:** GitHub reports an actual green check; fresh + upgraded DBs pass; the 781-test
  baseline stays green or increases.

### Stage 2 — Shared professional object substrate (before persona dashboards)
- **OPS-001** Issue engine (`Issue`, `IssueType`, `IssueStatus`, `IssueLink`, `IssueReview`,
  `IssueRepository`) — links Claims/events/entities/evidence/gaps/contradictions/work-products/
  runs.
- **OPS-002** Task & deadline engine (`ProfessionalTask`, `TaskDependency`, `Deadline`,
  `DeadlineCandidate`, `TaskEvidenceLink`, `TaskRepository`, `DeadlineRepository`) —
  `candidate deadline ≠ confirmed deadline`.
- **OPS-003** `SensitiveScope` — ONE shared policy controlling screen / retrieval / prompt /
  report / receipt / export visibility. No per-persona privacy forks.
- **OPS-004** Work-product run persistence (`WorkProductRun`, `WorkProductSectionRun`,
  `WorkProductClaimOccurrence`, `WorkProductManifest`, `WorkProductValidationRecord`) — reopen,
  compare, prove, regenerate deterministically.
- **OPS-005** Explicit email participant roles (`sender`/`to`/`cc`/`bcc`/`reply-to`) so
  directional phrasing is enabled only when the role is explicitly persisted (PA-EXT refused to
  infer from array order — this closes that follow-up).
- **Gate:** tests prove persona objects don't duplicate Claims; deleting workflow state never
  deletes evidence; deadlines stay candidate until confirmed; SensitiveScope blocks screen,
  prompt AND export consistently; prior work-product runs reopen identically; email direction is
  never inferred from order.

### Stage 3 — Persona Job Engine (reusable, not hard-coded per screen)
Definition types (`PersonaApplicationDefinition`, `PersonaToolDefinition`,
`PersonaWorkflowDefinition`, `…StepDefinition`, `…Requirement`, `…Validation`,
`…ArtifactDefinition`) + run types (`WorkflowRun`, `WorkflowStepRun`, `WorkflowDecision`,
`WorkflowArtifact`, `WorkflowCheckpoint`, `WorkflowAttentionItem`) + registries (application /
tool / workflow / object-schema / work-product / validator / terminology / automation).
Shared step classes: intake, scope, select-evidence, review-evidence, brainstorm, form, table,
matrix, timeline, graph, calculation, method, decision, human-approval, work-product-build,
effectiveness-review, closure. Every workflow supports start/pause/resume/branch/return/
incomplete-requirements/review-gates/attachments/generated-products/audit/cancel/supersede/
deterministic-reconstruction-after-relaunch.
- **Gate:** one synthetic workflow proves `start → save → close app → resume → complete method
  → human decision → produce cited work product → reopen exact run`. No persona dashboard before
  this passes.

### Stage 4 — Professional Method Engine
Persistent, evidence-linked working objects (NOT LLM prompts): `ProfessionalMethodDefinition`,
`MethodRun`, `MethodNode`, `MethodEdge`, `MethodEvidenceLink`, `MethodAssumption`,
`MethodFinding`, `MethodReview`, `MethodValidationResult`. First pack (powers the Investigator
slice): Brainstorming, 5W1H, Hypothesis Matrix, Evidence Collection Plan, Five Whys,
Fishbone/Ishikawa, Root-Cause Assessment, CAPA, Effectiveness Review, Contradiction Matrix, Gap
Analysis, Timeline Analysis, Relationship Analysis, Transaction Flow, Risk Matrix, Decision
Matrix. See `PROFESSIONAL_METHOD_CATALOG.csv`. Truth rules: brainstorming items are typed and
only `known Claim` points to canonical; Five Whys nodes carry status/evidence/assumptions/review
and must stop early when evidence runs out; Fishbone bones are candidate causes; a Root Cause is
confirmed ONLY by a recorded human decision; CAPA actions link to the cause they address.
- **Gate:** each method persists+reopens; retains exact evidence; preserves unsupported/inferred
  labels; exports without upgrading proposals to facts; supports undo + review history.

### Stage 5 — Evidence Workbench / DataLab
See `EVIDENCE_WORKBENCH_CONTRACT.md`. Port the *interaction patterns* of Datasimplify (layered
data, editable cells, safe parsed formulas, what-if scenarios, notebook, data-quality warnings,
multi-view, simple/advanced modes) — NOT its data/provider design (Kalsmritikosh is fully local,
no-network per `SHIP_DECISIONS.md`). LAB-001 dataset model; LAB-002 safe transformation engine
(parsed expression language, no `eval`); LAB-003 scenario + undo (canonical evidence read-only);
LAB-004 shared visual surfaces; LAB-005 data-quality warnings; LAB-006 simple/advanced modes
(one truth ledger, not a separate truth mode).
- **Gate:** select workspace Claims → build dataset → filter+calculate → chart/matrix →
  hypothesis note → scenario → undo → inspect exact evidence → save view → export with
  transformation manifest.

### Stage 6 — Shared persona application shell
`WorkspaceContext`, `PersonaWorkspaceShell`, `PersonaDashboard`, `PersonaToolNavigation`,
`EvidenceInspector`, `ContextualActionBar`, `WorkflowProgressPanel`, `AttentionQueue`,
`PersonaCommandPalette`, `PersonaHome`, `NewWorkspaceWizard`. Four-region shell (context/scope
bar · tool/workflow nav · primary surface · evidence/provenance inspector). The Universal
Evidence Inspector shows Claim text, evidence status, supporting/opposing evidence, source
version, exact locator, extraction path, confidence, review history, linked issues/tasks/methods,
dependent reports, source-opening action. The contextual action bar never silently widens
workspace scope.

### Vertical slice — Investigator FIRST (highest reusable coverage)
Sequencing change from the older "Individual first" plan is recorded here and in the matrix.
Investigator object extensions (`InvestigationCase`, `InvestigationSubject`, `Identifier`,
`IdentityResolutionDecision`, `Lead`, `Hypothesis`, `HypothesisEvidenceLink`, `EvidenceRequest`,
`SourceReliabilityAssessment`, `RootCauseCandidate`, `CAPAAction`, `EffectivenessCheck`,
`ClosureDecision`) store workflow state + canonical references only. 20 screens, one guided
workflow, ~19 work products, ≥5 gold cases (process deviation; payment discrepancy; project
delay; identity ambiguity; conflicting accounts). **Do not begin the second persona until the
entire Investigator slice is manually usable.**

### Remaining persona order (after Investigator template accepted)
Researcher/Historian → Journalist → Individual → **Lawyer last** (strictest validation; needs
mature SensitiveScope/redaction). Job lists in `PERSONA_JOB_COVERAGE_MATRIX.csv`.

### Parallel evidence-quality track (may run alongside Stage 3+ with schema coordination)
QUALITY-001 canonical assertion production · QUALITY-002 production source independence ·
QUALITY-003 Claim contradiction production · QUALITY-004 missing-evidence taxonomy ·
QUALITY-005 full Claim verifier · QUALITY-006 historical reconstruction depth ·
QUALITY-007 structured tables · QUALITY-008 durable ingestion · QUALITY-009 retrieval
evaluation (≥60 general gold + 5 gold cases/persona + lookup/aggregation/multihop/contradiction/
missing-evidence/table/privilege-leak tests).

### Release program
Gates per `SHIP_DECISIONS.md` §3 + `RELEASE_EVIDENCE_INDEX.md`: functional, truth, security,
scale (market only the tested corpus), owner acceptance (per persona), App Store.

---

## 4. Execution discipline

- **One logical green commit.** Never combine schema foundation + workflow engine + DataLab UI +
  persona screen + release cleanup in one commit.
- **No broad parallel edits** across branches to: `AppState.swift`, `SchemaMigrations.swift`,
  `IngestCoordinator.swift`, `WorkProductAssemblyService.swift`, `WorkspaceRepository.swift`,
  `project.pbxproj`.
- **Required report after every unit:** what changed · why required · files changed · schema
  changed · migration verification · tests added · full-suite result · manual render requirement ·
  known limitations · next unblocked task.
- **No fake completion.** A job is complete only when workflow + evidence links + persistence +
  validation + output + acceptance case all work.

### Task-state vocabulary
| State | Meaning |
|---|---|
| Implemented | Code builds |
| Unit verified | Focused tests pass |
| Integration verified | Full connected workflow passes |
| Real-data verified | Owner corpus used |
| Release verified | Signed production build passes |
| Done | All required gates completed |

---

## 5. Document supersession register (MASTER-001)

| Document | New status | Note |
|---|---|---|
| `SHIP_DECISIONS.md` | **CURRENT** | Locked product contract; top authority. |
| Production Readiness Instruction Pack (`01_MASTER_PRODUCTION_DIRECTIVE`, `03_LOCKED_PRODUCT_CONTRACT_AND_MOAT`) | **CURRENT** (evidence-engine contract) | Whole-project *scope* now extended by this program. |
| `WHOLE_PROJECT_COMPLETION_PROGRAM.md` | **CURRENT** | This file. |
| `PERSONA_JOB_COVERAGE_MATRIX.csv` | **CURRENT** | Per-job ledger. |
| `PROFESSIONAL_METHOD_CATALOG.csv` | **CURRENT** | Method engine scope. |
| `EVIDENCE_WORKBENCH_CONTRACT.md` | **CURRENT** | DataLab scope + safety. |
| `RELEASE_EVIDENCE_INDEX.md` | **CURRENT** | Release-gate evidence index. |
| `HISTORY_PRODUCT_CONTRACT.md` | **CURRENT** | Five-lens/history truth contract; referenced. |
| `PRODUCTION_STATUS.md` | **PARTIALLY SUPERSEDED** | Predates latest work; regenerate via STATUS-001. |
| `PRODUCTION_COMPLETION_LEDGER.md` | **PARTIALLY SUPERSEDED** | Folds into matrix + regenerated status. |
| `BUILD_PLAN_PERSONA_V2.md` | **PARTIALLY SUPERSEDED** | Export pipeline done; persona apps now under this program. |
| `PERSONA_V2_IMPLEMENTATION_STATUS.md` | **PARTIALLY SUPERSEDED** | Superseded by the matrix Status column. |
| `docs/PERSONA_JOBS_AND_CONTRIBUTIONS.md`, `docs/PERSONA_GAPS.md` | **HISTORICAL** (reference) | Planning research that fed the matrix. |
| `TASKS.md`, `PROJECT_TODOS.md`, `REMAINING_WORK.md`, `PROJECT_COMPLETION_INSTRUCTIONS.md`, `COMPLETION_STATUS.md`, `GATE2_ROADMAP.md`, `G3_PERIODIC_TABLE_ROADMAP.md` | **HISTORICAL** | Reference only; not a build gate. |

---

## 6. Milestone position (engineering estimate)

| Milestone | Whole-project completion |
|---|---:|
| Current state (evidence + export engine complete) | **50–55%** |
| Shared job/method/workbench foundation complete | **65–70%** |
| Investigator fully usable | **72–77%** |
| All five persona job packs complete | **88–92%** |
| Quality, scale, security & release gates complete | **100%** |

The evidence and export engine is the hard foundation and is done. What remains is professional
workflow, analytical workbench, persona applications, and release validation.

---

## 7. Immediate execution path

```
MASTER-001  (this reset — DONE on commit)
→ Stage 1: CI-001 · STATUS-001 · MIG-001
→ Stage 2: OPS-001..005
→ Stage 3: Persona Job Engine
→ Stage 4: Professional Method Engine
→ Stage 5: Evidence Workbench core
→ Stage 6: Shared persona shell
→ Investigator complete vertical slice
→ remaining four persona job packs
→ quality/evaluation closure
→ release gates
```
