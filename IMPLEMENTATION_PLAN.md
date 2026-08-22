# Implementation Plan — Guidance rollout completion + Sūtra roadmap (steps 2–5)

A single, execute-in-one-pass plan. Two parts: **A. Guidance** (finish `.guidance()` on every screen) and **B. Sūtra roadmap** (make the constitution drive the app). Each item lists the exact control, condition, and text/approach so implementation is mechanical.

**Ground rules (unchanged all along):** additive, non-breaking; build green after each part; tests for logic; grep guard clean; one commit per logical unit.

---

## PART A — Guidance rollout (remaining screens)

`.guidance(GuidanceTip(title, what:, enabledWhen:), enabled:)` on each screen's primary/gated control. `enabledWhen` = nil for always-on controls. The `enabled:` expression must mirror the control's existing `.disabled(...)`.

### A1. Actionable screens (add guidance) — 9 screens

| Screen · file | Control (existing `.disabled`) | `enabled:` (mirror) | Guidance — what / enabledWhen |
|---|---|---|---|
| **Convert** · ConvertView.swift:244 | Convert button `.disabled(disabled)` | `!disabled` | *"Turns the loaded file into the chosen format, fully on-device."* / *"Choose a file and a target format first."* |
| **Insights** · InsightsView.swift:152 | "Scan" `.disabled(scanning)` | `!scanning` | *"Scans your archive for gaps and contradictions — rule-based, no AI needed."* / *"Available when a scan isn't already running."* |
| **Completeness** · CompletenessView.swift:60 | Refresh `.disabled(loading)` | `!loading` | *"Recomputes how fully your archive has been processed — parsed, structured, embedded."* / *"Wait for the current check to finish."* |
| **Saved** · SavedQueriesView.swift:153 | "Re-investigate" `.disabled(runner==nil \|\| runningID != nil)` | `appState.investigationRunner != nil && runningID == nil` | *"Runs this saved question again against the current ledger."* / *"Available once the engine is ready and no re-investigation is running."* |
| **Citations** · CitationBuilderView.swift:93 | Copy/build `.disabled(text.trimmed == ".")` | `text.trimmingCharacters(in:.whitespacesAndNewlines) != "."` | *"Builds a layered Evidence Explained citation (full note · short note · bibliography) from the fields."* / *"Fill in at least one field first."* |
| **Explore** · ExplorerView.swift:104 | Search `.disabled(query.trimmed.count < 2)` | `query.trimmingCharacters(in:.whitespaces).count >= 2` | *"Explores the graph of people, orgs and documents starting from your term."* / *"Type at least two characters."* |
| **Audit** · AuditView.swift:92 | "Verify integrity" `.disabled(verifying)` | `!verifying` | *"Re-checks the ledger's integrity — content hashes and custody chain — and reports any breaks."* / *"Available when a verification isn't already running."* |
| **Transcripts** · TranscriptsView.swift:149 | Transcribe `.disabled(transcribing)` | `!transcribing` | *"Transcribes the audio/video on-device and adds it to your searchable archive."* / *"Wait for the current transcription to finish."* |
| **Sources** · SourcesView.swift:100/109 | "Stop watching" (destructive) | n/a (always enabled) | *"Stops watching this folder but keeps everything already learned from it. The forget variant also erases what was ingested — your original files are never touched."* (no enabledWhen) |

### A2. Display-only screens (SKIP — record the decision, don't force guidance)

No actionable primary control (they auto-load from the ledger); the sidebar blurb already describes them:
**Trends · Live · Caseload · Freshness · Library · Findings (FactStatus) · Fund Flow · Email Threads · Knowledge*.**

\* *Knowledge* has an inline "Save correction" in a sheet — optional micro-guidance, low value; defer.

### A3. Guidance — acceptance
- Build green; each ⓘ shows on hover / auto-reveals on disabled; popover shows unlock hint.
- Update task #1 → completed with the covered/skipped list recorded.
- ~9 edits; commit as 1–2 commits ("GUIDANCE: utility screens (Convert, Insights, Completeness, Saved, Citations, Explore, Audit, Transcripts, Sources)").

**Running total after Part A:** ~25 screens covered, remainder explicitly display-only. Guidance rollout = **complete**.

---

## PART B — Sūtra roadmap (steps 2–5)

Step 1 shipped: `JobToolingCatalog` (tier + method + surface per job-kind) and the persona Analyze phase now derives its launchers from it. Steps 2–5 make the constitution progressively *drive* the app.

### STEP 2 — Work Center step surfaces derived from the catalog
**Goal.** A workflow step that corresponds to an analytic job-kind opens the *right canvas* (ACH / Reasoning / Connections…) via the catalog, instead of each workflow hard-coding `launchesSurface`.

**Files.** `WorkCenter/WorkCenterEngine.swift` (WCOperation), `WCJobWorkflowFactory` (where steps are built), `UI/WorkCenterView.swift` (the "Open tool" button).

