# Measurably easier — frozen evaluation protocol (v1)

**Frozen:** 12 November 2026, Asia/Kolkata, by the agent (smart-map S14, BENEFIT-01), before any comparative run.
**Source:** `docs/IME_Measurably_Easier_Test_Protocol_2026-11-04.md` (proposed). This file adopts its design and
thresholds as written; it adds nothing that favours the candidate. **No comparative run, pilot or human session has
happened.** The owner may amend this protocol only through the amendment log below, before the first scored session.

**Integrity.** `PROTOCOL.sha256` holds the SHA-256 of the frozen rules (everything above the line "## Amendment log").
`ci/guards/evaluation-protocol-frozen.sh` fails the guard run if the rules change without the hash being updated
together with a dated amendment entry naming who changed what and why. A changed rule after any scored session
starts a NEW protocol version (v2) and its results are never pooled with v1.

## 1. Claim under test

"Investigators complete the defined, evidence-supported work products below with less total effort and time in
Investigations Made Easy than in their documented normal workflow, at no material loss of quality." English, macOS,
the nine advertised personas grouped into the five task families of §2. A result for one family or persona group is
never generalised to another.

## 2. Tasks (fixed)

| ID | Family | Task brief given to the participant | Required work product | Time limit L |
|---|---|---|---|---|
| T1 | Supplier payment | Establish the recorded transactions, identify duplicate records and what remains unknown. | Source-backed transaction schedule, a qualified finding, a missing-record request. | 60 min |
| T2 | Workplace allegation | Separate the allegation, supporting material, contrary material and response. | Reviewable allegation/evidence summary with response status and limitations. | 60 min |
| T3 | Email chronology | Establish who knew or said what and when, accounting for replies and attachments. | Source-linked chronology and unresolved questions. | 60 min |
| T4 | Public-document research / journalism | Distinguish claims, corrections, allegations and documented outcomes. | Claim-checking brief with sources and qualifications. | 60 min |
| T5 | Identity / history | Resolve what the records support about similar names or relationships. | Identity proposals and a chronology that preserve uncertainty. | 60 min |

Briefs state goals, never click paths. The same brief text is given in every arm.

## 3. Equivalent case variants (fixed rule)

For every task, three matched packs (A, B, C), each a different underlying case, matched within ±10 % on pages and
bytes, the same scan proportion (±5 points), the same counts of attachments, material facts, irrelevant documents,
genuine conflicts and namesakes, and the same required outputs. Renaming one story is not a variant. Pack-to-tool
assignment is rotated so no pack is always used with this app. Pack hashes are recorded in `datasets/manifest.json`
before the first session; a pack changed after that is a new pack.

## 4. Baseline and comparators

- **Primary baseline:** each participant's documented normal workflow (their PDF viewer, mail search, spreadsheet and
  word processor), with its normal features; nothing disabled.
- **Additional comparator:** a specialist tool only where it is actually available and the task suits its purpose;
  otherwise the claim is limited to the primary baseline.

## 5. Design

- Formative pilot first: five people new to the app, the sample task, normal help only. Pilot criterion: at least four
  of five finish without live coaching. Pilot data is never pooled with the comparison.
- Comparison: within-subject; two arms balanced app-first / baseline-first (three arms: each of the six orders used
  equally). Planned 12–20 participants for a directional study; a larger claim requires a sample size computed from the
  pilot's variability before any confirmatory session. No participant sees the same underlying case twice.
- Training and a practice task for unfamiliar tools, recorded separately. In-app help allowed; any moderator help is
  recorded and analysed as assisted completion.

## 6. Endpoints (fixed)

- **Primary:** capped time to an acceptable output, `T* = elapsed submission time if the submission passes the quality
  gate, else L`, timed from the same declared start (before importing the task's files) to submission.
- **Per participant:** `saving_i = 100 × (1 − T*_app,i / T*_baseline,i)`; aggregated as the **median of paired savings**
  with a bootstrap 95 % interval over participants. No other aggregate is used for the headline.
- **Secondary:** correct and unassisted completion rates; active vs waiting time; required facts recovered; unsupported
  or misattributed material claims; citation locator failures; unrepresented input items; true conflicts found and
  false alerts; repeated entry; assistance requests; difficulty and confidence (1–7, one reason); actual AI cost.
- Unmeasured values are null with a status, never zero.

## 7. Completion rubric and quality gate (fixed)

A submission passes only if, by two independent qualified human reviewers (a third resolves disagreement):
1. every material assertion is supported by its cited passage with context and attribution;
2. every indispensable fact named in the task's rubric is present, with contrary evidence and stated limitations;
3. no critical error: a misattribution that accuses someone, an invented material transaction, an unsafe disclosure, a
   conflation of people/transactions/dates, or a dropped decisive qualification — any one fails the submission;
4. allegations, hypotheses and findings stay distinguishable;
5. a recipient can resolve the references from the handed-over material;
6. nothing from another case or a prohibited source appears.
Rubrics (indispensable facts, critical errors) are written with a practitioner and hashed before the first session; they
are kept out of the app, its indexes and the operator's context during runs.

## 8. Time-outs, errors and exclusions (fixed)

- At L the submission is taken as it is; no repair after the timer stops. A crash, abandonment or wrong early answer
  scores L. A repaired follow-up is a separate record.
- Product failures (crash, silent omission, wrong attribution, cross-case exposure, unauthorised send) are results,
  never exclusions. They also stop the study for repair: the repaired build is a new candidate and repeats the affected
  sessions; old-build sessions are not pooled.
- The only exclusions: participant withdrew consent; a laboratory interruption outside the product (power, room) longer
  than 5 minutes, logged at the time. Every exclusion is published with its reason.
- AI provider outages and spending limits are recorded outcomes; the mode is never switched silently.

## 9. Decision thresholds (fixed)

| Gate | Pass rule |
|---|---|
| Technical integrity | The repository's release gates and the case journeys pass on the candidate; no open blocking fidelity, scope, privacy, persistence or export defect. |
| Formative usability | ≥ 4 of 5 pilot users finish the sample without live coaching. |
| Human time benefit | Median paired capped-time saving ≥ 30 % against the normal workflow, with the 95 % interval's lower bound above 0 and no lower completion or quality. |
| Specialist comparison | Median saving ≥ 20 %, only when that comparator and a suitable task were actually tested. |
| Work-product quality | The §7 gate passes at a rate no lower than the baseline arm; critical errors no more frequent. |
| AI accuracy | The existing ≤ 1 % wrong gate, with its accepted definition and denominators, per mode and family. |

## 10. Conclusions allowed

Exactly one of: (1) technical tests passed, human benefit unmeasured; (2) benefit observed for the tested workflows (with
the estimate, interval and scope); (3) comparison inconclusive (what is missing); (4) target not met (where). Claim
wording names population, task family, condition and comparator. An agent-operated run is labelled "agent-operated
benchmark" and never counted as participants or reviewers.

## Amendment log

| Date | Who | What changed | Why | New SHA-256 |
|---|---|---|---|---|
| 2026-11-12 | agent (S14) | Frozen v1 from the 2026-11-04 proposal; L fixed at 60 min per task; bootstrap interval named; exclusion list closed. | BENEFIT-01: rules fixed before any run. | see PROTOCOL.sha256 |
