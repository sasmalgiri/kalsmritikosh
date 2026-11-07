# Investigations Made Easy — agent execution protocol for “measurably easier”

**Prepared:** 4 November 2026, Asia/Calcutta  
**Status:** Proposed test protocol. No new app benchmark or human study was run to create this document.  
**Companion:** IME Competitive Research and Implementation Plan, 4 November 2026.  
**Purpose:** Establish whether real investigators complete defined, evidence-supported work products with less effort and time using IME, while maintaining the required quality.

## 1. What the agent is authorized to conclude

An agent can inspect the product, prepare fixtures and evaluation materials, run automated tests, exercise the real interface, collect measurements, identify defects and prepare the final analysis. AI-assisted grading can flag issues for review. These activities cannot supply the missing human observations in a claim about human ease of use.

Use three separate evidence records:

| Record | Who performs it | What it establishes |
|---|---|---|
| Engineering verification | Automated tests and agent-operated application runs | Defined functions and failure handling work on the tested configuration. |
| Investigation-quality evaluation | Automated checks plus independent human adjudication of source support and material judgements | Answers and work products meet a specified accuracy/completeness standard on the evaluated material. |
| Comparative usability study | Real intended users performing representative tasks | Whether those people complete those tasks with less time, assistance, repeated work and difficulty. |

A successful agent-operated comparison can identify workflow bottlenecks and justify proceeding to a human study. Label it “agent-operated benchmark”; never count simulated personas or AI judges as participants or human adjudicators.

NIST describes usability evaluation in terms of representative people and tasks, measured completion, errors, time and satisfaction. This protocol adopts that general approach. The numerical IME targets below are proposed product criteria, not thresholds mandated by NIST or an assertion of ISO certification. [S1]

## 2. Register the test before observing the final results

Create a versioned study plan and freeze it before the final evaluation. Preserve later amendments with dates and reasons; do not quietly overwrite thresholds after seeing results.

Record:

- The claim being tested, intended users, workflow families, supported language and scope.
- The exact IME commit, app version/build, binary hash, signing/distribution route and whether the working tree is clean. Use a new candidate identity for changes affecting measured behavior.
- Mac model, CPU, RAM, OS, available disk space and display/input setup; use the intended shipping app on the human-study machines.
- Connection mode, subscribed plan or own-key route, exact provider/model identifier, relevant settings and request budget. Do not rely solely on informal model names.
- Comparator product/version, account tier, enabled features and permitted tools. For a normal-workflow comparator, record each participant's actual toolset.
- Dataset IDs and hashes, question/task versions, source provenance, scoring rubric and the separate location of answer keys.
- Training instructions, participant eligibility, sample-size rationale, randomization, time limits, assistance rules, timing rules and exclusion rules.
- Primary and secondary outcomes, analysis method, quality thresholds and allowed wording for conclusions.

Keep the current accepted product decisions and release gates. The existing research used repository head `d0d6638a`; discover the real current head before running this protocol. Do not reset newer work to that historical revision.

Keep benchmark records outside the production evidence ledger. Store participant IDs rather than names in analysis files. Collect recordings only with permission, restrict access and define retention. The user's real cases, saved folders and provider secrets must not become test fixtures or logs.

## 3. Build three separate collections

### A. Development and regression fixtures

These may be inspected and reused while implementing fixes. Include the existing sample and previously used prosecution/Enron/real-case packs. Do not relabel material used to tune the product as a fresh holdout.

Use controlled cases covering at least:

| Scenario | Required behavior |
|---|---|
| Only surviving evidence is quoted inside a reply | The reading payload retains it and the citation resolves to the original context. |
| Same text appears in separate acquisitions or messages | Content reuse preserves occurrence/version and sender/recipient context; duplicates do not become independent corroboration. |
| One file is locked, one page fails OCR, one attachment is unsupported | Each limitation is visible; reading coverage and answer wording remain accurate. |
| A generated answer's claims fail verification | The product reports failed verification, not proof that the case contains no answer. |
| Two people share a surname | Identity is not silently merged or misattributed. |
| Event, publication and scheduled dates differ | The chronology and answer retain the date roles. |
| A plan is amended or an estimate changes | It is not automatically presented as two incompatible accounts of the same event. |
| One transaction occurs in two records | It is counted once with both sources available. |
| Gross outflow, return and net outflow coexist | Values retain their currency and meaning; a net outflow is not automatically called proven loss. |
| A genuine contradiction and a plausible false alert coexist | Both source passages can be inspected; the false alert can be dismissed durably without hiding the real one. |
| Only part of a requested record set arrives | The request remains partial with the missing items identified. |
| Privilege/scope changes between report preview and writing | The final release check prevents prohibited material from leaving. |
| A job finishes after case erasure, cancellation or scope change | It cannot revive erased content or silently publish stale/broader results. |
| Provider key rejection, timeout, credit exhaustion or rate limiting | Clear failure/blocked state, accurate usage accounting and no silent substitution of a different answering mode. |
| Injected document instructions | They cannot authorize actions, redirect tool use, leak another case or become evidence merely because they occur in a document. |
| App restart, supported backup restore and supported source reingestion | Review decisions, scope and source locators behave according to their declared revision rules. |

Reuse existing suites such as `CaseWholeReadingTests`, `CaseCoverageManifestTests`, `IngestCoverageHonestyTests`, `CaseOutputServiceTests`, `AICreditsTests` and the existing UI journey suite where applicable. Discover the actual current schemes and commands in the repository; do not invent an Xcode command or count compilation as execution.

### B. Matched usability case packs

Create equivalent but different packs for each compared tool. Match approximate pages/bytes, scan proportion, attachments, material facts, irrelevant material, genuine conflicts, namesakes and required outputs. Renaming the same story is not enough to eliminate learning from a previous attempt.

Initial task families:

| Family | Task given to the participant | Required work product |
|---|---|---|
| Supplier payment | Establish the recorded transactions, identify duplicate records and identify what remains unknown. | Source-backed transaction schedule, a qualified finding and a missing-record request. |
| Workplace allegation | Separate the allegation, supporting material, contrary material and response. | Reviewable allegation/evidence summary with response status and limitations. |
| Email chronology | Establish who knew or said what and when, accounting for replies and attachments. | Source-linked chronology and unresolved questions. |
| Public-document research or journalism | Distinguish claims, corrections, allegations and documented outcomes. | Claim-checking brief with sources and qualifications. |
| Identity/history | Resolve what the records support about similar names or relationships. | Identity proposals and a chronology that preserve uncertainty. |

Cover each of the nine advertised personas through the existing acceptance matrix: investigator, lawyer, HR/compliance, forensic accountant, SIU, journalist, researcher/historian, genealogist and individual/family. Shared engineering tests can support several personas. A usability result for one population does not automatically establish a benefit for all nine.

Use task goals rather than click instructions. For example: “Prepare a short, sourced assessment of whether the records establish two payments. Include the relevant transactions, conflicting or missing information and the record you would request next.” Do not tell the IME participant where the successful path is while leaving comparator users unguided.

### C. Fresh quality holdout

Prepare new sources/questions with a source-supported answer rubric after the implementation scope is stable. Keep it isolated from development prompts, model context, app indexes and the operator's access during a blind run.

If an agent helped create the answer keys, use a fresh execution context that has never received them for the blinded run. A process cannot become blind merely by being told to forget a key. Record contamination if that separation cannot be maintained.

For each question, record the material facts required, acceptable qualifications, supporting passages, misleading passages, genuinely unanswerable elements and what would constitute a material error. The rubric should allow semantically equivalent answers; exact string matching is insufficient for narrative answers.

A human must review the key. Neither an unverified AI-generated answer key nor an official allegation automatically establishes the underlying event as true. Score whether the product faithfully represents the record and its uncertainty.

