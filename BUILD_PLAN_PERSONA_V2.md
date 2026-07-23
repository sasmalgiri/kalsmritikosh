# Build Plan — Persona-v2 Full Implementation (all 366 tasks)

**Created:** 2026-07-23. **Source of truth:** `kalsmritikosh_persona_v2/` +
`PERSONA_V2_IMPLEMENTATION_STATUS.md`. **Mode:** blind-build permitted; owner validates each
stage after it lands. This plan sequences every backlog task into buildable stages with concrete
deliverables, files, schema migrations, and a verification bar per stage.

## How to read this
- Stages are **dependency-ordered**. Do not start a stage before its predecessors are green.
- Each stage lists: **Goal · Tasks covered · New types/files · Schema · Verify · Gate type.**
- **Gate type** = `HEADLESS` (compile + unit-test verifiable by me) or `RENDER` (needs the app
  to run — you test; I build compile-verified and flag render-unverified).
- **Commit granularity:** one logical unit per commit (per the repo rule), `feat(persona): …`.
- **Invariants that never bend** (from CLAUDE.md): capability discipline (no model names in
  Knowledge/Brain/Retrieval/Ingestion), one SQLite ledger behind `actor Database`, migrations
  append-only + SAVEPOINT + sentinel bump + verify-on-throwaway, one shared `EvidenceStatus`
  (extend, never fork), no network outside Routing/Providers, preserve-not-delete, deterministic
  before LLM prose, every material claim carries exact evidence.

## Task accounting (366 total)
| Group | Tasks | Stage |
|---|---:|---|
| PA-001 governance | 1 | S0 |
| Shared object engines (PA-009/010/011/012/013 + §10 tables) | 5 + schema | S1 |
| History kernel completion (HIS-004) + enrichment (ENR-001) | 2 | S1 |
| Work-product engine (WP-001…007) | 7 | S2 |
| Persona app architecture (PA-002/003/004/008 + registries) | 4 | S3 |
| Shared UX shell (PA-005/006/007/014/015 + Home/wizard) | 5 | S4 |
| Individual persona (IND-*) | 68 | S5 |
| Researcher/Historian persona (RES-*) | 70 | S6 |
| Journalist persona (JOU-*) | 61 | S7 |
| Investigator persona (INV-*) | 65 | S8 |
| Lawyer persona (LAW-*) | 64 | S9 |
| Innovations (INN-001…006) | 6 | S10 |
| Release gates (REL-001…005) | 5 | S11 |

Already done (carried in from the Universal History program): HIS-001/002/003, INN-002/003, and
`HistoryChronologyComposer` (first composer). These are reused, not rebuilt.

---

# STAGE 0 — Governance & the EvidenceStatus decision  ·  Gate: HEADLESS
**Goal.** Lock the five-persona contract and resolve the one blocking data decision before code.

- **PA-001.** Write `FIVE_PERSONA_PRODUCT_CONTRACT.md` (repo root): persona invariance (§4.2 — all
  five point at the same `Claim.ID`/`HistoryItem.ID`), the shared object list (§4.1), prohibited
  shortcuts (§17), per-persona guardrails (each spec §10), release gates (each spec §17). Add to
  the CLAUDE.md authority chain.
- **EvidenceStatus reconciliation (blocking).** The pack (§4.3) names cases our enum lacks:
  `corroborated, disputed, modelProposed, userConfirmed, missing, rejected`. Our enum has
  `directlyObserved, sourceAsserted, deterministicallyDerived, inferred, contradicted, unsupported,
  missingEvidence, humanConfirmed, humanCorrected, humanRejected`. **Plan:** extend the ONE enum
  additively — add `corroborated`, `disputed`, `modelProposed`; map `userConfirmed→humanConfirmed`,
  `missing→missingEvidence`, `rejected→humanRejected` (aliases in a mapping helper, not new cases).
  Update `isAssertable` (corroborated ⇒ assertable; disputed/modelProposed ⇒ not). One migration is
  NOT needed (stored as string; new cases are forward-only). **Flagged for your sign-off**, but the
  plan proceeds additively so nothing forks.

