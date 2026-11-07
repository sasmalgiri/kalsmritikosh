# Practitioner review — Genealogist, Investigator, Individual

**AGENT REVIEW — not a human practitioner review (owner direction 2026-11-01).**

- Reviewer: Claude agent (practitioner reviewer)
- Date: 2026-11-01
- Commit: 81cf335f (branch investigations-next)
- Scope: a read-only review of code, tests and docs. No build, test suite or UI session was run. Two behaviours
  were checked with stand-alone Swift snippets outside the repo: the lineage kinship regex, copied verbatim from
  `LineageExecutor`, and `NSDataDetector`'s time of day for a written date.

## Method

For each persona I read the job list (`Personas/<Persona>/*PersonaPackage.swift`) and the job contracts
(`Personas/JobContracts.swift:64-79, 193-231`). For each job I followed the executor assignment
(`Personas/JobExecutors.swift:23-66`), the executor code (`JobFamilyExecutors.swift`, `JobDeliverableExecutors.swift`),
the result columns and completion rules (`JobFields.swift`), the export renderer (`UI/JobResultView.swift:638-680`)
and the studios that build the persona-specific work products (`Investigate/PersonaDeliverables2.swift`,
`Investigate/ACHAnalysis.swift`). For the Investigator I also read the case-file allegation gate and report
(`Investigate/CaseFile/CaseFileRepository.swift`, `CaseFileDocuments.swift`) and the INV services (findings, identity
resolution, custody, hypotheses). I compared each against the acceptance scenarios
(`KalsmritikoshTests/JobAcceptanceScenarioTests.swift`, `JobDeliverableTests.swift`, `PersonaDeliverables2Tests.swift`)
and the measured matrix (`docs/JOB_OUTCOME_MATRIX.md`).

The standards applied:
- **Genealogist:** the Genealogical Proof Standard.
- **Investigator:** scope discipline, reproducibility, human-gated identity resolution, ACH diagnosticity,
  investigator-made findings with contrary evidence, and custody of exports.
- **Individual:** accuracy of records, dates and reminders; no advice; privacy.

The classes:
- **BLOCKER:** could mislead or harm; fix before release.
- **SHOULD-FIX:** release is acceptable with the limitation stated.
- **NOTE:** an observation or a strength.

---