**Approach (additive, non-breaking).**
1. Add an optional `jobKind: PersonaJobKind?` to `WCOperation` (default nil) — most workflows leave it nil.
2. In `WCJobWorkflowFactory.make`, when a job maps to a `PersonaJobKind`, set `op.jobKind` on the tool step.
3. In WorkCenterView's "Open tool" resolution: `let surface = op.launchesSurface ?? op.jobKind.flatMap { JobToolingCatalog.profile(for: $0)?.surface }` → `Destination(rawValue:)`. Existing `launchesSurface` still wins (no behavior change where set).
4. Show the step's tier/method as a small badge ("Analyze · ACH") from the catalog — the constitution made visible on the rail.

**Tests.** `WCJobWorkflowFactory` sets `jobKind` for analytic jobs; the resolver returns "hypotheses" for an `.analysis` step, "reasoning" for `.causalAnalysis`; nil-kind steps unchanged. **Acceptance:** opening an analysis step lands on the ACH matrix.

**Risk.** Low — additive field + fallback; blast radius is one factory + one resolver.

### STEP 3 — Formalize the Sūtra + an authoring/inspection surface
**Goal.** Promote the implicit doctrine into a first-class, versioned `Sutra` value, and a screen to view (and later import) it.

**Files (new).** `Sutra/Sutra.swift` (the schema from VISION §3: id, version, provenance, vocabulary, evidenceModel, phases[{tier, method, requires, obligations, humanDecisions, prohibitedConclusions}], proof{standardOfProof, report}); `Sutra/SutraCompiler.swift` (derive a `Sutra` for a persona by folding `JobDocumentation` + `JobToolingCatalog` + the persona's rubric); `UI/SutraView.swift` (read-only inspector: pick a persona → see its constitution — phases, tiers, methods, obligations, prohibited conclusions, standard of proof).

**Approach.** Pure derivation first (no new persistence): `SutraCompiler.sutra(forPersona:)` composes existing sources into a `Sutra`. The inspector renders it. *Import from SOP PDF* (draft via on-device AI, human ratifies — never auto-adopt) is a **later sub-step**, gated behind Full power, reusing the capability + JSON-validation pattern from `QueryAIParser`.

**Tests.** For the Investigator, the compiled `Sutra` has a `decideProduce` phase whose `proof.standardOfProof` is non-empty and whose `prohibitedConclusions` include "average conflicts"; the ACH phase has `method == .ach`. **Acceptance:** the inspector shows a real, non-empty constitution per persona.

**Risk.** Low-medium — new model + a read-only view; no mutation of existing flows. AI import is optional and isolated.

### STEP 4 — Conformance verification (the sealed receipt as a constitutional certificate)
**Goal.** Prove a completed run satisfied its Sūtra: every obligation met, every `humanDecision` made, no `prohibitedConclusion` asserted.

**Files (new).** `Sutra/SutraConformance.swift` — `func verify(run:, against sutra:) -> ConformanceReport { satisfied: [Obligation], unmet: [Obligation], humanDecisionsMade: Bool, prohibitedAsserted: [String] }`. Wire a compact conformance summary into the findings report (`RCAReportRenderer`/`InvestigationFindingsComposer`) and the Handoff view.

**Approach.** Deterministic checker over the run's recorded state (Work Center document field values + the findings approval + custody). Reuses the existing gates as evidence (standard-of-proof present → proof obligation met; open-items acknowledged → awareness obligation met).

**Tests.** A run missing a standard of proof → `unmet` contains the proof obligation; a run with an averaged conflict (if detectable) → `prohibitedAsserted` non-empty; a clean run → fully conformant. **Acceptance:** the exported report carries a "Sūtra conformance" block.

**Risk.** Low — pure checker over existing recorded state.

### STEP 5 — Ship a second discipline from a Sūtra alone
**Goal.** Prove generalization: a **non-investigation** domain running end-to-end with **no new UI code** — only a `Sutra`.

**Candidate.** *Clinical differential diagnosis* (VISION §5) or *safety-incident RCA*. Differential reuses the ACH matrix directly; safety-incident reuses Reasoning Studio + CAPA.

**Files.** A single new `Sutra` definition (data), registered like a persona; possibly a thin persona package. **No new views.**

**Tests.** The new discipline's compiled Sūtra drives the correct surfaces (differential → ACH); a run produces a conformant report. **Acceptance:** launch the new discipline, work a case, export a defensible report — entirely from the constitution.

**Risk.** Medium — depends on steps 2–4 landing; it's the proof, so do it last.

---

## Execution order (one pass)

1. **Part A guidance** (9 edits) → 1–2 commits. *Guidance rollout complete.*
2. **Step 2** (WC step surfaces from catalog) → 1 commit + tests.
3. **Step 3** (Sutra model + compiler + read-only inspector) → 1–2 commits + tests. *(AI-import sub-step optional, separate commit.)*
4. **Step 4** (conformance checker + report block) → 1 commit + tests.
5. **Step 5** (second discipline from a Sutra) → 1 commit + tests. *Vision proven.*

**Estimated:** ~6–8 commits, ~15–20 new tests, no schema migrations, no behavior regressions. Each step is independently shippable and reviewable; stop-points are clean.

## What this does NOT include (explicit scope guard)
- No cloud/network changes; PrivacyGate untouched.
- No edits to shipped migrations; Sūtra persistence (if any) is a *new* versioned migration only when step 3's import needs durability (until then it's derived/in-memory).
- The AI SOP→Sūtra import stays optional, Full-power-only, human-ratified — never auto-adopted (per the ambiguity discipline in VISION §4).