**Verify.** Doc committed; `EvidenceStatus` still single-definition; grep guard clean; full suite green.

---

# STAGE 1 — Shared object engines + schema  ·  Gate: HEADLESS
**Goal.** Build the canonical objects every persona binds to. This is the true foundation; ~90% of
the persona work is impossible or fake without it. All headless + unit-testable.

**Tasks:** PA-009 (Issue), PA-010 (Claim), PA-011 (Task/deadline), PA-012 (SensitiveScope),
PA-013 (persona-object review audit), HIS-004 (atomic HistoryClaimVerifier), ENR-001 (handlers).

**1a. Claim engine (PA-010) — §7.2.**
- `Core/Models/Claim.swift`: atomic subject–predicate–object + `EvidenceStatus` + confidence +
  corpus snapshot. `ClaimEvidence`, `ClaimContradiction`, `ClaimReview`, `ClaimUsage` models.
- Repos in `Storage/Repositories/`: `ClaimRepository`, `ClaimEvidenceRepository`,
  `ClaimContradictionRepository`, `ClaimReviewRepository`, `ClaimUsageRepository` (raw sqlite3
  C-API style, matching existing repos).
- **Schema migration vNN:** `claims, claim_evidence, claim_contradictions, claim_reviews,
  claim_usage` + indexes. Sentinel → `claim_usage`.
- Reuse: claims reference existing `Entity`, `EvidenceBlock`, `SourceLocator`. A claim can be
  *used by* legal facts / findings / journalism claims / interpretations / personal summaries
  (usage rows), never copied.

**1b. Issue engine (PA-009).**
- `Core/Models/Issue.swift` + `IssueLink` (polymorphic link to claim/history/evidence/workproduct).
- `IssueRepository`. **Migration:** `issues, issue_links`. Sentinel bump.

**1c. Task/deadline engine (PA-011) — §7.3.**
- `Core/Models/Task.swift`, `Deadline.swift` (candidate vs confirmed flag, evidence link,
  dependencies, automation source). `TaskRepository`, `DeadlineRepository`.
- **Migration:** `tasks, task_links, deadlines, deadline_evidence`. Sentinel bump.

**1d. SensitiveScope (PA-012).**
- `Core/Security/SensitiveScope.swift`: which subjects/sources/fields/categories may display /
  export / go to a model. Wire into a single decision point reused by retrieval + export + prompt
  assembly. Reuse existing `PIIRedactor`, `RedactionVerifier`, `SensitivityInheritance`,
  `EvidenceVault`. **Migration:** `sensitive_scopes, access_decisions`. Sentinel bump.

**1e. Persona-object extension substrate (PA-013 + §10).**
- `Core/Models/PersonaObjectExtension.swift` + `persona_object_extensions` table keyed to canonical
  IDs (the mechanism all persona objects use — never duplicate source facts). Review decisions on
  persona objects route through existing audit (`FactReview`/audit repo).

**1f. Atomic HistoryClaimVerifier (HIS-004).**
- `Knowledge/History/HistoryClaimVerifier.swift`: for each `HistoryItem`/material sentence, assert
  full entailment by its evidence set; drop/flag unentailed. Distinct from
  `NarrativeClaimVerifier` (prose). Reuse `ClaimGrounding`, `EvidenceVerifier`.

**1g. Enrichment handlers (ENR-001) — §13.3.**
- Add `EnrichmentJobKind` cases: `temporalClaims, identityCandidates, personaIndexes,
  historyProjection, workProductCache, transcriptionQuality, tableExtraction`. Register handlers on
  `EnrichmentDrainer`. Interactive queries pre-empt (reuse `QueryPriorityGate`). **Migration** only
  if new columns needed; else code-only.

**Verify.** New unit tests per engine (round-trip persistence, claim-usage integrity, deadline
candidate/confirmed, sensitive-scope block, HistoryClaimVerifier entailment, handler drain). Full
suite green. Migrations verified on a throwaway DB. Grep guard clean.