Predeclare the number of model repetitions within the available approved budget. Preserve first-attempt outcomes and separately report retries; never select the best of several answers as the sole result. Repeated calls on the same question measure variability, not additional independent cases. Record model/configuration changes as separate conditions.

If the team uses the holdout to diagnose and fix behavior, move it to regression status and use a new holdout for the subsequent final claim. Preserve original scores; independently documented key corrections must be applied consistently across arms, never selectively to improve IME.

## 4. Execute the engineering and real-app gates first

Run meaningful automated tests for the current changes and the repository's required checks. Then exercise the frozen app through ordinary user-facing controls on a Mac. Verify that test-only switches, canned model answers or direct database writes do not stand in for the behavior under evaluation.

Test AI off separately from each supported shipping AI configuration. A success in one route must not fill the result column for another. External provider outages and spending limits are recorded outcomes, not permission to switch modes invisibly.

For each end-to-end journey, verify:

1. Create/open a case and authorize the intended documents.
2. Inspect intake disposition and reading coverage.
3. Find or ask a material question and inspect the exact source passage.
4. Record a human review decision and its rationale.
5. Add the same reviewed item to the relevant chronology/report without re-entry.
6. Resolve or defer a contradiction and create a collection request.
7. Restart and verify preservation of the work state.
8. Export and reopen the permitted package outside the app.
9. Exercise the relevant source-change, privacy and restore cases.

Run these on the actual distribution-signed/TestFlight candidate when making release-specific assertions. A development walkthrough remains development evidence. A test prevented from launching is blocked, not passed; a required test skipped is not evidence of completion.

Retain screenshots or recordings of test fixtures where useful, logs, output hashes and result artifacts. Screenshots alone do not establish correctness, persistence or a working source link.

**Stop the human comparative study for product repair if** a blocking crash, silent source omission, serious attribution defect, cross-case exposure or unauthorized sending/export is observed. Preserve the failure. After repair, identify the new build and repeat the affected gate; do not pool affected old-build runs into a new candidate's score without a predeclared valid reason.

## 5. Run a formative beginner pilot

Use five real people unfamiliar with IME, distinct from the developers. This is a defect-finding pilot, not the final statistical proof.

Give each person the same outcome-oriented sample task and the app's normal help. Observe where they stall, backtrack, misunderstand a badge, ignore a failure or cannot find the next action. Think-aloud is useful here; keep this separate from the later timed comparison because talking can affect task times.

Record first supported finding, first reviewed export, assistance requests, misunderstood uncertainty and the exact point of failure. The existing proposed criterion is at least four of five completing the sample without live coaching. It is a formative threshold, not a universal usability guarantee.

Fix material pilot failures and repeat the affected journey. Do not keep cycling the same trained participants and label them new beginners. Freeze the candidate again before the comparative study.

## 6. Conduct the human comparison

### Comparators

**Primary:** each investigator's documented normal workflow, such as a PDF viewer, email search, spreadsheet and word processor. Allow its normal relevant features; do not deliberately disable good search or other available capabilities to make IME look faster.

**Additional:** a suitable specialist for the same task, using legitimate available access. Casefleet/CaseMap are plausible evidence-to-chronology/report comparators; DEVONthink or a notebook tool may suit document exploration. Hunchly, Maltego or i2 require collection or link-analysis tasks suited to their actual purpose. Do not force every product to complete a task outside its intended scope.

If no specialist can actually be tested, retain the normal-workflow comparison and limit the claim accordingly. No external account purchase, participant contact or private-source upload is implied merely by this protocol.

### Participants and assignment

Use the pilot to estimate variation and plan the final sample before examining confirmatory results. The earlier plan's 12–20 participants is a practical directional study range, not an automatic statistically adequate number. If the desired claim needs greater precision, calculate the sample size from the intended effect, observed variability and study design.

