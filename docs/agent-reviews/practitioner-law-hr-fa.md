# Practitioner review — Lawyer, HR / workplace compliance, Forensic accountant

**AGENT REVIEW — not a human practitioner review (owner direction 2026-11-01).**

- Reviewer: Claude agent (practitioner reviewer)
- Date: 2026-11-01
- Commit: 81cf335f (branch investigations-next)
- Scope: read-only review of code, tests and docs. No build, test run or UI session was performed for this review.

## Method

For each persona I took the job contract (`Kalsmritikosh/Personas/JobContracts.swift`), the result columns
(`JobFields.specs`), the completion rules (`JobFields.completionProblems`), the executor assigned in
`JobExecutorKind.assignments` (`JobExecutors.swift`) and its code (`JobFamilyExecutors.swift`,
`JobDeliverableExecutors.swift`). I then followed the result into the tools a practitioner would export from:
legal production (`Export/LegalProduction.swift`, `UI/LegalProductionView.swift`), the privilege log studio
(`Investigate/PrivilegeLog.swift`), the case file allegation gate (`Investigate/CaseFile/CaseFileRepository.swift`),
the workplace investigation studio (`Investigate/WorkplaceInvestigation.swift`) and the forensic schedule
(`Investigate/FAMoney.swift`, `Investigate/ForensicEngagement.swift`). I checked each against the acceptance
scenarios (`KalsmritikoshTests/JobAcceptanceScenarioTests.swift`, `JobDeliverableTests.swift`) and against the
measured matrix (`docs/JOB_OUTCOME_MATRIX.md`). I judged each finding against the professional standard named
in the brief. Classes:
**BLOCKER** means a practitioner could be misled or harmed, so it must be fixed before release.
**SHOULD-FIX** is a meaningful gap; release is acceptable with the limitation stated.
**NOTE** is an observation or a strength.

---

## 1. Lawyer / litigation support

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Production scope | The production set is built from the whole ledger, not from one matter. Documents coded privileged in the `law.document-coding` result of *every* case are **added** to the set, including documents that are not responsive in the matter being produced. Each gets a slip sheet, and its **file name** goes into `PRIVILEGE_LOG.csv` and the DAT load file that are served on the other side. The review codes (Responsive/Hot/Privileged) are also ledger-wide. With two matters in one ledger, producing matter A serves matter B's privileged documents: their existence, Bates numbers and file names (for example "Memo to counsel re settlement.docx") go to A's opposing counsel. No test covers production scope. The only production test drives `ProductionBuilder` directly with a hand-made list. | **BLOCKER** | `UI/LegalProductionView.swift:17-55` (no case parameter; `ids.formUnion(coded)` at :34); `Personas/JobResult.swift:350-357` (`codedPrivilegedObjectIDs`: no `case_id` filter); `Export/LegalProduction.swift:217-222` (log line with `doc.fileName`), `:55-63` (DAT FILENAME column); `Storage/Repositories/PlanFeatureRepositories.swift:190-195` (review codes ledger-wide); `KalsmritikoshTests/JobDeliverableTests.swift:73-95` |
| Privilege log basis | The production's `PRIVILEGE_LOG.csv` has only BEGBATES, ENDBATES, FILENAME, DOCID and BASIS, and BASIS is always the literal "Privileged". It has no date, author, recipients, privilege type (AC/WP) or a description that lets the claim be tested, so it does not meet FRCP 26(b)(5)(A), and it puts the file name where a description belongs. The privilege log studio does carry AC/WP/both and a description, but it is not connected to the production run. Document coding has no basis field either. | SHOULD-FIX | `Export/LegalProduction.swift:181, 219`; `Investigate/PrivilegeLog.swift:23-41, 168-171`; `Personas/JobFields.swift:77-78` |
| Partly privileged documents | A document coded "partly privileged" is withheld whole behind a slip sheet. No redacted copy is produced, so non-privileged content is over-withheld. The result states this as a limitation. | SHOULD-FIX | `Export/LegalProduction.swift:192-194`; `Personas/JobDeliverableExecutors.swift:466`; `DocumentCodingProduction.withholdingCodes` `:474` |
| Obligations / fact–element matrix | `law.obligations` and `law.fact-evidence` run the generic fact matrix: their rows are ledger "label: value" facts, not contract clauses or claim elements. Elements that no document states never appear and must be typed in. This is stated for elements. For obligations, the contract's "clause, party, trigger" register gets no clause extraction. | SHOULD-FIX | `Personas/JobExecutors.swift:43`; `Personas/JobFamilyExecutors.swift:265-305` (limitation at :304); `Personas/JobContracts.swift:83, 87` |
| Damages totals | The `law.damages` headline "distinct" total counts an amount once when the same normalised sentence appears in another document, and labels it "not a second amount". That contradicts the app's own forensic rule that two equal payments are two payments unless a transaction reference matches. The normaliser also strips currency symbols, so "Paid €1,000 to X" and "Paid £1,000 to X" collide. The plain sum of all mentions is shown beside the distinct total. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:413-436`; `Personas/JobDeliverableExecutors.swift:44-47`; `Investigate/FAMoney.swift:8-9`; `Investigate/ForensicEngagement.swift:169-172` |
| Bates in the exhibit binder | Binder Bates numbers come from the row index (`PROD-000001`…). They are labelled a proposal that production replaces. | NOTE | `Personas/JobFields.swift:72-76, 202` |
| Produced images | Production pages are PDFs rendered from the extracted (and optionally pattern-redacted) text, not images of the original pages, so layout is lost. On the plus side, a redacted document's native file is never produced. | NOTE | `Export/LegalProduction.swift:186-216` |
| Deadlines | Only deadlines a document states with a date are listed, each "unconfirmed". Rule-based deadlines (for example 30 days after service) are not computed, and this is stated. There is no per-deadline "confirmed by / on" field: confirmation is the row's acceptance plus the reviewer and time of the result-level review. | NOTE | `Personas/JobFamilyExecutors.swift:539-553`; `Personas/JobFields.swift:165`; `Personas/JobResult.swift:241` |
| Deposition outline | Every sentence that names a person becomes a "Put to X" question, so large matters will produce long, noisy outlines. Each question cites its passage. A disputed point shows both sources. A question with no passage cannot be accepted. | NOTE | `Personas/JobDeliverableExecutors.swift:641-673`; `Personas/JobFields.swift:271-274`; `JobDeliverableTests.swift:41-47` |
| Strengths | A privileged code withholds fail-closed (an undecided row still withholds). A withheld document's text and native are never produced. Bates numbers run continuously across runs. Party merges are human and reversible. Witness inconsistencies quote both statements. | NOTE | `Personas/JobDeliverableExecutors.swift:478-484`; `Export/LegalProduction.swift:205-216`; `JobAcceptanceScenarioTests.swift:252-292` |

