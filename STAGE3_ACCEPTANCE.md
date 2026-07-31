# STAGE 3 — Persona Job Engine: ACCEPTANCE RECORD

**Status: COMPLETE (acceptance-proven).** Closed by PJE-012 on 2026-07-31.
Authority: `SHIP_DECISIONS.md` → `WHOLE_PROJECT_COMPLETION_PROGRAM.md` → this record →
committed code + tests + recorded hosted CI. This document is the single source of truth for
Stage 3 completion; the per-unit history lives in each unit's implementation + evidence commit.

```
Stage 3 — Persona Job Engine: COMPLETE
Schema baseline:                 v78 (unchanged by PJE-012)
Test floor:                      1851 (ci/test-baseline.json)
17 step kinds:                   all registered, bound, covered
Architecture closure:            clean (guards + boundary suites)
Carried rulings:                 both closed (reviewEvidence, .brokenLineage)
```

> **The reusable Persona Job Engine is complete and acceptance-proven.** It can execute, persist,
> resume and reconstruct version-pinned professional workflows with evidence provenance,
> attachments, generic methods, human decisions, cited work products, safe automations and
> presentation-only terminology. Concrete professional methods (Stage 4), the Evidence Workbench
> (Stage 5) and persona interfaces (Stage 6) remain later stages and are **not** implemented.

---

## 1. Accepted units (implementation + evidence SHAs)

Every unit was NORMAL-merged to `main` (never squashed), preserving both its implementation and
evidence commits. Each row's implementation SHA is the accepted baseline for that unit.

| Unit | Scope | Impl SHA | Evidence SHA | Schema | Floor |
|---|---|---|---|---|---|
| PJE-001 | Workflow definition types + compiler | `df3c819` | `70698d8` | — | 1025 |
| PJE-002 | Application/tool/workflow registries + catalog | `fcd449c` | `2214ae5` | — | 1073 |
| PJE-003 | Persistent workflow runs (7 tables + codec) | `fde9955` | `417dfa2` | v75 | 1154 |
| PJE-004 | Lifecycle engine (transitions, supersede, relaunch) | `5b3e3c6` | `e432470` | v75 | 1257 |
| PJE-005 | Requirements + blockers engine | `94ba85d` | `5d366a2` | v75 | 1292 |
| PJE-006A | Step executor runtime + 6 working-surface executors | `10ba703` | `f8b0942` | v75 | 1398 |
| PJE-006B | 5 evidence/analytical executors + evidence gate | `a10480f` | `1b2f685` | v75 | 1471 |
| PJE-006B.1 | Unified stored-byte hash contract | `9b7eb34` | `2b108c6` | v76 | 1486 |
| PJE-006C | Remaining 6 executors — all 17 kinds executable | `8046569` | `1c2f800` | v76 | 1566 |
| PJE-007 | Evidence / attachment / provenance bridge | `a67c585` | `b6f9845` | v77 | 1677 |
| PJE-008 | Method boundary acceptance (generic adapter) | `bb2f501` | `220e189` | v77 | 1723 |
| PJE-009 | Work-product integration acceptance | `8a0a438` | `2b07e2d` | v77 | 1767 |
| PJE-010 | Automation + terminology runtime (proposals only) | `7ac63fe` | `e6ede3e` | v78 | 1824 |
| PJE-011 | Complete synthetic workflow (connected E2E) | `2896e13` | `1690599` | v78 | 1844 |
| PJE-012 | Stage 3 final acceptance (this record) | _(this unit)_ | _(this unit)_ | v78 | 1851 |

---

## 2. Cumulative Stage 3 contract audit

Every promised Stage 3 capability has an accepted implementation **and** executable evidence. No
capability is marked complete because a type merely exists.

