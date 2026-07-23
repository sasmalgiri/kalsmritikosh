# Persona-v2 Pack — Implementation Status & Gap Report

**Audited:** 2026-07-23 against `kalsmritikosh_persona_v2/` (366 tasks, 77 screens, 5 personas)
and the committed code at HEAD (`919b1b6`). Method: symbol-level codebase audit + backlog
reconciliation. This file is descriptive, not a claim of completion.

---

## 1. Bottom line (the honest yes/no)

**No — the persona-v2 pack is NOT fully implemented. It is roughly 5–8% built.**

The confusion is understandable, so state it plainly: **there are two different programs.**

| Program | Scope | Status |
|---|---|---|
| **Universal History program** (the 13-phase plan I finished earlier) | The shared history *kernel* | ✅ Done, 487 tests green, pushed |
| **Persona-v2 pack** (this 366-task pack) | 5 complete *workspace applications* built **on** that kernel | ❌ ~5% — only the kernel + 2 innovations |

The persona-v2 pack's own §14 says **"Phase A = shared kernel completion"** — that is the
history work I already delivered. But Phase A is only ~27 of the 366 tasks. The actual
product of this pack — **five persona operating systems** (Lawyer, Investigator, Journalist,
Researcher/Historian, Individual), ~328 tasks and all 77 screens — is essentially **not started**.

So when I said "all 13 phases done," that was true *for the Universal History program*. It is
**not** true for this persona-v2 pack, which is a much larger, mostly-UI program layered above it.

---

## 2. Status by layer

| Layer | Tasks | Done | Partial | Absent | % done |
|---|---:|---:|---:|---:|---:|
| **Foundation — Persona architecture** (PA-001…015) | 15 | 0 | 4 | 11 | ~10% |
| **Foundation — Work-product engine** (WP-001…007) | 7 | 0 | 4 | 3 | ~25% |
| **Foundation — History kernel** (HIS-001…004) | 4 | 3 | 1 | 0 | ~85% |
| **Foundation — Enrichment** (ENR-001) | 1 | 0 | 1 | 0 | ~40% |
| **Individual persona** (IND-*) | 68 | 0 | 0 | 68 | 0% |
| **Researcher/Historian persona** (RES-*) | 70 | 0 | 0 | 70 | 0% |
| **Journalist persona** (JOU-*) | 61 | 0 | 0 | 61 | 0% |
| **Investigator persona** (INV-*) | 65 | 0 | 0 | 65 | 0% |
| **Lawyer persona** (LAW-*) | 64 | 0 | 0 | 64 | 0% |
| **Cross-persona innovations** (INN-001…006) | 6 | 2 | 0 | 4 | ~33% |
| **Release gates** (REL-001…005) | 5 | 0 | 0 | 5 | 0% |
| **TOTAL** | **366** | **~5** | **~14** | **~347** | **~5%** |

The five persona applications are **90% of the backlog (328/366) and are at 0%.**

---

## 3. What is genuinely DONE (verifiable)

All from the Universal History program; all compile + test-green + pushed.

- **HIS-001 Complete HistoryReconstructionEngine** — `Knowledge/History/HistoryReconstructionEngine.swift`.
  Actor, AsyncStream: resolve → collect (ID-scoped) → project → outline → reconcile → verified.
  Non-entity subject *fails* (no silent global fallback).
- **HIS-002 Persist HistoryArtifact** — `Knowledge/History/HistoryArtifact.swift` +
  `Storage/Repositories/HistoryArtifactRepository.swift` (schema v61; versioned, supersede chain).
- **HIS-003 HistoryDiffEngine** — `Knowledge/History/HistoryDiffEngine.swift` (new/retracted/changed
  items + new/resolved gaps).
- **INN-002 Evidence Time Machine** — satisfied by HistoryDiffEngine.
- **INN-003 Missing Work Engine** — `Knowledge/History/MissingChapterEngine.swift` (gaps →
  persona-framed actions; identical gap/targets across personas).

Kernel support also present and used by the above: HistorySubject/Resolver, HistoryMaterialCollector,
TemporalClaim/TemporalEventProjector, HistoryOutline/Builder, HistoryReconciliationEngine,
HistoryNarrativeRenderer, SourceIndependenceGrouper.

---

## 4. What is PARTIAL (foundations exist, but short of the spec)

These pre-date or are adjacent to the persona-v2 pack. The master spec §2.1 explicitly credits
them as "correct foundations," but each falls short of what the pack requires.