**Previous open items (docs/PRACTITIONER_REVIEW_AGENT.md, Lawyer)**
- *Partly privileged → redacted copy:* **still open.** It is a stated limitation (`JobDeliverableExecutors.swift:466`); production withholds the whole document (`LegalProduction.swift:192`).
- *Privilege-log basis always "Privileged":* **still open in production** (`LegalProduction.swift:219`) and in document coding (`JobFields.swift:78`). AC/WP exists only in the separate privilege log studio (`PrivilegeLog.swift:23-41`), which the production does not use.

**Verdict: REJECT** — a production for one matter can serve another matter's privileged document names and slip sheets to opposing counsel, because the production set and the privilege coding are not scoped to the matter.

---

## 2. HR / workplace compliance investigator

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Allegation worksheet | `hr.allegations` runs the generic fact matrix, so its rows are document facts ("label: value"), not allegations. The person types the allegation, the response and the stance onto fact rows. The worksheet has no finding field and no link to the case-file allegations where the finding is recorded. The contract's acceptance rule ("an allegation without a response opportunity cannot be found substantiated") is enforced in the case file and the studio, not in this job. | SHOULD-FIX | `Personas/JobExecutors.swift:43`; `Personas/JobFields.swift:114-115`; `Personas/JobContracts.swift:104` |
| Interview plan fairness rule | `hr.interview-prep` has one row per named person: complainant, witnesses and respondent alike. Completion requires "Response opportunity: given" on every accepted row. That puts the respondent-only fairness rule onto witnesses, does not map to individual allegations, and makes a *preparation* plan impossible to complete before the interviews have happened. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:341-364`; `Personas/JobFields.swift:133, 252-255`; `JobAcceptanceScenarioTests.swift:206-209, 436-437` |
| Credibility | `hr.credibility` runs the source-reliability executor, so its rows are per document. Credibility is assessed per witness account. The fields (consistency, corroboration, plausibility, reasons) are right, but they sit on the wrong unit. No app grading takes place: rows stay "not assessed". | SHOULD-FIX | `Personas/JobExecutors.swift:41`; `Personas/JobFields.swift:101-103`; `JobAcceptanceScenarioTests.swift:193-196` |
| Corrective actions closed with evidence | An action marked done needs only a free-text closure note. The effectiveness review's "evidence of effect" is free text too. Neither requires a linked source, so closure "with evidence" rests on the investigator's say-so. Owner and due date are required, and an ineffective action does reopen its register row. | SHOULD-FIX | `Personas/JobFields.swift:40-44, 306-311`; `Personas/JobResult.swift:250-264` |
| FTC disclosure review | `hr.disclosure-review` (FTC Endorsement Guides) runs the PII disclosure executor. It finds email addresses, phone numbers, ID-like numbers and health terms, not endorsements or material connections, so every row must be built by hand. | SHOULD-FIX | `Personas/JobExecutors.swift:55`; `Personas/JobFamilyExecutors.swift:452-487`; `Personas/JobFields.swift:158-161` |
| Adverse-finding gate (case file) | A "substantiated" disposition needs a verified passage or live exhibit, which is strong. It also needs a non-empty response *or* a stated exception, but the response is free text with no put / awaiting / declined state. The studio has that state; the case file does not. A decision taken under an exception is printed in the report's limitations. | NOTE | `Investigate/CaseFile/CaseFileRepository.swift:144-178`; `Investigate/CaseFile/CaseFileDocuments.swift:350-351`; `Investigate/WorkplaceInvestigation.swift:54-80` |
| Findings by a human, standard of proof | Findings are classified only by the person. The standard of proof must be chosen before findings can be approved, and it is printed as chosen. A substantiated or partly substantiated finding needs supporting evidence, a statement of how contrary evidence and mitigation were weighed, and the respondent's response (or a recorded decline). "Unsubstantiated ≠ false complaint" is printed. Recommendations are omitted unless the mandate authorises them. | NOTE (strength) | `Investigate/WorkplaceInvestigation.swift:54-67, 156-157, 197, 263, 318-342` |
| Statements compared, not judged | Comparison is point by point on dates and amounts, with verbatim quotes. A speaker is tied to the reporting verb or left unassigned, and an unassigned speaker blocks completion. "Same figure" is stated narrowly, and a denial against an assertion is shown as differing. | NOTE (strength) | `Personas/JobDeliverableExecutors.swift:489-568`; `Personas/JobFields.swift:275-278`; `JobAcceptanceScenarioTests.swift:273-282` |
| Unverified HR jobs | `hr.complaint-intake`, `hr.parties` and `hr.name-resolution` give generic rows only and are "not verified" in the measured matrix. `hr.statements` was blocked on the sample case (no attributed statement). | NOTE | `docs/JOB_OUTCOME_MATRIX.md:162-169` |

**Previous open items (docs/PRACTITIONER_REVIEW_AGENT.md, HR)**
- *Statement "point" is a word cluster:* **now a stated boundary.** The point and event fields are editable, and the limitation tells the person to correct them (`JobFields.swift:122-124`; `JobDeliverableExecutors.swift:565`).
- *D4 empty-workspace message (marked fixed in the earlier pass):* not re-verified here (no UI run).

**Verdict: ACCEPT WITH LIMITATIONS** — the human-finding, response-opportunity and evidence gates that protect the respondent are enforced where findings are recorded. However, several HR jobs are seeded from the wrong unit (facts, documents, every person), and their limitations should be stated.

---

## 3. Forensic accountant

| Area | Finding | Class | Evidence |
|---|---|---|---|
| Repeated-statement dedup in funds tracing | `fa.funds-tracing` uses the same money executor as damages. An equal amount in an identically worded sentence in another document is flagged "one statement filed again, not a second amount; counted once" and dropped from the headline *distinct* total. Recurring payments with identical narration (for example monthly statements) would be under-counted, and the flag states a conclusion the evidence does not support. The app's own studio rule excludes a copy only when the transaction references match. Currency symbols are stripped before the comparison. The acceptance test checks only that two rows exist, not the totals. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:413-436`; `Personas/JobDeliverableExecutors.swift:44-47`; `Investigate/ForensicEngagement.swift:169-172`; `Investigate/FAMoney.swift:8-9`; `JobAcceptanceScenarioTests.swift:219-220` |
| Computed figures cannot trace | Workpapers are generated only from amounts the documents state. A report figure that is a computed sum or difference is flagged "untraced" and cannot be accepted. A hand-added workpaper never clears that flag, because the trace never consults person-added rows. The tested "fix" is to *reject* the figure, so every computed total in a report ends up rejected rather than supported. | SHOULD-FIX | `Personas/JobDeliverableExecutors.swift:681-718` (papers from `statedAmounts` only, :687-695); `Personas/JobFields.swift:283-286`; `JobDeliverableTests.swift:49-52` |
| Workpaper sourcing and sign-off | The `fa.workpapers` columns are only calculation and inputs. It is not in the list of jobs whose rows must cite a source, so a hand-added workpaper with no source can be accepted. The contract's "source links, reviewer sign-off" becomes one result-level review (who, when, note), with no preparer/reviewer split and no per-workpaper sign-off, which falls short of AICPA-style workpapers. | SHOULD-FIX | `Personas/JobFields.swift:152, 237-240`; `Personas/JobContracts.swift:130`; `Personas/JobResult.swift:239-246` |
| Trace by value equality | A report figure "traces" when any stated amount has the same normalised characters. A coincidentally equal figure is shown as supported. The reverse also happens: "USD 1,000" vs "1,000 USD" and "€1,000" vs "EUR 1,000" do not match, giving false "untraced" flags. That direction is safe. | SHOULD-FIX | `Personas/JobFamilyExecutors.swift:244-246`; `Personas/JobDeliverableExecutors.swift:697-709` |
| Missing-records / payee jobs unverified | `fa.discrepancies` ("absence ≠ fraud"; "a missing month is shown as missing, not as loss"), `fa.payee-workup` and `fa.entity-resolution` give generic rows and are "not verified". The schedule studio does show missing months, but the job named for discrepancies has no verified work product. | SHOULD-FIX | `docs/JOB_OUTCOME_MATRIX.md:150-152`; `KalsmritikoshTests/ForensicEngagementTests.swift:131` |
| Tracing method applied by the accountant | Funds tracing is a manual workpaper: the person links the accounts, classifies the transfer, handles duplicates and reversals, says what it reconciles to, and names the method (direct, LIBR, pro rata, FIFO). The app computes no allocation, and this is stated. A transfer to the same account is refused. | NOTE (boundary) | `Personas/JobFields.swift:143-151, 262-265`; `JobAcceptanceScenarioTests.swift:445-446` |
| Per-currency arithmetic | Money is Decimal. Totals are per currency only. A bare "$" or "¥" is not assumed to be any currency. "1.234" is refused as ambiguous, and magnitude words are refused. In the studio, gross, returned and net are kept apart, balances reconcile, and approval is cut when content changes. | NOTE (strength) | `Investigate/FAMoney.swift:53-112, 141-175`; `Storage/Repositories/StudioRecordRepository.swift:242`; `ForensicEngagementTests.swift:78-146` |
| Rounding for non-2-decimal currencies | `FAMoney.format` always rounds to 2 decimals with banker's rounding. A 3-decimal currency (KWD/BHD/OMR) is shown rounded in totals, and JPY is shown with ".00". | NOTE | `Investigate/FAMoney.swift:115-122` |
| Hypotheses | `fa.analysis` lists causal sentences as "hypothesis — not a finding" and asks for an alternative explanation. It is blocked when no document states a cause, as on the sample case. | NOTE | `Personas/JobFamilyExecutors.swift:369-391`; `docs/JOB_OUTCOME_MATRIX.md:154` |

**Previous open items (docs/PRACTITIONER_REVIEW_AGENT.md, Forensic accountant)**
- *LIBR/FIFO/pro-rata not computed:* **a stated boundary** (`JobFields.swift:143-145`). The method is recorded as the accountant's.
- *A computed figure needs a workpaper the person adds:* **still open, and narrower than the earlier pass stated.** Adding the workpaper does not make the figure trace; the figure can only be rejected (see "Computed figures cannot trace").

**Verdict: ACCEPT WITH LIMITATIONS** — the money arithmetic is sound and conservative, and nothing is concluded for the accountant. However, the workpaper trail cannot carry a computed figure or a per-workpaper sign-off, and the funds-tracing "distinct" total can under-count recurring payments. These must be stated or fixed.

---

## General

- Exports through the system save panel and a UI run of these jobs were **not verified** in this review.
- I did not re-run any test. Statements about tests are read from the test source.
- Counts: Lawyer 1 BLOCKER, 4 SHOULD-FIX; HR 0 BLOCKER, 5 SHOULD-FIX; Forensic accountant 0 BLOCKER, 5 SHOULD-FIX.