| Capability | Owner unit | Production surface | Acceptance suite | Status |
|---|---|---|---|---|
| Typed workflow definitions | PJE-001 | `WorkflowDefinition.swift`, `WorkflowDefinitionCompiler.swift` | WorkflowDefinitionCompilerTests | Accepted |
| Version-pinned application packages + registries | PJE-002 | `Workflow/Registry/*` (8 frozen registries) | PersonaJobCatalogTests, VersionedDefinitionRegistryTests | Accepted |
| Persistent workflow runs | PJE-003 | `WorkflowRun.swift`, `WorkflowRunRepository.swift`, schema v75 | WorkflowRunRepositoryTests, WorkflowRunSnapshotCodecTests | Accepted |
| Lifecycle transitions | PJE-004 | `Workflow/Lifecycle/*` | WorkflowLifecycleEngine/StateMachine Tests | Accepted |
| Requirements + blockers | PJE-005 | `WorkflowRequirementsEngine.swift` | WorkflowRequirementsEngineTests | Accepted |
| All 17 executor kinds | PJE-006A/B/B.1/C | `Workflow/Execution/Executors/*` (17) | PJE006CScopeGuardTests, PJE012 §5 | Accepted |
| Evidence / provenance bridge | PJE-007 | `Workflow/Provenance/*` | WorkflowProvenance* + PJE012 rulings | Accepted |
| Attachment binding | PJE-007 | `WorkflowAttachmentCoordinator.swift` | AttachmentCoordinatorTests, PJE011 | Accepted |
| Generic method boundary | PJE-008 | `MethodStepExecutor.swift` (adapter only) | WorkflowMethodBoundaryGuardTests | Accepted |
| Work-product integration | PJE-009 | `WorkflowWorkProductBuildCoordinator.swift` | PJE009WorkProductIntegrationTests | Accepted |
| Terminology runtime (presentation only) | PJE-010 | `PersonaTerminologyResolver.swift` | PersonaTerminologyResolverTests, PJE010BoundaryGuard | Accepted |
| Safe automation runtime (proposals only) | PJE-010 | `PersonaAutomationRuntimeCoordinator.swift`, schema v78 | PJE010AutomationRuntimeTests | Accepted |
| Pause / close / reopen / resume | PJE-003/004 | lifecycle + repository reopen | PJE011CompleteSyntheticWorkflowTests | Accepted |
| Branching + return paths | PJE-004/006C | decision executor + lifecycle | PJE006C decision tests, PJE011 | Accepted |
| Human decisions + approvals | PJE-006C | decision + human-approval executors | PJE006C tests, PJE011 | Accepted |
| Cancellation + supersession | PJE-004 | lifecycle `cancel` / `supersede` | PJE011IntegrationScenariosTests | Accepted |
| Final closure | PJE-006C | closure executor → `completeTerminal` | PJE006C closure tests, PJE011 | Accepted |
| Deterministic reconstruction | PJE-003..007 | contract/step/provenance stored-byte hashes | PJE011 tamper + relaunch tests | Accepted |

---

## 3. The 17 registered step kinds

`WorkflowStepKind` (`Core/Models/WorkflowDefinition.swift`, `CaseIterable`) has exactly 17 cases;
each binds to one stateless executor in `Workflow/Execution/Executors/` via
`WorkflowStepExecutorRegistry`. Executors are repository-free (protocol contract in
`WorkflowStepExecutor.swift`), gate evidence where required, never make unauthorized human
decisions, and never mutate canonical truth.

```
intake · scope · selectEvidence · reviewEvidence · brainstorm · form · table · matrix ·
timeline · graph · calculation · method · decision · humanApproval · workProductBuild ·
effectivenessReview · closure
```

Coverage: `PJE006CScopeGuardTests.allSeventeenKindsCovered`,
`PJE009WorkProductBoundaryGuardTests.allStepKindsStillResolve`,
`PJE011IntegrationScenariosTests.allStepKindsResolve`, and
`PJE012Stage3FinalAcceptanceTests.allSeventeenKindsBindStableExecutorIdentity` (asserts each kind
binds a distinct, stable executor identity + version handling exactly that kind).

---

## 4. Persistence & migration audit (schema v78)

Schema remains **v78**; the final audit exposed no defect requiring a migration.

