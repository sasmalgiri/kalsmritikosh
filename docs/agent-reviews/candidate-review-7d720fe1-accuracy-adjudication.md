# AGENT REVIEW — accuracy adjudication for candidate 7d720fe1 (not a human adjudicator; owner decision 2026-11-01)

- **Reviewer:** a Claude agent, recording the accuracy position of this candidate. It does not measure anything new.
- **Date:** 2026-11-04
- **Candidate:** `7d720fe1b0dbd7a2af6c24f7cc3d168da37498b0`
- **Owner decision (2026-11-04):** no paid live testing; simulation only. The ≤ 3 % wrong bar (`ci/release-gates.json`,
  `accuracy-adjudication`) is therefore **not measured** on this candidate. The question for this record is whether
  shipping without a live measurement can be accepted *as disclosed*. The owner's condition: only if the public texts make no
  accuracy claim.

## 1. Accuracy was NOT measured live on this candidate

No answering path of `7d720fe1` was run against real or held-out documents with a real model. The answer path changed
after every measurement below: the whole-case reader and consent once per case in `7bb6323b`, case analysis on the whole
case in `b66cf7a9`, and the simulation-found fixes in `c30d2191` / `7d720fe1`. The simulations (`PlanJourneySimulationTests`,
`CaseWholeReadingTests`) use a fake Anthropic API. They test plumbing, billing and consent, not the correctness of answers.

## 2. The last measured results (earlier code)

| Measurement | Code | Result | Status |
|---|---|---|---|
| Held-out bench **ho22-chron** (60 fresh public DOJ prosecutions, 928 questions per path, AGENT adjudication) — rules path | `e49783fd` | **0.00 %** wrong (blinded sample of 100 + all 30 flagged; 95 % one-sided upper bound 2.85 %); wrong + missed 0.86 %; wrong + partly 5.70 % | ≤ 3 % met **there**; sample estimate, not a census (`accuracy-adjudication-ho22-rules.md`) |
| ho22-chron — Opus 5 path (own key, verified reading) | `e49783fd` | **0.22 %** wrong (2 / 928, full check); wrong + missed 1.08 %; wrong + partly 6.68 % | ≤ 3 % met **there** (`accuracy-adjudication-ho22-opus5.md`) |
| Real solved cases, round 1, arm 3 "Opus 5 everywhere" (5 cases, 81 questions, AGENT judge) | `14e0708b` | **44.4 %** correct per question (C + RC), 32.1 % partly, 9.9 % wrong, **2.5 wrong at normal confidence per 100 questions**; contradictions 13 real / 9 false; key facts 44 / 65 | **Not a pass.** The cases are the ones the fixes were tuned on, so this is a regression check, not an independent measure. The six new cases are incomplete (bench key out of credit) (`real-case-old-six-ai-comparison-2026-11-04.md`, `real-case-v2-interim-2026-11-04.md`) |
| Whole-case reader (`7bb6323b` onwards) | — | **never evaluated on any real or held-out case** | — |

ho22 measures DOJ prosecution releases, a material much easier than real case files. The real-case figures are far below
both the ≤ 3 % wrong bar and the owner's own plan-A pass bar (≥ 90 % correct, ≤ 1 confident-wrong per 100). Neither set
describes this candidate.

## 3. Do the public texts make an accuracy claim? (verified)

**No accuracy figure appears anywhere public.** I checked `docs/index.html`, `docs/for/*.html`, `docs/support.html`,
`docs/privacy.html`, `docs/terms.html`, `release/APP_STORE_LISTING.md` (description, promotional text, What's New, review
notes, IAP text), `Core/LegalNotice.swift` and `UI/Help/HelpRegistry.swift` for percentages and accuracy wording. The FAQ
says "Accuracy has not been measured on this version of the app … no accuracy figure is claimed here"
(`docs/index.html:485`), and so does `docs/support.html:81`. Terms §3 says "There is no guarantee of accuracy". The listing
says "AI output can be incomplete or wrong". `docs/ACCURACY.md` opens with "Not measured on this version".

**But there are qualitative accuracy claims, and the last measurements contradict them.** Each one says, without
qualification, that the product does not guess or invent:

| Where | Text |
|---|---|
| App Store description (metadata, Guideline 2.3) — `release/APP_STORE_LISTING.md:51` | "When the evidence isn't there, it tells you honestly instead of guessing." |
| Marketing URL — `docs/index.html:199` | "If your documents don't say it, the answer says so — it won't guess." |
| `docs/index.html:234` | "…stays entirely on your Mac and refuses to guess — every answer tied to the exact evidence, so you can hand it the work you can't get wrong" |
| `docs/index.html:265` | "It won't guess — It won't guess about your documents." |
| `docs/index.html:414` | "Built for people who can't afford to be wrong" |
| In-app Help — `UI/Help/HelpRegistry.swift:159` | "When the documents do not support an answer the app says so instead of guessing." |

The last real-case run had 9.9 % wrong answers and 2.5 per 100 stated at normal confidence: statements the documents
did not support, shown as answers. The whole-case reader can also reply "The case's documents don't say" when it is only
the verifier's result (practitioner PB1). "It won't guess" / "instead of guessing" is therefore an accuracy claim that no
measurement of this candidate supports and the last real-case measurement contradicts. On the Marketing URL and in the App
Store description it also falls under 2.3 (accurate metadata). The rules-only "nothing invented"
(`docs/index.html:303`, Lightning column) and the registered "Every AI statement is checked against the exact source line
it cites" (it says checked, not correct) are acceptable.

## 4. Decision

**NOT APPROVED.** The owner's condition, that the public texts make no accuracy claims, is not met: the six sentences
above claim the product does not guess. Accepting a release with no live measurement is defensible only when nothing
public implies a level of accuracy. Here the App Store description and the marketing page do.

**To turn this into ACCEPTED** (owner decision to ship without a live measurement, accepted by AGENT review as disclosed),
on a new candidate commit:

1. Replace the six sentences with claims about behaviour, not outcomes. For example: "Every AI statement is checked
   against the source line it cites, and statements that cannot be matched are left out. Answers can still be incomplete
   or wrong — check the cited source." Drop "can't afford to be wrong" or qualify it.
2. Keep the FAQ / support / ACCURACY.md "not measured on this version" text as it is.
3. Fix practitioner PB1 so the app does not state an unverified negative as a fact.
4. Re-run the `claims` gate and re-issue this record for the new commit.

**Separate from this decision, for the record:**
- The gate title requires an "independent adjudication of a fresh held-out set on frozen code; ≤3 % wrong per mode and
  family". An ACCEPTED record would be a *waiver* of that, not a pass. It must say so in its Notes, as the owner's
  checklist asks (`release/OWNER_LAUNCH_CHECKLIST.md:127-130`).
- `ci/release-gates.json` (`accuracy-adjudication.owner_decision_2026_11_04`) says this gate "closes only by the owner's
  own record; the agent never writes it". The owner's general decision of 2026-11-01 says agent reviews replace human
  gates. These two instructions conflict. This agent record is NOT APPROVED, so it closes nothing either way. Before an
  ACCEPTED record is written, the owner should confirm which instruction governs this gate (or countersign).