- **WP-001 Expand BlueprintSection.Kind** — `Knowledge/Ontology/WorkProductBlueprint.swift` has
  **10** kinds (`narrative, chronology, matrix, exhibitList, relationships, transactions,
  bibliography, summary, gapsAndConflicts, deadlines`). The spec (§7.4) requires **~34**
  (claimMatrix, factEvidenceTable, peopleProfiles, quoteBook, transcriptExtracts, rightOfReply,
  screeningLog, sourceCriticism, interpretationComparison, custodyLog, privilegeCandidateLog, …).
- **WP-002 WorkProductSectionComposer protocol** — the *protocol* does not exist. There is **one**
  concrete composer, `HistoryChronologyComposer` (built as the Phase-12 foundation), but it does
  not yet conform to a shared protocol, and the other ~15 required composers are absent.
- **WP-005 WorkProductValidator** — `Export/WorkProductValidator.swift` checks claim/evidence
  counts, unsupported status, cited-source-in-manifest. Missing the spec's §7.5 checks:
  sensitive-scope, redaction, unresolved identity, source independence, date precision,
  prohibited-persona-claims, corpus-snapshot/engine-version stamping.
- **WP-007 Work-product manifest** — the F3 citation/export engine + `CitationRecord` exist;
  a full manifest with engine/policy versions per output is not assembled.
- **HIS-004 Atomic HistoryClaimVerifier** — closest is `Knowledge/Narrative/NarrativeClaimVerifier.swift`,
  which grounds **prose sentences**, not **atomic history claims**. The per-item entailment gate
  the spec wants is not built.
- **ENR-001 Deferred enrichment handlers** — `Ingestion/Pipeline/EnrichmentDrainer.swift` +
  `EnrichmentJob` exist with **6** kinds (embedding, typedFacts, entityReconciliation,
  contradictionScan, ocr, deepStudy). The spec wants **9**, adding temporalClaims,
  identityCandidates, personaIndexes, historyProjection, workProductCache, transcriptionQuality,
  tableExtraction. History-projection/persona-index draining is not wired.
- **PA-007 Command palette** — a generic `CommandPaletteView` exists in `UI/RootView.swift`;
  it is not workspace-scoped and doesn't resolve tools/workflows/outputs.