For a simple two-arm study, balance normal-workflow-first and IME-first. For three arms, an initial 18 participants allows three assignments to each of the six tool orders, provided recruitment and case allocation are balanced. Eighteen is an example of balanced scheduling, not a guarantee of statistical power.

Each participant uses different matched packs across tools and never receives the same underlying case twice. Rotate pack-to-tool assignment so an easier pack is not always assigned to IME. Record relevant professional experience, Mac familiarity and prior familiarity with the comparator.

Provide predefined training and a practice task for unfamiliar tools. Record training effort separately. First-use learning and trained-user execution are different outcomes; report both when measured. During timed tasks, permit normal in-app help but no unrecorded coaching. Record moderator interventions and analyze assisted completion separately.

### Session procedure

1. Confirm participant consent and use only the approved test material.
2. Check machine, app build, account/configuration, storage, network and available credits. Log the check.
3. Deliver the assigned task brief and source pack. Start timing at the same declared point for every arm, before importing the task's files.
4. Let the participant work normally. Observe without directing them. Instrument the application without materially changing its performance.
5. The participant submits the requested work product when they believe it is ready, or the fixed task time limit expires. Save the artifact and timestamp. Capture failures and abandonment.
6. Ask the same short post-task questions: “How difficult was this task?” and “How confident are you that the sources support your output?” Use a declared 1–7 scale and collect one reason. Confidence is not evidence of correctness.
7. Independently grade the work product afterward. The answer key stays hidden during the timed session.
8. Move to the next assigned tool and a different matched pack. Record fatigue or interruptions.

Allow the same necessary human judgement in every arm. The agent must not act as an expert co-investigator for IME participants while comparator participants work alone.

## 7. Measure the whole task and keep failures visible

Primary outcome: time to a submitted work product meeting the declared quality standard. Include file preparation within the task, import/index waiting, searching, source inspection, correction, review and export/reopening. Record active human time separately from elapsed time so cloud waiting and human effort remain distinguishable.

The post-task grader determines whether the submission meets the predeclared standard. No unrecorded repair after the timer stops can rescue the original submission. A repaired follow-up is a separate record with its additional time.

Prespecify a common time limit `L` for each matched task class. For the all-attempts comparative score define:

`T* = elapsed submission time if the submission meets the quality gate; otherwise L.`

This is a **capped time-to-acceptable-output score**, not a claim that failed users actually completed at `L`. Retain raw time, failure status and completion rates alongside it. An early wrong answer, abandonment or crash therefore cannot count as a fast success. If everyone reaches the cap, the task supplies no timing advantage evidence.

Do not turn a reduction in this capped score into a literal “completed X% faster” statement when unsuccessful tasks contribute artificial cap values. A literal completion-time statement uses observed successful completion times, discloses that subset and accompanies it with all-attempt completion/quality results. Predeclare both summaries so the reporting choice cannot be made to favor IME.

For participant `i` on a matched task pair:

`saving_i = 100 × (1 − T*_IME,i / T*_baseline,i)`

Use the preregistered aggregation, such as the median of paired savings. Do not switch to a ratio of unrelated group means because it produces a more favorable headline. Publish task-family and user-group results before an overall summary.

Secondary measures:

- Correct and unassisted completion rates.
- Human active time, waiting time and export-repair time.
- Required material facts recovered and material claims unsupported or misattributed.
- Citation locator failures and unrepresented input items.
- False alerts, true material conflicts found and minutes spent reviewing unhelpful alerts.
- Repeated entry of already reviewed text, lost navigation position and assistance requests.
- Difficulty ratings and participant explanations.
- Actual provider-reported usage, plan credits or own-key cost, retry/failure charges and billing uncertainty. Subscription allocation is separate from marginal model cost.

Calculate uncertainty at the independent unit supported by the design. For a fixed benchmark pack, a paired participant-level analysis can describe those packs. Treating every click or question from one participant as an independent person exaggerates the sample. Generalizing to new case populations requires an analysis accounting for case sampling as well, not merely more questions about the same few cases.

## 8. Grade quality independently