---

# STAGE 2 — Universal work-product engine  ·  Gate: HEADLESS
**Goal.** Real section composers replace the `GenericFact → field:value` mapping. Everything a
persona *outputs* flows through here.

**Tasks:** WP-001…007.
- **WP-001.** Expand `BlueprintSection.Kind` from 10 → the full 34 (executiveSummary, claimMatrix,
  factEvidenceTable, peopleProfiles, issueAnalysis, sourceMatrix, contradictionSchedule, gapRegister,
  relationshipGraph, transactionSchedule, locationChronology, communicationSchedule, quoteBook,
  transcriptExtracts, rightOfReply, screeningLog, extractionTable, sourceCriticism,
  interpretationComparison, exhibitList, redactionLog, privilegeCandidateLog, deadlineRegister,
  taskRegister, methodology, limitations, custodyLog, publicationAppendix, emergencyChecklist,
  documentIndex, custom, + existing). Keep existing raw values stable.
- **WP-002.** `WorkProductSectionComposer` protocol (`supportedKinds`, `compose(section:context:)
  async throws -> ComposedSection`) + `ComposedSection`. Conform existing `HistoryChronologyComposer`.
- **WP-004.** `WorkProductContext` (snapshot, workspace, scope, claims/history/tasks, sensitivity).
- **WP-002 composers (16).** `ChronologySectionComposer` (done), `ClaimMatrixSectionComposer`,
  `FactEvidenceSectionComposer`, `PeopleProfileSectionComposer`, `RelationshipSectionComposer`,
  `TransactionSectionComposer`, `QuoteSectionComposer`, `TranscriptSectionComposer`,
  `SourceCriticismSectionComposer`, `ScreeningSectionComposer`, `BibliographySectionComposer`,
  `ExhibitSectionComposer`, `RedactionSectionComposer`, `DeadlineSectionComposer`,
  `CustodySectionComposer`, `HistoryNarrativeSectionComposer`. Each deterministic, evidence-cited,
  in `Knowledge/WorkProduct/Composers/`.
- **WP-003.** `PersonaSectionComposerRegistry` — resolve composer by kind + persona policy.
- **WP-005.** Expand `WorkProductValidator` to the full §7.5 checklist: exact-source-reopen, claim
  evidence count, required human review, contradictions, unresolved identity, source independence,
  date precision, sensitive scope, redaction, prohibited-persona-claims, snapshot+engine version.
- **WP-006.** Persist runs/sections: **migration** `work_product_runs, work_product_sections,
  work_product_claims` + `WorkProductRunRepository` (reopen + compare by version). Sentinel bump.
- **WP-007.** `WorkProductManifest` — every output carries source list + engine/policy versions.

**Verify.** Composer unit tests (each kind → cited ComposedSection; unrelated kinds NOT routed to a
generic mapping); validator rejects unbacked/over-scope/unredacted; run persistence round-trips and
versions. Full suite green.

---

# STAGE 3 — Persona application architecture  ·  Gate: HEADLESS
**Goal.** The registry + routing + context layer that turns "persona = shortcuts" into "persona =
application." Pure data/types — headless.

**Tasks:** PA-002/003/004/008 + the 9 registries (§5.2).
- `Core/Personas/PersonaToolID.swift`: `PersonaToolID`, `PersonaToolGroup`, `PersonaCapability`,
  `PersonaToolDefinition`, `SavedViewDefinition`.
- `PersonaApplicationDefinition`, `PersonaDashboardDefinition`, `PersonaWorkflowDefinition`,
  `PersonaWorkflowID`, `QuestionTemplate`.
- **Registries (versioned):** `PersonaApplicationRegistry`, `PersonaToolRegistry`,
  `PersonaWorkflowRegistry`, `PersonaObjectSchemaRegistry`, `PersonaWorkProductRegistry`,
  `PersonaSectionComposerRegistry` (from S2), `PersonaValidatorRegistry`,
  `PersonaTerminologyRegistry` (fold in existing `PersonaTemplateCatalog`), `PersonaAutomationRegistry`.