## 1. Genealogist

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Kinship extraction → lineage chart | The kinship pattern accepts up to 40 characters of anything between person A and the kin word. It does not check whether another named person stands between them, so the relationship is given to the wrong person. Checked with the regex copied verbatim. "Ravi Rao, son of Asha Rao and husband of Meera Rao" produces **"Asha Rao — husband of — Meera Rao"**. "John Smith and Mary Brown, daughter of Thomas Brown, married" produces **"John Smith — daughter of — Thomas Brown"**. The `married` pattern does the same: "Asha Rao was present when Meera Rao married Dev Sharma" produces **"Asha Rao — married — Dev Sharma"**. Each false row is flagged "stated by a source" and carries the sentence as its source. The chart draws every row that is not rejected, including undecided drafts, as a **solid** (sourced) line, and the export prints that chart. Under the GPS this is a fabricated relationship that looks sourced. | **BLOCKER** | `Personas/JobDeliverableExecutors.swift:992-1001` (pattern at :995, :998; flag at :1000); `LineageChart.mermaid` :1033-1036 (only `.rejected` excluded; solid whenever refs exist); `UI/JobResultView.swift:648, 672-673`; scenario only tests positive sentences, `JobAcceptanceScenarioTests.swift:323-330` |
| Proof argument vs open conflicts | The contract says "a conclusion with unresolved conflicts is qualified", but this is not implemented. The Proof Argument studio is complete when the conflict-resolution text is non-empty and a "Citations complete" toggle is on. It does not read the case's open conflicts (`gen.conflicts`) and does not qualify the conclusion. The toggle is the researcher's own claim, printed in the export as "every fact reopens its source: **Yes**" without being checked. No test covers qualification. | SHOULD-FIX | `Investigate/PersonaDeliverables2.swift:276, 299-305, 340`; `UI/PersonaStudiosViews.swift:241`; `Personas/JobContracts.swift:205`; `KalsmritikoshTests/PersonaDeliverables2Tests.swift:105-124` |
| Same-person analysis | Candidate pairs include any two people with the **same surname**. In a family file that means most relatives. The "Identifiers compared" field is free text, so a conclusion of "same person" can rest on the name alone. No completion rule enforces the policy "never merge on matching names alone". The executor itself merges nothing. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:571-575`; `Personas/JobFields.swift:166-167`; `completionProblems` has no `gen.same-person` case, :241-312 |
| Vital-event subject | A vital event is given to the person named **first** in the sentence. In "Asha Rao registered the birth of Meera Rao on …", Person is prefilled as Asha Rao, as a source-derived value. Vital events are not drawn in the chart, which limits the harm. | SHOULD-FIX | `Personas/JobDeliverableExecutors.swift:1006-1012` |
| Citation prefill | The `gen.originals` citation is built as the first named person + file name + earliest date. The "author" is a guess, not an Evidence Explained element. The citation is flagged incomplete only when a name or date is missing. The required Repository field does stop completion until it is filled. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:160-163`; `Personas/JobFields.swift:83` |
| Parish-register formulae (open item from the 2026-10-30 pass) | Still open. The kin words have no abbreviations ("s.", "d.", "dau.", "wid."), `baptis\w*` does not match "bapt.", and the sentence splitter breaks at every full stop, so "Wm. Smith, s. of John" never reaches the pattern. | SHOULD-FIX | `Personas/JobDeliverableExecutors.swift:978-979`; `Personas/JobFamilyExecutors.swift:56-73` |
| Unproven relationships | A relationship added by hand with no source is drawn dashed and labelled "unproven — no source", and the export says so. Tested. | NOTE (strength) | `JobDeliverableExecutors.swift:1036`; `UI/JobResultView.swift:653`; `JobDeliverableTests.swift:169-184` |
| Source analysis | The fields hold the GPS vocabulary: original/derivative/authored, primary/secondary/indeterminate, direct/indirect/negative. Every source starts "not assessed", so the app grades nothing. | NOTE (strength) | `Personas/JobFields.swift:104-106`; `JobFamilyExecutors.swift:224`; `JobAcceptanceScenarioTests.swift:193-196` |
| Research log | Nil results are prompted for and logged. Repository and result are left for the researcher to fill rather than invented. | NOTE (strength) | `Investigate/StudioCasePrefill.swift:301-310`; `PersonaDeliverables2.swift:251-259` |
| Verification level | Five genealogist jobs are "not verified" in the measured matrix (research-plan, ask, ancestor-profile, conflicts, plus the closure service at service level only). | NOTE | `docs/JOB_OUTCOME_MATRIX.md` genealogist rows |

**Verdict: REJECT at 81cf335f.** Re-review to ACCEPT WITH LIMITATIONS once fixed. The lineage chart can show a
relationship the source does not state as a sourced solid line, which the GPS forbids. The fix: draw only accepted
rows solid, and refuse a kin match when another named person stands between A and the kin word.

---

## 2. Investigator