Have two qualified human reviewers assess material claims and outcomes independently, with disagreements resolved by a third reviewer or a documented reconciliation. Where feasible, conceal the producing tool and condition without changing substantive content or source references. Disclose any incomplete blinding. Reviewers need the original source pack and rubric, not just the answer text.

The agent can prepare review sheets, locate cited passages and flag possible discrepancies. It must not fabricate a human sign-off or resolve a substantive professional dispute by silently selecting its own preferred answer.

For every submitted product evaluate:

| Dimension | Check |
|---|---|
| Source fidelity | Each material assertion is supported by the cited passage with appropriate context and attribution. |
| Completeness | Required material facts, contrary evidence and specified limitations are included. |
| Identity and event accuracy | People, organizations, transactions, date roles and procedural stages are not conflated. |
| Appropriate uncertainty | Allegations, hypotheses, unassessed issues and findings remain distinguishable. |
| Traceability | A recipient can resolve the required references using the permitted handover materials. |
| Scope and protection | Other cases and prohibited source content do not enter the answer or export. |
| Practical usability | The output fulfils the task brief without substantial unmeasured repair. |

Before the study, define critical errors and indispensable facts with the relevant practitioner. A false accusation caused by misattribution, an invented material transaction, an unsafe disclosure or the omission of a decisive qualification cannot be offset by a high average score elsewhere. A source asserting something and the event actually occurring are different propositions.

Maintain the earlier proposed completeness and quality targets, documenting which are adopted before the run. A statement that quality is “no worse” needs a defined comparison and enough evidence; similar averages or a statistically nonsignificant difference alone do not prove equivalence. Report actual completion, omission and error counts even when both arms pass a minimum quality standard.

### The separate ≤1% answer gate

Use the product's existing accepted definition and denominator; record them explicitly before running. Do not redefine them after seeing the new results. At minimum publish:

- Total planned and actually evaluated questions by mode and task family.
- Fully correct answers; partially complete answers with no material falsehood; answers with at least one material error.
- Correct abstentions when the source cannot answer; avoidable abstentions when it can.
- Provider/tool failures, cancellations and unexecuted questions.
- Wrong answers divided by evaluated attempts, and wrong answers divided by substantive answers; state the exact membership of both denominators.
- Material-fact recall, wrong material-claim count and the reviewer's reasons.

A high refusal rate cannot establish useful accuracy. Do not pool a failing family or configuration into a larger successful group. Describe uncertainty and insufficient data honestly.

For illustration of sample-size limits, zero errors in 300 independent Bernoulli trials gives a one-sided 95% upper bound of about 1%. Many questions about a small number of related cases are not 300 independent trials. The fresh holdout and analysis must reflect case dependence. No fixed question count in this protocol automatically proves a population error rate below 1%.

## 9. Measure responsiveness, recovery and cost separately

Use the actual supported Mac baseline and a declared lower supported configuration when available. Do not generalize a developer's high-end machine to the support floor. Report gaps when a configuration could not be tested.

Use separate declared workloads: a small mixed case, a larger document case and a scan/attachment-heavy case within the intended support envelope. Specify pages, bytes, objects, source occurrences and scan proportion. The earlier 4,000-document/1.1 MB synthetic benchmark is not a substitute for these workloads.

Measure cold and warm import/opening, search, source opening, scrolling/review, export, cancellation/restart and peak memory/disk requirements. Preserve raw latency samples and report p50, p95 and maximum with sample counts. The existing proposed targets are p95 source opening under one second and search under two seconds on the declared supported corpus; these are targets to measure, not assumed capabilities.

Separate local latency from Online request latency. Record actual model/configuration, request/response timestamps, payload/token sizes where safely available, cache outcomes, usage and failure class. Do not assume prefix reuse always produces a billed cache hit. Check enough permitted budget before beginning without silently raising accepted spending caps.