- **PA-004.** `WorkspaceContext` (§5.3) — workspaceID, persona, corpusSnapshotID, selectedSubjectIDs,
  selectedIssueIDs, dateRange, sensitiveScope, reviewProfile. Threaded to every tool.
- **PA-008.** Expand `PersonaWorkAction` (§9.3): `openGlobal / openTool / startWorkflow /
  createWorkspace / buildWorkProduct / ask(QuestionTemplate)`. `PersonaWorkflowState` (resumable,
  remembers progress).
- **PersonaAutomationDefinition** (§12) scaffold: trigger/conditions/proposedActions/
  requiresConfirmation/sensitivity — engine that routes outputs to a review queue (no autonomous
  truth change; disallowed-outcome list enforced).

**Verify.** Registry-load tests (five app definitions load without root-view switches — PA-002 AC);
tool route resolves by ID and preserves context; workflow-aware action enum exhaustive. Full suite green.

---

# STAGE 4 — Shared UX shell  ·  Gate: RENDER (compile-verified by me, run-tested by you)
**Goal.** The four-region shell + inspector + object-actions + Home/wizard that all personas render into.

**Tasks:** PA-005/006/007/014/015 + §9 Home + §9.2 wizard + §13 `WorkspaceToolState`.
- **PA-005.** `UI/Personas/PersonaWorkspaceShell.swift` — context bar / tool nav / main surface /
  evidence inspector / selection-action bar (§6.1). Main surface supports timeline·table·graph·
  board·editor·viewer·form·map·dataset·checklist container kinds.
- **PA-006.** Simple/advanced navigation toggle (§6.4).
- **PA-007.** Upgrade the existing `CommandPaletteView` to be workspace-scoped and resolve
  tools/subjects/workflows/outputs.
- **PA-014.** `UI/Personas/EvidenceInspector.swift` — status, exact supporting + opposing evidence,
  source version, locator, extraction path, confidence, review history, dependent work products.
  Universal (reused on every screen).
- **PA-015.** Contextual object-action bar (§6.2): source selection → create fact/event/quote/claim/
  lead / add-to-chronology / add-to-work-product / flag-contradiction / request-corroboration /
  create-task, filtered by persona + object type.
- **§9 Home rewrite** (continue workspace, create, histories-ready, work-needing-review,
  new-evidence, persona job cards) + **§9.2 new-workspace wizard** (8 steps).
- **`WorkspaceToolState`** enum + empty/loading/partial/ready/validating/failed handling; every
  screen's contract (§5 of each persona spec): receives context, enforces scope, drill-through,
  persists layout, shows snapshot/freshness, undo, a11y, never widens scope silently.

**Verify.** Builds green; `XcodeRefreshCodeIssuesInFile` clean. **Owner runs**: shell renders, tabs
switch, inspector opens evidence in one action, wizard creates a workspace. Flagged render-unverified.

---

# STAGES 5–9 — The five persona applications
Each persona is one stage, built in the spec's dependency order (§14: Individual → Historian →
Journalist → Investigator → Lawyer). **Every persona stage follows the identical 8-step template**
below; the first (Individual) also establishes the reusable `Kalsmritikosh/Personas/<Name>/` layout
(ApplicationDefinition, DashboardView, ToolRegistry, WorkflowRegistry, ObjectExtensions,
WorkProductRegistry, Validators, Views/, Repositories/, Services/ — per each spec §11).

**Per-persona template (applied 5×):**
1. **Application definition + dashboard** (`…-001`, `…-002`) — register in the S3 registries;
   dashboard binds real workspace data + attention queues. `HEADLESS` def + `RENDER` dashboard.
2. **Persona objects** (`…-100…`) — each as a `persona_object_extensions` row type + a thin repo
   storing only workflow state, referencing canonical Claim/HistoryItem/Entity/EvidenceReference.
   One migration per persona for its extension tables. Sentinel bump. `HEADLESS`.