| Area | Finding | Class | Evidence |
|---|---|---|---|
| ACH confidence default | `ACHConclusion.confidence` defaults to `.moderate`. The ACH report always prints "**Confidence:** Moderate" under "Analyst's assessment (opinion)", even when the analyst picked no leading hypothesis and never touched the picker. A judgement nobody made appears in an exported report. | SHOULD-FIX | `Investigate/ACHAnalysis.swift:132, 376-381`; `UI/ACHMatrixView.swift:618` |
| "Findings" report wording | The `inv.findings` work product is assembled deterministically from review-resolved ledger claims. It is headed "Findings", and its mandate line says "workspace", although the scope is the case-authorised versions. Approval is human-gated: rationale, standard of proof, acknowledgment of open contradictions and gaps, and a scope-fingerprint and receipt check. Even so, a reader can take machine-selected claims for the investigator's findings. The case-file report, where allegations are decided by the investigator, is the right home for findings. | SHOULD-FIX | `Export/InvestigationFindingsComposer.swift:45-60`; `Personas/Investigator/InvestigationFindingsService.swift:43-110`; `UI/WorkProductHandoffView.swift:374-386` |
| Custody manifest read errors | `manifest(caseID:)` reads each file's custody history with `try?` and turns a failed read into an empty chain. A custody record that cannot be read looks like "no custody events", with no log line or flag. The case-file custody report says when custody could not be read; this manifest does not. | SHOULD-FIX | `Personas/Investigator/InvestigationCustodyService.swift:62` (cf. `Investigate/CaseFile/CaseOutputService.swift:17-18`) |
| Adverse finding gate | Substantiating an allegation needs a verified documentary passage or a live exhibit (a typed note does not count), a non-empty rationale, and the respondent's response or a stated exception. The report shows supporting, contradicting and neutral links per allegation, states "absence of contrary evidence is not proof", and separates accepted from provisional material. | NOTE (strength) | `Investigate/CaseFile/CaseFileRepository.swift:148-183`; `CaseFileDocuments.swift:264-346` |
| ACH method | An unrated cell is unassessed (not neutral). A preference needs a unique lowest score on fully assessed diagnostic rows. Ties are stated as ties. Evidence is "cited" only once its citation is verified. Diagnosticity treats any difference in symbol as diagnostic, including CC vs C, which Heuer would weigh lightly. The score counts only I/II, so this cannot change a leading hypothesis by itself. | NOTE | `Investigate/ACHAnalysis.swift:213-240, 388-404` |
| Hypothesis confirmation | Confirmation needs at least one supporting citation, a rationale, the contrary evidence addressed and the alternatives considered. Every decision is recorded with the evidence profile at that time. | NOTE (strength) | `Personas/Investigator/InvestigationAnalysisService.swift:85-88`; `InvestigationHypothesis.swift:137-163` |
| Identity resolution | Nothing merges automatically. `entities.merge` is reached only through `confirmMerge` after a recorded proposal. It is reversible, every step is recorded, and both entities must be in the case scope. | NOTE (strength) | `Personas/Investigator/InvestigationIdentityResolutionService.swift:9-52` |
| Exports | One output path: freeze → revalidate → protect → label (draft until approved) → atomic write, read-back and digest. Job-result exports re-check sources and scrub protected identities before writing. | NOTE (strength) | `Investigate/CaseFile/CaseOutputService.swift:5-23`; `App/AppState+Erasure.swift:276-292` |
| Approval API default | `approveFindings(proofStandard:)` replaces an empty rationale with "Approved.", bypassing `blankRationale`. The only UI caller requires a rationale first, so this is an API-level gap only. | NOTE | `Personas/Investigator/InvestigationFindingsService.swift:88-91`; `UI/WorkProductHandoffView.swift:376-377` |
| Data-lab query (open item from the 2026-10-30 pass) | A stated boundary. The query is still filter / group / total with no joins, matching the v1 Workbench contract. It is saved, re-applied and reproducible, and every computed row cites its rows. | NOTE (boundary) | `Personas/JobDeliverableExecutors.swift:1046-1147`; `JobAcceptanceScenarioTests.swift:331-335` |
| Verification level | inv.case-intake, ask, subject-dossier, identity-resolution and contradiction-gap are "not verified" in the measured matrix. Service tests exist for several of them, but none has a job-level acceptance check. | NOTE | `docs/JOB_OUTCOME_MATRIX.md` investigator rows |

**Verdict: ACCEPT WITH LIMITATIONS.** Scope, human-gated identity, ACH discipline and the adverse-finding gate
meet practice. The default ACH confidence, the "Findings" label on machine-assembled claims and the silent
custody read failure should be fixed or stated.

---

## 3. Individual