| Property | Evidence |
|---|---|
| Fresh v78 database | MigrationMatrixTests.freshDatabaseReachesLatest (sentinel = 78) |
| Upgrades through v74→v78 | WorkflowRun/Provenance/AutomationExecution MigrationTests (migration-matrix group, floor 90) |
| Repeated migration + stale user_version self-heal | MigrationMatrixTests |
| Interrupted / faulted migration rollback | MigrationFaultInjectionTests (SAVEPOINT rolls user_version back) |
| Self-heal sentinel updated every migration | `SchemaMigrations.isSchemaFullyApplied` (includes state_hash_semantics, provenance, automation markers) |
| Reopen of old workflow runs | WorkflowRunRepository reopen (contract hash + revision==events.count + checkpoint) |
| Legacy provenance handling | `legacyUntracked` rows reopen unrewritten (PJE-007) |
| Version-pinned contract snapshots | WorkflowRunContractSnapshot frozen at run creation |
| Stored-byte hash semantics | WorkflowStepStateHashContractTests (storedUTF8BytesV1) |
| Automation ledger idempotency | UNIQUE idempotency_key, PJE010AutomationRuntimeTests |
| No orphaned workflow-owned records | CASCADE FKs; canonical isolation tests |
| Workflow delete never cascades into canonical evidence | WorkProductRunRepository + PJE011 cancellation tests (claims count unchanged) |

---

## 5. Final truth & safety invariants

Each invariant is backed by executable coverage:

| Invariant | Evidence |
|---|---|
| candidate ≠ confirmed | OPS-002 `DeadlineCandidate ≠ Deadline`; PJE011 automation candidate status |
| proposal ≠ Claim | PJE010BoundaryGuardTests.neverConfirmsTruth; PJE012 automation-coexists test (claims unchanged) |
| reviewed ≠ supporting/contradicting polarity | **PJE012** reviewDispositionVocabularyIsClosed + reviewEvidenceProvenanceUsesReviewedRoleNeverPolarity |
| automation ≠ human decision | PJE010BoundaryGuardTests; automation creates PROPOSALS only |
| method result ≠ confirmed truth | WorkflowMethodBoundaryGuardTests.methodExecutorNoClaimConversion |
| work-product prose ≠ provenance | PJE009 coordinatorProvenanceNotFromProse |
| workflow completion ≠ professional correctness | effectiveness-review + human-approval are separate human gates |
| uncited material statements = 0 | WorkProductValidator; PJE009CitationTamperTests |

Confirmed: automation creates proposals only; terminology changes presentation only; methods remain
generic Stage 3 adapters (no Stage 4 engines); work products use canonical citations + manifests;
SensitiveScope is reapplied at viewing and export; human approval remains human; no workflow action
autonomously confirms Claims.

---

## 6. Carried rulings — CLOSED

### 6.1 `reviewEvidence` — intentional contract (closed)

```
role        = reviewed
disposition = active | needsFollowUp | excludedFromWorkflow
```

Supporting / contradicting polarity is a property of **claim / evidence assessment**, not of review
provenance. The `.reviewed` role therefore never carries polarity. The implementation is unchanged;
`WorkflowProvenanceRole.supporting`/`.contradicting` exist as a **separate** role family that
`reviewEvidence` never emits.

Closed by `PJE012Stage3FinalAcceptanceTests.reviewDispositionVocabularyIsClosedAndIntentional`
(vocabulary is the closed set; polarity is a distinct role family) and
`reviewEvidenceProvenanceUsesReviewedRoleNeverPolarity` (a driven run's review-step provenance uses
only `.reviewed` with dispositions in the closed set). See also existing
`ReviewEvidenceStepExecutorTests.allStatusesRecordable` and
`WorkflowProvenanceIntegrationTests.evidenceExecutorProvenanceRoles`.

### 6.2 `.brokenLineage` — reserved defensive inspector state (closed)

> `.brokenLineage` is a reserved defensive inspector state. The guarded resolution path
> (`WorkflowProvenanceInspector`) validates canonical existence **first** and classifies a missing
> or invalid canonical target as `.unresolved` before the `.brokenLineage` branch is reachable. It
> is **not** claimed as a normal reachable Stage 3 product state.