3. **Screens** (`…-003…0NN`) — SwiftUI, each honoring the §5 screen contract, using the S4 shell +
   inspector. `RENDER`.
4. **Guided workflows** (`…-200…204`) — resumable, audited, complete without prompt-writing; built
   on the S3 workflow engine. Logic `HEADLESS`, UI `RENDER`.
5. **Work products** (`…-300…3NN`) — each a blueprint (S2 kinds) + resolved composers + a
   persona validator; deterministic + evidence-cited + manifest. `HEADLESS`.
6. **Automations** (`…-400…409`) — `PersonaAutomationDefinition`s; propose-only into review queue,
   provenance recorded, disallowed outcomes blocked. `HEADLESS`.
7. **Persona tests** (`…-500`) — end-to-end corpus fixture exercising every job-map row.
8. **Safety + UX gates** (`…-501`, `…-502`) — guardrails enforced in UI/generation/export; new-user
   completes primary workflow with no prompt and opens proof in one action.

### STAGE 5 — Individual persona (IND-*, 68) — §14 Phase B (template-setter)
Objects: PersonalCategory, PersonalRecordType, OfficialDocument, DocumentVersionState, CareerPeriod,
EducationPeriod, FamilyRelationship, Subscription, PropertyRecord, InsurancePolicy, InsuranceClaim,
HealthRecordScope, ApplicationCase, ConfirmedReminder, ShareRecipe, EmergencyPack, LegacyCollection.
17 screens (My Records Home … Legacy Archive). 5 workflows. 15 work products. 10 automations.
Guardrails: opt-in sensitive categories; no diagnosis/legal/tax/financial advice; candidate
deadlines require confirmation; redaction verified on rendered output.

### STAGE 6 — Researcher/Historian (RES-*, 70) — §14 Phase C
Objects incl. ResearchProtocol, ArchiveHierarchy, MetadataTemplate, TranscriptionLayer,
AuthorityRecord, Periodisation, SourceCriticismAssessment, Interpretation, ScreeningDecision,
ExtractionSchema, BibliographicItem, EditionProject. Screens incl. Collection Catalogue,
Transcription & Facsimile Desk, Authority Control, Chronology & Periodisation, Source Criticism
Matrix, Literature Screening, Edition Builder. Work products incl. TEI/PAGE/ALTO export,
PRISMA-compatible counts, Prosopography, Citation audit. (Whisper/audio stays OFF per repo policy —
transcription desk consumes existing transcript segments only.)

### STAGE 7 — Journalist (JOU-*, 61) — §14 Phase D
Objects incl. StoryClaim, EditorialStatus, JournalisticSource, SourceConfidentiality, Quote,
TranscriptCorrection, RightOfReplyRequest/Response, ReportingGap, PublicationDecision. Screens incl.
Claim Board, Source Map, Quote Book, Right-of-Reply Center, Sensitive Source Vault (uses S1
SensitiveScope), Publication Package. Guardrail: confidential-source export checks.

### STAGE 8 — Investigator (INV-*, 65) — §14 Phase E
Objects incl. InvestigationSubject, Identifier, IdentityResolutionDecision, Lead, Hypothesis,
HypothesisEvidenceLink, SourceReliabilityAssessment, Transaction, Asset, Account, LocationObservation.
Screens incl. Subject Dossier, Identity Resolution Desk, Graph Lab, Hypothesis Matrix, Transaction &
Asset Flow, Evidence Vault & Custody (reuse `CustodyEvent`/`EvidenceVault`), Collection Plan.
Guardrail: a hypothesis never enters canonical history.