- **PA-008 Workflow-aware actions** — `UI/PersonaWorkCatalog.swift` `PersonaWorkAction` has only
  `.open(Destination)` / `.ask(String)`. The spec's `startWorkflow / buildWorkProduct /
  openTool / createWorkspace` cases are absent.
- **PA-013 Review-decision audit** — `FactReview` + audit surfaces exist for canonical objects,
  but not for the (unbuilt) persona objects.
- **Sensitivity infra** — `Core/Security/PIIRedactor`, `EvidenceVault`, `SensitivityInheritance`,
  `RedactionVerifier` exist, but there is **no `SensitiveScope` type** (PA-012) wiring them into
  screens/retrieval/prompts/exports as one policy.

---

## 5. What is ABSENT (the bulk of the work)

### 5.1 Persona *application* architecture (PA-002…006, 009…015)
None of these exist as the spec defines them:
- `PersonaToolID`, `PersonaToolDefinition`, `PersonaApplicationDefinition` (§5.1)
- The 9 registries (§5.2): `PersonaApplicationRegistry`, `PersonaToolRegistry`,
  `PersonaWorkflowRegistry`, `PersonaObjectSchemaRegistry`, `PersonaWorkProductRegistry`,
  `PersonaSectionComposerRegistry`, `PersonaValidatorRegistry`, `PersonaTerminologyRegistry`,
  `PersonaAutomationRegistry`
- `WorkspaceContext` propagation (§5.3)
- `PersonaWorkspaceShell` four-region shell (§6.1)
- Universal `EvidenceInspector` (§6.1) and contextual object-action bar (§6.2)

Today personas are a **presentation layer** — a `WorkspaceTemplate` enum (6 cases) +
`PersonaPolicy` + `PersonaTemplateCatalog` + a shared `WorkspacesView`. That is the "persona =
curated shortcuts" model the spec §2.3 explicitly says to **replace** with real applications.

### 5.2 Shared object engines (PA-009/010/011, §7.2–7.3, §10)
- **Claim engine** — no unified atomic Claim + `ClaimRepository / ClaimEvidenceRepository /
  ClaimContradictionRepository / ClaimReviewRepository / ClaimUsageRepository`. (There are
  scattered `ComposedClaim`, `TemporalClaim`, `WorkProductClaim`, `NarrativeClaimCitation`, but
  not the one shared claim object all five personas point at — the core of §4.2 persona invariance.)
- **Issue engine** — absent (only an unrelated `ExtractionIssue`).
- **Task/deadline engine** — absent (candidate vs confirmed deadlines).
- **~15 new shared tables** (§10: issues, claims, claim_evidence, tasks, deadlines,
  work_product_runs, work_product_sections, persona_object_extensions, sensitive_scopes,
  access_decisions, …) — none created. **WP-006** work-product-run persistence tables in
  particular do not exist (confirmed: no `work_product_runs` / `work_product_sections`).

### 5.3 The five persona applications (LAW/INV/JOU/RES/IND — ~328 tasks, 0%)
For **each** of the 5 personas, none of the following exist:
- application definition (…-001) + dashboard (…-002)
- 13–16 dedicated screens each (77 screens total across the pack — see `SCREEN_ROUTE_MATRIX.csv`)
- 12–18 persona objects each (MatterParty, LegalFact, WitnessProfile; InvestigationSubject,
  Hypothesis, Lead; StoryClaim, Quote, RightOfReplyRequest; AuthorityRecord, Periodisation,
  TranscriptionLayer; OfficialDocument, CareerPeriod, EmergencyPack; …)
- 5 guided workflows each (…-200…204)
- 14–17 persona work products each (…-300…316)
- ~10 automations each (…-400…409)
- end-to-end corpus + safety gates + UX acceptance (…-500…502)

### 5.4 Remaining innovations & release (INN-001/004/005/006, all REL-*)
- INN-001 Persona Lens Comparison, INN-004 Decision Genealogy, INN-005 Proof-preserving
  transformation, INN-006 History Quality Certificate — absent.
- REL-001…005 (readiness dashboard, truth-invariance suite, sensitive-export suite,
  clean-machine 5-workspace acceptance, honest capability matrix) — absent.

---

## 6. WHY it remains (honest reasons, not excuses)

1. **Scale.** This pack is ~328 net-new tasks and 77 screens — a multi-month application-build
   program, not a feature. It dwarfs the history kernel that's done.
2. **It's ~90% UI + interaction, which is render/run-gated.** Dashboards, four-region shells,
   graph/timeline/board/map canvases, inspectors, wizards — correctness is *rendering and
   interaction*, verifiable only by running the app, which is your side of the loop
   ("you do i will test it" applies, but building 77 screens blind before any of them is
   validated is high-risk and low-yield).
3. **It needs new schema + engines first (correct order).** Per §14 dependency order, the
   Claim/Issue/Task engines + persona registries + real composer protocol (PA/WP layer) must
   land **before** any persona app can be more than a shell. That foundation is largely absent,
   so persona screens have nothing real to bind to yet.
4. **Open product decisions.** The pack assumes an expanded `EvidenceStatus` (§4.3 adds
   `corroborated/disputed/modelProposed/userConfirmed`) — our locked rule is **one shared enum,
   never fork**; adding cases touches assertability logic app-wide and needs your sign-off.
   Persona ordering (§14 says Individual→Historian→Journalist→Investigator→Lawyer, "may be
   changed commercially") is also a product call.
5. **Prior "done" referred to the other backlog.** The 13-phase Universal History program was
   genuinely complete; this pack was read and its kernel-phase satisfied, but its persona phases
   were always the large remainder — now made explicit here.

---

## 7. Recommended next order (dependency-correct)

If you greenlight building it, the technically-forced order is:

1. **Foundation engines first** (unblocks everything, mostly headless + testable):
   `WorkProductSectionComposer` protocol + registry (WP-002/003), `WorkProductContext` (WP-004),
   expand `BlueprintSection.Kind` to all 34 (WP-001), the shared **Claim / Issue / Task** engines
   + tables (PA-009/010/011), `SensitiveScope` (PA-012), atomic `HistoryClaimVerifier` (HIS-004),
   remaining enrichment handlers (ENR-001).
2. **Persona application architecture** (PA-002…006, 014, 015): registries, `WorkspaceContext`,
   `PersonaWorkspaceShell`, `EvidenceInspector`.
3. **One persona end-to-end as the template** — Individual first (§14 Phase B: broadest, simplest,
   builds reusable infra), verified by you running it, *then* replicate for Historian → Journalist
   → Investigator → Lawyer.
4. **Innovations + release gates** (INN-001/004/005/006, REL-*) last.

Steps 1–2 are headless/compile-and-test verifiable (I can build these to green). Step 3+ is where
your run-testing is required per screen.