Test key rejection, timeout, rate limiting, cancellation and exhausted credits in a controlled fault suite. Keep deliberately injected faults identifiable; record naturally occurring failures in the usability study as they occur. Predeclare what qualifies as an unrelated laboratory interruption and publish exclusions rather than deleting inconvenient product failures.

## 10. Instrumentation and required deliverables

Use existing product test infrastructure where possible. Add evaluation logging in a test session mode, not unsolicited production telemetry. Capture event IDs, monotonic durations and timestamps without API keys or unnecessary evidence content. Reading a source is human activity; do not classify silent reading as idle merely because there are no keystrokes.

Suggested events include task started, import started/completed, coverage inspected, question sent, answer ready, citation opened, decision saved, issue dismissed, request created, result carried to report, export started/completed, artifact submitted, help requested, task abandoned and failure. Stable run/task/participant IDs link events to artifacts. Logs must not themselves modify the evidence under test.

Create one evaluation package tied to the candidate. Suggested repository destinations follow; adapt to existing conventions instead of creating a second status system.

| Deliverable | Contents |
|---|---|
| `docs/evaluation/measurably-easier/PROTOCOL.md` | Frozen questions, design, endpoints, sample-size rationale, thresholds, exclusions and claim rules. |
| `candidate.json` | Commit, build/binary identity, signing, hardware, OS, tool versions, model/plan/settings and benchmark configuration. No credentials. |
| `datasets/manifest.json` | Pack hashes, provenance, sizes, mode/scope constraints and holdout/regression classification. |
| `tasks/` | Participant task briefs, matched-pack assignments and declared time limits. |
| `rubrics/` | Separately access-controlled source-supported grading rubrics; exclude from app imports and operator context during blinded runs. |
| `runs/events.jsonl` | Append-only observed events; every run has a completion or explicit terminal failure/blocked state. |
| `runs/outcomes.csv` | One row per participant/task/condition with raw and capped time, result state, assistance, quality scores, cost and artifact reference. |
| `adjudication/` | Original independent ratings, disagreements, resolutions and disclosed answer-key amendments. |
| `analysis/` | Reproducible analysis scripts, declared estimands and uncertainty calculations. Test the analysis on explicitly synthetic records before using real data. |
| `evidence/` | Permitted UI evidence, exported work products, source-link checks and relevant logs. Restrict human recordings appropriately. |
| `RESULTS.md` | Full results, errors, missing data, limitations and whether each predeclared criterion passed. |
| `CLAIM_DECISION.md` | Exact supported wording, configuration/task limits, comparison scope and unproven claims. |

Suggested outcome fields:

`study_id, protocol_version, run_id, participant_id, persona_group, experience_group, tool_condition, tool_version, build_hash, task_family, pack_id, order, started_at, submitted_at, raw_elapsed_seconds, active_seconds, waiting_seconds, time_limit_seconds, capped_time_score_seconds, submitted, quality_pass, unassisted, assistance_count, material_claim_count, wrong_material_claim_count, required_facts_count, correct_required_facts_count, citation_failures, true_conflicts_found, false_alerts, repeated_entry_count, difficulty_rating, usage_cost, cost_status, terminal_state, artifact_hash, exclusion_reason`

Use null plus an explanatory status for unmeasured values. Never use zero to represent “not measured.” Keep raw records immutable; analysis corrections create traceable revisions. Participant-identifying information belongs in a separate restricted record.

## 11. Decision rules and exact claim boundaries

The following targets come from the implementation plan and must be adopted or explicitly amended before the final study. They are not claims of achieved performance.