### STAGE 9 — Lawyer (LAW-*, 64) — §14 Phase F (strictest)
Objects incl. MatterParty, MatterIssue, FactTimeline, LegalFact, WitnessProfile, DocumentCoding,
PrivilegeCandidate, RedactionDecision, Obligation, ClauseVersion, DamagesItem, DepositionOutline,
Exhibit, MatterDeadline. Screens incl. Fact Timeline Builder, Facts & Evidence Board, Issue Map,
Privilege & Confidentiality Queue, Damages Ledger, Deposition Builder, Exhibit Binder, Draft Studio,
Production & Export Center. Guardrails: no legal conclusions; privilege is candidate-only; strict
export validation.

**Per-stage verify.** Per-persona: migration on throwaway DB; object-delete-doesn't-delete-source
test; deterministic-rebuild test; every work product passes the validator; safety gate tests
(prohibited conclusions never canonical, sensitive scope blocks export, duplicates≠corroboration).
Full suite green after each persona. Screens flagged render-unverified for your run-test.

---

# STAGE 10 — Cross-persona innovations (INN-001…006)  ·  Gate: mixed
- **INN-001 Persona Lens Comparison** (`RENDER`) — one canonical history/claim set in five lenses;
  assert facts + citations identical across lenses (ties to REL-002 truth-invariance).
- **INN-002 Evidence Time Machine** — DONE (`HistoryDiffEngine`); extend to also diff claims +
  work products across snapshots (`HEADLESS`).
- **INN-003 Missing Work Engine** — DONE (`MissingChapterEngine`); wire outputs into each persona's
  task/lead/request objects (`HEADLESS`).
- **INN-004 Decision Genealogy** (`HEADLESS`) — chain prior-state → information → options → decision
  → approval → action → consequence over HistoryItems/claims.
- **INN-005 Proof-preserving transformation** (`RENDER`) — one source passage toggles to
  claim/history-item/graph-edge/timeline/quote/table-row/draft-sentence, same EvidenceReference.
- **INN-006 History Quality Certificate** (`HEADLESS`) — export coverage/gaps/conflicts/date-
  precision/citation-coverage/review-state/engine versions with any history or work product.

---

# STAGE 11 — Release gates (REL-001…005)  ·  Gate: HEADLESS suites + RENDER dashboard
- **REL-001** persona release-readiness dashboard (functional/UX/safety gates per persona).
- **REL-002** persona truth-invariance suite — same snapshot ⇒ identical canonical claims across
  all five lenses (the core §16 metric: persona truth divergence = 0).
- **REL-003** sensitive-export suite — restricted evidence never leaks through any persona output.
- **REL-004** clean-machine five-workspace acceptance — all personas ingest, work, validate,
  persist, export end-to-end.
- **REL-005** honest competitor/capability matrix doc (parity/differentiation/exclusions).

---

# Cross-cutting: shared success metrics enforced as tests (§16)
Bake these as assertions in the S11 suites, checked per persona: unsupported material claims = 0;
exact evidence reopen = 100%; silent global-scope fallback = 0; duplicate copies counted as
corroboration = 0; persona truth divergence = 0; deterministic outline stability = 100%.

# Sequencing summary & effort shape
```
S0 ─ S1 ─ S2 ─ S3 ─ S4 ┐
                        ├─ S5 (Individual, template) ─ S6 ─ S7 ─ S8 ─ S9 ─ S10 ─ S11
(S1–S3 unblock everything; S4 unblocks all screens)
```
- **Headless, I can take to green now:** S0, S1, S2, S3, plus every persona's objects/work-products/
  automations/tests logic, INN-002/003/004/006, REL-002/003/004 suites.
- **Render-gated, you validate:** S4 shell, all persona screens/dashboards, INN-001/005, REL-001 dash.
- **Order rule:** never build a persona screen (S5+) before S1–S4 are green — screens would bind to
  nothing real. This is why the status report is at 5%: the foundation (S1–S3) barely exists yet.

# Verification ritual per stage (unchanged from CLAUDE.md)
1. `BuildProject` green. 2. Grep guard clean. 3. New unit tests green + full suite no-regression.
4. Migrations verified on a throwaway DB with sentinel = newest table. 5. Commit one logical unit.
6. Report what changed + what was verified + what remains render-gated. Stop at stage boundary for
your review.