| Area | Finding | Class | Evidence |
|---|---|---|---|
| "Share safely (redacted)" | The job promises "Prepare a redacted copy to share — sensitive details masked", but no redacted copy is produced. The result is a review register, and its export is the only shareable file. Every row the person keeps, including those marked **Include = withhold** and health rows marked "do not share", is exported with its document name, the identifier counts found, and the document's **first sentence quoted** as the source. The Redactions field is free text and is never applied. A person who shares this "pack" discloses what they chose to withhold. | **BLOCKER** | `Personas/Individual/IndividualPersonaPackage.swift:47`; `Personas/JobFamilyExecutors.swift:476-481` (quote = first sentence); `Personas/JobFields.swift:154-157`; `UI/JobResultView.swift:648-669` (refs printed for every row not rejected) |
| Emergency binder freshness | The binder export prints "**Last reviewed:** \<generation date\>", so it shows the date of export, not of the last review. "Reviewed within the last year" is a boolean that never expires once ticked. The contract scenario "an old address is flagged for review" has no implementation (no per-item date). A binder untouched for years, exported today, tells loved ones it was reviewed today. | **BLOCKER** | `Investigate/PersonaDeliverables2.swift:479, 507, 534, 541`; `UI/PersonaStudiosViews.swift:398`; `Personas/JobContracts.swift:218` |
| Insurance renewal prefill | The insurance register's **Renewal** column is prefilled from the row date, which is the **earliest** date the policy document states (usually the issue or letter date), not the renewal date. The prefilled value is frozen as source-derived, so neither the screen nor the export marks it as a guess. A policy issued 2025-03-01 and renewing 2026-03-01 is listed with Renewal 2025-03-01. | **BLOCKER** | `Personas/JobFields.swift:87-88` (`prefill: .rowDate`); `Personas/JobFamilyExecutors.swift:150, 172` (`date: days.first` of the sorted dates); `Personas/JobResult.swift:162-168` (sourced freeze) |
| Due-today shown as passed | Written dates resolve to **noon local** (checked: "2 November 2026" gives 06:30Z in Asia/Kolkata). Reminders and record flags use `date < now`, so an expiry or deadline due today is shown as "passed" from midday on that day. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:168, 195`; `Investigate/StudioDraft.swift:311-315`; `Knowledge/Entities/EntityExtractor.swift:112` |
| Reminders scope and delivery | `ind.reminders` lists **every** stated date (birth dates, letter dates), each flagged passed or upcoming. It does not filter to renewals and expiries, and it schedules no notification. Local notifications exist only for case tasks. Accepting a row is the confirmation, which is tested. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:189-199`; `UI/CasesView.swift:296-325`; `JobAcceptanceScenarioTests.swift:191` |
| No-advice notice on job exports | Studio exports start with `LegalNotice.reportDisclaimer` ("not legal, financial, or professional advice"). Job-result exports (insurance, health scope, applications/disputes) carry no such notice. | SHOULD-FIX | `UI/JobResultView.swift:639-680`; `Core/LegalNotice.swift:38-44`; `PersonaDeliverables2.swift:532` |
| Health records and Online AI | The `ind.ask` contract says "a health record is not sent to the cloud", but that depends only on the person labelling the document above "confidential" or privileged. Nothing classifies health content. Online mode is opt-in and previewed. `ind.ask` is "not verified" in the matrix. | SHOULD-FIX | `Core/Security/CloudSourceGate.swift:1-13`; `Personas/JobContracts.swift:222`; `docs/JOB_OUTCOME_MATRIX.md` (`ind.ask`) |
| Identifier patterns | Disclosure patterns cover e-mail, phone, US SSN shape and 9–18-digit runs. They miss PAN-style, passport-style and alphanumeric IDs. This is stated ("patterns miss identifiers written in other forms"), and nothing is cleared by default. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:453-459, 476-486` |
| Career entries (fixed item C1 from the 2026-10-30 pass) | Verified closed. An entry must name a person or speak in the first or third person. A gap is shown only after an ending entry and is described as missing records, not as conduct. | NOTE (closed) | `Personas/JobDeliverableExecutors.swift:403-407, 418-437`; `JobAcceptanceScenarioTests.swift:264-268` |
| Property and vault | No ownership is inferred from a mention: one row per document, with the asset entered by the person. Vault hashes come from stored source-version hashes. | NOTE (strength) | `JobAcceptanceScenarioTests.swift:185-190`; `Personas/JobFields.swift:86, 91, 200` |

**Verdict: REJECT at 81cf335f.** Re-review once fixed. A consumer could disclose items they chose to withhold,
rely on a binder falsely shown as just reviewed, or carry a wrong renewal date shown as source-derived.

---

## Status of the open items from `docs/PRACTITIONER_REVIEW_AGENT.md` (2026-10-30) for these personas

| Item | Status at 81cf335f |
|---|---|
| Genealogist: parish-register formulae ("bapt.", "s. of") not read | **Still open.** No abbreviations in the kin or vital patterns, and the sentence splitter breaks at every full stop. |
| Investigator: query language has no joins | **Stated boundary** (v1 Workbench contract); unchanged. |
| Individual: procurement sentence shown as a career entry (C1, marked fixed) | **Closed**, verified in code and in the scenario. |
| General: exports not exercised through the UI | **Still open.** Run k (`docs/evidence/ui-journeys-2026-11-01k/JOURNEYS.md`) exercised no job-result or studio export through the save panel. |
| General: practitioner evaluation with real users | **Still open.** It needs people, not the agent. |

## Counts

| Persona | BLOCKER | SHOULD-FIX | NOTE |
|---|---|---|---|
| Genealogist | 1 | 5 | 4 |
| Investigator | 0 | 3 | 8 |
| Individual | 3 | 5 | 2 |