It is kept, explicitly documented as reserved, and proven not to leak information:

- Wherever a broken lineage genuinely arises (the SensitiveScope layer, for an unknown canonical
  target), it resolves to `.brokenLineage` — a **denial that carries no protection label** to expose
  (`PJE012 …brokenLineageResolvesToDenialCarryingNoLabel`; existing
  `SensitiveScopeRepositoryTests.unknownTargetReturnsBrokenLineage`,
  `SensitiveScopeEndToEndTests.brokenLineage_deniedOnScreenAndRetrieval`).
- The inspector strips **every** annotation (label, note, locator, source-version) from any
  inaccessible reference — the identical code path a reserved `.brokenLineage` reference would take
  (`PJE012 …inspectorInaccessibleReferenceExposesNoAnnotations`; the reference stays visible so
  counts remain honest, but exposes nothing).
- The guarded ordering (missing target → `.unresolved`, never `.brokenLineage`) is proven by
  `WorkflowProvenanceInspectorTests.unresolvedTargetReported`.

No redesign was introduced to force the state to occur.

---

## 7. Architecture closure audit — clean

Stage 3 contains none of the following; each is enforced by a guard and/or a boundary test:

| Prohibited | Evidence |
|---|---|
| AppState / UI dependency | PJE006C.noNetworkOrUIWiring, PJE011.runtimeLayerNoUINetworkLLM |
| Network dependency | `ci/guards/no-network-evidence-layers.sh`, PJE008/009/010/011 guards |
| LLM requirement | `ci/guards/capability-discipline.sh`, PJE008/009/010/011 guards |
| Concrete Stage 4 method engine | PJE006C.noStageFourMethodEngine, PJE008 noStage4Type* / noMethodTablesInSchema |
| DataLab implementation | (absent — no DataLab type in Workflow/Storage/Core) |
| Persona-specific execution switch | PJE010BoundaryGuardTests.noPersonaSwitch |
| Duplicate evidence store | one ledger behind `actor Database`; no second store introduced |
| Duplicate work-product assembly path | PJE009.coordinatorUsesOneAssemblyPath, PJE006C.oneSharedWorkProductWriter |
| Prose-to-provenance parser | PJE009.coordinatorProvenanceNotFromProse |
| Executor direct SQL | PJE006C.executorsAreRepositoryFree, PJE011.executorsNoDirectSQL |
| Automation-made approval / closure | PJE010.neverConfirmsTruth, PJE011.automationProposesCandidate |
| Terminology-driven workflow branching | PJE010.terminologyResolverPresentationOnly / labelNeverAnIdentifier, PJE011.terminologyInContextIsPresentationOnly |
| Source-byte copying into workflow artifacts | PJE009.workflowArtifactsHaveNoByteColumns |

CI enforces six mandatory jobs on every run: `build-and-test`, `migration-matrix`,
`sensitive-export`, `parser-fixtures`, `report-receipt-integrity`, `architecture-guards`.

---

## 8. Connected acceptance

`PJE011CompleteSyntheticWorkflowTests.completeWorkflowWithRelaunch` remains the primary connected
case: frozen package → run creation → blocking requirement → evidence + attachment → analysis +
generic method → pause/relaunch → human decision → cited work product → approval → closure → final
reopen, with exact hash reconstruction throughout. PJE-012 adds the narrowly-missing final check
`automationProposalCoexistsWithApprovedConnectedRun` (a safe automation proposes an unconfirmed
candidate that coexists with an approved, relaunched connected run and creates no canonical Claim).

---

## 9. What remains (NOT Stage 3)

Stage 4 Professional Method Engine (concrete methods), Stage 5 Evidence Workbench, and Stage 6
persona interfaces are later stages. The `PERSONA_JOB_COVERAGE_MATRIX.csv` persona job rows remain
`Absent` — those are persona-application work (Stage 6+), not the reusable engine, and are
intentionally left unchanged by PJE-012.