| Gate | Decision rule |
|---|---|
| Technical integrity | Required controlled cases pass; no unresolved blocking source-fidelity, scope, privacy, persistence or export defect. |
| Formative usability | Proposed four of five new users finish the sample without live coaching; major misunderstandings are repaired before the final study. |
| Human time benefit | Proposed median paired capped-time reduction of at least 30% against the declared normal workflow, with uncertainty supporting a positive benefit and no concealed completion/quality tradeoff. |
| Specialist comparison | Proposed 20% median reduction is an additional target only when that specialist and matched task are actually tested. |
| Work-product quality | Predeclared completeness, critical-error and source-traceability criteria pass; comparison meets the adopted standard for no material loss of quality. |
| AI accuracy | The existing ≤1% wrong gate passes as defined for each applicable mode/family, with refusals, useful coverage and uncertainty reported. |
| Claim scope | Wording names the tested population, task class, condition and comparator; other personas/modes are not silently included. |

An interval that includes no improvement means a general positive time-benefit claim remains inconclusive. A point estimate of 30% does not establish that the population saving is at least 30%. To assert a lower-bound saving, the analysis must support that lower bound. A descriptive statement about the observed study can report its estimate and interval directly.

Produce one of these conclusions:

1. **Technical tests passed; human benefit unmeasured.** Human sessions are missing or invalid. State this even if an AI agent completed the app very quickly.
2. **Benefit observed for the tested workflows.** Report actual results and uncertainty, and the satisfied quality standard. Limit the claim to the tested conditions.
3. **Comparison inconclusive.** Precision is inadequate, key data are missing, or the quality comparison cannot support the desired wording. Specify the remaining evidence rather than inventing a pass.
4. **Target not met.** Identify where time, quality, completion or cost failed. Repair the largest measured obstacle and evaluate the new candidate under an appropriate fresh protocol.

### Claim templates

**When only agent/automated testing is complete:**

“This build passed the specified automated and agent-operated investigation workflow tests. Human comparative usability has not yet been measured.”

**When human comparison supports the stated result:**

“In a [N]-participant evaluation of [specified workflows], [specified users] using IME [build/configuration] achieved [observed result, with interval] versus [named workflow/tool]. [Completion counts] met the predefined source-support and completeness standard. Results apply to the tested cases and conditions.”

**When an AI-enabled arm wins but AI off is untested or does not win:**

“The observed benefit applies to the tested Online configuration.” Do not advertise that timing as an offline result.

Do not turn one successful fixture into “all investigations are easier,” describe an agent run as a human pilot, claim superiority over an untested competitor, or remove unsuccessful participants from the headline. Competitive viability and App Store release readiness remain distinct questions; this study supplies evidence about defined user workflows.

## 12. Final instructions for the agent

Proceed with baseline discovery, fixtures, instrumentation, regression tests, real-app walkthroughs, participant materials and analysis preparation. Fix reproducible product defects and record the changed candidate. Most of this work is autonomous.

Before any external communication or new paid account, use the existing authorization rules. Independent people must supply actual usability observations and human adjudication; do not silently replace them with simulated roles. If a dependency prevents those steps, complete the remaining independent work and leave the corresponding evidence state accurately pending.

Finish by delivering the evaluation package and a concise conclusion naming the exact candidate, observed time/quality/cost results, blocked tests and the wording the evidence supports. The goal is a reproducible result that could survive an independent rerun, not a checklist that always returns a favorable answer.

## Sources and relationship to the existing plan

- **S1 — [NIST, Usability Testing](https://www.nist.gov/programs-projects/usability-testing):** General basis for representative-user/task evaluation and effectiveness, efficiency and satisfaction measures. Consulted 4 November 2026. The detailed IME design and thresholds in this document are proposals developed for this product.
- **S2 — [NIST, Industry Usability Report project overview](https://www.nist.gov/itl/tted/iusr-project-industry-usability-report):** Historical explanation of reporting product versions, users, tasks, design and results. This archived overview is used as reporting background, not as a current certification requirement.
- **[IME Competitive Research and Implementation Plan, 4 November 2026](https://chatgpt.com/library?file_id=libfile_a4486a7fcacc8191a876d6429fd4569e&account_id=personal):** Current companion plan, especially its acceptance fixture, milestones, proposed targets and persona matrix. This protocol operationalizes those targets and clarifies failures, timing, independent review and claim limits.
