# Persona Job-Depth Map (SOP-grounded)

**Purpose.** Answer a design question: *why does one job (causal analysis) get a full studio while others don't?* The honest answer is that tooling depth should follow the **cognitive shape of the job in its real SOP** — not be assigned ad-hoc. This document classifies every shared job into a tier, records the surface it launches today, anchors it to a recognized standard + SOP, and flags where the app is **under-** or **over-tooled**.

**Unit of analysis.** All 10 personas are *lenses* over the **same 16 `PersonaJobKind`s** (routed by `PersonaJobService` into one shared service each). So the map is keyed by the 16 kinds; persona differences are vocabulary + DataLab templates + the recognized rubric each persona now surfaces (SIU fraud indicators, FA funds-tracing, HR fairness, GPS, PRISMA/GRADE, journalistic verification).

---

## The four tiers

| Tier | The job's shape | Right surface | Studio warranted? |
|---|---|---|---|
| **1 · Capture** | fill a register / log / matrix of facts | table / form (DataLab, Work Center) | No — a rich table is correct |
| **2 · Analyze** | the work *is* structured reasoning over evidence | **interactive canvas / studio** | **Yes** |
| **3 · Read / derive** | assemble evidence → display → judge | dedicated view | No — a good view is correct |
| **4 · Decide / produce** | a gated human decision + sealed output | gated form + receipt | No — rigor, not richness |

Over-tooling a tier-1 capture with a "studio" is as wrong as under-tooling a tier-2 analysis with a flat form.

---

## The map — 16 shared job-kinds

| # | Job-kind | Tier | Surface today | SOP anchor | Verdict |
|---|---|---|---|---|---|
| 1 | `caseIntake` | 4 | Work Center intake form → `InvestigationCaseRepository` (scope + authorization) | Intake/logging + preliminary assessment & **written authorization** before a full investigation | ✅ Right-tooled |
| 2 | `ask` | 3 | **AskView** (rich, cited answers) | Analysis-phase evidence Q&A | ✅ |
| 3 | `methods` | 2–3 | Method workbench (checklist/form) | Structured analytic techniques (SATs) | 🟡 Adequate; could host SAT canvases |
| 4 | `dataLab` | 1 | **DataLab** (rich tables + persona templates) | Case file / registers | ✅ Rich table is correct |
| 5 | `subjectDossier` | 3 | **DossierView** (rich, cited) | Subject/background workup | ✅ |
| 6 | `identityResolution` | 3–4 | Reversible, human-gated merge (service + confirm) | Entity resolution with human gate | ✅ |
| 7 | **`analysis`** | **2** | **Work Center FORM** (hypotheses as flat fields) | **Analysis of Competing Hypotheses (ACH)** — an 8-step, **matrix-based** SAT (hypotheses × evidence, consistency scored) | ❌ **UNDER-TOOLED — the one clear gap** |
| 8 | `sourceReliability` | 3 | Reliability schedule (form/service; now Admiralty) | **Admiralty/NATO** source-info scale | 🟡 Right tier; a rating grid would help |
| 9 | `linkage` | 2 | **Timeline + Connections/Graph + Fund Flow** (rich canvases) | ANACAPA association matrix, link/timeline analysis | ✅ Well-tooled |
| 10 | `contradictionGap` | 3 | Desk (form/service) + now surfaced at report time | Conflict resolution; absence ≠ proof | ✅ |
| 11 | **`causalAnalysis`** | **2** | **Reasoning Studio** (brainstorm · 5 Whys · fishbone · report) | RCA; Ishikawa cause-and-effect; 5 Whys | ✅ Studio is correct |
| 12 | `capaRegister` | 1 | Register (form/table) | CAPA — corrective & preventive actions | ✅ |
| 13 | `effectivenessReview` | 4 | Verify decision (form/service) | Action-effectiveness verification | ✅ |
| 14 | `evidenceCustody` | 1–3 | **Append-only ledger + integrity hashes** (`InvestigationCustodyService`) | **SWGDE / NIST SP 800-86** chain of custody: contemporaneous record, unique id, transfers, **hash early** | ✅ Matches SWGDE |
| 15 | **`findings`** | **4** | **Handoff & Review** — gated, **now: standard-of-proof + open-items gate**, sealed receipt | Self-contained, defensible final report | ✅ Hardened this cycle |
| 16 | `closure` | 4 | Handoff & Review closure (retains unresolved items) | Archiving + post-investigation review | ✅ |

---

## SOP anchors (recognized standards + notes)

- **Investigation lifecycle** (kinds 1, 14, 15, 16): intake/logging → preliminary assessment & **written authorization** → evidence handling with **chain of custody** → complete case file → **defensible final report** → archive/post-review. Sources: [ConvergePoint 7-step workplace investigation](https://www.convergepoint.com/incident-management-software/7-steps-detailed-workplace-incident-management/), [GIR Corporate Investigator's Handbook — Investigation Procedure Manual](https://globalinvestigationsreview.com/guide/the-aci-corporate-investigators-handbook-in-association-gir/first-edition/article/investigation-procedure-manual), [Forensic Investigations SOP](https://www.taxtmi.com/article/detailed?id=15459).
- **`analysis` = ACH** (kind 7): the **matrix** is the technique's defining feature — hypotheses across the top, evidence down the side, each cell rated consistent/inconsistent; you select the hypothesis with the **fewest inconsistencies**, not the most support. 8 steps (Heuer). Sources: [Pherson — How ACH Improves Analysis](https://pherson.org/wp-content/uploads/2013/06/06.-How-Does-ACH-Improve-Analysis_FINAL.pdf), [SANS ISC — ACH](https://isc.sans.edu/diary/22460), [Heuer, *Psychology of Intelligence Analysis*, ch.8 (PDF)](https://www.futuribles.com/wp-content/uploads/related-documents/analysis-of-competing-hypotheses.pdf?postId=73706). Caveat noted in the literature: analysts often skip steps and ACH doesn't weigh base rates ([Dhami 2019, *Applied Cognitive Psychology*](https://onlinelibrary.wiley.com/doi/full/10.1002/acp.3550)) — so the tool should *aid* judgment, not compute a verdict.
- **`sourceReliability` = Admiralty/NATO** (kind 8): reliability A–F × credibility 1–6 (already added as `AdmiraltyCode`).
- **`evidenceCustody` = SWGDE/NIST** (kind 14): contemporaneous chain-of-custody record, unique identifier, every transfer, and **hash as early as possible** with secure storage. Sources: [SWGDE Best Practices for Digital Evidence Collection (18-F-002)](https://www.swgde.org/documents/published-complete-listing/18-f-002-swgde-best-practices-for-digital-evidence-collection/), [SWGDE Model SOP for Computer Forensics v3.0 (PDF)](https://www.swgde.org/wp-content/uploads/2023/11/2012-09-13-SWGDE-Model-SOP-for-Computer-Forensics-V3-0.pdf), NIST SP 800-86.
- **SIU** (persona lens over kinds 7/15): red flags are **leads, not proof**; referral needs **objective, written criteria** (NAIC Model #901; NICB Red Flags; ISO ClaimSearch); law-enforcement referral at the **probable-cause** threshold. Sources: [Superunit — What is an SIU](https://www.superunit.com/blog/what-is-a-special-investigations-unit-siu), [CA DOI SIU Regulations (PDF)](https://www.insurance.ca.gov/0300-fraud/upload/revised_siu_regs.pdf), [FraudOps — SIU Referral Management](https://fraudops.ai/investigation-management/siu-referral-management/).
- **Persona rubrics already surfaced:** SIU fraud-indicator taxonomy · Forensic funds-tracing methods (direct/indirect) · HR procedural-fairness · Genealogical Proof Standard · PRISMA/GRADE · journalistic verification · (Lawyer) FRCP 26(b)(5) privilege.

---

## Findings — where the app is mis-tooled

**Under-tooled (fix):**
1. **`analysis` (ACH hypothesis worksheet) — the headline gap.** It is a tier-2 analytical job whose SOP is *fundamentally a matrix*, but it's presented as flat Work Center fields. This is exactly the asymmetry that prompted the question: causal analysis got the Reasoning Studio and linkage got Timeline/Connections/Fund Flow, but the hypothesis-analysis job never got its canvas. **Fix:** an **ACH matrix studio** — hypotheses as columns, evidence as rows, per-cell consistency (CC/C/N/I/II), a "fewest inconsistencies" ranking, an assumptions/indicators panel, and an export that states confidence and does *not* claim a computed verdict. It should reuse the Reasoning Studio's shell (persisted JSON, report/approval) for consistency.

**Adequate but improvable (optional, lower priority):**
2. `sourceReliability` — a small **rating grid** (source × Admiralty A–F/1–6) would beat the current per-item form.
3. `methods` — could host lightweight canvases for other SATs (key-assumptions check, indicators/ACH-lite) rather than a checklist.

**Correctly tooled (no change):** everything else — intake, ask, dataLab, dossier, identity, linkage, contradiction/gap, causal (studio), CAPA, effectiveness, custody (SWGDE), findings (hardened), closure.

**Over-tooled:** none found — no tier-1 capture has been given a needless studio.

---

## Recommended sequence
1. Build the **ACH matrix studio** for `analysis` (closes the one real gap; makes the tier-2 set consistent: causal ✓, linkage ✓, hypotheses ✓).
2. (Optional) `sourceReliability` rating grid.
3. (Optional) additional SAT canvases under `methods`.

*This map is the plan; no code changes are implied by it beyond the fixes listed above.*
